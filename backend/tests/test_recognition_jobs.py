"""Background recognition jobs. See `RecognitionJob`'s own docstring
(`app/models/db.py`) for why this exists and why it is a row, not a queue.

`run_recognition_job` opens its own session via `app.db.session_scope`,
deliberately -- production runs it from a FastAPI `BackgroundTasks`
callback, after the request's own session has already closed. These tests
point `app.db`'s module-level session factory at the same StaticPool engine
the rest of the file uses, so that session sees what a test set up.
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, datetime

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app import db as db_module
from app.models.db import Base, RecognitionJob
from app.services.library import create_project, create_unit_type, upload_floor_plan
from app.services.recognition import ExtractionResult, ProposedOpening, ProposedRoom
from app.services.recognition_jobs import (
    NoSuchFloorPlan,
    latest_recognition_job,
    run_recognition_job,
    start_recognition_job,
)


@pytest.fixture
def db(monkeypatch) -> Iterator[sessionmaker[Session]]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)

    # run_recognition_job reaches the database through app.db.session_scope,
    # which reads these module globals -- point them at this test's own
    # engine so the background job's session sees what the test set up.
    monkeypatch.setattr(db_module, "_Session", factory)
    monkeypatch.setattr(db_module, "_engine", engine)

    yield factory
    engine.dispose()


def _a_floor_plan(session: Session) -> str:
    project = create_project(session, name="ABC Development")
    session.commit()
    unit_type = create_unit_type(
        session, project_id=project.id, name="Type B", created_by_user_id="admin-1"
    )
    session.commit()
    plan = upload_floor_plan(
        session,
        unit_type.id,
        filename="type-b.jpg",
        content_type="image/jpeg",
        image_data=b"\xff\xd8\xff fake jpeg bytes",
        uploaded_by_user_id="admin-1",
    )
    session.commit()
    return plan.id


class TestStartRecognitionJob:
    def test_creates_a_pending_row(self, db) -> None:
        with db() as session:
            floor_plan_id = _a_floor_plan(session)
            job = start_recognition_job(
                session, floor_plan_id, requested_by_user_id="admin-1"
            )
            session.commit()

            assert job.status == "pending"
            assert job.floor_plan_id == floor_plan_id
            assert job.openings == []
            assert job.rooms == []

    def test_an_unknown_floor_plan_raises(self, db) -> None:
        with db() as session, pytest.raises(NoSuchFloorPlan):
            start_recognition_job(
                session, "not-a-real-id", requested_by_user_id="admin-1"
            )

    def test_a_floor_plan_with_no_image_data_raises(self, db) -> None:
        with db() as session:
            project = create_project(session, name="ABC")
            session.commit()
            unit_type = create_unit_type(
                session, project_id=project.id, name="Type C", created_by_user_id="a"
            )
            session.commit()
            # No upload_floor_plan call -- no floor plan row exists at all,
            # which is the same "nothing to recognise yet" case.
            with pytest.raises(NoSuchFloorPlan):
                start_recognition_job(
                    session, unit_type.id, requested_by_user_id="admin-1"
                )


class TestRunRecognitionJob:
    def test_the_null_provider_produces_a_done_job_with_nothing_found(
        self, db, monkeypatch
    ) -> None:
        monkeypatch.delenv("RECOGNITION_PROVIDER", raising=False)
        with db() as session:
            floor_plan_id = _a_floor_plan(session)
            job = start_recognition_job(
                session, floor_plan_id, requested_by_user_id="admin-1"
            )
            session.commit()
            job_id = job.id

        run_recognition_job(job_id)

        with db() as session:
            done = session.get(RecognitionJob, job_id)
            assert done.status == "done"
            assert done.configured is False
            assert done.provider == "none"
            assert done.openings == []
            assert done.rooms == []
            assert done.completed_at is not None

    def test_a_configured_providers_result_is_stored(self, db, monkeypatch) -> None:
        result = ExtractionResult(
            configured=True,
            provider="anthropic",
            openings=[
                ProposedOpening(
                    label="W1",
                    room="Living",
                    nominal_w_tmm=12000,
                    nominal_h_tmm=15000,
                    confidence=0.9,
                    suggested_track_w_tmm=13500,
                    suggested_drop_h_tmm=None,
                )
            ],
            rooms=[
                ProposedRoom(name="Living", nominal_area_mm2=12_000_000, confidence=0.8)
            ],
        )

        class _FakeProvider:
            def extract(self, *, image_data, content_type):
                return result

        monkeypatch.setattr(
            "app.services.recognition_jobs.get_recognition_provider",
            lambda: _FakeProvider(),
        )

        with db() as session:
            floor_plan_id = _a_floor_plan(session)
            job = start_recognition_job(
                session, floor_plan_id, requested_by_user_id="admin-1"
            )
            session.commit()
            job_id = job.id

        run_recognition_job(job_id)

        with db() as session:
            done = session.get(RecognitionJob, job_id)
            assert done.status == "done"
            assert done.configured is True
            assert done.provider == "anthropic"
            assert done.openings[0]["label"] == "W1"
            assert done.openings[0]["suggested_track_w_tmm"] == 13500
            assert done.openings[0]["suggested_drop_h_tmm"] is None
            assert done.rooms[0]["name"] == "Living"

    def test_a_provider_exception_fails_the_job_not_the_process(
        self, db, monkeypatch
    ) -> None:
        class _BrokenProvider:
            def extract(self, *, image_data, content_type):
                raise RuntimeError("boom")

        monkeypatch.setattr(
            "app.services.recognition_jobs.get_recognition_provider",
            lambda: _BrokenProvider(),
        )

        with db() as session:
            floor_plan_id = _a_floor_plan(session)
            job = start_recognition_job(
                session, floor_plan_id, requested_by_user_id="admin-1"
            )
            session.commit()
            job_id = job.id

        run_recognition_job(job_id)  # must not raise

        with db() as session:
            failed = session.get(RecognitionJob, job_id)
            assert failed.status == "failed"
            assert "boom" in failed.note

    def test_an_unknown_job_id_is_a_quiet_no_op(self, db) -> None:
        run_recognition_job("not-a-real-job-id")  # must not raise


class TestLatestRecognitionJob:
    def test_none_when_never_asked_for(self, db) -> None:
        with db() as session:
            floor_plan_id = _a_floor_plan(session)
            assert latest_recognition_job(session, floor_plan_id) is None

    def test_the_most_recent_of_several_attempts_wins(self, db) -> None:
        # Explicit, clearly-ordered timestamps: two jobs started within the
        # same real second (server_default=func.now(), second-resolution on
        # SQLite) would otherwise make "most recent" a coin flip.
        with db() as session:
            floor_plan_id = _a_floor_plan(session)
            first = start_recognition_job(
                session, floor_plan_id, requested_by_user_id="admin-1"
            )
            first.created_at = datetime(2026, 1, 1, tzinfo=UTC)
            session.commit()

            second = start_recognition_job(
                session, floor_plan_id, requested_by_user_id="admin-1"
            )
            second.created_at = datetime(2026, 1, 2, tzinfo=UTC)
            session.commit()

            latest = latest_recognition_job(session, floor_plan_id)
            assert latest.id == second.id
            assert latest.id != first.id
