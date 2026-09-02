"""Generates a systematic sweep both engines must agree on.

`shared/pricing-fixtures.json` is the contract: hand-written cases that pin the
rules that matter. This is different -- a wide, mechanical sweep across widths,
heights, variants, stages and tiers, so the two engines are compared on
thousands of inputs nobody thought to write a case for.

It proves the engines AGREE, not that either is right. The fixtures prove
correctness; this catches drift. Both are needed: §9.4 has the server re-price
every line the app sends, and a disagreement there means the customer was told
one number and invoiced another.

Run:  python tool/build_crosscheck.py

The Dart suite loads the result and must reproduce every total.
"""
from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from app.core.length import Length  # noqa: E402
from app.pricing.engine import (  # noqa: E402
    LineRequest,
    NoApplicableRate,
    ProductRuleViolation,
    price_line,
)
from app.pricing.models import (  # noqa: E402
    CustomerTier,
    Fulfilment,
    Layer,
    PricingStage,
    RateCard,
)

FT = 3048
IN = 254

# Widths and heights chosen to sit on and around every boundary that matters:
# exact feet, the 10ft band edge, one tenth of a millimetre either side of it,
# whole inches, and values that produce recurring fractions.
WIDTHS = [
    3 * FT,
    12 * FT,            # exactly 12ft -- the round-trip regression
    12 * FT + 4 * IN,   # 12ft 4in -> 37/3 ft, a recurring fraction
    17 * FT + 7 * IN,   # deliberately awkward
    20 * FT,            # the ZIP limit, exactly
    1000,               # not a whole anything
]
HEIGHTS = [
    4 * FT,
    9 * FT,
    10 * FT,            # exactly 10ft -- the band fencepost
    10 * FT + 1,        # one tenth of a mm over it
    13 * FT + 5 * IN,
]


def main() -> None:
    card = RateCard.from_json(
        json.loads(
            (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(
                encoding="utf-8"
            )
        )
    )

    # One representative rule per (variant, material), so every priceable
    # product on the card is swept rather than just the ones in the fixtures.
    seen: set[tuple[str, str | None]] = set()
    products = []
    for rule in sorted(card.rules, key=lambda r: r.sort_order):
        key = (rule.variant, rule.material_key)
        if key in seen:
            continue
        seen.add(key)
        products.append(rule)

    cases = []
    skipped = 0
    for rule in products:
        for width in WIDTHS:
            for height in HEIGHTS:
                for stage in (PricingStage.ESTIMATE, PricingStage.FINAL):
                    # MVP only where the rule actually has an MVP rate;
                    # sweeping it elsewhere just duplicates the standard case.
                    tiers = [CustomerTier.STANDARD]
                    if rule.mvp_rate_sen is not None:
                        tiers.append(CustomerTier.MVP)
                    for tier in tiers:
                        request = LineRequest(
                            variant=rule.variant,
                            material_key=rule.material_key,
                            layer=rule.layer,
                            fulfilment=rule.fulfilment,
                            width=Length(width),
                            height=Length(height),
                        )
                        try:
                            priced = price_line(
                                request=request,
                                card=card,
                                stage=stage,
                                tier=tier,
                            )
                        except (NoApplicableRate, ProductRuleViolation):
                            # A refusal is correct behaviour, but the two
                            # engines refuse via different exception types, so
                            # only successful prices are compared here. The
                            # refusals have their own hand-written tests.
                            skipped += 1
                            continue

                        cases.append(
                            {
                                "variant": rule.variant,
                                "material_key": rule.material_key,
                                "layer": rule.layer.value,
                                "fulfilment": rule.fulfilment.value,
                                "width_tmm": width,
                                "height_tmm": height,
                                "stage": stage.value,
                                "tier": tier.value,
                                "rule_id": priced.rule.id,
                                "billed_qty": (
                                    str(priced.billed_qty.numerator)
                                    if priced.billed_qty.denominator == 1
                                    else f"{priced.billed_qty.numerator}/{priced.billed_qty.denominator}"
                                ),
                                "rate_sen": priced.rate_sen,
                                "total_sen": priced.total.sen,
                            }
                        )

    out = {
        "_purpose": (
            "A mechanical sweep both engines must agree on, generated by "
            "tool/build_crosscheck.py from the Python engine. It proves the two "
            "engines AGREE; shared/pricing-fixtures.json is what proves either "
            "is RIGHT. Regenerate after any deliberate pricing change, and read "
            "the diff before committing it -- a changed total here that you did "
            "not intend is the bug."
        ),
        "_rate_card": "rate-card-fair-2026-08.json",
        "generated_cases": len(cases),
        "cases": cases,
    }
    dest = ROOT / "shared" / "engine-crosscheck.json"
    dest.write_text(json.dumps(out, indent=1) + "\n", encoding="utf-8")

    print(f"wrote {dest.relative_to(ROOT)}")
    print(f"  products swept : {len(products)}")
    print(f"  cases          : {len(cases)}")
    print(f"  refusals skipped: {skipped}")
    print(f"  size           : {dest.stat().st_size / 1024:.0f} KB")


main()
