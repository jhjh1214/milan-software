"""The order status pipeline, against the same cases the Dart suite loads.

SPEC.md §6.3. If this file and ``mobile/test/pricing/order_status_test.dart``
ever disagree, a handset and the server disagree about whether a job is in
production -- and the handset is the copy nobody else can see.

The fixture cases cover the transitions somebody remembered to write down. The
tests below the fixtures cover the shape of the machine itself: that every
status is reachable, that the two terminals are the only ways out, and that the
guards fire on exactly one transition each.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.pricing.order_status import (
    _ALLOWED,
    MIN_REASON_LENGTH,
    PIPELINE,
    OrderLineState,
    OrderStatus,
    StatusRefusal,
    UnknownOrderStatus,
    advance_order,
    allowed_from,
    next_in_pipeline,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads(
    (ROOT / "shared" / "pricing-fixtures.json").read_text(encoding="utf-8")
)
CASES = FIXTURES["order_status_cases"]

EVERYTHING_DONE = OrderLineState(
    needs_measuring=True,
    has_final_dimensions=True,
    material_deferred=True,
    material_chosen=True,
)
UNMEASURED = OrderLineState(
    needs_measuring=True,
    has_final_dimensions=False,
    material_deferred=False,
    material_chosen=False,
)
STILL_DEFERRING = OrderLineState(
    needs_measuring=False,
    has_final_dimensions=False,
    material_deferred=True,
    material_chosen=False,
)


class TestTheSharedContract:
    def test_the_contract_carries_cases_at_all(self) -> None:
        # A fixture file that silently lost its cases would turn this whole
        # file green while testing nothing.
        assert len(CASES) >= 20

    def test_every_refusal_reason_is_exercised(self) -> None:
        covered = {
            c["expect"]["refused_because"] for c in CASES if not c["expect"]["allowed"]
        }
        assert covered == {
            r.value for r in StatusRefusal
        }, "a refusal nothing exercises is a refusal nobody has checked"

    def test_every_forward_edge_is_exercised(self) -> None:
        covered = {f"{c['from']}->{c['to']}" for c in CASES if c["expect"]["allowed"]}
        forward = {
            "confirmed->measurement_booked",
            "measurement_booked->measured",
            "measured->material_selected",
            "material_selected->in_production",
            "in_production->ready",
            "ready->installed",
            "installed->closed",
        }
        assert forward <= covered

    @pytest.mark.parametrize("case", CASES, ids=[c["id"] for c in CASES])
    def test_the_fixtures_agree_with_the_machine(self, case: dict) -> None:
        result = advance_order(
            frm=OrderStatus.from_wire(case["from"]),
            to=OrderStatus.from_wire(case["to"]),
            reason=case.get("reason"),
            lines=[
                OrderLineState(
                    needs_measuring=line["needs_measuring"],
                    has_final_dimensions=line["has_final_dimensions"],
                    material_deferred=line["material_deferred"],
                    material_chosen=line["material_chosen"],
                )
                for line in case["lines"]
            ],
        )

        why = case["why"]
        expected = case["expect"]
        assert result.is_allowed == expected["allowed"], why
        if expected["allowed"]:
            assert result.to is not None
            assert result.to.value == case["to"], why
        else:
            assert result.refused_because is not None
            assert result.refused_because.value == expected["refused_because"], why


class TestTheShapeOfTheMachine:
    def test_the_statuses_are_the_ones_the_spec_names(self) -> None:
        # Asserted as a literal list, not derived from the enum, so that adding
        # or renaming a status is a decision somebody has to make twice.
        assert [s.value for s in OrderStatus] == [
            "confirmed",
            "measurement_booked",
            "measured",
            "material_selected",
            "in_production",
            "ready",
            "installed",
            "closed",
            "cancelled",
        ]

    def test_an_unknown_status_raises_rather_than_defaulting(self) -> None:
        # A silent default puts a real order in the wrong column of every
        # report. Better to fail on the row than to be quietly wrong about it.
        for wire in ("awaiting_paint", "", "CONFIRMED"):
            with pytest.raises(UnknownOrderStatus):
                OrderStatus.from_wire(wire)

    def test_exactly_two_statuses_are_terminal(self) -> None:
        assert {s for s in OrderStatus if s.is_terminal} == {
            OrderStatus.CLOSED,
            OrderStatus.CANCELLED,
        }

    def test_the_transition_table_and_is_terminal_say_the_same_thing(self) -> None:
        # Two mechanisms express one rule: the empty table entries, and the
        # early answer of `terminal`. The early answer wins, which makes the
        # entries unreachable -- so nothing but this would notice if one of
        # them grew an edge.
        for status in OrderStatus:
            assert (not allowed_from(status)) == status.is_terminal, status

    def test_the_table_covers_every_status(self) -> None:
        # A status missing from the table would be a dead end that reports
        # `not_a_transition` for everything, which reads like a bug in the
        # caller rather than a hole in the machine.
        assert set(_ALLOWED) == set(OrderStatus)

    def test_nothing_moves_out_of_a_terminal_status(self) -> None:
        for terminal in (OrderStatus.CLOSED, OrderStatus.CANCELLED):
            for to in OrderStatus:
                result = advance_order(
                    frm=terminal,
                    to=to,
                    lines=[],
                    reason="a perfectly good reason",
                )
                assert not result.is_allowed, f"{terminal} -> {to}"

    def test_every_status_is_reachable_from_confirmed(self) -> None:
        # A status nothing can reach is a column in a report that stays empty
        # forever while looking like it means something.
        seen = {OrderStatus.CONFIRMED}
        queue = [OrderStatus.CONFIRMED]
        while queue:
            frm = queue.pop()
            for to in OrderStatus:
                if to in seen:
                    continue
                if advance_order(
                    frm=frm,
                    to=to,
                    lines=[EVERYTHING_DONE],
                    reason="a perfectly good reason",
                ).is_allowed:
                    seen.add(to)
                    queue.append(to)
        assert seen == set(OrderStatus)

    def test_the_pipeline_walks_straight_through(self) -> None:
        at = OrderStatus.CONFIRMED
        walked = [at]
        while (nxt := next_in_pipeline(at)) is not None:
            result = advance_order(frm=at, to=nxt, lines=[EVERYTHING_DONE])
            assert result.is_allowed, f"{at} -> {nxt}"
            assert result.to is not None
            at = result.to
            walked.append(at)

        assert tuple(walked) == PIPELINE
        assert at is OrderStatus.CLOSED

    def test_next_in_pipeline_stops_at_the_end_and_ignores_cancelled(self) -> None:
        assert next_in_pipeline(OrderStatus.CLOSED) is None
        # Cancelled is a branch off the side, not a stage, so it has no next.
        assert next_in_pipeline(OrderStatus.CANCELLED) is None
        assert next_in_pipeline(OrderStatus.READY) is OrderStatus.INSTALLED


class TestTheGuards:
    def test_a_line_needing_no_measuring_never_blocks_measured(self) -> None:
        # Otherwise a supply-only line would hold up an order forever, and the
        # measurer would have nothing to do about it.
        result = advance_order(
            frm=OrderStatus.MEASUREMENT_BOOKED,
            to=OrderStatus.MEASURED,
            lines=[
                OrderLineState(
                    needs_measuring=False,
                    has_final_dimensions=False,
                    material_deferred=False,
                    material_chosen=False,
                )
            ],
        )
        assert result.is_allowed

    def test_the_measured_guard_does_not_leak_onto_other_transitions(self) -> None:
        # An unmeasured line must not stop the order being booked in for the
        # very visit that would measure it, or being cancelled.
        assert advance_order(
            frm=OrderStatus.CONFIRMED,
            to=OrderStatus.MEASUREMENT_BOOKED,
            lines=[UNMEASURED],
        ).is_allowed
        assert advance_order(
            frm=OrderStatus.CONFIRMED,
            to=OrderStatus.CANCELLED,
            lines=[UNMEASURED],
            reason="customer changed their mind",
        ).is_allowed

    def test_the_material_guard_does_not_leak_onto_other_transitions(self) -> None:
        # A deferred material is the normal state of every line at confirmation
        # (§13 B7). If this guard fired anywhere but material_selected, no
        # order would ever get its measurement booked.
        assert advance_order(
            frm=OrderStatus.CONFIRMED,
            to=OrderStatus.MEASUREMENT_BOOKED,
            lines=[STILL_DEFERRING],
        ).is_allowed
        # Past material_selected the guard has already been satisfied once;
        # refiring it here would deadlock the order.
        assert advance_order(
            frm=OrderStatus.MATERIAL_SELECTED,
            to=OrderStatus.IN_PRODUCTION,
            lines=[STILL_DEFERRING],
        ).is_allowed

    def test_one_bad_line_among_many_is_enough_to_refuse(self) -> None:
        assert (
            advance_order(
                frm=OrderStatus.MEASUREMENT_BOOKED,
                to=OrderStatus.MEASURED,
                lines=[EVERYTHING_DONE, EVERYTHING_DONE, UNMEASURED, EVERYTHING_DONE],
            ).refused_because
            is StatusRefusal.LINES_NOT_MEASURED
        )
        assert (
            advance_order(
                frm=OrderStatus.MEASURED,
                to=OrderStatus.MATERIAL_SELECTED,
                lines=[EVERYTHING_DONE, STILL_DEFERRING],
            ).refused_because
            is StatusRefusal.MATERIAL_NOT_CHOSEN
        )

    def test_an_order_with_no_lines_passes_both_guards(self) -> None:
        for frm, to in (
            (OrderStatus.MEASUREMENT_BOOKED, OrderStatus.MEASURED),
            (OrderStatus.MEASURED, OrderStatus.MATERIAL_SELECTED),
        ):
            assert advance_order(frm=frm, to=to, lines=[]).is_allowed, f"{frm} -> {to}"


class TestCancelling:
    @pytest.mark.parametrize(
        ("reason", "refused"),
        [
            ("lost", False),
            ("  lost  ", False),
            ("   lost", False),
            ("los", True),
            ("  a  ", True),
            ("", True),
            ("   ", True),
            (None, True),
        ],
    )
    def test_four_trimmed_characters_is_the_bar(
        self, reason: str | None, refused: bool
    ) -> None:
        result = advance_order(
            frm=OrderStatus.CONFIRMED,
            to=OrderStatus.CANCELLED,
            lines=[UNMEASURED],
            reason=reason,
        )
        assert (result.refused_because is StatusRefusal.NO_REASON) == refused
        assert MIN_REASON_LENGTH == 4

    def test_a_reason_is_not_asked_for_on_any_other_transition(self) -> None:
        # Only cancellation needs one. Requiring it everywhere would put a
        # dialog in front of the measurer six times a day.
        assert advance_order(
            frm=OrderStatus.READY,
            to=OrderStatus.INSTALLED,
            lines=[EVERYTHING_DONE],
        ).is_allowed

    def test_the_reason_is_not_checked_before_the_transition_itself(self) -> None:
        # installed -> cancelled is refused because it is not an edge, not
        # because of the reason. Reporting "no reason" there would send
        # somebody off to write a better one for a move never to be allowed.
        assert (
            advance_order(
                frm=OrderStatus.INSTALLED,
                to=OrderStatus.CANCELLED,
                lines=[EVERYTHING_DONE],
                reason="",
            ).refused_because
            is StatusRefusal.NOT_A_TRANSITION
        )


def test_staying_put_is_distinguishable_from_being_refused() -> None:
    # The screen shows nothing for already_there and an error for the rest, so
    # collapsing them would put an error in front of somebody who tapped twice.
    result = advance_order(frm=OrderStatus.READY, to=OrderStatus.READY, lines=[])
    assert not result.is_allowed
    assert result.refused_because is StatusRefusal.ALREADY_THERE
