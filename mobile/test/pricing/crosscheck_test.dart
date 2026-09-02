import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/pricing/engine.dart';
import 'package:milan_quote/pricing/models.dart';

/// Every case in `shared/engine-crosscheck.json`, priced by the Dart engine.
///
/// That file is a mechanical sweep generated from the **Python** engine:
/// 4,080 combinations of product, width, height, stage and tier, across every
/// priceable row on the card. It proves the two engines AGREE.
/// `pricing-fixtures.json` is what proves either is RIGHT.
///
/// Both are needed. §9.4 has the server re-price every line the app sends, so a
/// disagreement means the customer was told one number and invoiced another —
/// and the hand-written fixtures only cover cases somebody thought to write.
///
/// If this goes red after a deliberate pricing change, regenerate with
/// `python tool/build_crosscheck.py` and **read the diff**. A total that moved
/// when you did not mean it to is the bug.
void main() {
  late RateCard card;
  late List<dynamic> cases;

  setUpAll(() {
    var dir = Directory.current;
    while (!File('${dir.path}/shared/engine-crosscheck.json').existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) fail('repo root not found');
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
    cases =
        (jsonDecode(
                  File(
                    '${dir.path}/shared/engine-crosscheck.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>)['cases']
            as List<dynamic>;
  });

  test('the sweep is substantial enough to be worth trusting', () {
    // A green run over three cases would prove nothing.
    expect(cases, hasLength(greaterThan(3000)));
  });

  test(
    'every case the Python engine priced, the Dart engine prices the same',
    () {
      // Run as one test rather than 4,080 parametrised ones: the failure message
      // names the exact case, and 4,080 test names would bury the signal.
      final failures = <String>[];

      for (final raw in cases) {
        final c = raw as Map<String, dynamic>;
        final id =
            '${c['variant']}'
            '${c['material_key'] == null ? '' : '/${c['material_key']}'}'
            ' w=${c['width_tmm']} h=${c['height_tmm']} '
            '${c['stage']}/${c['tier']}';

        try {
          final result = priceLine(
            request: LineRequest(
              variant: c['variant'] as String,
              materialKey: c['material_key'] as String?,
              layer: Layer.fromWire(c['layer'] as String),
              fulfilment: Fulfilment.fromWire(c['fulfilment'] as String),
              width: Length.tenths(c['width_tmm'] as int),
              height: Length.tenths(c['height_tmm'] as int),
            ),
            card: card,
            stage: c['stage'] == 'estimate'
                ? PricingStage.estimate
                : PricingStage.finalPricing,
            tier: c['tier'] == 'mvp' ? CustomerTier.mvp : CustomerTier.standard,
          );

          if (result.rule.id != c['rule_id']) {
            failures.add('$id: rule ${result.rule.id} != ${c['rule_id']}');
          } else if (result.billedQty.toString() != c['billed_qty']) {
            failures.add('$id: qty ${result.billedQty} != ${c['billed_qty']}');
          } else if (result.rateSen != c['rate_sen']) {
            failures.add('$id: rate ${result.rateSen} != ${c['rate_sen']}');
          } else if (result.total.sen != c['total_sen']) {
            failures.add('$id: total ${result.total.sen} != ${c['total_sen']}');
          }
        } catch (e) {
          // Python priced it; Dart refusing is a disagreement.
          failures.add('$id: Dart threw where Python priced — $e');
        }
      }

      expect(
        failures.take(10),
        isEmpty,
        reason:
            '${failures.length} of ${cases.length} cases disagree between the '
            'Dart and Python engines',
      );
    },
  );
}
