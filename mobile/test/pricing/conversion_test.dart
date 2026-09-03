/// Confirming a quote as an order. SPEC.md §6.3 and §3.
///
/// > customer pays RM300 minimum deposit PER PRODUCT CATEGORY
/// > → ORDER IS CONFIRMED. Not a quote, not a lead. A confirmed sale.
///
/// Client, Sep 2026: *"the quote should be recorded as reference to the order,
/// so have rough estimate of what to do."* So the quote survives conversion
/// untouched, and the order points back at it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/pricing/conversion.dart';
import 'package:milan_quote/pricing/engine.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

final confirmedAt = DateTime(2026, 8, 29, 15, 30);

/// A real rule from the real card, rather than a hand-built one. A snapshot
/// taken from a fabricated rule proves nothing about the fields the card
/// actually carries.
late PricingRule nightCurtain;

PricingRule aRule() => nightCurtain;

PricedLine priced({
  PricingRule? rule,
  int totalSen = 55200,
  int rateSen = 4600,
  int standardRateSen = 4600,
  bool materialDeferred = false,
}) => PricedLine(
  rule: rule ?? aRule(),
  stage: PricingStage.estimate,
  rawQty: Rational.fromInt(12),
  billedQty: Rational.fromInt(12),
  billedUnit: 'ft',
  minQtyApplied: false,
  materialDeferred: materialDeferred,
  materialOptions: const [],
  standardRateSen: standardRateSen,
  rateSen: rateSen,
  quantity: 1,
  total: Money.sen(totalSen),
);

ConvertibleLine convertible({
  String id = 'line-1',
  PricedLine? line,
  RateBasis? basis,
  String? parentLineId,
}) => ConvertibleLine(
  id: id,
  sortOrder: 0,
  room: '客厅',
  layer: 'night',
  width: Length.tenths(36576),
  height: Length.tenths(27432),
  parentLineId: parentLineId,
  priced: line ?? priced(),
  basis:
      basis ??
      const RateBasis(
        source: RateSource.fairCurrent,
        rateCardVersion: 1,
        discountPct: Rational.zero,
      ),
);

var _next = 0;
String nextLineId() => 'order-line-${_next++}';

ConversionResult confirm({
  List<ConvertibleLine>? lines,
  Money? deposit,
  Money? estimate,
  Channel channel = Channel.fair,
}) => confirmQuoteAsOrder(
  orderId: 'order-1',
  quoteId: 'quote-1',
  channel: channel,
  pinnedRateCardVersion: 1,
  lines: lines ?? [convertible()],
  estimateTotal: estimate ?? Money.sen(55200),
  depositPaid: deposit ?? Money.sen(30000),
  at: confirmedAt,
  newLineId: nextLineId,
  customerName: '陈大文',
);

