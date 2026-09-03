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

  group('tryParse', () {
    // Two callers: a rate-card CSV cell and the counted-cash field at cash up.
    // Both are places where "unparseable" has to stay distinguishable from
    // "zero" -- a cell that quietly becomes RM0.00 is a wrong price, and a
    // till that quietly counts nothing reads as a RM0 variance rather than as
    // a blank nobody filled in.
    test('reads what an admin actually types', () {
      expect(Money.tryParse('46.50'), const Money.rm(46, 50));
      expect(Money.tryParse('RM46.50'), const Money.rm(46, 50));
      expect(Money.tryParse(' RM 1,234.05 '), const Money.rm(1234, 5));
      expect(Money.tryParse('9'), const Money.rm(9));
    });

    test('a third decimal rounds half up, once', () {
      expect(Money.tryParse('0.005'), const Money.sen(1));
      expect(Money.tryParse('12.344'), const Money.sen(1234));
      expect(Money.tryParse('12.345'), const Money.sen(1235));
    });

    test('nothing at all is null, not zero', () {
      expect(Money.tryParse(''), isNull);
      expect(Money.tryParse('   '), isNull);
      // Stripping leaves an empty string behind, which must not become RM0.
      expect(Money.tryParse('RM'), isNull);
      expect(Money.tryParse('RM ,'), isNull);
    });

    test('rubbish is null, not zero', () {
      expect(Money.tryParse('abc'), isNull);
      expect(Money.tryParse('4.5.6'), isNull);
      expect(Money.tryParse('46.50x'), isNull);
      expect(Money.tryParse('-'), isNull);
    });

    test('round trips the formatted form it prints', () {
      for (final sen in [0, 5, 900, 4650, 55200, 123405]) {
        expect(Money.tryParse(Money.sen(sen).toString()), Money.sen(sen));
      }
    });
  });

  group('toPlainString — the CSV form', () {
    // format() groups thousands with a comma, which is right on a quote and
    // fatal in a CSV cell: the comma splits the field and the row silently
    // loses a column, shifting every rate one place left.
    test('never groups, however large', () {
      expect(const Money.sen(150000).toPlainString(), '1500.00');
      expect(const Money.sen(123456789).toPlainString(), '1234567.89');
      expect(const Money.sen(150000).toPlainString(), isNot(contains(',')));
    });

    test('always two decimals, and no symbol', () {
      expect(Money.zero.toPlainString(), '0.00');
      expect(const Money.sen(5).toPlainString(), '0.05');
      expect(const Money.sen(900).toPlainString(), '9.00');
      expect(const Money.sen(4650).toPlainString(), isNot(contains('RM')));
    });

    test('a negative keeps its sign ahead of the number', () {
      expect(const Money.sen(-4650).toPlainString(), '-46.50');
      expect(const Money.sen(-5).toPlainString(), '-0.05');
      expect(const Money.sen(-150000).toPlainString(), '-1500.00');
    });

    test('tryParse reads back what it wrote, and refuses a negative', () {
      for (final sen in [0, 5, 900, 4650, 123456789]) {
        expect(Money.tryParse(Money.sen(sen).toPlainString()), Money.sen(sen));
      }

      // Deliberately not symmetric. Both callers of tryParse read an amount
      // that cannot be negative -- a rate card cell and counted cash -- and
      // the CSV importer relies on the refusal being loud: a null is reported
      // as "not a price" and the row is rejected, rather than a minus sign
      // quietly becoming a credit.
      expect(Money.tryParse(const Money.sen(-4650).toPlainString()), isNull);
    });
  });

  group('Money.rm', () {
    // Called with runtime values on purpose. Everywhere else Money.rm is
    // written as a const literal, so its body is evaluated at compile time and
    // never executes -- which is why Linux coverage reports the constructor
    // line as unexecuted while Windows reports it as hit. The arithmetic is
    // worth asserting at runtime either way.
    test('combines ringgit and sen', () {
      for (final case_ in [
        (46, 50, 4650),
        (46, 0, 4600),
        (0, 5, 5),
        (0, 0, 0),
        (1500, 99, 150099),
      ]) {
        final (ringgit, sen, expected) = case_;
        expect(Money.rm(ringgit, sen).sen, expected);
      }
    });

    test('the sen argument is optional', () {
      var ringgit = 46;
      expect(Money.rm(ringgit).sen, 4600);
      ringgit = 0;
      expect(Money.rm(ringgit).sen, 0);
    });

    test('carries past a whole ringgit rather than clamping', () {
      // 100 sen is not rejected; it is RM1. Nothing depends on this today, but
      // clamping would silently lose a ringgit if it ever were called that way.
      var sen = 100;
      expect(Money.rm(0, sen).sen, 100);
      sen = 250;
      expect(Money.rm(1, sen).sen, 350);
    });
  });
}
