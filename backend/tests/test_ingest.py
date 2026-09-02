"""Accepting quotes from a device.

§9.2: "Server endpoints idempotent on the client UUID. Retry must be safe.
**Write the double-submit test before the endpoint.**" So this file was written
first.

§9.4: the server re-prices every line. Match, accept silently. Mismatch, accept
the order anyway and raise it for review — never lose a sale over a rounding
dispute, and never silently accept the client's number either.
"""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.api.schemas import QuoteIn, QuoteLineIn
from app.models.db import (
    Base,
    IdempotencyRecord,
    PricingDiscrepancy,
    Quote,
    QuoteLine,
)
from app.services.ingest import (
    UnknownRateCardVersion,
    active_card,
    publish_card,
    push_quote,
)

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)
STANDARD = json.loads(
    (ROOT / "shared" / "rate-card-standard.json").read_text(encoding="utf-8")
)


@pytest.fixture
def session() -> Session:
    # SQLite in memory. The JSONB and partial-index bits are Postgres-only, so
    # those are exercised by the migration tests rather than here; what this
    # file tests is the ingest logic, which is dialect-agnostic.
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as s:
        publish_card(s, list_id="fair", payload=FAIR)
        s.commit()
        yield s


def a_quote(
    *,
    quote_id: str | None = None,
    line_total_sen: int | None = 55200,
    version: int = 1,
) -> QuoteIn:
    """A 12ft x 9ft night curtain — the golden case, worth RM552."""
    now = datetime.now(UTC)
    return QuoteIn(
        id=quote_id or str(uuid.uuid4()),
        rate_card_version=version,
        tier="standard",
        language="zh",
        device_total_sen=line_total_sen,
        created_at=now,
        updated_at=now,
        device_id=str(uuid.uuid4()),
        lines=[
            QuoteLineIn(
                id=str(uuid.uuid4()),
                sort_order=0,
                room="客厅",
                variant="night_curtain",
                material_key=None,
                layer="night",
                width_tmm=36576,
                height_tmm=27432,
                raw_width="12'",
                raw_height="9'",
                quantity=1,
                device_total_sen=line_total_sen,
            )
        ],
    )


class TestDoubleSubmit:
    """Written before the endpoint, per §9.2."""

    def test_the_same_quote_pushed_twice_creates_one_row(
        self, session: Session
    ) -> None:
        payload = a_quote()

        first = push_quote(session, payload)
        session.commit()
        second = push_quote(session, payload)
        session.commit()

        assert first.duplicate is False
        assert second.duplicate is True
        assert session.scalar(select(Quote).where(Quote.id == payload.id)) is not None
        assert len(session.scalars(select(Quote)).all()) == 1
        assert len(session.scalars(select(QuoteLine)).all()) == 1

    def test_a_retry_reports_the_same_totals(self, session: Session) -> None:
        # The device cannot tell whether the first attempt landed, so the second
        # response has to be usable as if it were the first.
        payload = a_quote()
        first = push_quote(session, payload)
        session.commit()
        second = push_quote(session, payload)

        assert second.server_total_sen == first.server_total_sen
        assert second.device_total_sen == first.device_total_sen

    def test_ten_retries_are_still_one_quote(self, session: Session) -> None:
        # A fair's connection drops repeatedly; the outbox drains FIFO with
        # backoff and will genuinely send the same row many times.
        payload = a_quote()
        for _ in range(10):
            push_quote(session, payload)
            session.commit()

        assert len(session.scalars(select(Quote)).all()) == 1
        assert len(session.scalars(select(QuoteLine)).all()) == 1
        assert len(session.scalars(select(IdempotencyRecord)).all()) == 1

    def test_two_different_quotes_both_land(self, session: Session) -> None:
        # Idempotency must not collapse genuinely distinct work.
        push_quote(session, a_quote())
        push_quote(session, a_quote())
        session.commit()
        assert len(session.scalars(select(Quote)).all()) == 2


