"""Derives the standard (non-fair) price list from the fair one.

PROVISIONAL. The client's answer to SPEC.md section 13 A3, Sep 2026, given
explicitly as a placeholder to unblock: "for non fair price all curtains are 20%
more expensive, blinds are 50% more expensive, will revise back after".

Run:  python tool/build_standard_card.py

Regenerate whenever the fair card changes, or delete this script and drop in the
real standard list the moment one exists. The derivation is recorded in the
output file so nobody mistakes it for a printed price.

Two decisions this makes, both flagged in section 13:

1. **MVP keeps its flat differential rather than being marked up.** Section 4.1
   is explicit that MVP is "a FLAT discount, not a percentage. Constant sen off."
   Marking RM40 up by 20% would turn RM6 off into RM7.20 off and quietly make
   MVP a percentage. So the standard rate moves and the gap stays: night curtain
   RM55.20 with MVP RM49.20.

2. **Families with no markup keep the fair rate**, because inventing one would
   be inventing a price. That is 45 of the 77 rows, including every track.
"""
import json
import pathlib
from fractions import Fraction

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAIR = ROOT / "shared" / "rate-card-fair-2026-08.json"
OUT = ROOT / "shared" / "rate-card-standard.json"

# Only what the client actually stated. Anything absent keeps the fair rate.
MARKUP = {
    "curtain": Fraction(6, 5),   # +20%
    "blind": Fraction(3, 2),     # +50%
}


def main() -> None:
    card = json.loads(FAIR.read_text(encoding="utf-8"))

    marked, untouched = 0, 0
    rules = []
    for rule in card["rules"]:
        markup = MARKUP.get(rule["family"])
        if markup is None:
            untouched += 1
            rules.append(rule)
            continue

        rate = Fraction(rule["rate_sen"]) * markup
        if rate.denominator != 1:
            raise SystemExit(
                f"{rule['id']}: markup does not land on a whole sen ({float(rate)})"
            )
        new_rate = int(rate)

        mvp = rule["mvp_rate_sen"]
        if mvp is not None:
            # Preserve the flat differential, per section 4.1.
            mvp = new_rate - (rule["rate_sen"] - mvp)

        marked += 1
        rules.append({**rule, "rate_sen": new_rate, "mvp_rate_sen": mvp})

    unmarked_families = sorted(
        {r["family"] for r in card["rules"] if r["family"] not in MARKUP}
    )

    out = {
        "_source": "DERIVED from rate-card-fair-2026-08.json, not a printed price list.",
        "_derivation": (
            "Client instruction, Sep 2026, explicitly provisional: curtains +20%, "
            "blinds +50% over the fair rate. MVP keeps its flat differential "
            "rather than being marked up, because section 4.1 requires MVP to be "
            "a constant sen off rather than a percentage."
        ),
        "_warning": (
            "NO MARKUP WAS SPECIFIED for " + ", ".join(unmarked_families) + ". "
            f"Those {untouched} rows therefore sell at FAIR price in the showroom, "
            "including all 22 track rows -- and a track is often dearer than the "
            "curtain it carries. See SPEC.md section 13, A3a."
        ),
        "_replace_me": (
            "Delete this file and drop in the real standard list as soon as one "
            "exists. Regenerate with tool/build_standard_card.py."
        ),
        "provisional": True,
        # A separate version lineage from the fair card, so a quote that records
        # its rate_card_version is never ambiguous about which list priced it.
        # Phase 3 gives versions a proper home in Postgres and this goes away.
        "version": 101,
        # No promo block: the standard list is not promotional and never expires.
        "config": card["config"],
        "delivery_zones": card["delivery_zones"],
        "product_rules": card["product_rules"],
        "rules": rules,
    }

    OUT.write_text(
        json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(f"wrote {OUT.relative_to(ROOT)}")
    print(f"  marked up : {marked} rows")
    print(f"  unchanged : {untouched} rows ({', '.join(unmarked_families)})")
    nc = next(r for r in rules if r["id"] == "night-curtain-lo")
    print(f"  night curtain: RM{nc['rate_sen'] / 100:.2f}, MVP RM{nc['mvp_rate_sen'] / 100:.2f}")


main()
