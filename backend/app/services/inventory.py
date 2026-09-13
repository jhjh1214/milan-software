"""Inventory. SPEC.md Phase 9.

    materials -> stock_lots -> stock_movements (the ledger, append-only)
                             -> allocations (one order line's claim on stock)

Built once SPEC.md §13 F2 had a real answer -- a named person, the office's
own purchasing/supplier-ordering role -- because a ledger nobody is
accountable for drifts until nobody trusts the screen, which is worse than
no system at all. That is the whole reason this module exists rather than
a simpler running total.

## `qty_on_hand` is derived, never edited directly

Every function here that changes a lot's quantity does so by inserting a
`StockMovement` in the same breath -- `_record_movement` is the one place
that happens, so the ledger and the convenience column it maintains can
never drift apart from inside this module. Nothing else may write
`StockLot.qty_on_hand`.

## Two routes to an approved allocation, one gate

An auto-proposable material (§13 F3: only where the billed-quantity-to-
stock conversion is exact, today just an area-priced, box-counted material)
gets a `proposed` row from `propose_allocation_for_line`, called once, from
`push_measurement`. Everything else is created already decided, by an
admin, through `create_manual_allocation` -- there is no automatic guess to
review because none was made. Either way, only `approve_allocation` ever
moves stock; `propose_allocation_for_line`'s own proposal never does.

## Quantities are exact rationals

`qty_on_hand`, `delta`, `qty`, `coverage_per_unit` and `reorder_level` are
all stored as text and read through `fractions.Fraction` -- the same
convention `OrderLine.billed_qty` already uses. CLAUDE.md's arithmetic
invariant does not carve out an exception for a box count.
"""

from __future__ import annotations

import math
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from fractions import Fraction

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models.db import Allocation, Material, OrderLine, StockLot, StockMovement

STATUSES = ("proposed", "approved", "rejected", "released")
REASONS = (
    "receipt",
    "allocation",
    "release",
    "consumption",
    "offcut_return",
    "adjustment",
    "damage",
    "return_to_supplier",
)
#: Reasons a person may record directly through `adjust_stock`. `allocation`
#: and `release` are only ever written by `approve_allocation` /
#: `release_allocation`, which carry their own accounting; letting a free
#: adjustment claim either reason would let stock move against an order
#: with no `Allocation` row to explain it.
ADJUSTABLE_REASONS = (
    "receipt",
    "offcut_return",
    "adjustment",
    "damage",
    "return_to_supplier",
)


class NoSuchMaterial(Exception):
    pass


class NoSuchLot(Exception):
    pass


class NoSuchAllocation(Exception):
    pass


class WrongStatus(Exception):
    """The allocation is not in the status this action requires."""


class DuplicateMaterialCode(Exception):
    pass


def _parse_positive(value: str, name: str) -> Fraction:
    parsed = Fraction(value)
    if parsed <= 0:
        raise ValueError(f"{name} must be positive")
    return parsed


def _ceil_fraction(value: Fraction) -> Fraction:
    return Fraction(math.ceil(value))


def _record_movement(
    session: Session,
    lot: StockLot,
    *,
    delta: Fraction,
    reason: str,
    by_user_id: str,
    order_id: str | None = None,
    note: str | None = None,
    at: datetime | None = None,
) -> StockMovement:
    """The one place `qty_on_hand` ever changes. Refuses a movement that
    would take a lot negative -- a ledger cannot record taking out more
    than was ever put in.
    """
    new_qty = Fraction(lot.qty_on_hand) + delta
    if new_qty < 0:
        raise ValueError(f"movement would take lot {lot.id} negative")
    lot.qty_on_hand = str(new_qty)

    movement = StockMovement(
        id=str(uuid.uuid4()),
        material_id=lot.material_id,
        lot_id=lot.id,
        delta=str(delta),
        reason=reason,
        order_id=order_id,
        by_user_id=by_user_id,
        at=at or datetime.now(UTC),
        note=note,
    )
    session.add(movement)
    session.flush()
    return movement


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------


def create_material(
    session: Session,
    *,
    family: str,
    variant_compat: list[str],
    code: str,
    names: dict,
    uom: str,
    coverage_per_unit: str | None = None,
    reorder_level: str | None = None,
) -> Material:
    existing = session.scalars(select(Material).where(Material.code == code)).first()
    if existing is not None:
        raise DuplicateMaterialCode(code)

    material = Material(
        id=str(uuid.uuid4()),
        family=family,
        variant_compat=list(variant_compat),
        code=code,
        names=dict(names),
        uom=uom,
        coverage_per_unit=coverage_per_unit,
        reorder_level=reorder_level,
    )
    session.add(material)
    session.flush()
    return material