class TestServerRepricing:
    def test_an_agreeing_quote_records_no_discrepancy(
        self, session: Session
    ) -> None:
        result = push_quote(session, a_quote(line_total_sen=55200))
        session.commit()

        assert result.discrepancies == []
        assert result.server_total_sen == 55200
        assert session.scalars(select(PricingDiscrepancy)).all() == []

    def test_a_disagreement_is_recorded_but_the_order_is_still_accepted(
        self, session: Session
    ) -> None:
        # §9.4: never lose a sale over a rounding dispute. The customer already
        # agreed a number and may already have paid a deposit.
        payload = a_quote(line_total_sen=55100)  # one ringgit light
        result = push_quote(session, payload)
        session.commit()

        assert session.get(Quote, payload.id) is not None, "the order still lands"
        assert len(result.discrepancies) == 1

        recorded = session.scalars(select(PricingDiscrepancy)).all()
        assert len(recorded) == 1
        assert recorded[0].device_total_sen == 55100
        assert recorded[0].server_total_sen == 55200
        assert recorded[0].reviewed_at is None, "raised for review, not resolved"

    def test_both_numbers_are_kept_rather_than_one_overwriting_the_other(
        self, session: Session
    ) -> None:
        payload = a_quote(line_total_sen=55100)
        push_quote(session, payload)
        session.commit()

        line = session.scalars(select(QuoteLine)).one()
        assert line.device_total_sen == 55100
        assert line.server_total_sen == 55200

    def test_the_server_prices_at_the_version_the_device_recorded(
        self, session: Session
    ) -> None:
        # Not at whatever is current. Substituting today's card would reprice a
        # quote the customer has already been shown.
        publish_card(session, list_id="standard", payload=STANDARD)
        session.commit()

        result = push_quote(session, a_quote(version=1, line_total_sen=55200))
        session.commit()
        assert result.server_total_sen == 55200, "priced at the fair card, v1"

        standard_quote = a_quote(version=101, line_total_sen=66240)
        result = push_quote(session, standard_quote)
        session.commit()
        # 12ft x RM55.20
        assert result.server_total_sen == 66240
        assert result.discrepancies == []

    def test_an_unknown_version_is_refused(self, session: Session) -> None:
        # Better to refuse than to reprice at a card the device never saw.
        with pytest.raises(UnknownRateCardVersion):
            push_quote(session, a_quote(version=999))

    def test_a_line_the_server_cannot_price_still_lands(
        self, session: Session
    ) -> None:
        # A quote the server cannot price is a data problem to review, not a
        # reason to reject a confirmed sale.
        payload = a_quote()
        payload.lines[0].variant = "no_such_product"
        result = push_quote(session, payload)
        session.commit()

        assert session.get(Quote, payload.id) is not None
        line = session.scalars(select(QuoteLine)).one()
        assert line.server_total_sen is None
        assert len(result.discrepancies) == 1
        assert "NoApplicableRate" in (result.discrepancies[0].detail or "")


class TestPublishing:
    def test_publishing_deactivates_the_previous_version_but_keeps_it(
        self, session: Session
    ) -> None:
        # CLAUDE.md: rows are never updated in place and never deleted, so a
        # quote priced at v1 stays explainable after v2 exists.
        bumped = {**FAIR, "version": 2}
        publish_card(session, list_id="fair", payload=bumped)
        session.commit()

        current = active_card(session, "fair")
        assert current is not None
        assert current.version == 2

        from app.models.db import RateCardVersion

        all_versions = session.scalars(select(RateCardVersion)).all()
        assert {v.version for v in all_versions} == {1, 2}
        assert [v.version for v in all_versions if v.is_active] == [2]

    def test_the_two_lists_are_separate_lineages(self, session: Session) -> None:
        # Publishing a standard card must not deactivate the fair one: both are
        # live, and the date decides which applies.
        publish_card(session, list_id="standard", payload=STANDARD)
        session.commit()

        assert active_card(session, "fair").version == 1
        assert active_card(session, "standard").version == 101
