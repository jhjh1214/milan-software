"""Background recognition jobs. Sep 2026, once the office actually wanted to
upload a floor plan and walk away rather than sit watching a locally hosted
model think for several minutes.

See `RecognitionJob`'s own docstring (`app/models/db.py`) for why this is a
row and a `BackgroundTasks` call rather than a queue: SPEC.md §14.7 already
named this exact shape ("a status a client polls") as the lightweight
pattern to reach for before infrastructure this system does not otherwise
run is ever justified.

`POST /api/recognize` (stateless, `app/services/recognition.py`) is
unchanged and stays the fast path: a handset trying recognition on its own
photo, or the dashboard re-checking an already-fetched image, both still
get an answer inline and neither needs a floor plan id to exist first. This
module is the second path, for the one place recognition has a floor plan
id already and can afford to wait: after an admin's own upload.
"""

from __future__ import annotations

import dataclasses
import logging
import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import session_scope
from ..models.db import FloorPlan, RecognitionJob
from .recognition import get_recognition_provider

logger = logging.getLogger(__name__)


class NoSuchFloorPlan(Exception):
    pass


def start_recognition_job(
    session: Session, floor_plan_id: str, *, requested_by_user_id: str | None
) -> RecognitionJob:
    """Creates the pending row and nothing else -- the actual provider call
    happens in `run_recognition_job`, off this request's own session and
    thread, so the route can answer immediately and let the caller leave.

    Idempotent on an already-pending job: a double click before the button's
    own disabled state catches up, or a client retrying a slow response,
    hands back the same row rather than firing a second call at whatever
    provider is configured -- worth avoiding on its own even before a paid
    vendor makes it a cost question too.
    """
    plan = session.get(FloorPlan, floor_plan_id)
    if plan is None or plan.image_data is None:
        raise NoSuchFloorPlan(floor_plan_id)

    existing = latest_recognition_job(session, floor_plan_id)
    if existing is not None and existing.status == "pending":
        return existing

    job = RecognitionJob(
        id=str(uuid.uuid4()),
        floor_plan_id=floor_plan_id,
        status="pending",
        openings=[],
        rooms=[],
        requested_by_user_id=requested_by_user_id,
    )
    session.add(job)
    session.flush()
    return job


def run_recognition_job(job_id: str) -> None:
    """The actual work. Runs after the request that started it has already
    answered (FastAPI's `BackgroundTasks`, dispatched to a worker thread --
    it does not block the event loop the rest of the API serves from), so
    it opens its own session rather than reusing the request's, which is
    already closed by the time this runs.

    Never lets a provider's own exception escape -- every registered
    provider already promises not to raise (SPEC.md §14.7's reliability
    posture), but this is the same "do not trust the caller's gating to be
    the only enforcement" reasoning `recordMeasurement` already follows:
    a future provider breaking that promise fails this one job, not the
    background thread pool.
    """
    with session_scope() as session:
        job = session.get(RecognitionJob, job_id)
        if job is None:
            return

        plan = session.get(FloorPlan, job.floor_plan_id)
        if plan is None or plan.image_data is None:
            job.status = "failed"
            job.note = "the floor plan's image is no longer available"
            job.completed_at = datetime.now(UTC)
            return

        try:
            result = get_recognition_provider().extract(
                image_data=plan.image_data, content_type=plan.content_type or ""
            )
        except Exception as exc:
            logger.warning("recognition job %s failed: %s", job_id, exc)
            job.status = "failed"
            job.note = str(exc)
            job.completed_at = datetime.now(UTC)
            return

        job.status = "done"
        job.provider = result.provider
        job.configured = result.configured
        job.openings = [dataclasses.asdict(o) for o in result.openings]
        job.rooms = [dataclasses.asdict(r) for r in result.rooms]
        job.note = result.note
        job.completed_at = datetime.now(UTC)


def latest_recognition_job(
    session: Session, floor_plan_id: str
) -> RecognitionJob | None:
    """The most recent attempt, or None if recognition was never asked for
    on this floor plan. A retry is a new row (see the model's own
    docstring), so "latest" is always the one worth showing."""
    return session.scalars(
        select(RecognitionJob)
        .where(RecognitionJob.floor_plan_id == floor_plan_id)
        .order_by(RecognitionJob.created_at.desc())
    ).first()
