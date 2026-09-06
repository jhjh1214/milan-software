import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/pricing/engine.dart';
import 'package:milan_quote/pricing/einvoice_threshold.dart';
import 'package:milan_quote/pricing/final_pricing.dart';
import 'package:milan_quote/pricing/models.dart';

/// Runs `shared/pricing-fixtures.json`, the contract between the Dart and
/// Python engines. CLAUDE.md hard rule 3: every case lives there once and both
/// suites load it. A rule change means editing the fixture, then making both
/// sides pass.
void main() {
  late RateCard card;
  late Map<String, dynamic> fixtures;

  setUpAll(() {
    // Walk up from the test's working directory to the repo root, so this
    // works whether the suite is run from mobile/ or from the root.
    var dir = Directory.current;
    while (!File('${dir.path}/shared/pricing-fixtures.json').existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) {
        fail(
          'could not locate shared/pricing-fixtures.json from ${Directory.current}',
        );
      }
      dir = parent;
    }
    card = RateCard.fromJson(
      jsonDecode(
            File(
              '${dir.path}/shared/rate-card-fair-2026-08.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
    fixtures =
        jsonDecode(
              File(
                '${dir.path}/shared/pricing-fixtures.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
  });

  test('the card is the real price list, not the provisional stand-in', () {
    // A2a is answered: this card is transcribed from the MITC Aug 2026 list.
    expect(card.provisional, isFalse);
    expect(card.version, greaterThanOrEqualTo(1));
    expect(
      card.rules.length,
      greaterThan(60),
      reason: 'the full list has 77 rows across seven families',
    );
    expect(card.deliveryZones, hasLength(2));
    expect(card.productRules, isNotEmpty);
  });

  test('the fair rates from the printed list are exactly what is loaded', () {
    // Spot-checks straight off the PDF. If someone edits the card by hand and
    // fat-fingers a rate, this is where it surfaces.
    const printed = <String, int>{
      'night-curtain-lo': 4600,
      'night-curtain-hi': 5800,
      'day-curtain-lo': 3600,
      'day-curtain-hi': 4800,
      's-track-night-lo': 8000,
      's-track-night-hi': 9200,
      'multi-track-lo': 6800,
      'multi-track-hi': 7500,
      'doso-track': 900,
      'meyer-track': 1000,
      'roller-blackout': 900,
      'roller-printing': 1700,
      'zebra-blackout-jbl': 1200,
      'zebra-blackout-tbl': 1500,
      'timber-35': 2100,
      'spc-8mm-hrw': 1200,
      'spc-herringbone': 800,
      'self-levelling': 300,
      'korea-wallpaper': 80000,
    };
    for (final entry in printed.entries) {
      final rule = card.rules.firstWhere(
        (r) => r.id == entry.key,
        orElse: () => fail('missing rule ${entry.key}'),
      );
      expect(rule.rateSen, entry.value, reason: entry.key);
    }
  });

  test('MVP rates appear only where the list prints them', () {
    // Inventing an MVP rate for a product that has none would quietly discount
    // it forever. The printed list gives MVP on night curtain and S-track only.
    final withMvp =
        card.rules.where((r) => r.mvpRateSen != null).map((r) => r.id).toList()
          ..sort();
    expect(withMvp, [
      'night-curtain-hi',
      'night-curtain-lo',
      's-track-night-hi',
      's-track-night-lo',
    ]);
  });

  test('no rate is hardcoded in the engine — every rule came from data', () {
    expect(card.rules, isNotEmpty);
    for (final rule in card.rules) {
      expect(rule.rateSen, greaterThan(0), reason: '${rule.id} has no rate');
    }
  });

  group('line cases', () {
    test('the fixture file actually contains cases', () {
      expect((fixtures['cases'] as List).length, greaterThanOrEqualTo(15));
    });

    for (final raw
        in (jsonDecode(File(_findFixtures()).readAsStringSync())
                as Map<String, dynamic>)['cases']
            as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      final id = c['id'] as String;
      final why = c['why'] as String;

      test('$id — $why', () {
        final line = c['line'] as Map<String, dynamic>;
        final expected = c['expect'] as Map<String, dynamic>;

        final result = priceLine(
          request: LineRequest(
            variant: line['variant'] as String,
            materialKey: line['material_key'] as String?,
            layer: Layer.fromWire(line['layer'] as String),
            fulfilment: Fulfilment.fromWire(line['fulfilment'] as String),
            width: Length.tenths(line['width_tmm'] as int),
            height: line['height_tmm'] == null
                ? null
                : Length.tenths(line['height_tmm'] as int),
            quantity: line['quantity'] as int,
          ),
          card: card,
          stage: _stage(c['stage'] as String),
          tier: _tier(c['tier'] as String),
        );

        expect(
          result.rule.id,
          expected['rule_id'],
          reason: 'wrong rule chosen',
        );
        expect(
          result.billedQty.toString(),
          expected['billed_qty'],
          reason: 'billed quantity',
        );
        expect(result.billedUnit, expected['billed_unit']);
        expect(result.minQtyApplied, expected['min_qty_applied']);
        expect(result.rateSen, expected['rate_sen'], reason: 'wrong rate');
        expect(
          result.total.sen,
          expected['total_sen'],
          reason:
              'expected ${Money.sen(expected['total_sen'] as int)}, '
              'got ${result.total}',
        );

        if (expected.containsKey('material_deferred')) {
          expect(
            result.materialDeferred,
            expected['material_deferred'],
            reason: 'material deferral',
          );
        }
        if (expected.containsKey('material_options')) {
          expect(
            result.materialOptions,
            expected['material_options'],
            reason: 'material options offered',
          );
        }
        if (expected.containsKey('deposit_category')) {
          expect(
            result.depositCategory.name,
            expected['deposit_category'],
            reason: 'deposit category — a lock on the wrong category misprices',
          );
        }
      });
    }
  });

  group('final pricing cases', () {
    // SPEC.md §11 Phase 6. `available_card_versions` says which cards the
    // caller holds. Only version 1 exists as a file, so a case listing another
    // version is saying the held card is not to hand — which must refuse
    // rather than quietly fall back to the active one.
    test('the fixture file actually contains cases', () {
      expect(
        (fixtures['final_pricing_cases'] as List).length,
        greaterThanOrEqualTo(10),
      );
    });

    for (final raw
        in (jsonDecode(File(_findFixtures()).readAsStringSync())
                as Map<String, dynamic>)['final_pricing_cases']
            as List<dynamic>) {
      final c = raw as Map<String, dynamic>;

      test('${c['id']} — ${c['why']}', () {
        final cards = <int, RateCard>{
          for (final v in (c['available_card_versions'] as List).cast<int>())
            if (v == card.version) v: card,
        };

        final result = repriceOrder(
          lines: [
            for (final rawLine in c['lines'] as List<dynamic>)
              () {
                final l = rawLine as Map<String, dynamic>;
                return MeasuredLine(
                  id: l['id'] as String,
                  variant: l['variant'] as String,
                  materialKey: l['material_key'] as String?,
                  layer: Layer.fromWire(l['layer'] as String),
                  fulfilment: Fulfilment.fromWire(l['fulfilment'] as String),
                  quantity: l['quantity'] as int,
                  estimateTotal: Money.sen(l['estimate_total_sen'] as int),
                  appliedRateCardVersion: l['applied_rate_card_version'] as int,
                  finalWidth: l['final_width_tmm'] == null
                      ? null
                      : Length.tenths(l['final_width_tmm'] as int),
                  finalHeight: l['final_height_tmm'] == null
                      ? null
                      : Length.tenths(l['final_height_tmm'] as int),
                  materialDeferred: l['material_deferred'] as bool,
                );
              }(),
          ],
          cards: cards,
        );

        final expected = c['expect'] as Map<String, dynamic>;
        final expectedLines = (expected['lines'] as List)
            .cast<Map<String, dynamic>>();

        expect(
          result.lines.map((l) => l.id).toList(),
          expectedLines.map((e) => e['id']).toList(),
          reason: 'every line comes back, in order',
        );

        for (var i = 0; i < expectedLines.length; i++) {
          final got = result.lines[i];
          final want = expectedLines[i];

          expect(
            got.pricedAtVersion,
            want['priced_at_version'],
            reason: '${got.id}: priced at the version it recorded',
          );
          expect(
            got.finalTotal?.sen,
            want['final_total_sen'],
            reason: '${got.id}: final total',
          );
          expect(
            got.variance?.sen,
            want['variance_sen'],
            reason: '${got.id}: variance',
          );
          expect(
            got.isOverEstimate,
            want['over_estimate'],
            reason: '${got.id}: over the estimate',
          );
          expect(
            got.refusal?.wire,
            want['refusal'],
            reason: '${got.id}: refusal',
          );

          if (want.containsKey('billed_qty')) {
            expect(
              billedQuantityOf(got).toString(),
              want['billed_qty'],
              reason: '${got.id}: the tape is billed exactly',
            );
            expect(got.priced?.billedUnit, want['billed_unit']);
          }
        }

        expect(result.estimateTotal.sen, expected['estimate_total_sen']);
        expect(
          result.finalTotal?.sen,
          expected['final_total_sen'],
          reason: 'order total',
        );
        expect(result.variance?.sen, expected['variance_sen']);
        expect(result.isComplete, expected['is_complete']);
      });
    }

    test('every refusal reason is exercised by a case', () {
      // A refusal nothing covers is a branch that will be wrong the first time
      // it fires, in a house, with a customer watching.
      final seen = <String>{
        for (final raw in fixtures['final_pricing_cases'] as List)
          for (final line
              in ((raw as Map<String, dynamic>)['expect']
                      as Map<String, dynamic>)['lines']
                  as List)
            if ((line as Map<String, dynamic>)['refusal'] != null)
              line['refusal'] as String,
      };

      expect(seen, contains(FinalPricingRefusal.notMeasured.wire));
      expect(seen, contains(FinalPricingRefusal.materialNotChosen.wire));
      expect(seen, contains(FinalPricingRefusal.cardUnavailable.wire));
    });
  });

  group('plausible dimensions come off the card', () {
    // §5.4 requires these in config, not code. If they ever stop being read
    // from the card, this is where it shows up.
    test('the real card configures a range per category', () {
      final ranges = card.config.plausibleByCategory;
      expect(ranges.keys, containsAll(<String>['curtain', 'flooring']));

      final curtain = ranges['curtain']!;
      expect(curtain.width, isNotNull);
      expect(curtain.second, isNotNull);
    });

    test('8000in is outside the curtain range, 8000mm is inside it', () {
      // The worked example, against the card the app actually ships.
      final width = card.config.plausibleByCategory['curtain']!.width!;
      expect(width.covers(8000 * 254), isFalse, reason: '203 metres');
      expect(width.covers(8000 * 10), isTrue, reason: '8 metres');
    });

    test('a curtain drop is bounded tighter than a curtain width', () {
      // They are different questions, which is why they are separate fields.
      final curtain = card.config.plausibleByCategory['curtain']!;
      expect(curtain.second!.maxTmm, lessThan(curtain.width!.maxTmm!));
    });

    test('the card names the second dimension for what it is', () {
      // A curtain has a `drop`, a floor a `length`, a wall a `height`. The
      // loader reads whichever the category uses, and the card is edited by
      // hand — so it has to read correctly to the person editing it.
      final raw =
          jsonDecode(File(_findCard()).readAsStringSync())
              as Map<String, dynamic>;
      final plausible =
          (raw['config'] as Map<String, dynamic>)['plausible_dimensions']
              as Map<String, dynamic>;

      expect((plausible['curtain'] as Map).keys, contains('drop_max_tmm'));
      expect(
        (plausible['flooring'] as Map).keys,
        contains('length_max_tmm'),
        reason: 'a floor lies flat — it has a length, not a height',
      );
      expect((plausible['wallpaper'] as Map).keys, contains('height_max_tmm'));

      // And each one is actually read, whatever it is called.
      for (final category in const ['curtain', 'flooring', 'wallpaper']) {
        expect(
          card.config.plausibleByCategory[category]?.second,
          isNotNull,
          reason: '$category: the second dimension must be loaded',
        );
      }
    });
  });

  group('what a family calls its second dimension', () {
    test('a floor has a length, a curtain a drop, a wall a height', () {
      // The arithmetic is the same either way — per_sqft multiplies the two.
      // What differs is what a person is asked to measure, and asking for the
      // "height" of a floor invites them to type the wall.
      expect(secondDimensionOf(Family.flooring), SecondDimension.length);
      expect(secondDimensionOf(Family.curtain), SecondDimension.drop);
      expect(secondDimensionOf(Family.blind), SecondDimension.drop);
      expect(secondDimensionOf(Family.track), SecondDimension.drop);
      expect(secondDimensionOf(Family.wallpaper), SecondDimension.height);
    });

    test('every family has an answer', () {
      // A family with none would fall through to whatever the switch defaults
      // to, silently, on a screen.
      for (final family in Family.values) {
        expect(secondDimensionOf(family), isNotNull, reason: family.name);
      }
    });

    test('no flooring row bands, which is why it has no drop', () {
      // The reason flooring is the odd one out. Nothing it sells is priced by
      // how tall it is, so its second dimension never selects a rate — it is
      // the other side of a floor area.
      final flooring = card.rules.where((r) => r.family == Family.flooring);
      expect(flooring, isNotEmpty);
      for (final rule in flooring) {
        expect(rule.bandField, BandField.none, reason: rule.id);
      }
    });

    test('flooring is sold by area, except skirting which is a run', () {
      // Skirting follows the wall, so it is charged in running feet and uses
      // only the first dimension. Worth pinning: it is the one flooring row
      // where a second dimension would be meaningless rather than mislabelled.
      final byBasis = <PriceBasis, List<String>>{};
      for (final rule in card.rules.where((r) => r.family == Family.flooring)) {
        (byBasis[rule.basis] ??= []).add(rule.id);
      }

      expect(byBasis[PriceBasis.perFtWidth], ['skirting']);
      expect(
        byBasis[PriceBasis.perSqft],
        hasLength(greaterThan(5)),
        reason: 'every other flooring row is an area',
      );
      expect(byBasis.keys, hasLength(2), reason: 'no third basis crept in');
    });
  });

  group('e-invoice threshold cases', () {
    // SPEC.md §10.2-§10.4. The two figures come off the real card, never from
    // literals here: §10.3 says the threshold lives in config because it will
    // change, and a test that hard-coded it would keep passing after it did.
    test('the fixture file actually contains cases', () {
      expect(
        (fixtures['einvoice_threshold_cases'] as List).length,
        greaterThanOrEqualTo(12),
      );
    });

    for (final raw
        in (jsonDecode(File(_findFixtures()).readAsStringSync())
                as Map<String, dynamic>)['einvoice_threshold_cases']
            as List<dynamic>) {
      final c = raw as Map<String, dynamic>;

      test('${c['id']} — ${c['why']}', () {
        final result = checkThreshold(
          total: Money.sen(c['total_sen'] as int),
          stage: ThresholdStage.fromWire(c['stage'] as String),
          config: card.config.thresholds,
          buyerDetailsComplete: c['buyer_details_complete'] as bool,
          einvoiceRequested: c['einvoice_requested'] as bool,
        );

        final expected = c['expect'] as Map<String, dynamic>;
        expect(
          result.mustCapture,
          expected['must_capture'],
          reason: 'whether buyer details are wanted',
        );
        expect(
          result.blocksAdvance,
          expected['blocks_advance'],
          reason: 'whether the order may go on without them',
        );
        expect(result.reason?.wire, expected['reason'], reason: 'why');
      });
    }

    test('the thresholds come off the card, not out of the code', () {
      // §10.3: "Threshold lives in config, not code. It will change." If it
      // ever stops being read from the card, this is where that shows up.
      expect(card.config.einvoiceThresholdSen, 1000000);
      expect(card.config.einvoicePromptSen, 800000);

      // And the rule follows the card rather than a constant.
      final moved = const ThresholdConfig(
        threshold: Money.sen(2000000),
        prompt: Money.sen(1500000),
      );
      expect(
        checkThreshold(
          total: const Money.sen(1200000),
          stage: ThresholdStage.finalPricing,
          config: moved,
        ).blocksAdvance,
        isFalse,
      );
    });

    test('a card published before this defaults to the law', () {
      // Not to "never ask". A missing threshold that meant no check would be
      // silent non-compliance on exactly the oldest handsets.
      final old = RateCardConfig.fromJson(const {
        'min_deposit_sen': 30000,
        'band_edge_warn_tmm': 760,
      });
      expect(old.einvoiceThresholdSen, 1000000);
      expect(old.einvoicePromptSen, 800000);
    });

    test('every reason is exercised by a case', () {
      final seen = <String>{
        for (final raw in fixtures['einvoice_threshold_cases'] as List)
          if (((raw as Map<String, dynamic>)['expect']
                  as Map<String, dynamic>)['reason'] !=
              null)
            ((raw['expect']) as Map<String, dynamic>)['reason'] as String,
      };
      expect(seen, {for (final r in ThresholdReason.values) r.wire});
    });
  });

  group('buyer detail cases', () {
    // SPEC.md §10.3. What counts as having the buyer's details, which is the
    // only thing that clears the RM10,000 block.
    for (final raw
        in (jsonDecode(File(_findFixtures()).readAsStringSync())
                as Map<String, dynamic>)['buyer_details_cases']
            as List<dynamic>) {
      final c = raw as Map<String, dynamic>;

      test('${c['id']} — ${c['why']}', () {
        final b = c['buyer'] as Map<String, dynamic>;
        final buyer = BuyerDetails(
          name: b['name'] as String?,
          tin: b['tin'] as String?,
          idType: b['id_type'] as String?,
          idNumber: b['id_number'] as String?,
          addressLine1: b['address_line1'] as String?,
          addressLine2: b['address_line2'] as String?,
          city: b['city'] as String?,
          state: b['state'] as String?,
          postcode: b['postcode'] as String?,
        );

        final expected = c['expect'] as Map<String, dynamic>;
        expect(buyerDetailsComplete(buyer), expected['complete']);
        expect(
          missingBuyerDetails(buyer).map((m) => m.wire).toList(),
          expected['missing'],
          reason: 'everything outstanding, named at once and in order',
        );
      });
    }

    test('every missing piece is exercised by a case', () {
      final seen = <String>{
        for (final raw in fixtures['buyer_details_cases'] as List)
          ...(((raw as Map<String, dynamic>)['expect']
                      as Map<String, dynamic>)['missing']
                  as List)
              .cast<String>(),
      };
      expect(seen, {for (final m in BuyerDetailsMissing.values) m.wire});
    });
  });

  group('quote total cases', () {
    for (final raw
        in (jsonDecode(File(_findFixtures()).readAsStringSync())
                as Map<String, dynamic>)['quote_total_cases']
            as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      final id = c['id'] as String;

      test('$id — ${c['why']}', () {
        final stage = _stage(c['stage'] as String);
        final lineTotals = (c['line_totals_sen'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(DepositCategory.values.byName(k), v as int),
        );

        final totals = totalQuote(
          lines: [
            for (final e in lineTotals.entries)
              _stubLine(category: e.key, totalSen: e.value, card: card),
          ],
          card: card,
          stage: stage,
          deliveryZoneId: c['delivery_zone_id'] as String?,
        );

        final expected = c['expect'] as Map<String, dynamic>;
        final expectedSubtotals =
            (expected['category_subtotals_sen'] as Map<String, dynamic>);
        final expectedUplift =
            (expected['category_floor_uplift_sen'] as Map<String, dynamic>);

        for (final e in expectedSubtotals.entries) {
          final cat = DepositCategory.values.byName(e.key);
          expect(
            totals.categorySubtotals[cat]?.sen,
            e.value,
            reason: 'subtotal ${e.key}',
          );
        }
        for (final e in expectedUplift.entries) {
          final cat = DepositCategory.values.byName(e.key);
          expect(
            totals.categoryFloorUplift[cat]?.sen,
            e.value,
            reason: 'uplift ${e.key}',
          );
        }
        if (expected.containsKey('delivery_charge_sen')) {
          expect(
            totals.deliveryCharge.sen,
            expected['delivery_charge_sen'],
            reason: 'delivery charge',
          );
        }
        expect(totals.total.sen, expected['total_sen'], reason: 'quote total');
      });
    }
  });
}

PricingStage _stage(String s) => switch (s) {
  'estimate' => PricingStage.estimate,
  'final' => PricingStage.finalPricing,
  _ => throw ArgumentError('unknown stage $s'),
};

CustomerTier _tier(String s) => switch (s) {
  'standard' => CustomerTier.standard,
  'mvp' => CustomerTier.mvp,
  _ => throw ArgumentError('unknown tier $s'),
};

/// Builds a line that only carries a total and a category, for exercising the
/// order-level floor without re-testing line pricing.
PricedLine _stubLine({
  required DepositCategory category,
  required int totalSen,
  required RateCard card,
}) {
  final family = switch (category) {
    DepositCategory.curtain => Family.curtain,
    DepositCategory.flooring => Family.flooring,
    DepositCategory.wallpaper => Family.wallpaper,
  };
  final rule = card.rules.first;
  return PricedLine(
    rule: PricingRule(
      id: 'stub',
      family: family,
      variant: rule.variant,
      layer: rule.layer,
      materialKey: null,
      fulfilment: rule.fulfilment,
      labels: rule.labels,
      basis: rule.basis,
      bandField: BandField.none,
      bandMinTmm: null,
      bandMaxTmm: null,
      bandLabels: null,
      rateSen: rule.rateSen,
      mvpRateSen: null,
      minQty: null,
      sortOrder: 0,
    ),
    stage: PricingStage.estimate,
    rawQty: Rational.one,
    billedQty: Rational.one,
    billedUnit: 'ft',
    minQtyApplied: false,
    standardRateSen: totalSen,
    rateSen: totalSen,
    quantity: 1,
    total: Money.sen(totalSen),
  );
}

String _findCard() {
  var dir = Directory.current;
  while (!File('${dir.path}/shared/pricing-fixtures.json').existsSync()) {
    dir = dir.parent;
  }
  return '${dir.path}/shared/rate-card-fair-2026-08.json';
}

String _findFixtures() {
  var dir = Directory.current;
  while (!File('${dir.path}/shared/pricing-fixtures.json').existsSync()) {
    dir = dir.parent;
  }
  return '${dir.path}/shared/pricing-fixtures.json';
}
