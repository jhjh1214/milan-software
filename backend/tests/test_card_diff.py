"""What a rate card publish would change. SPEC.md §11 Phase 5.

    Publishing shows exactly which products move and by how much before commit

That is the acceptance criterion, and it is a promise about the moment before a
price change goes live. So the tests are about what somebody would be misled by:
a row that moves and is not listed, a rule that disappears without being called
out, and a preview so full of noise that the two rows that matter are lost in it.

The real 77-row fair card is used rather than a toy, because the shape of a real
rule — labels as a map, an optional MVP rate, ids that are stable while labels
are not — is where this would go wrong.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from app.services.card_diff import diff_cards

ROOT = Path(__file__).resolve().parents[2]
CARD = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)


@pytest.fixture
def card() -> dict:
    return copy.deepcopy(CARD)


def rule_of(card: dict, rule_id: str) -> dict:
    return next(r for r in card["rules"] if r["id"] == rule_id)


class TestNothingMoves:
    def test_a_card_against_itself_is_empty(self, card) -> None:
        # Publishing a card identical to the live one creates a version nobody
        # can tell apart from the last. Saying so plainly beats an empty list.
        diff = diff_cards(card, copy.deepcopy(card))
        assert diff.is_empty
        assert diff.unchanged == len(card["rules"])
        assert diff.total_delta_sen == 0

    def test_a_relabelled_rule_is_not_a_price_change(self, card) -> None:
        # Listing it would bury the rows that are. The id is what identifies a
        # rule; the label is what an admin reads.
        after = copy.deepcopy(card)
        rule_of(after, "night-curtain-lo")["labels"]["en"] = "Night Curtain"

        diff = diff_cards(card, after)
        assert diff.is_empty
        assert diff.changed == []


class TestWhatMoves:
    def test_a_changed_rate_is_listed_with_both_numbers(self, card) -> None:
        after = copy.deepcopy(card)
        rule_of(after, "night-curtain-lo")["rate_sen"] = 5000

        diff = diff_cards(card, after)
        assert len(diff.changed) == 1

        change = diff.changed[0]
        assert change.rule_id == "night-curtain-lo"
        assert change.old_rate_sen == 4600
        assert change.new_rate_sen == 5000
        assert change.delta_sen == 400
        assert change.rate_changed

    def test_an_mvp_rate_moving_on_its_own_still_counts(self, card) -> None:
        # The MVP tier is a flat discount and its own number. A card where only
        # the MVP rates move would otherwise preview as "nothing changes".
        after = copy.deepcopy(card)
        rule_of(after, "night-curtain-lo")["mvp_rate_sen"] = 3500

        diff = diff_cards(card, after)
        assert len(diff.changed) == 1
        assert diff.changed[0].mvp_changed
        assert not diff.changed[0].rate_changed

    def test_the_label_shown_is_the_reader_s_language(self, card) -> None:
        after = copy.deepcopy(card)
        rule_of(after, "night-curtain-lo")["rate_sen"] = 5000

        english = diff_cards(card, after, language="en").changed[0].label
        chinese = diff_cards(card, after, language="zh").changed[0].label
        assert english == rule_of(CARD, "night-curtain-lo")["labels"]["en"]
        assert chinese == rule_of(CARD, "night-curtain-lo")["labels"]["zh"]
        assert english != chinese

    def test_the_biggest_move_is_first(self, card) -> None:
        # The row that will start an argument is the row somebody reads first.
        after = copy.deepcopy(card)
        rule_of(after, "night-curtain-lo")["rate_sen"] = 4700  # +1
        rule_of(after, "night-curtain-hi")["rate_sen"] = 10000

        diff = diff_cards(card, after)
        assert diff.changed[0].rule_id == "night-curtain-hi"

    def test_a_drop_sorts_by_size_not_by_sign(self, card) -> None:
        # A big cut is as worth reading as a big rise, and burying it under a
        # one-ringgit increase would be the wrong way round.
        after = copy.deepcopy(card)
        rule_of(after, "night-curtain-lo")["rate_sen"] = 4700  # +1
        rule_of(after, "night-curtain-hi")["rate_sen"] = 100  # a large cut

        diff = diff_cards(card, after)
        assert diff.changed[0].rule_id == "night-curtain-hi"

    def test_the_total_says_which_way_the_card_went(self, card) -> None:
        # Forty rows each a ringgit dearer is a price rise nobody described
        # that way, and it is invisible row by row.
        after = copy.deepcopy(card)
        for rule in after["rules"][:10]:
            rule["rate_sen"] = (rule.get("rate_sen") or 0) + 100

        diff = diff_cards(card, after)
        assert len(diff.changed) == 10
        assert diff.total_delta_sen == 1000


class TestAddedAndRemoved:
    def test_a_new_rule_is_called_out_separately(self, card) -> None:
        after = copy.deepcopy(card)
        fresh = copy.deepcopy(rule_of(after, "night-curtain-lo"))
        fresh["id"] = "night-curtain-brand-new"
        after["rules"].append(fresh)

        diff = diff_cards(card, after)
        assert [c.rule_id for c in diff.added] == ["night-curtain-brand-new"]
        assert diff.changed == []
        assert not diff.is_empty

    def test_a_vanished_rule_is_called_out_too(self, card) -> None:
        # A product that stops being quotable is at least as big a change as
        # one that gets dearer, and it is the one nobody would notice.
        after = copy.deepcopy(card)
        after["rules"] = [r for r in after["rules"] if r["id"] != "night-curtain-lo"]

        diff = diff_cards(card, after)
        assert [c.rule_id for c in diff.removed] == ["night-curtain-lo"]
        assert diff.removed[0].old_rate_sen == 4600
        assert diff.removed[0].new_rate_sen is None

    def test_an_added_rule_has_no_delta(self, card) -> None:
        # "Moved by RM46" is a sentence about a rule that existed before.
        after = copy.deepcopy(card)
        fresh = copy.deepcopy(rule_of(after, "night-curtain-lo"))
        fresh["id"] = "brand-new"
        after["rules"].append(fresh)

        assert diff_cards(card, after).added[0].delta_sen is None

    def test_added_rules_do_not_move_the_total(self, card) -> None:
        # The total is about what changed price, not about how much new stock
        # exists. Mixing them makes the number mean nothing.
        #
        # Today this holds structurally: an added rule's delta is None, so
        # summing over `added` as well would contribute zero and no test could
        # tell the difference. Mutation testing found exactly that. What this
        # still pins is the property that survives if `delta_sen` ever changes
        # -- give an added rule a delta of `new - 0` and this goes red.
        after = copy.deepcopy(card)
        fresh = copy.deepcopy(rule_of(after, "night-curtain-lo"))
        fresh["id"] = "brand-new"
        after["rules"].append(fresh)

        diff = diff_cards(card, after)
        assert diff.total_delta_sen == 0
        assert diff.added[0].new_rate_sen == 4600, (
            "the rule really does carry a price, so a total that counted it "
            "would be visibly wrong rather than coincidentally right"
        )


class TestTheFirstCard:
    def test_against_nothing_every_rule_reads_as_added(self, card) -> None:
        # The first card on a fresh box changes nothing, because there was
        # nothing.
        diff = diff_cards(None, card)
        assert len(diff.added) == len(card["rules"])
        assert diff.changed == []
        assert diff.removed == []
        assert not diff.is_empty

    def test_a_card_with_no_rules_removes_everything(self, card) -> None:
        # Which is a thing somebody has to be shown before they confirm it.
        diff = diff_cards(card, {"rules": []})
        assert len(diff.removed) == len(card["rules"])
        assert diff.changed == []


class TestMalformedInput:
    def test_a_missing_rules_list_is_not_a_crash(self, card) -> None:
        # A publish preview is the last place to throw. Somebody pasted the
        # wrong file, and they need to be told, not shown a stack trace.
        assert len(diff_cards(card, {}).removed) == len(card["rules"])
        assert diff_cards({}, {}).is_empty

    def test_a_rule_with_no_id_is_ignored_rather_than_guessed(self, card) -> None:
        after = copy.deepcopy(card)
        after["rules"].append({"labels": {"en": "Mystery"}, "rate_sen": 100})
        assert diff_cards(card, after).added == []

    def test_a_rule_with_no_labels_still_has_a_name(self, card) -> None:
        after = copy.deepcopy(card)
        after["rules"].append({"id": "no-labels", "rate_sen": 100})
        assert diff_cards(card, after).added[0].label == "no-labels"

    def test_a_missing_rate_is_none_rather_than_zero(self, card) -> None:
        # Zero is a real price. Treating "absent" as RM0.00 would preview a
        # free product as though somebody had chosen to give it away.
        after = copy.deepcopy(card)
        del rule_of(after, "night-curtain-lo")["rate_sen"]

        change = diff_cards(card, after).changed[0]
        assert change.new_rate_sen is None
        assert change.old_rate_sen == 4600
