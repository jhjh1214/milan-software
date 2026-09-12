"""The Property / Project / Unit Library. SPEC.md Phase 8.

Two things carry the weight here.

**Reference measurements are not site measurements** -- nothing in this file
touches an order; it is entirely about what a quote may start from.

And the **two-step gate**: a part-timer's submission is never approved by
the same action that created it, and both an approval and a rejection leave
the reviewer's name on the version they acted on.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.models.db import Base
from app.services.library import (
    FloorPlanIn,
    NoSuchFloorPlan,
    NoSuchProject,
    NoSuchUnitType,
    OpeningIn,
    RoomIn,
    WrongStatus,
    add_corrected_version,
    approve_unit_type,
    approved_version,
    calibrate_floor_plan,
    create_project,
    create_unit_type,
    list_unit_types,
    reject_unit_type,
    search_projects,
    submit_for_review,
    unit_type_detail,
    upload_floor_plan,
)


@pytest.fixture
def db() -> Iterator[sessionmaker[Session]]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield sessionmaker(bind=engine, expire_on_commit=False)
    engine.dispose()


OPENINGS = [
    OpeningIn(label="W1", room="Living", nominal_w_tmm=18000, nominal_h_tmm=24000),
    OpeningIn(label="W2", room="Bedroom 1", nominal_w_tmm=12000, nominal_h_tmm=24000),
]
ROOMS = [
    RoomIn(name="Living", nominal_area_mm2=18_000_000, skirting_run_tmm=140_000),
    RoomIn(name="Bedroom 1", nominal_area_mm2=10_000_000, skirting_run_tmm=90_000),
]


class TestProjects:
    def test_a_created_project_is_findable(self, db) -> None:
        with db() as session:
            create_project(session, name="ABC Development", area="Ayer Keroh")
            session.commit()

            found = search_projects(session, query="ayer")
            assert [p.name for p in found] == ["ABC Development"]

    def test_search_matches_the_name_too(self, db) -> None:
        with db() as session:
            create_project(session, name="ABC Development", area="Ayer Keroh")
            create_project(session, name="XYZ Residences", area="Bukit Beruang")
            session.commit()

            assert [p.name for p in search_projects(session, query="XYZ")] == [
                "XYZ Residences"
            ]

    def test_no_query_returns_everything(self, db) -> None:
        with db() as session:
            create_project(session, name="ABC Development")
            create_project(session, name="XYZ Residences")
            session.commit()

            assert len(search_projects(session)) == 2


class TestCreatingAUnitType:
    def test_it_starts_as_a_draft_with_version_one(self, db) -> None:
        with db() as session:
            project = create_project(session, name="ABC Development")
            session.commit()

            unit_type = create_unit_type(
                session,
                project_id=project.id,
                name="Type B",
                created_by_user_id="u1",
                openings=OPENINGS,
                rooms=ROOMS,
            )
            session.commit()

            assert unit_type.status == "draft"
            detail = unit_type_detail(session, unit_type.id)
            assert len(detail.versions) == 1
            assert detail.versions[0].version == 1
            assert {o.label for o in detail.versions[0].openings} == {"W1", "W2"}
            assert {r.name for r in detail.versions[0].rooms} == {
                "Living",
                "Bedroom 1",
            }

    def test_an_unknown_project_is_refused(self, db) -> None:
        with db() as session, pytest.raises(NoSuchProject):
            create_unit_type(
                session,
                project_id="not-a-real-id",
                name="Type B",
                created_by_user_id="u1",
            )

    def test_a_floor_plan_keeps_the_original_document(self, db) -> None:
        with db() as session:
            project = create_project(session, name="ABC Development")
            session.commit()

            unit_type = create_unit_type(
                session,
                project_id=project.id,
                name="Type B",
                created_by_user_id="u1",
                floor_plan=FloorPlanIn(file_ref="plans/abc-type-b.pdf"),
            )
            session.commit()

            detail = unit_type_detail(session, unit_type.id)
            plan = detail.versions[0].floor_plan
            assert plan.file_ref == "plans/abc-type-b.pdf"
            # Not calibrated yet -- null, not zero, which would be a real ratio.
            assert plan.scale_tmm_per_px is None

    def test_a_part_timers_one_shot_submission_skips_draft(self, db) -> None:
        # "submit" is the only action a part-timer takes -- there is no
        # separate draft stage for them to come back to.
        with db() as session:
            project = create_project(session, name="ABC Development")
            session.commit()

            unit_type = create_unit_type(
                session,
                project_id=project.id,
                name="Type B",
                created_by_user_id="parttimer-1",
                openings=OPENINGS,
                submit=True,
            )
            session.commit()

            assert unit_type.status == "pending_review"

    def test_a_variant_points_at_the_type_it_varies(self, db) -> None:
        with db() as session:
            project = create_project(session, name="ABC Development")
            session.commit()
            original = create_unit_type(
                session, project_id=project.id, name="Type A", created_by_user_id="u1"
            )
            session.commit()

            mirror = create_unit_type(
                session,
                project_id=project.id,
                name="Type A mirror",
                created_by_user_id="u1",
                variant_of=original.id,
            )
            session.commit()

            assert mirror.variant_of == original.id


class TestTheReviewGate:
    def _draft(self, session) -> str:
        project = create_project(session, name="ABC Development")
        session.commit()
        unit_type = create_unit_type(
            session,
            project_id=project.id,
            name="Type B",
            created_by_user_id="parttimer-1",
            openings=OPENINGS,
        )
        session.commit()
        return unit_type.id

    def test_submitting_moves_it_to_pending_review(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            submit_for_review(session, unit_type_id)
            session.commit()

            assert unit_type_detail(session, unit_type_id).status == "pending_review"

    def test_submitting_twice_is_refused(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            submit_for_review(session, unit_type_id)
            session.commit()

            with pytest.raises(WrongStatus):
                submit_for_review(session, unit_type_id)

    def test_an_admin_may_approve_straight_from_draft(self, db) -> None:
        # The admin's own upload path never passes through pending_review.
        with db() as session:
            unit_type_id = self._draft(session)
            approve_unit_type(session, unit_type_id, by_user_id="admin-1")
            session.commit()

            detail = unit_type_detail(session, unit_type_id)
            assert detail.status == "approved"
            assert detail.versions[0].approved_by_user_id == "admin-1"
            assert detail.versions[0].approved_at is not None

    def test_a_part_timers_submission_is_not_quotable_until_approved(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            submit_for_review(session, unit_type_id)
            session.commit()

            detail = unit_type_detail(session, unit_type_id)
            assert approved_version(detail) is None

            approve_unit_type(session, unit_type_id, by_user_id="admin-1")
            session.commit()

            detail = unit_type_detail(session, unit_type_id)
            assert approved_version(detail) is not None

    def test_rejecting_sends_it_back_to_draft_with_a_reason_on_record(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            submit_for_review(session, unit_type_id)
            session.commit()

            reject_unit_type(
                session,
                unit_type_id,
                by_user_id="admin-1",
                reason="Window 2 looks too wide -- please recheck the schedule",
            )
            session.commit()

            detail = unit_type_detail(session, unit_type_id)
            assert detail.status == "draft"
            version = detail.versions[0]
            assert version.rejected_by_user_id == "admin-1"
            assert version.rejected_at is not None
            assert "recheck" in version.rejection_reason
            # Never approved by the rejection.
            assert version.approved_at is None

    def test_rejecting_a_draft_that_was_never_submitted_is_refused(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            with pytest.raises(WrongStatus):
                reject_unit_type(
                    session, unit_type_id, by_user_id="admin-1", reason="no"
                )

    def test_approving_an_already_approved_type_is_refused(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            approve_unit_type(session, unit_type_id, by_user_id="admin-1")
            session.commit()

            with pytest.raises(WrongStatus):
                approve_unit_type(session, unit_type_id, by_user_id="admin-1")

    def test_an_unknown_unit_type_is_an_error_everywhere(self, db) -> None:
        with db() as session:
            with pytest.raises(NoSuchUnitType):
                submit_for_review(session, "not-a-real-id")
            with pytest.raises(NoSuchUnitType):
                approve_unit_type(session, "not-a-real-id", by_user_id="admin-1")
            with pytest.raises(NoSuchUnitType):
                reject_unit_type(
                    session, "not-a-real-id", by_user_id="admin-1", reason="x"
                )


class TestVersioning:
    def test_a_correction_is_a_new_version_not_an_edit(self, db) -> None:
        with db() as session:
            project = create_project(session, name="ABC Development")
            session.commit()
            unit_type = create_unit_type(
                session,
                project_id=project.id,
                name="Type B",
                created_by_user_id="admin-1",
                openings=OPENINGS,
            )
            approve_unit_type(session, unit_type.id, by_user_id="admin-1")
            session.commit()

            add_corrected_version(
                session,
                unit_type.id,
                created_by_user_id="admin-1",
                openings=[
                    OpeningIn(
                        label="W1",
                        room="Living",
                        nominal_w_tmm=19000,
                        nominal_h_tmm=24000,
                    )
                ],
                note="Developer revised the schedule",
            )
            session.commit()

            detail = unit_type_detail(session, unit_type.id)
            # Sent back for review -- a new version is unreviewed by
            # definition, whatever the type's previous status was.
            assert detail.status == "draft"
            assert len(detail.versions) == 2
            assert detail.versions[1].version == 2

    def test_an_order_pinned_to_version_one_stays_explainable_after_version_two(
        self, db
    ) -> None:
        # The point of versioning: approving version 2 must not retroactively
        # change what version 1 says.
        with db() as session:
            project = create_project(session, name="ABC Development")
            session.commit()
            unit_type = create_unit_type(
                session,
                project_id=project.id,
                name="Type B",
                created_by_user_id="admin-1",
            )
            approve_unit_type(session, unit_type.id, by_user_id="admin-1")
            session.commit()

            add_corrected_version(session, unit_type.id, created_by_user_id="admin-1")
            session.commit()

            detail = unit_type_detail(session, unit_type.id)
            v1, v2 = detail.versions
            assert v1.version == 1
            assert v1.approved_at is not None
            assert v2.approved_at is None
            # v1's own approval is untouched by v2 existing.
            assert v1.approved_by_user_id == "admin-1"


class TestListing:
    def test_filters_by_project_and_status(self, db) -> None:
        with db() as session:
            a = create_project(session, name="ABC Development")
            b = create_project(session, name="XYZ Residences")
            session.commit()

            create_unit_type(
                session, project_id=a.id, name="Type A", created_by_user_id="u1"
            )
            in_b = create_unit_type(
                session, project_id=b.id, name="Type Z", created_by_user_id="u1"
            )
            approve_unit_type(session, in_b.id, by_user_id="admin-1")
            session.commit()

            assert [u.name for u in list_unit_types(session, project_id=a.id)] == [
                "Type A"
            ]
            assert [u.name for u in list_unit_types(session, status="approved")] == [
                "Type Z"
            ]


class TestFloorPlanUpload:
    def _draft(self, session) -> str:
        project = create_project(session, name="ABC Development")
        session.commit()
        unit_type = create_unit_type(
            session, project_id=project.id, name="Type B", created_by_user_id="admin-1"
        )
        session.commit()
        return unit_type.id

    def test_the_image_and_who_uploaded_it_are_kept(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            upload_floor_plan(
                session,
                unit_type_id,
                filename="type-b.jpg",
                content_type="image/jpeg",
                image_data=b"\xff\xd8\xff fake jpeg bytes",
                uploaded_by_user_id="admin-1",
            )
            session.commit()

            detail = unit_type_detail(session, unit_type_id)
            plan = detail.versions[0].floor_plan
            assert plan.file_ref == "type-b.jpg"
            assert plan.content_type == "image/jpeg"
            assert plan.image_data == b"\xff\xd8\xff fake jpeg bytes"
            assert plan.uploaded_by_user_id == "admin-1"
            assert plan.scale_tmm_per_px is None

    def test_uploading_again_replaces_the_image_not_the_row(self, db) -> None:
        # One floor plan per version -- a second upload before approval is a
        # correction to the same draft, not a second document.
        with db() as session:
            unit_type_id = self._draft(session)
            first = upload_floor_plan(
                session,
                unit_type_id,
                filename="v1.jpg",
                content_type="image/jpeg",
                image_data=b"first",
                uploaded_by_user_id="admin-1",
            )
            session.commit()

            second = upload_floor_plan(
                session,
                unit_type_id,
                filename="v2.jpg",
                content_type="image/png",
                image_data=b"second",
                uploaded_by_user_id="admin-1",
            )
            session.commit()

            assert second.id == first.id
            detail = unit_type_detail(session, unit_type_id)
            assert len(detail.versions) == 1
            plan = detail.versions[0].floor_plan
            assert plan.file_ref == "v2.jpg"
            assert plan.image_data == b"second"

    def test_an_already_approved_version_refuses_a_new_image(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            approve_unit_type(session, unit_type_id, by_user_id="admin-1")
            session.commit()

            with pytest.raises(WrongStatus):
                upload_floor_plan(
                    session,
                    unit_type_id,
                    filename="v2.jpg",
                    content_type="image/jpeg",
                    image_data=b"data",
                    uploaded_by_user_id="admin-1",
                )

    def test_too_large_is_refused(self, db) -> None:
        with db() as session:
            unit_type_id = self._draft(session)
            with pytest.raises(ValueError):
                upload_floor_plan(
                    session,
                    unit_type_id,
                    filename="huge.jpg",
                    content_type="image/jpeg",
                    image_data=b"x" * (10 * 1024 * 1024 + 1),
                    uploaded_by_user_id="admin-1",
                )

    def test_an_unknown_unit_type_is_an_error(self, db) -> None:
        with db() as session, pytest.raises(NoSuchUnitType):
            upload_floor_plan(
                session,
                "not-a-real-id",
                filename="x.jpg",
                content_type="image/jpeg",
                image_data=b"x",
                uploaded_by_user_id="admin-1",
            )


class TestCalibration:
    def _floor_plan(self, session) -> tuple[str, str]:
        """Returns (unit_type_id, floor_plan_id)."""
        project = create_project(session, name="ABC Development")
        session.commit()
        unit_type = create_unit_type(
            session, project_id=project.id, name="Type B", created_by_user_id="admin-1"
        )
        session.commit()
        plan = upload_floor_plan(
            session,
            unit_type.id,
            filename="plan.jpg",
            content_type="image/jpeg",
            image_data=b"data",
            uploaded_by_user_id="admin-1",
        )
        session.commit()
        return unit_type.id, plan.id

    def _floor_plan_id(self, session) -> str:
        return self._floor_plan(session)[1]

    def test_the_scale_is_an_exact_rational(self, db) -> None:
        with db() as session:
            floor_plan_id = self._floor_plan_id(session)
            # A wall photographed as 500px, known from the schedule to be
            # 3000mm (30000 tenths) -- 30000/500 reduces to 60/1, printed as
            # a whole number the same way Fraction always does.
            plan = calibrate_floor_plan(
                session, floor_plan_id, pixel_distance=500, real_distance_tmm=30000
            )
            session.commit()
            assert plan.scale_tmm_per_px == "60"

    def test_a_ratio_that_does_not_reduce_to_a_whole_number_stays_exact(
        self, db
    ) -> None:
        with db() as session:
            floor_plan_id = self._floor_plan_id(session)
            plan = calibrate_floor_plan(
                session, floor_plan_id, pixel_distance=381, real_distance_tmm=4375
            )
            session.commit()
            assert plan.scale_tmm_per_px == "4375/381"

    def test_recalibrating_overwrites_the_old_scale(self, db) -> None:
        with db() as session:
            unit_type_id, floor_plan_id = self._floor_plan(session)
            calibrate_floor_plan(
                session, floor_plan_id, pixel_distance=500, real_distance_tmm=30000
            )
            session.commit()
            calibrate_floor_plan(
                session, floor_plan_id, pixel_distance=250, real_distance_tmm=30000
            )
            session.commit()

            detail = unit_type_detail(session, unit_type_id)
            assert detail.versions[0].floor_plan.scale_tmm_per_px == "120"

    def test_zero_pixels_is_refused_not_a_division_error(self, db) -> None:
        with db() as session:
            floor_plan_id = self._floor_plan_id(session)
            with pytest.raises(ValueError):
                calibrate_floor_plan(
                    session, floor_plan_id, pixel_distance=0, real_distance_tmm=30000
                )

    def test_an_unknown_floor_plan_is_an_error(self, db) -> None:
        with db() as session, pytest.raises(NoSuchFloorPlan):
            calibrate_floor_plan(
                session, "not-a-real-id", pixel_distance=100, real_distance_tmm=1000
            )
