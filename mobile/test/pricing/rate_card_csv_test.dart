import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/pricing/engine.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_card_csv.dart';

/// The admin changes prices in a spreadsheet, not in code.
///
/// CLAUDE.md hard rule 1: a price change must never need a code change, a
/// rebuild or a release.
void main() {
  late RateCard card;
  late String cardSource;

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    cardSource = File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).readAsStringSync();
    card = RateCard.fromJson(jsonDecode(cardSource) as Map<String, dynamic>);
  });

  group('export', () {
    test('every rule gets a row, with a header and guidance', () {
      final csv = exportRateCardCsv(card, 'en');
      final lines = csv
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      expect(lines.first, startsWith('id,'));
      expect(lines.length, card.rules.length + 1);
    });

    test('prices export as plain decimals an admin can read', () {
      final csv = exportRateCardCsv(card, 'en');
      final row = csv
          .split('\n')
          .firstWhere((l) => l.startsWith('night-curtain-lo,'));
      // RM46.00 and the MVP RM40.00, without the RM prefix so Excel treats
      // them as numbers.
      expect(row, contains(',46.00,40.00,'));
    });

    test('a product name containing a comma is quoted', () {
      final csv = exportRateCardCsv(card, 'en');
      for (final line in csv.split('\n')) {
        if (line.startsWith('#') || line.startsWith('id,')) continue;
        if (line.isEmpty) continue;
        // Every row must split back into at least the 7 declared columns.
        expect(
          readRateCardCsv('id,a,b,c,d,e,f\n$line', card).errors,
          isEmpty,
          reason: 'row did not round-trip: $line',
        );
      }
    });

    test('a round trip with nothing edited changes nothing', () {
      final csv = exportRateCardCsv(card, 'en');
      final result = readRateCardCsv(csv, card);
      expect(result.errors, isEmpty);
      expect(result.changes, hasLength(card.rules.length));
      expect(result.actualChanges, isEmpty, reason: 'no edits, no changes');
    });
  });

  group('import', () {
    String edited(String id, String rate, {String mvp = ''}) =>
        'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
        '$id,Night Curtain,Up to 10ft,ft,$rate,$mvp,';

    test('a changed rate is detected and reported with its delta', () {
      final result = readRateCardCsv(
        edited('night-curtain-lo', '50.00', mvp: '44.00'),
        card,
      );
      expect(result.errors, isEmpty);
      final change = result.actualChanges.single;
      expect(change.oldRateSen, 4600);
      expect(change.newRateSen, 5000);
      expect(change.deltaSen, 400);
      expect(change.newMvpRateSen, 4400);
    });

    test('decimals are exact — 4.80 is 480 sen, not 479 or 481', () {
      // Parsed as an exact decimal, never through a double: binary floating
      // point does not hold 4.80.
      final result = readRateCardCsv(edited('spc-4mm', '4.80'), card);
      expect(result.actualChanges, isEmpty, reason: '4.80 is the current rate');

      final changed = readRateCardCsv(edited('spc-4mm', '4.85'), card);
      expect(changed.actualChanges.single.newRateSen, 485);
    });

    test('an RM prefix and thousands separators are tolerated', () {
      // A comma inside a cell must be quoted, which is what Excel writes. The
      // parser then strips the separator and the RM an admin may have typed.
      final result = readRateCardCsv(
        edited('dream-blind-motor', '"RM1,600.00"'),
        card,
      );
      expect(result.errors, isEmpty);
      expect(result.actualChanges.single.newRateSen, 160000);
    });

    test('an unquoted thousands separator is caught, not misread', () {
      // Splitting on it would silently read RM1,600 as RM1 and shift every
      // later column. Better to fail loudly.
      final result = readRateCardCsv(
        edited('dream-blind-motor', 'RM1,600.00'),
        card,
      );
      expect(result.errors, isNotEmpty);
    });

    test('an unknown id is an error, never a silent no-op', () {
      // A typo that quietly does nothing is worse than an error: the admin
      // walks away believing the price changed.
      final result = readRateCardCsv(
        edited('night-curtain-typo', '50.00'),
        card,
      );
      expect(result.errors.single, contains('night-curtain-typo'));
      expect(result.actualChanges, isEmpty);
    });

    test('a duplicated id is an error', () {
      final result = readRateCardCsv(
        'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
        'night-curtain-lo,a,b,ft,50.00,,\n'
        'night-curtain-lo,a,b,ft,60.00,,',
        card,
      );
      expect(result.errors.single, contains('more than once'));
    });

    test('a rate that is not a number is an error', () {
      expect(
        readRateCardCsv(
          edited('night-curtain-lo', 'fifty'),
          card,
        ).errors.single,
        contains('not a price'),
      );
    });

    test('a zero or negative rate is refused', () {
      expect(
        readRateCardCsv(edited('night-curtain-lo', '0'), card).errors.single,
        contains('not sellable'),
      );
      // A negative is stopped one step earlier, by the money parser, so it
      // reports "not a price" rather than "not sellable". Either way it is
      // refused; the point of the test is that no rule ever holds one.
      expect(
        readRateCardCsv(edited('night-curtain-lo', '-1.00'), card).errors,
        isNotEmpty,
      );
    });

    group('a placeholder row', () {
      // Stairs and landings were added before their rates were known. The
      // export writes 0.00 for them, so the import has to accept that value
      // back on those rows — and only those rows.
      test('accepts the 0.00 the export wrote, as no change', () {
        final result = readRateCardCsv(edited('stair-step-narrow', '0.00'), card);
        expect(result.errors, isEmpty);
        expect(result.actualChanges, isEmpty);
      });

      test('a negative rate is still refused', () {
        // The exception is for zero exactly, not for "anything unsellable".
        expect(
          readRateCardCsv(edited('stair-step-narrow', '-1.00'), card).errors,
          isNotEmpty,
        );
      });

      test('a real rate makes it sellable in the same edit', () {
        // The flag and the number move together. If they could drift apart the
        // admin would type RM120, be told it was accepted, and the engine
        // would still refuse to quote the product.
        final result = readRateCardCsv(
          edited('stair-step-narrow', '120.00'),
          card,
        );
        expect(result.errors, isEmpty);
        final change = result.actualChanges.single;
        expect(change.newRateSen, 12000);
        expect(change.clearsProvisional, isTrue);

        final applied = applyRateCardImport(card, result);
        final rule = applied.rules.firstWhere(
          (r) => r.id == 'stair-step-narrow',
        );
        expect(rule.provisional, isFalse);
        expect(rule.rateSen, 12000);

        // And the one it did not price is untouched.
        expect(
          applied.rules.firstWhere((r) => r.id == 'stair-step-wide').provisional,
          isTrue,
        );
      });

      test('is quotable once priced, and refused before', () {
        LineRequest request() => LineRequest(
          variant: 'stair_step',
          width: Length.tenths(4 * 3048),
          quantity: 14,
        );

        expect(
          () => priceLine(
            request: request(),
            card: card,
            stage: PricingStage.estimate,
          ),
          throwsA(isA<NoApplicableRate>()),
        );

        final priced = applyRateCardImport(
          card,
          readRateCardCsv(edited('stair-step-narrow', '120.00'), card),
        );
        expect(
          priceLine(
            request: request(),
            card: priced,
            stage: PricingStage.estimate,
          ).total.sen,
          168000,
          reason: '14 steps at RM120',
        );
      });

      test('the JSON route clears the flag too', () {
        // The two apply paths must agree: one writes the map the asset is
        // rebuilt from, the other the card held in memory.
        final json = jsonDecode(cardSource) as Map<String, dynamic>;
        final out = applyRateCardImportToJson(
          json,
          readRateCardCsv(edited('stair-step-narrow', '120.00'), card),
        );
        final row = (out['rules'] as List<dynamic>).firstWhere(
          (r) => (r as Map<String, dynamic>)['id'] == 'stair-step-narrow',
        ) as Map<String, dynamic>;
        expect(row['provisional'], isFalse);
        expect(row['rate_sen'], 12000);
      });
    });

    test('an MVP rate above the standard rate is refused', () {
      // A transcription slip that would quietly charge the best customers most.
      final result = readRateCardCsv(
        edited('night-curtain-lo', '46.00', mvp: '50.00'),
        card,
      );
      expect(result.errors.single, contains('above the standard rate'));
    });

    test('a missing header is an error', () {
      expect(
        readRateCardCsv('night-curtain-lo,a,b,ft,50.00,,', card).errors,
        isNotEmpty,
      );
    });

    test('comments and blank lines are ignored', () {
      final result = readRateCardCsv(
        '# a note\n\n'
        'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
        '\n'
        'night-curtain-lo,a,b,ft,50.00,,\n',
        card,
      );
      expect(result.errors, isEmpty);
      expect(result.actualChanges, hasLength(1));
    });
  });

  group('editing one price in the app', () {
    PricingRule rule(String id) => card.rules.firstWhere((r) => r.id == id);

    test('goes through the same validation as the CSV route', () {
      // One set of rules about what a price may be, not two that drift apart.
      final result = editSingleRate(
        rule: rule('night-curtain-lo'),
        rateText: '50.00',
        mvpText: '44.00',
      );
      expect(result.errors, isEmpty);
      final change = result.actualChanges.single;
      expect(change.newRateSen, 5000);
      expect(change.newMvpRateSen, 4400);
      expect(change.deltaSen, 400);
    });

    test('a blank MVP field clears the MVP rate', () {
      final result = editSingleRate(
        rule: rule('night-curtain-lo'),
        rateText: '46.00',
        mvpText: '',
      );
      expect(result.actualChanges.single.newMvpRateSen, isNull);
    });

    test('an unreadable rate is rejected', () {
      expect(
        editSingleRate(
          rule: rule('night-curtain-lo'),
          rateText: 'abc',
          mvpText: '',
        ).errors,
        contains('rate'),
      );
    });

    test('a zero rate is rejected', () {
      expect(
        editSingleRate(
          rule: rule('night-curtain-lo'),
          rateText: '0',
          mvpText: '',
        ).errors,
        contains('rate'),
      );
    });

    test('an MVP rate above the standard rate is rejected', () {
      expect(
        editSingleRate(
          rule: rule('night-curtain-lo'),
          rateText: '46.00',
          mvpText: '50.00',
        ).errors,
        contains('mvp_above_rate'),
      );
    });

    test('typing the same price back is not a change', () {
      final result = editSingleRate(
        rule: rule('night-curtain-lo'),
        rateText: '46.00',
        mvpText: '40.00',
      );
      expect(result.errors, isEmpty);
      expect(
        result.actualChanges,
        isEmpty,
        reason: 'no version bump for a no-op',
      );
    });

    test('decimals stay exact', () {
      expect(
        editSingleRate(
          rule: rule('spc-4mm'),
          rateText: '4.85',
          mvpText: '',
        ).actualChanges.single.newRateSen,
        485,
      );
    });
  });

  group('applying', () {
    test('publishes a new version rather than editing in place', () {
      // CLAUDE.md: rate card rows are never updated in place, so a quote
      // already priced at the old version can still be explained.
      final import = readRateCardCsv(
        'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
        'night-curtain-lo,a,b,ft,50.00,44.00,',
        card,
      );
      final updated = applyRateCardImport(card, import);

      expect(updated.version, card.version + 1);
      expect(
        card.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        4600,
      );
      expect(
        updated.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        5000,
      );
    });

    test('untouched rules are carried across unchanged', () {
      final import = readRateCardCsv(
        'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
        'night-curtain-lo,a,b,ft,50.00,,',
        card,
      );
      final updated = applyRateCardImport(card, import);
      expect(updated.rules, hasLength(card.rules.length));
      expect(
        updated.rules.firstWhere((r) => r.id == 'roller-blackout').rateSen,
        900,
      );
      expect(updated.deliveryZones, hasLength(2));
      expect(updated.productRules, isNotEmpty);
    });

    test('the new rate is what the engine then charges', () {
      // The whole point: a price change is data, and the next quote uses it
      // with no code change and no rebuild.
      final before = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: Length.tenths(36576),
          height: Length.tenths(27432),
        ),
        card: card,
        stage: PricingStage.estimate,
      );
      expect(before.total.format(), 'RM 552.00');

      final updated = applyRateCardImport(
        card,
        readRateCardCsv(
          'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
          'night-curtain-lo,a,b,ft,50.00,,',
          card,
        ),
      );
      final after = priceLine(
        request: LineRequest(
          variant: 'night_curtain',
          layer: Layer.night,
          width: Length.tenths(36576),
          height: Length.tenths(27432),
        ),
        card: updated,
        stage: PricingStage.estimate,
      );
      expect(after.total.format(), 'RM 600.00', reason: '12ft x RM50');
    });

    test('an import cannot change a band, a basis or which products exist', () {
      // Only rates move. Restructuring the card through a spreadsheet with no
      // validation is how a band silently disappears.
      final import = readRateCardCsv(
        'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
        'night-curtain-lo,RENAMED,DIFFERENT BAND,sqft,50.00,,999',
        card,
      );
      final updated = applyRateCardImport(card, import);
      final rule = updated.rules.firstWhere((r) => r.id == 'night-curtain-lo');

      expect(rule.basis, PriceBasis.perFtWidth, reason: 'basis unchanged');
      expect(rule.bandMaxTmm, 30481, reason: 'band unchanged');
      expect(rule.minQty, isNull, reason: 'minimum unchanged');
      expect(
        rule.labels('en'),
        contains('Night Curtain'),
        reason: 'label kept',
      );
      expect(rule.rateSen, 5000, reason: 'only the rate moved');
    });
  });
}
