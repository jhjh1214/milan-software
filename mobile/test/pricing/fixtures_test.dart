import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/pricing/engine.dart';
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
            File('${dir.path}/shared/rate-card-seed.json').readAsStringSync(),
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

  test('the seed card is flagged provisional until A2a arrives', () {
    // If this ever fails because the flag was flipped, the real price list
    // landed — check that the rates were replaced, not just the boolean.
    expect(
      card.provisional,
      isTrue,
      reason: 'shared/rate-card-seed.json is spec examples, not the price list',
    );
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
      });
    }
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

String _findFixtures() {
  var dir = Directory.current;
  while (!File('${dir.path}/shared/pricing-fixtures.json').existsSync()) {
    dir = dir.parent;
  }
  return '${dir.path}/shared/pricing-fixtures.json';
}
