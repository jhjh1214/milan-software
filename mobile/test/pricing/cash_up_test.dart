/// The daily cash-up. SPEC.md §6.4.
///
/// > End of day, per user: expected total by method versus what they actually
/// > hold. Small to build, catches most of what goes wrong with cash at a fair.
///
/// The two things it must never do: report a day as balanced when nobody
/// counted, and lose a refund by netting it into silence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/pricing/cash_up.dart';

CashUpEntry took(
  int sen, {
  PaymentMethod method = PaymentMethod.cash,
  PaymentKind kind = PaymentKind.deposit,
}) => CashUpEntry(kind: kind, method: method, amountSen: sen);

void main() {
  group('what should be in the drawer', () {
    test('three RM300 deposits in cash come to RM900', () {
      final day = cashUpFor([took(30000), took(30000), took(30000)]);
      expect(day.byMethod, hasLength(1));
      expect(day.byMethod.single.expected, Money.sen(90000));
      expect(day.expectedTotal, Money.sen(90000));
    });

    test('methods are totalled separately', () {
      // The whole point of "by method": a card total and a cash total cannot
      // be checked the same way.
      final day = cashUpFor([
        took(30000),
        took(30000, method: PaymentMethod.cardTerminal),
        took(50000, method: PaymentMethod.duitnow),
      ]);

      expect(day.byMethod.map((m) => m.method), [
        PaymentMethod.cash,
        PaymentMethod.cardTerminal,
        PaymentMethod.duitnow,
      ]);
      expect(day.expectedTotal, Money.sen(110000));
    });

    test('a refund comes off the method it went back through', () {
      final day = cashUpFor([
        took(30000),
        took(30000, kind: PaymentKind.refund),
        took(50000, method: PaymentMethod.cardTerminal),
      ]);

      expect(day.byMethod.first.expected, Money.zero);
      expect(day.expectedTotal, Money.sen(50000));
    });

    test('a method that nets to zero still shows', () {
      // Three deposits and three refunds is not the same day as no payments at
      // all, and hiding it would hide the thing worth asking about.
      final day = cashUpFor([
        took(30000),
        took(30000, kind: PaymentKind.refund),
      ]);

      expect(day.byMethod, hasLength(1));
      expect(day.byMethod.single.expected, Money.zero);
    });

    test('a method nobody used does not appear', () {
      final day = cashUpFor([took(30000)]);
      expect(day.byMethod.map((m) => m.method), [PaymentMethod.cash]);
    });

    test('an empty day is empty, not an error', () {
      final day = cashUpFor(const []);
      expect(day.byMethod, isEmpty);
      expect(day.expectedTotal, Money.zero);
      expect(day.anyDiscrepancy, isFalse);
    });

    test('the order is the same every evening', () {
      // A screen whose rows move around by volume is one where a missing row
      // is invisible.
      final day = cashUpFor([
        took(100, method: PaymentMethod.cheque),
        took(100, method: PaymentMethod.cash),
        took(100, method: PaymentMethod.duitnow),
      ]);
      expect(day.byMethod.map((m) => m.method), [
        PaymentMethod.cash,
        PaymentMethod.duitnow,
        PaymentMethod.cheque,
      ]);
    });
  });

  group('against what is actually held', () {
    test('counting the right amount balances', () {
      final day = cashUpFor(
        [took(30000), took(30000)],
        counted: {PaymentMethod.cash: Money.sen(60000)},
      );

      expect(day.byMethod.single.isBalanced, isTrue);
      expect(day.byMethod.single.variance, Money.zero);
      expect(day.anyDiscrepancy, isFalse);
    });

    test('being short shows as a negative variance', () {
      // RM300 taken, RM250 in the tin. This is the number the boss wants.
      final day = cashUpFor(
        [took(30000)],
        counted: {PaymentMethod.cash: Money.sen(25000)},
      );

      expect(day.byMethod.single.variance, Money.sen(-5000));
      expect(day.anyDiscrepancy, isTrue);
      expect(day.discrepancies, hasLength(1));
    });

    test('a surplus is a discrepancy too', () {
      // Too much money is also somebody having recorded the wrong thing.
      final day = cashUpFor(
        [took(30000)],
        counted: {PaymentMethod.cash: Money.sen(35000)},
      );
      expect(day.byMethod.single.variance, Money.sen(5000));
      expect(day.anyDiscrepancy, isTrue);
    });

    test('not counting is not the same as balancing', () {
      // The failure that makes a cash-up worthless: a day nobody checked
      // reported as fine.
      final day = cashUpFor([took(30000)]);

      expect(day.byMethod.single.variance, isNull);
      expect(day.byMethod.single.isBalanced, isFalse);
      expect(
        day.anyDiscrepancy,
        isFalse,
        reason: 'nothing is known to be wrong',
      );
      expect(
        day.uncounted,
        hasLength(1),
        reason: 'but it is an open question, and it says so',
      );
    });

    test('only cash is asked to be counted', () {
      // A card total is what the terminal says it is. Asking somebody to
      // "count" their DuitNow invites a made-up number.
      final day = cashUpFor([
        took(30000, method: PaymentMethod.cardTerminal),
        took(30000, method: PaymentMethod.duitnow),
      ]);
      expect(day.uncounted, isEmpty);
    });

    test('a counted card total is still reconciled if given', () {
      // Nobody is asked, but if a slip total is entered it is checked.
      final day = cashUpFor(
        [took(30000, method: PaymentMethod.cardTerminal)],
        counted: {PaymentMethod.cardTerminal: Money.sen(29000)},
      );
      expect(day.discrepancies, hasLength(1));
    });

    test('counting a method with no payments is ignored', () {
      // Nothing came in that way, so there is nothing to reconcile against.
      final day = cashUpFor(
        [took(30000)],
        counted: {PaymentMethod.cheque: Money.sen(500)},
      );
      expect(day.byMethod.map((m) => m.method), [PaymentMethod.cash]);
    });
  });

  group('the wire values', () {
    test('every kind and method round trips', () {
      // These land in the database and go to the server. A rename on one side
      // only would quietly stop reconciling.
      for (final kind in PaymentKind.values) {
        expect(PaymentKind.fromWire(kind.wire), kind);
      }
      for (final method in PaymentMethod.values) {
        expect(PaymentMethod.fromWire(method.wire), method);
      }
    });

    test('only a refund subtracts', () {
      for (final kind in PaymentKind.values) {
        expect(
          kind.sign,
          kind == PaymentKind.refund ? -1 : 1,
          reason: kind.wire,
        );
      }
    });
  });
}
