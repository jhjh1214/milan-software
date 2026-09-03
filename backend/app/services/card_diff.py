"""What a rate card publish would actually change. SPEC.md §11 Phase 5.

    Publishing shows exactly which products move and by how much before commit

That is the first acceptance criterion of Phase 5, and it is really a promise
about the moment before a price change becomes live: nobody publishes 77 rows
and hopes. What this returns is the list somebody reads out loud before saying
yes.

## Why the server owns this and not the dashboard

CLAUDE.md hard rule 4 makes the server the authority on pricing. A diff computed
in TypeScript would be a third implementation beside the Dart one on the handset
and whatever the server does at publish time, and the one that decides what is
*shown* would not be the one that decides what is *stored*. Then the preview
becomes a thing people learn not to trust.

So the dashboard asks, and this answers. The handset keeps its own CSV importer
for the admin editing on a phone, and that one is compared against the same
rules in `rate_card_csv.dart` -- but it publishes through the server too, so the
server's answer is always the one that lands.

## What counts as a change

Only the rate and the MVP rate. A label moving from "Night curtain" to "Night
Curtain" is not a price change and putting it in this list would bury the two
rows that are. Added and removed rules are called out separately, because a rule
that vanishes silently is a product nobody can quote any more.

Pure of HTTP. The router calls this; the tests call it directly.
"""

from __future__ import annotations

from dataclasses import dataclass, field

#: Which language's label to show in the diff. The admin reads product names
#: they recognise; the ids are stable and the labels are not.
DEFAULT_LANGUAGE = "zh"


@dataclass(frozen=True, slots=True)
class RateChange:
    """One rule whose price moves."""

    rule_id: str
    label: str

    old_rate_sen: int | None
    new_rate_sen: int | None

    old_mvp_rate_sen: int | None
    new_mvp_rate_sen: int | None

    @property
    def rate_changed(self) -> bool:
        return self.old_rate_sen != self.new_rate_sen

    @property
    def mvp_changed(self) -> bool:
        return self.old_mvp_rate_sen != self.new_mvp_rate_sen

    @property
    def delta_sen(self) -> int | None:
        """What the standard rate moves by, or None when a side is missing.

        None for an added or removed rule: "moved by RM46" is a sentence about
        a rule that existed before and still does.
        """
        if self.old_rate_sen is None or self.new_rate_sen is None:
            return None
        return self.new_rate_sen - self.old_rate_sen


@dataclass(frozen=True, slots=True)
class CardDiff:
    """Everything a publish would do, before it does any of it."""

    #: Rules that exist on both sides with a different price.
    changed: list[RateChange] = field(default_factory=list)

    #: Rules the new card has and the old one does not.
    added: list[RateChange] = field(default_factory=list)

    #: Rules the old card has and the new one does not. A product that stops
    #: being quotable is at least as big a change as one that gets dearer.
    removed: list[RateChange] = field(default_factory=list)

    #: Rules on both sides at the same price. Counted, not listed -- a preview
    #: is only readable if it shows what moves.
    unchanged: int = 0

    @property
    def is_empty(self) -> bool:
        """Nothing would move.

        Worth its own answer. Publishing a card identical to the live one
        creates a version nobody can tell apart from the last, and the honest
        thing is to say so rather than to show an empty list.
        """
        return not (self.changed or self.added or self.removed)

    @property
    def total_delta_sen(self) -> int:
        """What the changed rules move by, added up.

        A quick read on direction: forty rows each a ringgit dearer is a price
        rise nobody described that way, and it is invisible row by row.
        """
        return sum(c.delta_sen or 0 for c in self.changed)


def _label_of(rule: dict, language: str) -> str:
    """A rule's name in the reader's language.

    Labels are a map, never parallel columns (CLAUDE.md), so this reads the map
    and falls back rather than assuming any one language is present.
    """
    labels = rule.get("labels") or {}
    if isinstance(labels, dict):
        for key in (language, "en", "zh", "ms"):
            value = labels.get(key)
            if isinstance(value, str) and value:
                return value
    name = rule.get("variant") or rule.get("id")
    return str(name) if name is not None else "(unnamed)"


def _rate_of(rule: dict, key: str) -> int | None:
    value = rule.get(key)
    return value if isinstance(value, int) else None


def _by_id(card: dict) -> dict[str, dict]:
    rules = card.get("rules")
    if not isinstance(rules, list):
        return {}
    return {
        str(rule["id"]): rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("id") is not None
    }


def diff_cards(
    old: dict | None, new: dict, *, language: str = DEFAULT_LANGUAGE
) -> CardDiff:
    """What publishing ``new`` would change about ``old``.

    ``old`` may be None -- the first card on a fresh box changes nothing
    because there was nothing, and every rule reads as added.
    """
    before = _by_id(old or {})
    after = _by_id(new)

    changed: list[RateChange] = []
    added: list[RateChange] = []
    unchanged = 0

    for rule_id, rule in after.items():
        new_rate = _rate_of(rule, "rate_sen")
        new_mvp = _rate_of(rule, "mvp_rate_sen")
        label = _label_of(rule, language)

        old_rule = before.get(rule_id)
        if old_rule is None:
            added.append(
                RateChange(
                    rule_id=rule_id,
                    label=label,
                    old_rate_sen=None,
                    new_rate_sen=new_rate,
                    old_mvp_rate_sen=None,
                    new_mvp_rate_sen=new_mvp,
                )
            )
            continue

        old_rate = _rate_of(old_rule, "rate_sen")
        old_mvp = _rate_of(old_rule, "mvp_rate_sen")

        # Only prices. A relabelled rule is not a price change, and listing it
        # would bury the two rows that are.
        if old_rate == new_rate and old_mvp == new_mvp:
            unchanged += 1
            continue

        changed.append(
            RateChange(
                rule_id=rule_id,
                label=label,
                old_rate_sen=old_rate,
                new_rate_sen=new_rate,
                old_mvp_rate_sen=old_mvp,
                new_mvp_rate_sen=new_mvp,
            )
        )

    removed = [
        RateChange(
            rule_id=rule_id,
            label=_label_of(rule, language),
            old_rate_sen=_rate_of(rule, "rate_sen"),
            new_rate_sen=None,
            old_mvp_rate_sen=_rate_of(rule, "mvp_rate_sen"),
            new_mvp_rate_sen=None,
        )
        for rule_id, rule in before.items()
        if rule_id not in after
    ]

    # Sorted by how far the price moves, dearest first, so the row that will
    # start an argument is the row somebody reads first. Added and removed keep
    # their card order, which is the order the admin arranged them in.
    changed.sort(key=lambda c: abs(c.delta_sen or 0), reverse=True)

    return CardDiff(changed=changed, added=added, removed=removed, unchanged=unchanged)
