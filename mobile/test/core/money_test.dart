import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/core/rational.dart';

void main() {
  group('construction', () {
    test('RM46.00 is 4600 sen', () {
      expect(const Money.rm(46).sen, 4600);
      expect(const Money.rm(46, 50).sen, 4650);
    });
  });

  group('half-up rounding, applied once', () {
    // (exact sen as a fraction, expected whole sen)
    const cases = <(int, int, int)>[
      (5, 2, 3), //  2.5 -> 3, half goes up
      (3, 2, 2), //  1.5 -> 2
      (1, 4, 0), //  0.25 -> 0
      (3, 4, 1), //  0.75 -> 1
      (1, 2, 1), //  0.5 -> 1
      (0, 1, 0),
      (56730314, 100000, 567), // the A11 worked example, in sen
    ];

    for (final (n, d, expected) in cases) {
      test('$n/$d sen rounds to $expected', () {
        expect(Money.roundFrom(Rational(n, d)).sen, expected);
      });
    }

    test('negatives round half away from zero, not toward it', () {
      // Refunds arrive in Phase 4; the rule must already be right.
      expect(Money.roundFrom(Rational(-5, 2)).sen, -3);
      expect(Money.roundFrom(Rational(-1, 4)).sen, 0);
    });

    test('rounding is not banker\'s rounding', () {
      // Banker's would send 2.5 to 2 and 3.5 to 4. Ours sends both up.
      expect(Money.roundFrom(Rational(5, 2)).sen, 3);
      expect(Money.roundFrom(Rational(7, 2)).sen, 4);
    });
  });

  group('formatting — SPEC.md §8.3', () {
    test('always two decimals and an RM prefix', () {
      expect(const Money.sen(55200).format(), 'RM 552.00');
      expect(const Money.sen(4600).format(), 'RM 46.00');
      expect(const Money.sen(5).format(), 'RM 0.05');
      expect(Money.zero.format(), 'RM 0.00');
    });

    test('thousands are grouped', () {
      expect(const Money.sen(123450).format(), 'RM 1,234.50');
      expect(const Money.sen(1000000).format(), 'RM 10,000.00');
      expect(const Money.sen(123456789).format(), 'RM 1,234,567.89');
      expect(const Money.sen(100000).format(), 'RM 1,000.00');
    });

    test('negatives keep the sign ahead of the number', () {
      expect(const Money.sen(-55200).format(), 'RM -552.00');
    });

    test('the symbol can be dropped for table columns', () {
      expect(const Money.sen(55200).format(withSymbol: false), '552.00');
    });
  });

  group('arithmetic', () {
    test('addition and subtraction stay in whole sen', () {
      expect((const Money.sen(4600) + const Money.sen(400)).sen, 5000);
      expect((const Money.sen(4600) - const Money.sen(600)).sen, 4000);
    });

    test('multiplying by a line quantity happens after rounding', () {
      // SPEC.md §4.3 step 8: roundHalfUp(qty * rate) * lineQty.
      expect((const Money.sen(55200) * 3).sen, 165600);
    });

    test('max applies a floor without touching the parts', () {
      // The RM300 quotation floor is a max at the category subtotal.
      expect(const Money.sen(25000).max(const Money.sen(30000)).sen, 30000);
      expect(const Money.sen(55200).max(const Money.sen(30000)).sen, 55200);
    });

    test('min returns the smaller amount', () {
      expect(const Money.sen(25000).min(const Money.sen(30000)).sen, 25000);
      expect(const Money.sen(55200).min(const Money.sen(30000)).sen, 30000);
    });

    test('negation flips the sign, for refunds', () {
      expect((-const Money.sen(30000)).sen, -30000);
      expect((-const Money.sen(-30000)).sen, 30000);
      expect((-Money.zero).sen, 0);
    });

    test('isNegative and isZero', () {
      expect(const Money.sen(-1).isNegative, isTrue);
      expect(const Money.sen(1).isNegative, isFalse);
      expect(Money.zero.isNegative, isFalse);
      expect(Money.zero.isZero, isTrue);
      expect(const Money.sen(1).isZero, isFalse);
    });

    test('ringgit truncates toward zero', () {
      expect(const Money.sen(55299).ringgit, 552);
      expect(const Money.sen(99).ringgit, 0);
    });
  });

  group('comparison', () {
    test('compareTo orders by sen', () {
      expect(const Money.sen(100).compareTo(const Money.sen(200)), lessThan(0));
      expect(
        const Money.sen(200).compareTo(const Money.sen(100)),
        greaterThan(0),
      );
      expect(const Money.sen(100).compareTo(const Money.sen(100)), 0);
    });

    test('the operators agree with compareTo', () {
      const a = Money.sen(100);
      const b = Money.sen(200);
      expect(a < b, isTrue);
      expect(a <= b, isTrue);
      expect(a > b, isFalse);
      expect(a >= b, isFalse);
      expect(b > a, isTrue);
      expect(b >= a, isTrue);
      expect(a <= const Money.sen(100), isTrue);
      expect(a >= const Money.sen(100), isTrue);
    });

    test('a list of amounts sorts correctly', () {
      final amounts = [
        const Money.sen(55200),
        const Money.sen(-100),
        Money.zero,
        const Money.sen(16200),
      ]..sort();
      expect(amounts.map((m) => m.sen), [-100, 0, 16200, 55200]);
    });
  });

  group('value semantics', () {
    test('equality is by amount', () {
      expect(const Money.sen(4600) == const Money.rm(46), isTrue);
      expect(const Money.sen(4600) == const Money.sen(4601), isFalse);
      expect(const Money.sen(4600) == Object(), isFalse);
    });

    test('equal amounts share a hash code', () {
      expect(const Money.sen(4600).hashCode, const Money.rm(46).hashCode);
      final byValue = <Money>{}
        ..add(const Money.sen(4600))
        ..add(const Money.rm(46));
      expect(byValue.length, 1);
    });

    test('toString is the formatted amount', () {
      expect(const Money.sen(55200).toString(), 'RM 552.00');
    });
  });
}
