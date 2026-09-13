"""Inventory. SPEC.md Phase 9.

Three things matter most:

**The ledger is the truth.** `qty_on_hand` only ever changes alongside a
`StockMovement`, and a movement that would take a lot negative is refused
rather than silently allowed.

**Two routes to an approved allocation, one gate.** An auto-proposed
allocation never touches stock until an admin approves it; a manual one is
created already decided, because there was no automatic guess to check.

**"Available" is on-hand minus what is already proposed**, not raw on-hand
-- a `proposed` allocation is a claim, not yet a withdrawal.
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, datetime
from fractions import Fraction

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.models.db import Base, OrderLine, StockLot
from app.services.inventory import (
    DuplicateMaterialCode,
    NoSuchAllocation,
    NoSuchLot,
    NoSuchMaterial,
    WrongStatus,
    adjust_stock,
    approve_allocation,
    available_for_material,
    create_manual_allocation,
    create_material,
    deactivate_material,
    list_materials,
    pending_allocations,
    propose_allocation,
    propose_allocation_for_line,
    receive_stock,
    reject_allocation,
    release_allocation,
    reorder_alerts,
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


AT = datetime(2026, 9, 13, 9, tzinfo=UTC)


def make_spc(session, *, coverage_per_unit="18", reorder_level=None):
    return create_material(
        session,
        family="flooring",
        variant_compat=["spc_click_4mm"],
        code="SPC-OAK-4MM",
        names={"zh": "SPC地板", "en": "SPC flooring", "ms": "Lantai SPC"},
        uom="box",
        coverage_per_unit=coverage_per_unit,
        reorder_level=reorder_level,
    )


def make_order_line(
    session,
    *,
    id="ol-1",
    order_id="o-1",
    variant="spc_click_4mm",
    billed_unit="sqft",
    billed_qty="100",
    material_key="oak",
) -> OrderLine:
    line = OrderLine(
        id=id,
        order_id=order_id,
        quote_line_id=f"{id}-q",
        sort_order=0,
        room="Living",
        variant=variant,
        material_key=material_key,
        layer="",
        est_width_tmm=1,
        applied_rule_id="rule-1",
        applied_rate_card_version=1,
        standard_rate_sen=100,
        rate_sen=100,
        billed_qty=billed_qty,
        billed_unit=billed_unit,
        line_total_sen=1000,
    )
    session.add(line)
    session.flush()
    return line


class TestMaterials:
    def test_created_and_listed(self, db) -> None:
        with db() as session:
            make_spc(session)
            session.commit()
            materials = list_materials(session)
            assert [m.code for m in materials] == ["SPC-OAK-4MM"]

    def test_duplicate_code_is_refused(self, db) -> None:
        with db() as session:
            make_spc(session)
            session.commit()
            with pytest.raises(DuplicateMaterialCode):
                make_spc(session)

    def test_deactivating_removes_it_from_the_default_list(self, db) -> None:
        with db() as session:
            material = make_spc(session)
            session.commit()
            deactivate_material(session, material.id)
            session.commit()
            assert list_materials(session) == []
            assert list_materials(session, active_only=False)[0].id == material.id

    def test_an_unknown_material_is_an_error(self, db) -> None:
        with db() as session, pytest.raises(NoSuchMaterial):
            deactivate_material(session, "not-a-real-id")


class TestReceivingStock:
    def test_a_new_lot_ref_creates_a_new_lot(self, db) -> None:
        with db() as session:
            material = make_spc(session)
            session.commit()
            lot = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="50",
                by_user_id="admin-1",
                cost_sen=1200,
                received_at=AT,
            )
            session.commit()
            assert lot.qty_on_hand == "50"
            assert lot.cost_sen == 1200

    def test_the_same_lot_ref_tops_up_rather_than_creating_a_second_lot(
        self, db
    ) -> None:
        with db() as session:
            material = make_spc(session)
            session.commit()
            first = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="50",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()
            second = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="10",
                by_user_id="admin-1",
                received_at=datetime(2026, 9, 20, tzinfo=UTC),
            )
            session.commit()

            assert second.id == first.id
            assert second.qty_on_hand == "60"
            # FIFO ordering depends on the ORIGINAL arrival date surviving
            # a top-up, not the date of the top-up itself.
            assert second.received_at == AT

    def test_a_different_lot_ref_is_a_different_lot_even_for_the_same_material(
        self, db
    ) -> None:
        # "Same code, different lot, visible colour difference" -- the
        # reason this table exists at all.
        with db() as session:
            material = make_spc(session)
            session.commit()
            receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="50",
                by_user_id="admin-1",
                received_at=AT,
            )
            receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-002",
                qty="30",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()
            assert available_for_material(session, material.id) == Fraction(80)

    def test_an_unknown_material_is_an_error(self, db) -> None:
        with db() as session, pytest.raises(NoSuchMaterial):
            receive_stock(
                session,
                material_id="not-a-real-id",
                lot_ref="DYE-001",
                qty="10",
                by_user_id="admin-1",
            )

    def test_a_non_positive_quantity_is_refused(self, db) -> None:
        with db() as session:
            material = make_spc(session)
            session.commit()
            with pytest.raises(ValueError):
                receive_stock(
                    session,
                    material_id=material.id,
                    lot_ref="DYE-001",
                    qty="0",
                    by_user_id="admin-1",
                )


class TestAdjustingStock:
    def _lot(self, session):
        material = make_spc(session)
        session.commit()
        lot = receive_stock(
            session,
            material_id=material.id,
            lot_ref="DYE-001",
            qty="50",
            by_user_id="admin-1",
            received_at=AT,
        )
        session.commit()
        return lot

    def test_damage_reduces_qty_on_hand(self, db) -> None:
        with db() as session:
            lot = self._lot(session)
            adjust_stock(
                session,
                lot_id=lot.id,
                delta="-2",
                reason="damage",
                by_user_id="admin-1",
                note="two boxes cracked in transit",
            )
            session.commit()
            assert lot.qty_on_hand == "48"

    def test_an_offcut_return_increases_it(self, db) -> None:
        with db() as session:
            lot = self._lot(session)
            adjust_stock(
                session,
                lot_id=lot.id,
                delta="1",
                reason="offcut_return",
                by_user_id="admin-1",
            )
            session.commit()
            assert lot.qty_on_hand == "51"

    def test_a_movement_that_would_go_negative_is_refused(self, db) -> None:
        with db() as session:
            lot = self._lot(session)
            with pytest.raises(ValueError):
                adjust_stock(
                    session,
                    lot_id=lot.id,
                    delta="-1000",
                    reason="damage",
                    by_user_id="admin-1",
                )
            assert lot.qty_on_hand == "50", "the refused write must not partially apply"

    def test_allocation_and_release_are_not_adjustable_reasons(self, db) -> None:
        # Those reasons carry their own Allocation row; a free adjustment
        # claiming one would move stock against an order with no allocation
        # to explain it.
        with db() as session:
            lot = self._lot(session)
            with pytest.raises(ValueError):
                adjust_stock(
                    session,
                    lot_id=lot.id,
                    delta="-1",
                    reason="allocation",
                    by_user_id="admin-1",
                )

    def test_a_zero_delta_is_refused(self, db) -> None:
        with db() as session:
            lot = self._lot(session)
            with pytest.raises(ValueError):
                adjust_stock(
                    session,
                    lot_id=lot.id,
                    delta="0",
                    reason="adjustment",
                    by_user_id="admin-1",
                )


class TestAutoProposal:
    def test_an_area_priced_line_proposes_the_ceiling_of_billed_over_coverage(
        self, db
    ) -> None:
        with db() as session:
            make_spc(session, coverage_per_unit="18")
            session.commit()
            line = make_order_line(session, billed_qty="100")  # 100/18 -> 6 boxes

            allocation = propose_allocation_for_line(
                session,
                order_line=line,
                order_id="o-1",
                final_billed_qty=Fraction(line.billed_qty),
            )
            session.commit()

            assert allocation is not None
            assert allocation.status == "proposed"
            assert allocation.qty == "6"

    def test_an_exact_multiple_does_not_round_up_unnecessarily(self, db) -> None:
        with db() as session:
            make_spc(session, coverage_per_unit="18")
            session.commit()
            line = make_order_line(session, billed_qty="36")  # exactly 2 boxes

            allocation = propose_allocation_for_line(
                session,
                order_line=line,
                order_id="o-1",
                final_billed_qty=Fraction(line.billed_qty),
            )
            session.commit()
            assert allocation.qty == "2"

    def test_it_picks_the_oldest_lot_that_alone_covers_the_quantity(self, db) -> None:
        with db() as session:
            material = make_spc(session, coverage_per_unit="18")
            session.commit()
            older = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-OLD",
                qty="10",
                by_user_id="admin-1",
                received_at=datetime(2026, 8, 1, tzinfo=UTC),
            )
            newer = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-NEW",
                qty="10",
                by_user_id="admin-1",
                received_at=datetime(2026, 9, 1, tzinfo=UTC),
            )
            session.commit()
            line = make_order_line(session, billed_qty="36")  # needs 2 boxes

            allocation = propose_allocation_for_line(
                session,
                order_line=line,
                order_id="o-1",
                final_billed_qty=Fraction(line.billed_qty),
            )
            session.commit()

            assert allocation.lot_id == older.id
            # Proposing never decrements -- both lots are untouched.
            assert older.qty_on_hand == "10"
            assert newer.qty_on_hand == "10"

    def test_no_single_lot_covering_it_still_proposes_with_no_lot_chosen(
        self, db
    ) -> None:
        with db() as session:
            material = make_spc(session, coverage_per_unit="18")
            session.commit()
            receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-A",
                qty="1",
                by_user_id="admin-1",
                received_at=AT,
            )
            receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-B",
                qty="1",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()
            line = make_order_line(session, billed_qty="36")  # needs 2 boxes

            allocation = propose_allocation_for_line(
                session,
                order_line=line,
                order_id="o-1",
                final_billed_qty=Fraction(line.billed_qty),
            )
            session.commit()

            assert allocation is not None
            assert allocation.lot_id is None
            assert allocation.decision_note is not None

    def test_a_fabric_line_with_no_exact_conversion_proposes_nothing(self, db) -> None:
        # SPEC.md §13 F3 -- a curtain's billed per_ft_width quantity is not
        # its fabric yardage. Guessing one would be exactly the confident
        # wrong number this phase warns against.
        with db() as session:
            make_spc(session)
            session.commit()
            line = make_order_line(
                session,
                variant="night_curtain_sfold",
                billed_unit="ft",
                billed_qty="12",
                material_key="navy",
            )
            assert (
                propose_allocation_for_line(
                    session,
                    order_line=line,
                    order_id="o-1",
                    final_billed_qty=Fraction(line.billed_qty),
                )
                is None
            )

    def test_no_untracked_material_matches_produces_no_proposal(self, db) -> None:
        with db() as session:
            # No material at all is registered for this variant.
            line = make_order_line(session, variant="some_untracked_variant")
            assert (
                propose_allocation_for_line(
                    session,
                    order_line=line,
                    order_id="o-1",
                    final_billed_qty=Fraction(line.billed_qty),
                )
                is None
            )

    def test_a_line_already_proposed_is_not_proposed_again_on_remeasure(
        self, db
    ) -> None:
        with db() as session:
            make_spc(session, coverage_per_unit="18")
            session.commit()
            line = make_order_line(session, billed_qty="36")
            first = propose_allocation_for_line(
                session,
                order_line=line,
                order_id="o-1",
                final_billed_qty=Fraction(line.billed_qty),
            )
            session.commit()
            assert first is not None

            second = propose_allocation_for_line(
                session,
                order_line=line,
                order_id="o-1",
                final_billed_qty=Fraction(line.billed_qty),
            )
            assert second is None


class TestApprovalAndRejection:
    def _proposal(self, session, qty="6"):
        material = make_spc(session, coverage_per_unit="18")
        session.commit()
        receive_stock(
            session,
            material_id=material.id,
            lot_ref="DYE-001",
            qty="20",
            by_user_id="admin-1",
            received_at=AT,
        )
        session.commit()
        allocation = propose_allocation(
            session,
            order_line_id="ol-1",
            order_id="o-1",
            material_id=material.id,
            qty=qty,
        )
        session.commit()
        return material, allocation

    def test_approving_decrements_the_lot_and_writes_a_movement(self, db) -> None:
        with db() as session:
            material, allocation = self._proposal(session)
            approve_allocation(
                session, allocation_id=allocation.id, by_user_id="admin-1"
            )
            session.commit()

            assert allocation.status == "approved"
            assert allocation.decided_by_user_id == "admin-1"
            lot = session.get(StockLot, allocation.lot_id)
            assert lot.qty_on_hand == "14"

    def test_proposing_never_decrements_only_approving_does(self, db) -> None:
        with db() as session:
            material, allocation = self._proposal(session)
            lot = session.get(StockLot, allocation.lot_id)
            assert lot.qty_on_hand == "20", "still untouched before approval"

    def test_rejecting_requires_a_reason(self, db) -> None:
        with db() as session:
            _, allocation = self._proposal(session)
            with pytest.raises(ValueError):
                reject_allocation(
                    session,
                    allocation_id=allocation.id,
                    by_user_id="admin-1",
                    reason="",
                )

    def test_rejecting_touches_no_stock(self, db) -> None:
        with db() as session:
            _, allocation = self._proposal(session)
            reject_allocation(
                session,
                allocation_id=allocation.id,
                by_user_id="admin-1",
                reason="wrong material chosen",
            )
            session.commit()
            lot = session.get(StockLot, allocation.lot_id)
            assert lot.qty_on_hand == "20"
            assert allocation.status == "rejected"

    def test_approving_twice_is_refused(self, db) -> None:
        with db() as session:
            _, allocation = self._proposal(session)
            approve_allocation(
                session, allocation_id=allocation.id, by_user_id="admin-1"
            )
            session.commit()
            with pytest.raises(WrongStatus):
                approve_allocation(
                    session, allocation_id=allocation.id, by_user_id="admin-1"
                )

    def test_approving_with_no_lot_chosen_requires_an_override(self, db) -> None:
        with db() as session:
            material = make_spc(session, coverage_per_unit="18")
            session.commit()
            # No stock at all -- propose_allocation finds no covering lot.
            allocation = propose_allocation(
                session,
                order_line_id="ol-1",
                order_id="o-1",
                material_id=material.id,
                qty="2",
            )
            session.commit()
            assert allocation.lot_id is None

            with pytest.raises(ValueError):
                approve_allocation(
                    session, allocation_id=allocation.id, by_user_id="admin-1"
                )

    def test_an_unknown_allocation_is_an_error(self, db) -> None:
        with db() as session, pytest.raises(NoSuchAllocation):
            approve_allocation(
                session, allocation_id="not-a-real-id", by_user_id="admin-1"
            )


class TestManualAllocation:
    def test_creates_and_approves_in_one_step(self, db) -> None:
        with db() as session:
            material = make_spc(session)
            session.commit()
            lot = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="20",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()

            allocation = create_manual_allocation(
                session,
                order_line_id="ol-fabric",
                order_id="o-1",
                material_id=material.id,
                lot_id=lot.id,
                qty="5",
                by_user_id="admin-1",
            )
            session.commit()

            assert allocation.status == "approved"
            assert lot.qty_on_hand == "15"

    def test_a_lot_from_a_different_material_is_refused(self, db) -> None:
        with db() as session:
            spc = make_spc(session)
            other = create_material(
                session,
                family="curtain",
                variant_compat=["night_curtain_sfold"],
                code="FAB-NAVY",
                names={"zh": "藏青布", "en": "Navy fabric", "ms": "Kain navy"},
                uom="metre",
            )
            session.commit()
            lot = receive_stock(
                session,
                material_id=spc.id,
                lot_ref="DYE-001",
                qty="20",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()

            with pytest.raises(NoSuchLot):
                create_manual_allocation(
                    session,
                    order_line_id="ol-fabric",
                    order_id="o-1",
                    material_id=other.id,
                    lot_id=lot.id,
                    qty="5",
                    by_user_id="admin-1",
                )


class TestReleasingAnAllocation:
    def test_releasing_an_approved_allocation_puts_the_stock_back(self, db) -> None:
        with db() as session:
            material = make_spc(session)
            session.commit()
            lot = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="20",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()
            allocation = create_manual_allocation(
                session,
                order_line_id="ol-1",
                order_id="o-1",
                material_id=material.id,
                lot_id=lot.id,
                qty="5",
                by_user_id="admin-1",
            )
            session.commit()
            assert lot.qty_on_hand == "15"

            release_allocation(
                session,
                allocation_id=allocation.id,
                by_user_id="admin-1",
                note="order cancelled",
            )
            session.commit()

            assert lot.qty_on_hand == "20"
            assert allocation.status == "released"

    def test_releasing_a_proposed_allocation_is_refused(self, db) -> None:
        with db() as session:
            material = make_spc(session, coverage_per_unit="18")
            session.commit()
            receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="20",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()
            allocation = propose_allocation(
                session,
                order_line_id="ol-1",
                order_id="o-1",
                material_id=material.id,
                qty="6",
            )
            session.commit()
            with pytest.raises(WrongStatus):
                release_allocation(
                    session, allocation_id=allocation.id, by_user_id="admin-1"
                )


class TestAvailableAndReorderAlerts:
    def test_available_subtracts_only_proposed_not_approved(self, db) -> None:
        with db() as session:
            material = make_spc(session, coverage_per_unit="18")
            session.commit()
            lot = receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="20",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()

            proposed = propose_allocation(
                session,
                order_line_id="ol-1",
                order_id="o-1",
                material_id=material.id,
                qty="3",
            )
            approved_source = propose_allocation(
                session,
                order_line_id="ol-2",
                order_id="o-2",
                material_id=material.id,
                qty="4",
            )
            session.commit()
            approve_allocation(
                session, allocation_id=approved_source.id, by_user_id="admin-1"
            )
            session.commit()

            # on_hand is now 20 - 4 = 16 (the approved allocation already
            # left it); the proposed 3 is still only committed, not spent.
            assert available_for_material(session, material.id) == Fraction(13)
            assert lot.qty_on_hand == "16"
            assert proposed.status == "proposed"

    def test_reorder_alert_fires_on_available_not_raw_on_hand(self, db) -> None:
        with db() as session:
            material = make_spc(session, coverage_per_unit="18", reorder_level="10")
            session.commit()
            receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="12",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()
            # 12 on hand is above the reorder level of 10 -- no alert yet.
            assert reorder_alerts(session) == []

            propose_allocation(
                session,
                order_line_id="ol-1",
                order_id="o-1",
                material_id=material.id,
                qty="5",
            )
            session.commit()
            # 12 on hand - 5 committed = 7 available, below the level of 10.
            alerts = reorder_alerts(session)
            assert len(alerts) == 1
            assert alerts[0].material.id == material.id
            assert alerts[0].available == "7"

    def test_a_material_with_no_reorder_level_never_alerts(self, db) -> None:
        with db() as session:
            make_spc(session, reorder_level=None)
            session.commit()
            assert reorder_alerts(session) == []

    def test_pending_allocations_lists_only_proposed_oldest_first(self, db) -> None:
        with db() as session:
            material = make_spc(session)
            session.commit()
            receive_stock(
                session,
                material_id=material.id,
                lot_ref="DYE-001",
                qty="10",
                by_user_id="admin-1",
                received_at=AT,
            )
            session.commit()
            first = propose_allocation(
                session,
                order_line_id="ol-1",
                order_id="o-1",
                material_id=material.id,
                qty="1",
            )
            session.commit()
            second = propose_allocation(
                session,
                order_line_id="ol-2",
                order_id="o-1",
                material_id=material.id,
                qty="1",
            )
            session.commit()
            approve_allocation(session, allocation_id=first.id, by_user_id="admin-1")
            session.commit()

            pending = pending_allocations(session)
            assert [a.id for a in pending] == [second.id]