void main() {
  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    final card = RateCard.fromJson(
      jsonDecode(
            File(
              '${dir.path}/shared/rate-card-fair-2026-08.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
    nightCurtain = card.rules.firstWhere((r) => r.id == 'night-curtain-lo');
  });

  setUp(() => _next = 0);

  group('the deposit is what confirms it', () {
    test('a quote with a deposit becomes an order', () {
      final result = confirm();
      expect(result.confirmed, isTrue);
      expect(result.order!.confirmedAt, confirmedAt);
    });

    test('no deposit means no order', () {
      // §3. Without money this is still a quote, however finished it looks —
      // and calling it confirmed would put it on the production board.
      final result = confirm(deposit: Money.zero);
      expect(result.confirmed, isFalse);
      expect(result.refusedBecause, ConversionRefusal.noDeposit);
    });

    test('an empty quote is a lead, not a sale', () {
      final result = confirm(lines: const []);
      expect(result.refusedBecause, ConversionRefusal.noLines);
    });

    test('a line the engine could not price stops the whole thing', () {
      // Confirming around it would put a number on an order that cannot be
      // explained to the customer it is billed to.
      final result = confirm(
        lines: [
          convertible(),
          ConvertibleLine(
            id: 'broken',
            sortOrder: 1,
            room: '书房',
            layer: 'night',
            width: Length.tenths(36576),
            height: null,
            basis: const RateBasis(
              source: RateSource.fairCurrent,
              rateCardVersion: 1,
              discountPct: Rational.zero,
            ),
          ),
        ],
      );
      expect(result.refusedBecause, ConversionRefusal.unpricedLine);
    });
  });

  group('the quote is referenced, not consumed', () {
    test('the order points back at the quote it came from', () {
      // Client: "the quote should be recorded as reference to the order, so
      // have rough estimate of what to do." The measurement team reads it.
      expect(confirm().order!.quoteId, 'quote-1');
    });

    test('every line keeps the quote line it came from', () {
      final order = confirm().order!;
      expect(order.lines.single.quoteLineId, 'line-1');
      expect(
        order.lines.single.id,
        isNot('line-1'),
        reason: 'the order line is its own row, not the quote line renamed',
      );
    });

    test('the estimate total is kept, not replaced', () {
      // §6.3 keeps estimate and final side by side so the variance report can
      // say who is guessing badly. An order that only carried the final would
      // have nothing to compare.
      final order = confirm(estimate: Money.sen(120000)).order!;
      expect(order.estimateTotal, Money.sen(120000));
    });
  });

  group('what a line remembers about its price', () {
    test('the rule, band, rate and version are all snapshotted', () {
      // A year later the card may have been superseded twice. "Why was this
      // RM552?" has to be answerable without reconstructing that afternoon.
      final line = confirm().order!.lines.single;

      expect(line.appliedRuleId, 'night-curtain-lo');
      expect(line.appliedRateCardVersion, 1);
      expect(line.rateSen, 4600);
      expect(line.billedQty, '12');
      expect(line.billedUnit, 'ft');
      expect(line.lineTotal, Money.sen(55200));
    });

    test('a held line records the lock that priced it', () {
      // §6.1: the whole point of the lock is that a later publish cannot move
      // this price, and the order has to say which lock that was.
      final line = confirm(
        lines: [
          convertible(
            basis: RateBasis(
              source: RateSource.held,
              rateCardVersion: 1,
              discountPct: Rational(1, 10),
              lockId: 'lock-curtain',
            ),
          ),
        ],
      ).order!.lines.single;

      expect(line.appliedRateCardVersion, 1);
      expect(line.appliedDiscountPct, Rational(1, 10));
      expect(line.categoryLockId, 'lock-curtain');
    });

    test('a lock holding a different version refuses the whole order', () {
      // The quote on screen was priced at version 1; this lock says the
      // customer's RM300 bought version 55. One of the two is what they should
      // pay, and confirming would carve the disagreement into an order that
      // claims to have been priced at a version it was not.
      final result = confirm(
        lines: [
          convertible(
            basis: const RateBasis(
              source: RateSource.held,
              rateCardVersion: 55,
              discountPct: Rational.zero,
              lockId: 'lock-curtain',
            ),
          ),
        ],
      );

      expect(result.confirmed, isFalse);
      expect(result.refusedBecause, ConversionRefusal.heldVersionNotApplied);
    });

    test('an unheld line records no lock', () {
      // §6.1's hard rule, one step downstream: an order line must not claim a
      // lock priced it when none did.
      expect(confirm().order!.lines.single.categoryLockId, isNull);
    });

    test('both rates are kept, standard and applied', () {
      // The quote prints the standard rate beside the MVP one, so the customer
      // can see what the membership is worth.
      final line = confirm(
        lines: [
          convertible(
            line: priced(rateSen: 4000, standardRateSen: 4600, totalSen: 48000),
          ),
        ],
      ).order!.lines.single;

      expect(line.standardRateSen, 4600);
      expect(line.rateSen, 4000);
    });

    test('a deferred material is carried through', () {
      // B7: material is chosen at measurement, and the line was quoted at the
      // dearest option. The order has to know that is still outstanding.
      final line = confirm(
        lines: [convertible(line: priced(materialDeferred: true))],
      ).order!.lines.single;
      expect(line.materialDeferred, isTrue);
    });

    test('an upgrade stays attached to its parent', () {
      final order = confirm(
        lines: [
          convertible(),
          convertible(id: 'motor', parentLineId: 'line-1'),
        ],
      ).order!;

      expect(order.lines.last.parentLineId, 'line-1');
    });
  });

  group('what is not known yet', () {
    test('every line arrives unmeasured', () {
      // §8.5 promises the final will be the same or lower, and that promise is
      // only kept by taking a tape to it.
      final order = confirm().order!;
      expect(order.hasUnmeasuredLines, isTrue);
      expect(order.lines.single.needsMeasuring, isTrue);
    });

    test('the estimate dimensions are what was entered at the fair', () {
      final line = confirm().order!.lines.single;
      expect(line.estWidth.tmm, 36576);
      expect(line.estHeight!.tmm, 27432);
    });

    test('no balance is worked out from the estimate', () {
      // Client, Sep 2026: "no need to say owe how much based on quotation,
      // only say deposit is for fair lock price rate." A figure derived from
      // an estimate is one the customer remembers and the tape contradicts,
      // and §8.5 promises the final can only fall.
      final order = confirm(
        estimate: Money.sen(120000),
        deposit: Money.sen(30000),
      ).order!;

      expect(order.estimateTotal, Money.sen(120000));
      expect(order.depositPaid, Money.sen(30000));
      // There is no `balanceDue` to read. The type does not offer one, so no
      // screen can accidentally show it.
    });

    test('what the deposit bought is the rate, and it says which', () {
      // "must have price rate at that time reference for that bill."
      final order = confirm().order!;
      expect(order.heldRateReference, 1);
      expect(order.lines.single.appliedRateCardVersion, 1);
      expect(order.lines.single.rateSen, 4600);
    });
  });

  test('the order number is not invented here', () {
    // Like a receipt number, it is server-issued and shown as "pending sync"
    // until it arrives. Two part-timers offline at one fair would produce the
    // same one, on a document the customer takes away.
    final order = confirm().order!;
    expect(
      order.id,
      'order-1',
      reason: 'a client-generated UUID, not a number',
    );
  });
}