def list_materials(session: Session, *, active_only: bool = True) -> list[Material]:
    stmt = select(Material).order_by(Material.family, Material.code)
    if active_only:
        stmt = stmt.where(Material.is_active.is_(True))
    return list(session.scalars(stmt))


def deactivate_material(session: Session, material_id: str) -> Material:
    """Never deleted -- movements and allocations still name it. Matches
    every other "retire, never erase" rule in this codebase (a user, a rate
    card row).
    """
    material = session.get(Material, material_id)
    if material is None:
        raise NoSuchMaterial(material_id)
    material.is_active = False
    session.flush()
    return material


# ---------------------------------------------------------------------------
# Lots and the ledger
# ---------------------------------------------------------------------------


def receive_stock(
    session: Session,
    *,
    material_id: str,
    lot_ref: str,
    qty: str,
    by_user_id: str,
    cost_sen: int | None = None,
    location: str | None = None,
    received_at: datetime | None = None,
    note: str | None = None,
) -> StockLot:
    """A delivery. Re-using an existing `lot_ref` for this material tops it
    up in place -- a genuine top-up of one physical batch, e.g. a completed
    backorder; a **new** `lot_ref` is a new lot even for the identical
    material code, because "same code, different lot, visible colour
    difference" is the whole reason lots exist (SPEC.md §11 Phase 9).

    A top-up keeps the lot's original `received_at` and `cost_sen` --
    FIFO ordering reflects when the batch first arrived, and averaging cost
    across a top-up is real costing work explicitly out of v1 scope. A
    different price is a different `lot_ref`.
    """
    material = session.get(Material, material_id)
    if material is None:
        raise NoSuchMaterial(material_id)
    qty_frac = _parse_positive(qty, "qty")
    at = received_at or datetime.now(UTC)

    lot = session.scalars(
        select(StockLot).where(
            StockLot.material_id == material_id, StockLot.lot_ref == lot_ref
        )
    ).first()
    if lot is None:
        lot = StockLot(
            id=str(uuid.uuid4()),
            material_id=material_id,
            lot_ref=lot_ref,
            qty_on_hand="0",
            location=location,
            received_at=at,
            cost_sen=cost_sen,
        )
        session.add(lot)
        session.flush()

    _record_movement(
        session,
        lot,
        delta=qty_frac,
        reason="receipt",
        by_user_id=by_user_id,
        note=note,
        at=at,
    )
    return lot


def adjust_stock(
    session: Session,
    *,
    lot_id: str,
    delta: str,
    reason: str,
    by_user_id: str,
    note: str | None = None,
    at: datetime | None = None,
) -> StockMovement:
    """A correction that is not a receipt -- an offcut returned, damage, a
    stock-take adjustment, a return to the supplier. Never `allocation` or
    `release`: those carry their own `Allocation` row and only
    `approve_allocation`/`release_allocation` may write them, so a movement
    against an order can always be explained by the allocation that caused
    it.
    """
    if reason not in ADJUSTABLE_REASONS:
        raise ValueError(f'"{reason}" is not a reason `adjust_stock` may record')
    lot = session.get(StockLot, lot_id)
    if lot is None:
        raise NoSuchLot(lot_id)

    delta_frac = Fraction(delta)
    if delta_frac == 0:
        raise ValueError("delta must not be zero")

    return _record_movement(
        session,
        lot,
        delta=delta_frac,
        reason=reason,
        by_user_id=by_user_id,
        note=note,
        at=at,
    )


def _material_position(session: Session, material_id: str) -> tuple[Fraction, Fraction]:
    """`(on_hand, committed)`. `committed` counts only `proposed`
    allocations -- an `approved` one already left `on_hand` through its own
    movement, so counting it again would subtract it twice.
    """
    on_hand = sum(
        (
            Fraction(lot.qty_on_hand)
            for lot in session.scalars(
                select(StockLot).where(StockLot.material_id == material_id)
            )
        ),
        Fraction(0),
    )
    committed = sum(
        (
            Fraction(a.qty)
            for a in session.scalars(
                select(Allocation).where(
                    Allocation.material_id == material_id,
                    Allocation.status == "proposed",
                )
            )
        ),
        Fraction(0),
    )
    return on_hand, committed


def available_for_material(session: Session, material_id: str) -> Fraction:
    """What is actually free to promise right now -- on hand, minus what is
    already claimed by a pending review. Not a forecast: every number in it
    is a row this system already has.
    """
    on_hand, committed = _material_position(session, material_id)
    return on_hand - committed


@dataclass(frozen=True)
class ReorderAlert:
    material: Material
    on_hand: str
    committed: str
    available: str
    reorder_level: str


