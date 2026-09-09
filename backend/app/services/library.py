"""The Property / Project / Unit Library. SPEC.md Phase 8.

    Development -> Unit Type -> verified stored measurements -> quotation

A salesperson hears "ABC Development, Type B", picks the development, picks
the unit type, and the known windows, rooms and skirting runs load. This
module is what makes that fast from the second customer onward -- **never**
from the first, and never by reading the uploaded plan image. The numbers a
quote is built from are typed once from the developer's schedule by someone
who can check them; the plan is a backdrop for tapping, not a ruler.

## Reference measurements are NOT site measurements

Nothing here ever touches an order directly. A plan-sourced line is a
better-informed estimate, and it reaches production only through the same
site visit every other line takes -- this module has no opinion about orders
at all, only about what a quote can start from.

## Two routes in, one gate

    ADMIN         upload -> draft -> verify -> approved -> library
    PART-TIMER    submit -> pending_review -> admin verifies / corrects
                          -> approved -> library
                          -> or rejected, with a reason

A part-timer's submission is never searchable or quotable until an admin has
approved it. Approval and rejection are both audited with the reviewer's
name (§6.7) -- see `UnitTypeVersion.approved_*` / `rejected_*`.

Pure of HTTP. The router calls this; the tests call it directly.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from ..models.db import FloorPlan, Opening, Project, Room, UnitType, UnitTypeVersion

#: A unit type's own lifecycle stage. `superseded` is reserved -- nothing in
#: this module sets it yet; see SPEC.md §13, this phase's open question about
#: what it would even mean given versioning already handles "the plan
#: changed" without retiring the unit type itself.
STATUSES = ("draft", "pending_review", "approved", "superseded")


class NoSuchProject(Exception):
    pass


class NoSuchUnitType(Exception):
    pass


class WrongStatus(Exception):
    """The unit type is not in the status this action requires."""


@dataclass(frozen=True)
class OpeningIn:
    label: str
    room: str
    nominal_w_tmm: int
    nominal_h_tmm: int
    floor: int | None = None
    sort_order: int = 0


@dataclass(frozen=True)
class RoomIn:
    name: str
    nominal_area_mm2: int
    floor: int | None = None
    skirting_run_tmm: int | None = None


@dataclass(frozen=True)
class FloorPlanIn:
    file_ref: str
    #: "12/1" style rational string, or None until an admin calibrates it.
    scale_tmm_per_px: str | None = None


def create_project(
    session: Session,
    *,
    name: str,
    developer: str | None = None,
    area: str | None = None,
) -> Project:
    """A development, so its unit types have somewhere to live.

    No dedupe against an existing project of the same name -- the same
    discipline the rest of this app leaves to whoever is typing (a phone
    number is the one field this codebase enforces unique, because it is the
    login identifier; a development's name is not).
    """
    project = Project(id=str(uuid.uuid4()), name=name, developer=developer, area=area)
    session.add(project)
    session.flush()
    return project


def search_projects(session: Session, *, query: str | None = None) -> list[Project]:
    """What a salesperson finds by typing an area or a development name."""
    stmt = select(Project).order_by(Project.name)
    if query:
        like = f"%{query}%"
        stmt = stmt.where((Project.name.ilike(like)) | (Project.area.ilike(like)))
    return list(session.scalars(stmt))


def create_unit_type(
    session: Session,
    *,
    project_id: str,
    name: str,
    created_by_user_id: str | None,
    floor_count: int | None = None,
    variant_of: str | None = None,
    openings: list[OpeningIn] = (),  # type: ignore[assignment]
    rooms: list[RoomIn] = (),  # type: ignore[assignment]
    floor_plan: FloorPlanIn | None = None,
    submit: bool = False,
) -> UnitType:
    """A floor plan, digitised once.

    Starts as `draft` -- even an admin's own upload passes through draft
    before it is verified and approved, per the workflow diagram above.
    `submit=True` is the part-timer's one-shot path: their submission goes
    straight to `pending_review` in the same call, because "submit" is the
    only action they take -- there is no separate draft stage for them to
    come back to.
    """
    if session.get(Project, project_id) is None:
        raise NoSuchProject(project_id)

    unit_type = UnitType(
        id=str(uuid.uuid4()),
        project_id=project_id,
        name=name,
        floor_count=floor_count,
        variant_of=variant_of,
        status="pending_review" if submit else "draft",
        created_by_user_id=created_by_user_id,
    )
    session.add(unit_type)

    version = UnitTypeVersion(
        id=str(uuid.uuid4()),
        unit_type_id=unit_type.id,
        version=1,
        created_by_user_id=created_by_user_id,
    )
    session.add(version)
    _attach_version_contents(
        session, version, openings, rooms, floor_plan, created_by_user_id
    )

    session.flush()
    return unit_type


def add_corrected_version(
    session: Session,
    unit_type_id: str,
    *,
    created_by_user_id: str | None,
    openings: list[OpeningIn] = (),  # type: ignore[assignment]
    rooms: list[RoomIn] = (),  # type: ignore[assignment]
    floor_plan: FloorPlanIn | None = None,
    note: str | None = None,
) -> UnitTypeVersion:
    """The plan changed. A new version, never an edit to the old one --
    `unit_type_versions` is never updated in place, the same rule as a rate
    card and for the same reason: an order that instantiated from version 1
    must stay explainable after version 2 exists.

    Sends the type back to `draft`: a new version is unreviewed by
    definition, whatever the type's previous status was.
    """
    unit_type = session.get(UnitType, unit_type_id)
    if unit_type is None:
        raise NoSuchUnitType(unit_type_id)

    latest = _latest_version(session, unit_type_id)
    next_number = (latest.version + 1) if latest is not None else 1

    version = UnitTypeVersion(
        id=str(uuid.uuid4()),
        unit_type_id=unit_type_id,
        version=next_number,
        created_by_user_id=created_by_user_id,
        note=note,
    )
    session.add(version)
    _attach_version_contents(
        session, version, openings, rooms, floor_plan, created_by_user_id
    )

    unit_type.status = "draft"
    unit_type.updated_at = datetime.now(UTC)
    session.flush()
    return version


def submit_for_review(session: Session, unit_type_id: str) -> UnitType:
    """The part-timer path: `draft` -> `pending_review`."""
    unit_type = session.get(UnitType, unit_type_id)
    if unit_type is None:
        raise NoSuchUnitType(unit_type_id)
    if unit_type.status != "draft":
        raise WrongStatus(f'"{unit_type_id}" is {unit_type.status}, not draft')

    unit_type.status = "pending_review"
    unit_type.updated_at = datetime.now(UTC)
    session.flush()
    return unit_type


def approve_unit_type(
    session: Session, unit_type_id: str, *, by_user_id: str
) -> UnitType:
    """Makes the latest version live in the library. Admin-only -- enforced
    by the route (`AdminDep`), not here, the same split every other admin
    action in this codebase already keeps.

    Accepts `draft` as well as `pending_review`: an admin's own upload never
    passes through `pending_review` at all (see the workflow diagram).
    """
    unit_type = session.get(UnitType, unit_type_id)
    if unit_type is None:
        raise NoSuchUnitType(unit_type_id)
    if unit_type.status not in ("draft", "pending_review"):
        raise WrongStatus(f'"{unit_type_id}" is {unit_type.status}')

    version = _latest_version(session, unit_type_id)
    assert version is not None  # every unit type is created with one

    version.approved_by_user_id = by_user_id
    version.approved_at = datetime.now(UTC)
    unit_type.status = "approved"
    unit_type.updated_at = datetime.now(UTC)
    session.flush()
    return unit_type


def reject_unit_type(
    session: Session, unit_type_id: str, *, by_user_id: str, reason: str
) -> UnitType:
    """A part-timer's submission, sent back. Admin-only, same split as above.

    Reverts the type to `draft` rather than leaving it stuck in
    `pending_review` -- the flagged assumption in SPEC.md §13: the status
    enum names no separate "rejected" state, and `draft` is what lets the
    same unit type be corrected and resubmitted. The rejected version itself
    is kept, never edited or deleted, with the reviewer's name and reason on
    it -- §6.7's audit requirement applies to a "no" exactly as much as a
    "yes".
    """
    unit_type = session.get(UnitType, unit_type_id)
    if unit_type is None:
        raise NoSuchUnitType(unit_type_id)
    if unit_type.status != "pending_review":
        raise WrongStatus(f'"{unit_type_id}" is {unit_type.status}, not pending_review')

    version = _latest_version(session, unit_type_id)
    assert version is not None

    version.rejected_by_user_id = by_user_id
    version.rejected_at = datetime.now(UTC)
    version.rejection_reason = reason
    unit_type.status = "draft"
    unit_type.updated_at = datetime.now(UTC)
    session.flush()
    return unit_type


def unit_type_detail(session: Session, unit_type_id: str) -> UnitType | None:
    """One unit type with every version, opening, room and floor plan
    loaded -- the office reads the whole history, not just the latest.
    """
    stmt = (
        select(UnitType)
        .where(UnitType.id == unit_type_id)
        .options(
            selectinload(UnitType.project),
            selectinload(UnitType.versions).selectinload(UnitTypeVersion.openings),
            selectinload(UnitType.versions).selectinload(UnitTypeVersion.rooms),
            selectinload(UnitType.versions).selectinload(UnitTypeVersion.floor_plan),
        )
    )
    return session.scalars(stmt).first()


def approved_version(unit_type: UnitType) -> UnitTypeVersion | None:
    """What a quote may actually start from. `None` until one exists --
    a draft or pending submission is not searchable or quotable, by design.
    """
    approved = [v for v in unit_type.versions if v.approved_at is not None]
    return max(approved, key=lambda v: v.version) if approved else None


def list_unit_types(
    session: Session, *, project_id: str | None = None, status: str | None = None
) -> list[UnitType]:
    """Everything, or filtered to one project or one status.

    Eager-loads the project and every version's openings/rooms/floor plan --
    the one screen this feeds today is the admin review queue, which needs
    the submission's actual content to review it, and that queue is always
    small: a handful of pending unit types, never hundreds of orders.
    """
    stmt = (
        select(UnitType)
        .order_by(UnitType.name)
        .options(
            selectinload(UnitType.project),
            selectinload(UnitType.versions).selectinload(UnitTypeVersion.openings),
            selectinload(UnitType.versions).selectinload(UnitTypeVersion.rooms),
            selectinload(UnitType.versions).selectinload(UnitTypeVersion.floor_plan),
        )
    )
    if project_id:
        stmt = stmt.where(UnitType.project_id == project_id)
    if status:
        stmt = stmt.where(UnitType.status == status)
    return list(session.scalars(stmt))


def _latest_version(session: Session, unit_type_id: str) -> UnitTypeVersion | None:
    stmt = (
        select(UnitTypeVersion)
        .where(UnitTypeVersion.unit_type_id == unit_type_id)
        .order_by(UnitTypeVersion.version.desc())
        .limit(1)
    )
    return session.scalars(stmt).first()


def _attach_version_contents(
    session: Session,
    version: UnitTypeVersion,
    openings: list[OpeningIn],
    rooms: list[RoomIn],
    floor_plan: FloorPlanIn | None,
    uploaded_by_user_id: str | None,
) -> None:
    for o in openings:
        session.add(
            Opening(
                id=str(uuid.uuid4()),
                unit_type_version_id=version.id,
                label=o.label,
                room=o.room,
                floor=o.floor,
                nominal_w_tmm=o.nominal_w_tmm,
                nominal_h_tmm=o.nominal_h_tmm,
                sort_order=o.sort_order,
            )
        )
    for r in rooms:
        session.add(
            Room(
                id=str(uuid.uuid4()),
                unit_type_version_id=version.id,
                name=r.name,
                floor=r.floor,
                nominal_area_mm2=r.nominal_area_mm2,
                skirting_run_tmm=r.skirting_run_tmm,
            )
        )
    if floor_plan is not None:
        session.add(
            FloorPlan(
                id=str(uuid.uuid4()),
                unit_type_version_id=version.id,
                file_ref=floor_plan.file_ref,
                scale_tmm_per_px=floor_plan.scale_tmm_per_px,
                uploaded_by_user_id=uploaded_by_user_id,
            )
        )
