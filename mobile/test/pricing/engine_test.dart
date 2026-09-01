import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/pricing/engine.dart';
import 'package:milan_quote/pricing/models.dart';

String _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/shared/pricing-fixtures.json').existsSync()) {
    dir = dir.parent;
  }
  return dir.path;
}

RateCard _card() => RateCard.fromJson(
  jsonDecode(
        File(
          '${_repoRoot()}/shared/rate-card-fair-2026-08.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

Length ft(num v) => Length.tenths((v * 3048).round());

void main() {
  late RateCard card;
  setUpAll(() => card = _card());

  group('an expired fair card is detected, not silently trusted', () {
    // SPEC.md §13 A3. The only card in the system is a four-day fair promo.
    // Quoting a walk-in from it in November undercharges on every sale, and
    // nothing on screen would say so.
    test('the card carries its promotion window', () {
      expect(card.promo, isNotNull);
      expect(card.promo!.code, 'MITC-2026-08');
      expect(card.promo!.validFrom, DateTime(2026, 8, 28));
      expect(card.promo!.validTo, DateTime(2026, 8, 31));
    });

    test('inside the fair, the card is current', () {
      for (final day in [
        DateTime(2026, 8, 28),
        DateTime(2026, 8, 30),
        DateTime(2026, 8, 31), // the final day is inclusive
      ]) {
        expect(
          card.isExpiredOn(day),
          isFalse,
          reason: '${day.toIso8601String()} is inside the fair',
        );
      }
    });

    test('a day either side of the fair, the card is expired', () {
      expect(card.isExpiredOn(DateTime(2026, 8, 27)), isTrue);
      expect(card.isExpiredOn(DateTime(2026, 9, 1)), isTrue);
      expect(card.isExpiredOn(DateTime(2026, 11, 15)), isTrue);
    });

    test('the time of day does not affect the last day of the fair', () {
      // A quote at 9pm on the closing night is still a fair quote.
      expect(card.isExpiredOn(DateTime(2026, 8, 31, 21, 30)), isFalse);
    });

    test('a card with no promotion never expires', () {
      final standing = RateCard(
        version: 1,
        provisional: false,
        config: card.config,
        rules: card.rules,
      );
      expect(standing.isExpiredOn(DateTime(2099, 1, 1)), isFalse);
    });
  });

  group('constraints that are not prices', () {
    // SPEC.md §4.1 lists these as rules rather than rates. A 25ft ZIP blind is
    // not a wrong price — it is an order that cannot be fulfilled, and finding
    // that out at installation costs far more than finding it out here.
    test('an outdoor ZIP blind wider than 20ft is refused', () {
      expect(
        () => priceLine(
          request: LineRequest(
            variant: 'outdoor_zip_manual',
            width: ft(21),
            height: ft(8),
          ),
          card: card,
          stage: PricingStage.estimate,
        ),
        throwsA(isA<ProductRuleViolation>()),
      );
    });

    test('exactly 20ft is allowed — the limit is a maximum, not a barrier', () {
      final result = priceLine(
        request: LineRequest(
          variant: 'outdoor_zip_manual',
          width: ft(20),
          height: ft(8),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      expect(result.billedQty, Rational.fromInt(160));
    });

    test('one tenth of a millimetre over the limit is refused', () {
      expect(
        () => priceLine(
          request: LineRequest(
            variant: 'outdoor_zip_manual',
            width: Length.tenths(60961),
            height: ft(8),
          ),
          card: card,
          stage: PricingStage.estimate,
        ),
        throwsA(isA<ProductRuleViolation>()),
      );
    });

    test('the motorised ZIP carries the same width limit', () {
      expect(
        () => priceLine(
          request: LineRequest(
            variant: 'outdoor_zip_motor',
            width: ft(25),
            height: ft(8),
          ),
          card: card,
          stage: PricingStage.estimate,
        ),
        throwsA(isA<ProductRuleViolation>()),
      );
    });

    test('the violation carries its message in all three languages', () {
      // The UI must be able to say what is wrong in the reader's language
      // rather than showing an English string baked into the engine.
      try {
        priceLine(
          request: LineRequest(
            variant: 'outdoor_zip_manual',
            width: ft(25),
            height: ft(8),
          ),
          card: card,
          stage: PricingStage.estimate,
        );
        fail('should have raised');
      } on ProductRuleViolation catch (e) {
        expect(e.rule.messages('zh'), contains('20'));
        expect(e.rule.messages('en').toLowerCase(), contains('20ft'));
        expect(e.rule.messages('ms').toLowerCase(), contains('20'));
        expect(e.actual.tmm, greaterThan(e.rule.valueTmm!));
      }
    });

    test('a curtain is not constrained by a blind rule', () {
      // The rules are keyed by variant. A 25ft curtain is unusual but legal.
      final result = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: ft(25),
          height: ft(9),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      expect(result.billedQty, Rational.fromInt(25));
    });
  });

  group('the engine is pure', () {
    test('nothing under lib/pricing imports Flutter', () {
      // CLAUDE.md: "The pricing engine is pure. No Flutter imports, no I/O, no
      // clock reads except an injected one." A structural test, because this
      // is the kind of rule that erodes one convenient import at a time.
      final dir = Directory('${_repoRoot()}/mobile/lib/pricing');
      final offenders = <String>[];
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        for (final line in file.readAsLinesSync()) {
          final t = line.trim();
          if (!t.startsWith('import ')) continue;
          if (t.contains('package:flutter/') ||
              t.contains('package:flutter_riverpod') ||
              t.contains("'dart:io'") ||
              t.contains("'dart:ui'")) {
            offenders.add('${file.uri.pathSegments.last}: $t');
          }
        }
      }
      expect(offenders, isEmpty, reason: 'the pricing engine must stay pure');
    });
  });

  group('band selection never guesses', () {
    test('a gap in the rate card raises rather than picking the cheapest', () {
      // SPEC.md §4.3 step 2: "no match -> throw NoApplicableRate. NEVER pick
      // the cheapest." A silent fallback is a confident wrong price.
      final gapCard = RateCard(
        version: 0,
        provisional: true,
        config: card.config,
        rules: [
          for (final r in card.rules)
            if (r.id == 'seed-night-curtain-lower') r,
        ],
      );
      expect(
        () => priceLine(
          request: LineRequest(
            variant: 'night_curtain',
            layer: Layer.night,
            width: ft(12),
            height: ft(12), // above the only band present
          ),
          card: gapCard,
          stage: PricingStage.estimate,
        ),
        throwsA(isA<NoApplicableRate>()),
      );
    });

    test('an unknown variant raises', () {
      expect(
        () => priceLine(
          request: LineRequest(variant: 'no_such_product', width: ft(12)),
          card: card,
          stage: PricingStage.estimate,
        ),
        throwsA(isA<NoApplicableRate>()),
      );
    });

    test('a banded product with no height given raises', () {
      expect(
        () => priceLine(
          request: LineRequest(
            variant: 'night_curtain',
            layer: Layer.night,
            width: ft(12),
          ),
          card: card,
          stage: PricingStage.estimate,
        ),
        throwsA(isA<NoApplicableRate>()),
      );
    });

    test('the wrong material key does not silently match another rate', () {
      // Zebra J/BL and TBL differ by RM3/sqft. Falling through to the other
      // one would be invisible and wrong.
      expect(
        () => priceLine(
          request: const LineRequest(
            variant: 'zebra_blackout',
            materialKey: 'does_not_exist',
            width: Length.zero,
          ),
          card: card,
          stage: PricingStage.estimate,
        ),
        throwsA(isA<NoApplicableRate>()),
      );
    });
  });

  group('height selects the band and never multiplies', () {
    test('changing height alone changes the band, not the quantity', () {
      // Hard rule 5, and SPEC.md calls it the single most likely thing to get
      // wrong. Same width, two heights: quantity identical, rate different.
      final low = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: ft(12),
          height: ft(9),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      final high = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: ft(12),
          height: ft(12),
        ),
        card: card,
        stage: PricingStage.estimate,
      );

      expect(low.billedQty, high.billedQty, reason: 'height must not multiply');
      expect(low.billedQty, Rational.fromInt(12));
      expect(low.rateSen, 4600);
      expect(high.rateSen, 5800);
      expect(high.total.sen - low.total.sen, 14400, reason: 'the RM144 step');
    });
  });

  group('minimum quantity', () {
    test('applies before the rate multiplies, not after', () {
      // 12 sqft at RM9 would be RM108. The minimum is on the quantity, so the
      // answer is 18 x RM9 = RM162, not max(RM108, some minimum charge).
      final result = priceLine(
        request: LineRequest(
          variant: 'roller_blackout',
          width: ft(3),
          height: ft(4),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      expect(result.rawQty, Rational.fromInt(12));
      expect(result.billedQty, Rational.fromInt(18));
      expect(result.minQtyApplied, isTrue);
      expect(result.total.sen, 16200);
    });

    test('does not fire when the real quantity is already above it', () {
      final result = priceLine(
        request: LineRequest(
          variant: 'roller_blackout',
          width: ft(5),
          height: ft(6),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      expect(result.billedQty, Rational.fromInt(30));
      expect(result.minQtyApplied, isFalse);
    });
  });

  group('MVP is a flat rate', () {
    test('substitutes the printed MVP rate, with no percentage arithmetic', () {
      final standard = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: ft(12),
          height: ft(9),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      final mvp = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: ft(12),
          height: ft(9),
        ),
        card: card,
        stage: PricingStage.estimate,
        tier: CustomerTier.mvp,
      );

      expect(standard.rateSen, 4600);
      expect(mvp.rateSen, 4000);
      // RM6 off flat, identical in both bands — never a ratio.
      expect(standard.rateSen - mvp.rateSen, 600);
      expect(mvp.standardRateSen, 4600, reason: 'the quote still prints RM46');
      expect(mvp.tierRateApplied, isTrue);
    });

    test(
      'a product without an MVP rate charges standard, not an invention',
      () {
        final mvp = priceLine(
          request: LineRequest(
            variant: 'day_curtain',
            layer: Layer.day,
            width: ft(12),
            height: ft(9),
          ),
          card: card,
          stage: PricingStage.estimate,
          tier: CustomerTier.mvp,
        );
        expect(mvp.rateSen, 3600);
        expect(mvp.tierRateApplied, isFalse);
      },
    );
  });

  group('deposit category mapping', () {
    test('blinds and tracks ride the curtain deposit', () {
      // SPEC.md §6.1. Kept in one function precisely so this cannot drift.
      expect(depositCategoryOf(Family.curtain), DepositCategory.curtain);
      expect(depositCategoryOf(Family.blind), DepositCategory.curtain);
      expect(depositCategoryOf(Family.track), DepositCategory.curtain);
      expect(depositCategoryOf(Family.flooring), DepositCategory.flooring);
      expect(depositCategoryOf(Family.wallpaper), DepositCategory.wallpaper);
    });

    test('a roller blind line belongs to the curtain deposit', () {
      final result = priceLine(
        request: LineRequest(
          variant: 'roller_blackout',
          width: ft(3),
          height: ft(4),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      expect(result.depositCategory, DepositCategory.curtain);
    });
  });

  group('quantity of identical windows', () {
    test('multiplies after the line rounds, not before', () {
      final one = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: ft(12),
          height: ft(9),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      final three = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: ft(12),
          height: ft(9),
          quantity: 3,
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      expect(three.total.sen, one.total.sen * 3);
    });

    test('a quantity below one is rejected', () {
      expect(
        () => priceLine(
          request: LineRequest(
            variant: 'night_curtain',
            layer: Layer.night,
            width: ft(12),
            height: ft(9),
            quantity: 0,
          ),
          card: card,
          stage: PricingStage.estimate,
        ),
        throwsArgumentError,
      );
    });
  });

  group('the RM300 quotation floor', () {
    test('is read from config, not compiled in', () {
      expect(card.config.minDepositSen, 30000);
    });

    test('lifts a small quote and reports the uplift separately', () {
      final line = priceLine(
        request: LineRequest(
          variant: 'roller_blackout',
          width: ft(3),
          height: ft(4),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      final totals = totalQuote(
        lines: [line],
        card: card,
        stage: PricingStage.estimate,
      );

      // The line keeps its real total; the floor is a separate row.
      expect(line.total.sen, 16200);
      expect(totals.categorySubtotals[DepositCategory.curtain]!.sen, 16200);
      expect(totals.categoryFloorUplift[DepositCategory.curtain]!.sen, 13800);
      expect(totals.total.sen, 30000);
      expect(totals.anyFloorApplied, isTrue);
    });

    test('does not apply at final pricing', () {
      final line = priceLine(
        request: LineRequest(
          variant: 'roller_blackout',
          width: ft(3),
          height: ft(4),
        ),
        card: card,
        stage: PricingStage.finalPricing,
      );
      final totals = totalQuote(
        lines: [line],
        card: card,
        stage: PricingStage.finalPricing,
      );
      expect(totals.total.sen, 16200);
      expect(totals.anyFloorApplied, isFalse);
    });
  });

  group('the two stages round differently, on purpose', () {
    test('the estimate is never below the final for the same window', () {
      // The property behind the disclaimer in §8.5: rounding up only ever
      // moves one way, so a customer can only be surprised downward.
      for (var inches = 0; inches < 12; inches++) {
        final width = Length.tenths(12 * 3048 + inches * 254);
        final request = LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: width,
          height: ft(9),
        );
        final estimate = priceLine(
          request: request,
          card: card,
          stage: PricingStage.estimate,
        );
        final settled = priceLine(
          request: request,
          card: card,
          stage: PricingStage.finalPricing,
        );
        expect(
          estimate.total.sen,
          greaterThanOrEqualTo(settled.total.sen),
          reason: 'at 12ft ${inches}in the quote must not undercut the bill',
        );
      }
    });

    test('12ft 4in quotes RM598.00 and bills RM567.33', () {
      final width = Length.tenths(12 * 3048 + 4 * 254);
      final request = LineRequest(
        variant: 'night_curtain',
        layer: Layer.night,
        width: width,
        height: ft(9),
      );
      expect(
        priceLine(
          request: request,
          card: card,
          stage: PricingStage.estimate,
        ).total.format(),
        'RM 598.00',
      );
      expect(
        priceLine(
          request: request,
          card: card,
          stage: PricingStage.finalPricing,
        ).total.format(),
        'RM 567.33',
      );
    });
  });
}