def reorder_alerts(session: Session) -> list[ReorderAlert]:
    alerts: list[ReorderAlert] = []
    materials = session.scalars(
        select(Material).where(
            Material.is_active.is_(True), Material.reorder_level.is_not(None)
        )
    )
    for material in materials:
        on_hand, committed = _material_position(session, material.id)
        available = on_hand - committed
        level = Fraction(material.reorder_level)
        if available < level:
            alerts.append(
                ReorderAlert(
                    material=material,
                    on_hand=str(on_hand),
                    committed=str(committed),
                    available=str(available),
                    reorder_level=material.reorder_level,
                )
            )
    return alerts


# ---------------------------------------------------------------------------
# Allocations
# ---------------------------------------------------------------------------


def propose_allocation(
    session: Session,
    *,
    order_line_id: str,
    order_id: str,
    material_id: str,
    qty: str,
) -> Allocation:
    """Stakes a claim on stock without moving any -- `status='proposed'`
    never touches `qty_on_hand`. Picks the first lot, oldest `received_at`
    first, that alone covers `qty`; finding none, still creates the
    proposal with `lot_id=None` rather than silently splitting across two
    dye lots on somebody's behalf (SPEC.md §11 Phase 9).
    """
    material = session.get(Material, material_id)
    if material is None:
        raise NoSuchMaterial(material_id)
    qty_frac = _parse_positive(qty, "qty")

    lots = session.scalars(
        select(StockLot)
        .where(StockLot.material_id == material_id)
        .order_by(StockLot.received_at)
    ).all()
    chosen = next((lot for lot in lots if Fraction(lot.qty_on_hand) >= qty_frac), None)

    allocation = Allocation(
        id=str(uuid.uuid4()),
        order_line_id=order_line_id,
        order_id=order_id,
        material_id=material_id,
        lot_id=chosen.id if chosen else None,
        qty=str(qty_frac),
        status="proposed",
        decision_note=(
            None
            if chosen
            else "no single lot covers the required quantity -- needs manual review"
        ),
    )
    session.add(allocation)
    session.flush()
    return allocation


def propose_allocation_for_line(
    session: Session,
    *,
    order_line: OrderLine,
    order_id: str,
    final_billed_qty: Fraction | None,
) -> Allocation | None:
    """Called once, from `push_measurement`, right after final pricing has
    run for this line. SPEC.md §13 F3.

    **`final_billed_qty` is the exact quantity `reprice_order` just
    computed** (`FinalLine.billed_qty` on the pricing result), never
    `OrderLine.billed_qty` -- that column is the *estimate*, set once at
    order confirmation and never updated, and using it here would size
    every proposal off the fair's rounded-up guess instead of the tape.
    `None` means the line has not (yet) priced -- refused, or still
    missing a dimension on another line in the same order -- and there is
    nothing to propose against.

    Proposes **only** where the conversion from billed quantity to stock
    quantity is exact -- v1 recognises one case: an area-priced material
    (`uom='box'`, the line billed `per_sqft`), converted by
    `coverage_per_unit` and rounded up to whole boxes. Every other
    combination returns `None` quietly: most products are never
    inventory-tracked, and a fabric line's real yardage depends on fullness
    and drop that nothing in this pricing engine models, so guessing one
    here would be exactly the "confident wrong number" this phase's own
    spec warns against.

    Matched by `variant` alone, not `material_key` -- an area-priced
    material's stock unit (a box of a given SPC finish) is what the
    `variant` already names; `material_key` is the fabric-family concept of
    a colour choice within one variant; unrelated fields.
    """
    if order_line.billed_unit != "sqft" or final_billed_qty is None:
        return None

    candidates = session.scalars(
        select(Material).where(Material.is_active.is_(True), Material.uom == "box")
    )
    match = next(
        (
            m
            for m in candidates
            if order_line.variant in (m.variant_compat or []) and m.coverage_per_unit
        ),
        None,
    )
    if match is None:
        return None

    already = session.scalars(
        select(Allocation).where(
            Allocation.order_line_id == order_line.id,
            Allocation.material_id == match.id,
        )
    ).first()
    if already is not None:
        # A remeasure on a line already proposed/decided is left for a
        # person to reconcile by hand rather than silently proposing again.
        return None

    coverage = Fraction(match.coverage_per_unit)
    boxes = _ceil_fraction(final_billed_qty / coverage)

    return propose_allocation(
        session,
        order_line_id=order_line.id,
        order_id=order_id,
        material_id=match.id,
        qty=str(boxes),
    )


def pending_allocations(session: Session) -> list[Allocation]:
    return list(
        session.scalars(
            select(Allocation)
            .where(Allocation.status == "proposed")
            .order_by(Allocation.proposed_at)
        )
    )


