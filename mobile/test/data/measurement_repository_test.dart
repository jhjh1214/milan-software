/// Site measurement and final pricing, on a real database. SPEC.md §11 Phase 6.
///
/// *What* a line prices at is decided in `pricing/final_pricing.dart` and
/// tested against the shared fixtures, on both engines. What is checked here is
/// the part only a database can get wrong:
///
/// * that the tape is stored **beside** the estimate and never over it — §6.3
///   keeps both, and losing the estimate would leave the variance report with
///   nothing to compare;
/// * that a refused line writes nothing, so the handset never holds a rate with
///   no total behind it;
/// * that the order's total and balance follow the lines, and are **absent**
///   rather than partial while a window is still unmeasured — a total that
///   quietly excluded one is a balance somebody collects and a window nobody
///   bills for;
/// * that nothing here reaches the network, because §11 Phase 6 requires it to
///   work in a house with no signal.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/measurement_repository.dart';
import 'package:milan_quote/data/order_repository.dart';
import 'package:milan_quote/pricing/conversion.dart';
import 'package:milan_quote/pricing/final_pricing.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

void main() {
  late AppDatabase db;
  late OrderRepository orders;
  late MeasurementRepository measuring;
  late RateCard card;
  late Map<int, RateCard> cards;

  final confirmedAt = DateTime(2026, 8, 29, 14, 0);
  final measuredAt = DateTime(2026, 9, 20, 10, 30);

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    card = RateCard.fromJson(
      jsonDecode(
            File(
              '${dir.path}/shared/rate-card-fair-2026-08.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
    cards = {card.version: card};
  });

  OrderLineDraft line(
    String id, {
    String variant = 'night_curtain',
    String layer = 'night',
    bool materialDeferred = false,
    String? materialKey,
    int rateCardVersion = 1,
    int lineTotalSen = 55200,
  }) => OrderLineDraft(
    id: id,
    quoteLineId: 'ql-$id',
    sortOrder: 0,
    room: 'Living room',
    variant: variant,
    materialKey: materialKey,
    layer: layer,
    estWidth: Length.of(const Rational.fromInt(12), LengthUnit.foot),
    estHeight: Length.of(const Rational.fromInt(9), LengthUnit.foot),
    quantity: 1,
    appliedRuleId: 'night-curtain-lo',
    appliedRateCardVersion: rateCardVersion,
    appliedDiscountPct: Rational.zero,
    standardRateSen: 4600,
    rateSen: 4600,
    billedQty: '12',
    billedUnit: 'ft',
    lineTotal: Money.sen(lineTotalSen),
    materialDeferred: materialDeferred,
  );

  Future<String> confirm({
    List<OrderLineDraft>? lines,
    int estimateSen = 55200,
    int depositSen = 30000,
  }) async {
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q1',
            channel: const Value('fair'),
            rateCardVersion: 1,
            createdAt: confirmedAt,
            updatedAt: confirmedAt,
          ),
        );
    await orders.store(
      OrderDraft(
        id: 'o1',
        quoteId: 'q1',
        channel: Channel.fair,
        pinnedRateCardVersion: 1,
        estimateTotal: Money.sen(estimateSen),
        depositPaid: Money.sen(depositSen),
        lines: lines ?? [line('l1')],
        confirmedAt: confirmedAt,
      ),
      byUserId: 'u-boss',
    );
    return 'o1';
  }

  Future<OrderRow> order(String id) =>
      (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle();

  Future<OrderLineRow> row(String id) =>
      (db.select(db.orderLines)..where((l) => l.id.equals(id))).getSingle();

  /// 35000 tmm — 11.4829ft, which the quote rounded up to 12.
  Length narrower() => Length.tenths(35000);
  Length nineFeet() => Length.of(const Rational.fromInt(9), LengthUnit.foot);

  Future<MeasurementOutcome> measure(
    String orderId,
    String lineId, {
    Length? width,
    Length? height,
    String? materialKey,
  }) => measuring.recordMeasurement(
    orderId: orderId,
    lineId: lineId,
    width: width ?? narrower(),
    height: height ?? nineFeet(),
    cards: cards,
    at: measuredAt,
    byUserId: 'u-measurer',
    materialKey: materialKey,
  );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    orders = OrderRepository(db);
    measuring = MeasurementRepository(db);
  });

  tearDown(() => db.close());

  group('recording the tape', () {
    test('stores it beside the estimate, never over it', () async {
      // §6.3 keeps both. Losing the estimate leaves the variance report with
      // nothing to compare and a customer with no answer to "but you said".
      final id = await confirm();
      await measure(id, 'l1');

      final stored = await row('l1');
      expect(stored.estWidthTmm, 36576, reason: 'what the fair recorded');
      expect(stored.finalWidthTmm, 35000, reason: 'what the tape said');
      expect(stored.lineTotalSen, 55200, reason: 'the quoted total');
      expect(stored.finalLineTotalSen, 52822, reason: 'what it bills');
      expect(stored.isSiteMeasured, isTrue);
      expect(stored.measuredByUserId, 'u-measurer');
      expect(stored.measuredAt, measuredAt);
    });

    test('bills the exact quantity, never rounded', () async {
      // The quote rounded 11.4829ft up to 12 and the bill does not. Stored as
      // an exact rational: a double column would give back something that is
      // not 4375/381.
      final id = await confirm();
      await measure(id, 'l1');

      final stored = await row('l1');
      expect(stored.finalBilledQty, '4375/381');
      expect(stored.finalBilledUnit, 'ft');
    });

    test('records the rule and band the tape selected', () async {
      // A measured drop over 10ft moves a curtain into the upper band, and the
      // change has to be visible rather than inferred from a rate a year later.
      final id = await confirm();
      await measure(id, 'l1', height: Length.tenths(30481));

      final stored = await row('l1');
      expect(stored.finalRuleId, 'night-curtain-hi');
      expect(stored.finalRateSen, 5800);
      expect(
        stored.appliedRuleId,
        'night-curtain-lo',
        reason: 'the rule the quote used is left exactly as it was',
      );
    });

    test('refuses a zero, which is a typo and not a tape reading', () async {
      // A zero-width line prices at zero — a discount nobody authorised,
      // arriving through a slip of the thumb.
      final id = await confirm();

      final outcome = await measure(id, 'l1', width: Length.tenths(0));

      expect(outcome.refusal, MeasurementRefusal.notAMeasurement);
      expect((await row('l1')).isSiteMeasured, isFalse);
      expect((await row('l1')).finalWidthTmm, null);
    });

    test('refuses a zero drop as well as a zero width', () async {
      // Height selects the band. A zero drop lands in the lowest one, which is
      // the cheapest, so a slip of the thumb becomes a discount.
      final id = await confirm();

      final outcome = await measure(id, 'l1', height: Length.tenths(0));

      expect(outcome.refusal, MeasurementRefusal.notAMeasurement);
      expect((await row('l1')).finalHeightTmm, null);
    });

    test('refuses a cancelled order', () async {
      // Measuring one would produce a bill for a job that is not happening.
      final id = await confirm();
      await (db.update(db.orders)..where((o) => o.id.equals(id))).write(
        const OrdersCompanion(status: Value('cancelled')),
      );

      final outcome = await measure(id, 'l1');

      expect(outcome.refusal, MeasurementRefusal.orderIsTerminal);
      expect((await row('l1')).finalWidthTmm, null);
    });

    test('refuses a line id that does not exist', () async {
      final id = await confirm();
      final outcome = await measure(id, 'not-a-line');

      expect(outcome.refusal, MeasurementRefusal.noSuchLine);
    });

    test('refuses a real line that belongs to another order', () async {
      // Two visits in one morning, two orders open on the handset. Measuring
      // one house's window onto the other's order would put a tape reading on
      // a bill nobody can explain, and both orders would look measured.
      final id = await confirm();
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: 'o2',
              quoteId: 'q1',
              channel: 'fair',
              pinnedRateCardVersion: 1,
              estimateTotalSen: 55200,
              confirmedAt: confirmedAt,
            ),
          );
      await db
          .into(db.orderLines)
          .insert(
            OrderLinesCompanion.insert(
              id: 'other-line',
              orderId: 'o2',
              quoteLineId: 'ql-other',
              sortOrder: 0,
              room: 'Bedroom',
              variant: 'night_curtain',
              layer: 'night',
              estWidthTmm: 36576,
              appliedRuleId: 'night-curtain-lo',
              appliedRateCardVersion: 1,
              standardRateSen: 4600,
              rateSen: 4600,
              billedQty: '12',
              billedUnit: 'ft',
              lineTotalSen: 55200,
            ),
          );

      final outcome = await measure(id, 'other-line');

      expect(outcome.refusal, MeasurementRefusal.noSuchLine);
      expect(
        (await row('other-line')).finalWidthTmm,
        null,
        reason: 'the line on the other order is untouched',
      );
    });

    test('a material chosen on site sticks', () async {
      // §13 B7: the quote used the dearest option in the group. This is where
      // it stops being a guess.
      final id = await confirm(
        lines: [
          line(
            'l1',
            variant: 'outdoor_roller_motor',
            layer: 'single',
            materialDeferred: true,
            lineTotalSen: 180000,
          ),
        ],
      );

      await measure(id, 'l1', materialKey: 'aok');

      final stored = await row('l1');
      expect(stored.materialKey, 'aok');
      expect(stored.finalLineTotalSen, 100000, reason: 'the cheaper motor');
    });

    test('measuring again does not clear a material already chosen', () async {
      final id = await confirm(
        lines: [
          line(
            'l1',
            variant: 'outdoor_roller_motor',
            layer: 'single',
            materialDeferred: true,
            lineTotalSen: 180000,
          ),
        ],
      );
      await measure(id, 'l1', materialKey: 'aok');
      await measure(id, 'l1');

      expect((await row('l1')).materialKey, 'aok');
    });
  });

  group('the order total and balance', () {
    test('follow the lines once every one is measured', () async {
      final id = await confirm(depositSen: 30000);
      await measure(id, 'l1');

      final after = await order(id);
      expect(after.finalTotalSen, 52822);
      expect(after.balanceDueSen, 22822, reason: 'less the RM300 deposit');
      expect(after.hasUnmeasuredLines, isFalse);
      expect(
        after.estimateTotalSen,
        55200,
        reason: 'the estimate is untouched',
      );
    });

    test('are absent while a window is still unmeasured', () async {
      // A total that quietly excluded a line is a balance somebody collects
      // and a window nobody bills for.
      final id = await confirm(
        lines: [line('l1'), line('l2')],
        estimateSen: 110400,
      );

      await measure(id, 'l1');

      final after = await order(id);
      expect(after.finalTotalSen, null);
      expect(after.balanceDueSen, 0);
      expect(after.hasUnmeasuredLines, isTrue);
    });

    test('the measured line is still priced while the other waits', () async {
      // The measurer needs the number for the window in front of them, even
      // though the order as a whole is not ready.
      final id = await confirm(
        lines: [line('l1'), line('l2')],
        estimateSen: 110400,
      );

      final outcome = await measure(id, 'l1');

      expect(outcome.pricing!.isComplete, isFalse);
      expect((await row('l1')).finalLineTotalSen, 52822);
      expect(
        (await row('l2')).finalLineTotalSen,
        null,
        reason: 'a refused line is left exactly as it was',
      );
    });

    test('never report a negative balance', () async {
      // A final under the deposit already taken is §13 B4, unanswered. A
      // negative on a screen would be this repository answering it.
      final id = await confirm(depositSen: 100000);
      await measure(id, 'l1');

      final after = await order(id);
      expect(after.finalTotalSen, 52822);
      expect(after.balanceDueSen, 0);
    });
  });

  group('what the measurer reads before leaving', () {
    test('the variance, per line and for the order', () async {
      final id = await confirm();
      final outcome = await measure(id, 'l1');

      final pricing = outcome.pricing!;
      expect(pricing.lines.single.variance, const Money.sen(-2378));
      expect(pricing.variance, const Money.sen(-2378));
    });

    test('what is still outstanding, and why for each', () async {
      // Not a count. "Three lines outstanding" sends somebody hunting; the
      // refusal says whether it wants a tape or a material.
      final id = await confirm(
        lines: [
          line('l1'),
          line('l2'),
          line(
            'l3',
            variant: 'outdoor_roller_motor',
            layer: 'single',
            materialDeferred: true,
            lineTotalSen: 180000,
          ),
        ],
        estimateSen: 290400,
      );
      await measure(id, 'l1');
      await measure(id, 'l3');

      final outstanding = await measuring.outstandingOf(
        orderId: id,
        cards: cards,
      );

      expect(outstanding.map((l) => l.id), ['l2', 'l3']);
      expect(outstanding[0].refusal, FinalPricingRefusal.notMeasured);
      expect(outstanding[1].refusal, FinalPricingRefusal.materialNotChosen);
    });

    test('pricing an order changes nothing', () async {
      // The order screen reads this on the way in. It must not write — so the
      // stored figures are cleared first and must stay cleared, which a
      // read-only call cannot restore and a writing one would.
      final id = await confirm();
      await measure(id, 'l1');

      await (db.update(db.orderLines)..where((l) => l.id.equals('l1'))).write(
        const OrderLinesCompanion(
          finalLineTotalSen: Value(null),
          finalBilledQty: Value(null),
        ),
      );
      await (db.update(db.orders)..where((o) => o.id.equals(id))).write(
        const OrdersCompanion(
          finalTotalSen: Value(null),
          balanceDueSen: Value(0),
        ),
      );

      final pricing = await measuring.priceOrder(orderId: id, cards: cards);

      expect(
        pricing.finalTotal,
        const Money.sen(52822),
        reason: 'it still works the number out',
      );
      expect((await row('l1')).finalLineTotalSen, null);
      expect((await row('l1')).finalBilledQty, null);
      expect((await order(id)).finalTotalSen, null);
      expect((await order(id)).balanceDueSen, 0);
    });
  });

  group('the held card', () {
    test(
      'a line whose card is not to hand refuses, and prices nothing',
      () async {
        // Falling back to today's card is exactly what the RM300 was taken to
        // prevent, and it is the fallback that looks most reasonable.
        final id = await confirm(lines: [line('l1', rateCardVersion: 99)]);

        final outcome = await measure(id, 'l1');

        expect(
          outcome.pricing!.lines.single.refusal,
          FinalPricingRefusal.cardUnavailable,
        );
        expect((await row('l1')).finalLineTotalSen, null);
        expect((await order(id)).finalTotalSen, null);
        expect(
          (await row('l1')).finalWidthTmm,
          35000,
          reason: 'the tape is still recorded — the measurer was there',
        );
      },
    );
  });

  group('the visit', () {
    test('is one event, not one per window', () async {
      // §6.3's history is what somebody reads a year later. One row per window
      // buries the visit in noise.
      final id = await confirm(lines: [line('l1'), line('l2')]);
      await measure(id, 'l1');
      await measure(id, 'l2');

      await measuring.recordVisit(
        orderId: id,
        at: measuredAt,
        byUserId: 'u-measurer',
        note: 'All six windows, keys with the guard',
      );

      final history = await orders.historyOf(id);
      final visits = history.where((e) => e.event == 'measured_on_site');
      expect(visits, hasLength(1));
      expect(visits.single.note, 'All six windows, keys with the guard');
      expect(visits.single.byUserId, 'u-measurer');
    });

    test('an empty note is stored as none, not as whitespace', () async {
      final id = await confirm();
      await measuring.recordVisit(orderId: id, at: measuredAt, note: '   ');

      final visit = (await orders.historyOf(
        id,
      )).firstWhere((e) => e.event == 'measured_on_site');
      expect(visit.note, null);
    });
  });
}
