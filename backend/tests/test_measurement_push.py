"""Site measurements reaching the server. FINDINGS.md #1, SPEC.md §11 Phase 6.

An order is pushed to the server once, at confirmation, before the site visit
happens. Until this endpoint existed nothing ever pushed the tape reading up
afterward — `push_order`'s idempotency check treats a retry as a pure
duplicate and never touches lines again — so `OrderLine.is_site_measured`
stayed `False` forever, and `advance_order_status`'s `measured` guard refused
every real order regardless of what was actually done in the field. The last
test in this file is that end-to-end case.

Mirrors `test_buyer_details_push.py`'s shape: it merges/refuses the same way,
staled on a timestamp instead of letting the last arrival win — except the
timestamp is the LINE's own `measured_at`, because a measurement is naturally
per line rather than per order.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import MeasurementIn, OrderIn, OrderLineIn, StatusChangeIn
from app.models.db import Base, Order, OrderLine, PricingDiscrepancy
from app.services.ingest import (
    advance_order_status,
    publish_card,
    push_measurement,
    push_order,
)

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)

CONFIRMED_AT = datetime(2026, 8, 29, 14, 0, tzinfo=UTC)
MEASURED_AT = CONFIRMED_AT + timedelta(days=14)

ORDER_ID = "11111111-1111-4111-8111-111111111111"
LINE_ID = "22222222-2222-4222-8222-222222222222"

# The golden fixture: a 12ft x 9ft night curtain, RM552 at the quote.
EST_WIDTH_TMM = 36576
EST_HEIGHT_TMM = 27432
EST_TOTAL_SEN = 55200


@pytest.fixture
def db() -> Iterator[sessionmaker[Session]]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    session_factory = sessionmaker(bind=engine, expire_on_commit=False)
    with session_factory() as s:
        publish_card(s, list_id="fair", payload=FAIR)
        s.commit()
    yield session_factory
    engine.dispose()


def seed(session: Session) -> None:
    push_order(
        session,
        OrderIn(
            id=ORDER_ID,
            quote_id="33333333-3333-4333-8333-333333333333",
            channel="fair",
            pinned_rate_card_version=1,
            customer_name="Ah Lian",
            estimate_total_sen=EST_TOTAL_SEN,
            deposit_paid_sen=30000,
            confirmed_at=CONFIRMED_AT,
            lines=[
                OrderLineIn(
                    id=LINE_ID,
                    quote_line_id="44444444-4444-4444-8444-444444444444",
                    sort_order=0,
                    room="Living room",
                    variant="night_curtain",
                    layer="night",
                    est_width_tmm=EST_WIDTH_TMM,
                    est_height_tmm=EST_HEIGHT_TMM,
                    applied_rule_id="night-curtain-lo",
                    applied_rate_card_version=1,
                    standard_rate_sen=4600,
                    rate_sen=4600,
                    billed_qty="12",
                    billed_unit="ft",
                    line_total_sen=EST_TOTAL_SEN,
                )
            ],
        ),
    )
    session.commit()


def measure(
    session: Session,
    *,
    at: datetime | None = None,
    width_tmm: int = 33528,  # 11ft — a real tape, not the quoted 12ft
    height_tmm: int | None = EST_HEIGHT_TMM,
    material_key: str | None = None,
    device_final_total_sen: int | None = None,
    line_id: str = LINE_ID,
):
    return push_measurement(
        session,
        MeasurementIn(
            order_id=ORDER_ID,
            line_id=line_id,
            measured_at=at or MEASURED_AT,
            final_width_tmm=width_tmm,
            final_height_tmm=height_tmm,
            material_key=material_key,
            device_final_total_sen=device_final_total_sen,
        ),
    )


def stored(session: Session) -> tuple[Order, OrderLine]:
    session.expire_all()
    return session.get(Order, ORDER_ID), session.get(OrderLine, LINE_ID)


def test_a_measurement_reaches_the_server_and_reprices_the_order(
    db: sessionmaker[Session],
) -> None:
    """11ft x RM46 = RM506, against RM552 quoted — the drop §8.5 promises."""
    with db() as session:
        seed(session)
        result = measure(session)
        session.commit()

        assert result.refused_because is None
        assert result.is_site_measured is True
        assert result.final_total_sen == 50600
        assert result.has_unmeasured_lines is False

        order, line = stored(session)
        assert order.final_total_sen == 50600
        assert order.has_unmeasured_lines is False
        assert line.final_width_tmm == 33528
        assert line.is_site_measured is True
        # SQLite drops the timezone off a `timestamptz`; compare on the naive
        # wall-clock value the way `_as_utc` treats it, not on tzinfo.
        assert line.measured_at.replace(tzinfo=UTC) == MEASURED_AT


def test_who_measured_comes_from_the_session_not_the_payload(
    db: sessionmaker[Session],
) -> None:
    from app.models.db import User

    with db() as session:
        seed(session)
        measurer = User(id="u-measurer", name="Ah Meng", role="staff")
        session.add(measurer)
        session.flush()

        push_measurement(
            session,
            MeasurementIn(
                order_id=ORDER_ID,
                line_id=LINE_ID,
                measured_at=MEASURED_AT,
                final_width_tmm=33528,
                final_height_tmm=EST_HEIGHT_TMM,
            ),
            by=measurer,
        )
        session.commit()

        _, line = stored(session)
        assert line.measured_by_user_id == "u-measurer"


def test_the_same_instant_is_not_stale(db: sessionmaker[Session]) -> None:
    with db() as session:
        seed(session)
        measure(session, at=MEASURED_AT)
        session.commit()

        result = measure(session, at=MEASURED_AT, width_tmm=33528)
        session.commit()

        assert result.refused_because is None


def test_an_older_measurement_arriving_late_is_refused(
    db: sessionmaker[Session],
) -> None:
    with db() as session:
        seed(session)
        measure(session, at=MEASURED_AT, width_tmm=33528)
        session.commit()

        # A stale retry arrives with a different (wrong) reading.
        result = measure(session, at=MEASURED_AT - timedelta(hours=1), width_tmm=99999)
        session.commit()

        assert result.refused_because == "stale"
        _, line = stored(session)
        assert line.final_width_tmm == 33528


def test_a_refused_stale_push_still_reports_the_truth(
    db: sessionmaker[Session],
) -> None:
    with db() as session:
        seed(session)
        measure(session, at=MEASURED_AT)
        session.commit()

        result = measure(session, at=MEASURED_AT - timedelta(hours=1))
        session.commit()

        assert result.refused_because == "stale"
        assert result.is_site_measured is True
        assert result.final_total_sen == 50600
        assert result.has_unmeasured_lines is False


def test_measurement_for_an_order_that_has_not_landed_is_refused(
    db: sessionmaker[Session],
) -> None:
    with db() as session:
        result = push_measurement(
            session,
            MeasurementIn(
                order_id=str(uuid.uuid4()),
                line_id=LINE_ID,
                measured_at=MEASURED_AT,
                final_width_tmm=33528,
                final_height_tmm=EST_HEIGHT_TMM,
            ),
        )
        assert result.refused_because == "unknown_order"
        assert result.is_site_measured is False


def test_measurement_for_a_line_that_does_not_exist_is_refused(
    db: sessionmaker[Session],
) -> None:
    with db() as session:
        seed(session)
        result = measure(session, line_id=str(uuid.uuid4()))
        assert result.refused_because == "unknown_line"


class TestMaterialKey:
    def test_absent_leaves_a_chosen_material_unchanged(
        self, db: sessionmaker[Session]
    ) -> None:
        with db() as session:
            seed(session)
            measure(session, at=MEASURED_AT, material_key="tbl")
            session.commit()

            # A later push carries no material choice at all.
            measure(session, at=MEASURED_AT + timedelta(minutes=1), material_key=None)
            session.commit()

            _, line = stored(session)
            assert line.material_key == "tbl"


def test_a_device_server_total_mismatch_is_logged_not_refused(
    db: sessionmaker[Session],
) -> None:
    with db() as session:
        seed(session)
        result = measure(session, device_final_total_sen=99999)
        session.commit()

        # Accepted anyway — hard rule 4, never lose a sale over a rounding
        # dispute.
        assert result.refused_because is None
        assert result.final_total_sen == 50600

        logged = session.scalars(select(PricingDiscrepancy)).all()
        assert len(logged) == 1
        assert logged[0].line_id == LINE_ID
        assert logged[0].device_total_sen == 99999
        assert logged[0].server_total_sen == 50600


def test_a_matching_device_total_logs_nothing(db: sessionmaker[Session]) -> None:
    with db() as session:
        seed(session)
        measure(session, device_final_total_sen=50600)
        session.commit()

        assert session.scalars(select(PricingDiscrepancy)).all() == []


def test_pushing_a_measurement_unblocks_the_measured_transition(
    db: sessionmaker[Session],
) -> None:
    """The bug this whole endpoint exists to fix.

    Before this push, the server's copy of `is_site_measured` never left
    `False`, so this transition refused forever regardless of what the
    device believed. `advance_order_status` itself needed no change — it
    already reads `OrderLine` fresh on every call.
    """
    with db() as session:
        seed(session)

        booked = advance_order_status(
            session,
            StatusChangeIn(
                order_id=ORDER_ID,
                event_id=str(uuid.uuid4()),
                to="measurement_booked",
                at=CONFIRMED_AT + timedelta(days=1),
            ),
        )
        session.commit()
        assert booked.refused_because is None

        refused = advance_order_status(
            session,
            StatusChangeIn(
                order_id=ORDER_ID,
                event_id=str(uuid.uuid4()),
                to="measured",
                at=CONFIRMED_AT + timedelta(days=2),
            ),
        )
        session.commit()
        assert refused.refused_because == "lines_not_measured"

        measure(session)
        session.commit()

        allowed = advance_order_status(
            session,
            StatusChangeIn(
                order_id=ORDER_ID,
                event_id=str(uuid.uuid4()),
                to="measured",
                at=CONFIRMED_AT + timedelta(days=3),
            ),
        )
        session.commit()
        assert allowed.refused_because is None
        assert allowed.status == "measured"


def test_a_flooring_measurement_proposes_an_allocation_off_the_exact_tape(
    db: sessionmaker[Session],
) -> None:
    """SPEC.md Phase 9's one auto-allocation trigger, end to end: a real
    site measurement, through the real pricing engine, produces a box count
    off the EXACT final area -- never the estimate's rounded-up sqft, which
    `OrderLine.billed_qty` still holds and never updates.
    """
    from app.models.db import Allocation
    from app.services.inventory import create_material, receive_stock

    flooring_order_id = "55555555-5555-4555-8555-555555555555"
    flooring_line_id = "66666666-6666-4666-8666-666666666666"

    with db() as session:
        material = create_material(
            session,
            family="flooring",
            variant_compat=["spc_4mm_1mm"],
            code="SPC-OAK-4MM",
            names={"zh": "SPC地板", "en": "SPC flooring", "ms": "Lantai SPC"},
            uom="box",
            coverage_per_unit="18",
        )
        receive_stock(
            session,
            material_id=material.id,
            lot_ref="DYE-001",
            qty="20",
            by_user_id="admin-1",
            received_at=CONFIRMED_AT,
        )
        session.commit()

        push_order(
            session,
            OrderIn(
                id=flooring_order_id,
                quote_id="77777777-7777-4777-8777-777777777777",
                channel="fair",
                pinned_rate_card_version=1,
                customer_name="Ah Beng",
                # A rough fair estimate -- deliberately not 100 sqft, so the
                # test fails if the allocation is ever sized off this
                # column instead of the tape.
                estimate_total_sen=99999,
                deposit_paid_sen=30000,
                confirmed_at=CONFIRMED_AT,
                lines=[
                    OrderLineIn(
                        id=flooring_line_id,
                        quote_line_id="88888888-8888-4888-8888-888888888888",
                        sort_order=0,
                        room="Living room",
                        variant="spc_4mm_1mm",
                        layer="single",
                        est_width_tmm=30480,
                        est_height_tmm=30480,
                        applied_rule_id="spc-4mm-1mm",
                        applied_rate_card_version=1,
                        standard_rate_sen=1000,
                        rate_sen=1000,
                        billed_qty="150",  # the rough fair estimate
                        billed_unit="sqft",
                        line_total_sen=99999,
                    )
                ],
            ),
        )
        session.commit()

        # 10ft x 10ft, exactly -- an area with no rounding ambiguity.
        result = push_measurement(
            session,
            MeasurementIn(
                order_id=flooring_order_id,
                line_id=flooring_line_id,
                measured_at=MEASURED_AT,
                final_width_tmm=30480,
                final_height_tmm=30480,
            ),
        )
        session.commit()
        assert result.refused_because is None

        allocation = session.scalars(
            select(Allocation).where(Allocation.order_line_id == flooring_line_id)
        ).first()

        assert allocation is not None, "the exact-conversion case should auto-propose"
        assert allocation.status == "proposed"
        # 100 sqft / 18 sqft-per-box -> ceil(5.55..) -> 6 boxes. Sized off
        # the exact 10x10 tape, not the "150" estimate on the line itself.
        assert allocation.qty == "6"