def approve_allocation(
    session: Session,
    *,
    allocation_id: str,
    by_user_id: str,
    lot_id: str | None = None,
    at: datetime | None = None,
) -> Allocation:
    """The only function that turns a claim into a withdrawal. `lot_id`
    overrides the auto-picked one -- required when a proposal had none
    (§13 F3's "no single lot covers it" case), optional otherwise.
    """
    allocation = session.get(Allocation, allocation_id)
    if allocation is None:
        raise NoSuchAllocation(allocation_id)
    if allocation.status != "proposed":
        raise WrongStatus(f'"{allocation_id}" is {allocation.status}, not proposed')

    chosen_lot_id = lot_id or allocation.lot_id
    if chosen_lot_id is None:
        raise ValueError("no lot to allocate from -- pass lot_id")
    lot = session.get(StockLot, chosen_lot_id)
    if lot is None or lot.material_id != allocation.material_id:
        raise NoSuchLot(chosen_lot_id)

    when = at or datetime.now(UTC)
    _record_movement(
        session,
        lot,
        delta=-Fraction(allocation.qty),
        reason="allocation",
        by_user_id=by_user_id,
        order_id=allocation.order_id,
        at=when,
    )

    allocation.lot_id = lot.id
    allocation.status = "approved"
    allocation.decided_by_user_id = by_user_id
    allocation.decided_at = when
    allocation.allocated_at = when
    session.flush()
    return allocation


def reject_allocation(
    session: Session,
    *,
    allocation_id: str,
    by_user_id: str,
    reason: str,
    at: datetime | None = None,
) -> Allocation:
    """Sent back with a reason on record -- the same rule the library's own
    reviewer follows for a rejection. Nothing was ever decremented, so
    there is nothing to reverse.
    """
    if not reason.strip():
        raise ValueError("a rejection needs a reason")
    allocation = session.get(Allocation, allocation_id)
    if allocation is None:
        raise NoSuchAllocation(allocation_id)
    if allocation.status != "proposed":
        raise WrongStatus(f'"{allocation_id}" is {allocation.status}, not proposed')

    allocation.status = "rejected"
    allocation.decided_by_user_id = by_user_id
    allocation.decided_at = at or datetime.now(UTC)
    allocation.decision_note = reason
    session.flush()
    return allocation


def create_manual_allocation(
    session: Session,
    *,
    order_line_id: str,
    order_id: str,
    material_id: str,
    lot_id: str,
    qty: str,
    by_user_id: str,
    at: datetime | None = None,
) -> Allocation:
    """An admin allocates directly, already decided -- for a material with
    no exact auto-proposal conversion (§13 F3), or a manual split across a
    second lot after a first allocation used up one lot's worth. There is
    no proposal to review because no automatic guess was made.
    """
    material = session.get(Material, material_id)
    if material is None:
        raise NoSuchMaterial(material_id)
    lot = session.get(StockLot, lot_id)
    if lot is None or lot.material_id != material_id:
        raise NoSuchLot(lot_id)
    qty_frac = _parse_positive(qty, "qty")

    allocation = Allocation(
        id=str(uuid.uuid4()),
        order_line_id=order_line_id,
        order_id=order_id,
        material_id=material_id,
        lot_id=lot.id,
        qty=str(qty_frac),
        status="proposed",
    )
    session.add(allocation)
    session.flush()

    return approve_allocation(
        session,
        allocation_id=allocation.id,
        by_user_id=by_user_id,
        lot_id=lot.id,
        at=at,
    )


def release_allocation(
    session: Session,
    *,
    allocation_id: str,
    by_user_id: str,
    note: str | None = None,
    at: datetime | None = None,
) -> Allocation:
    """Reverses an approved allocation -- an order cancelled after stock was
    set aside for it (orders are cancellable up to `ready`, §6.6). Puts the
    quantity back on the lot it came from with its own append-only
    `release` movement, never an edit to the original `allocation` row.
    """
    allocation = session.get(Allocation, allocation_id)
    if allocation is None:
        raise NoSuchAllocation(allocation_id)
    if allocation.status != "approved":
        raise WrongStatus(f'"{allocation_id}" is {allocation.status}, not approved')

    lot = session.get(StockLot, allocation.lot_id)
    if lot is None:
        raise NoSuchLot(allocation.lot_id)

    when = at or datetime.now(UTC)
    _record_movement(
        session,
        lot,
        delta=Fraction(allocation.qty),
        reason="release",
        by_user_id=by_user_id,
        order_id=allocation.order_id,
        note=note,
        at=when,
    )
    allocation.status = "released"
    allocation.released_at = when
    session.flush()
    return allocation
