/// What the deposit prompt earned, per category. SPEC.md §6.2, §11 Phase 4.
///
/// > Declined category deposits appear in a report
///
/// The arithmetic is pure, so it is tested here rather than through a screen.
/// The number that matters is `leftOnTheTable` — what a fair quoted in a
/// category and did not take a deposit on. A report that only counted refusals
/// would say a stall had a bad day without saying what it cost.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/pricing/deposit_prompt.dart';
import 'package:milan_quote/pricing/models.dart';

void main() {
  PromptOutcome outcome(
    DepositChoice choice, {
    DepositCategory category = DepositCategory.curtain,
    int subtotalSen = 55200,
  }) => PromptOutcome(
    category: category,
    choice: choice,
    categorySubtotal: Money.sen(subtotalSen),
  );

  test('nothing asked is an empty report, not a zeroed one', () {
    // A row of zeroes says the question was put and went nowhere. Nothing at
    // all says it was never put, and those need different conversations.
    expect(summariseDeposits(const []), isEmpty);
  });

  test('it counts each answer separately', () {
    final report = summariseDeposits([
      outcome(DepositChoice.collected),
      outcome(DepositChoice.collected),
      outcome(DepositChoice.declined),
      outcome(DepositChoice.dismissed),
      outcome(DepositChoice.linesRemoved),
    ]).single;

    expect(report.asked, 5);
    expect(report.collected, 2);
    expect(report.declined, 1);
    expect(report.dismissed, 1);
    expect(report.linesRemoved, 1);
  });

  test('a dismissal is never folded into a decline', () {
    // "They said no" and "nobody got an answer" are different problems, and
    // only one of them is the customer's.
    final report = summariseDeposits([
      outcome(DepositChoice.dismissed),
      outcome(DepositChoice.dismissed),
    ]).single;

    expect(report.declined, 0);
    expect(report.dismissed, 2);
  });

  group('what was left on the table', () {
    test('is everything quoted and not deposited on', () {
      final report = summariseDeposits([
        outcome(DepositChoice.collected, subtotalSen: 100000),
        outcome(DepositChoice.declined, subtotalSen: 55200),
        outcome(DepositChoice.dismissed, subtotalSen: 30000),
        outcome(DepositChoice.linesRemoved, subtotalSen: 20000),
      ]).single;

      // The collected one is not in it: a deposit was taken, so nothing was
      // left behind.
      expect(report.leftOnTheTable, const Money.sen(105200));
    });

    test('is zero when every question was answered with money', () {
      final report = summariseDeposits([
        outcome(DepositChoice.collected),
        outcome(DepositChoice.collected),
      ]).single;
      expect(report.leftOnTheTable, Money.zero);
    });
  });

  group('the take rate', () {
    test('is money over answers, exactly', () {
      // Exact rational, never a double. It is reported as a percentage and a
      // rounding error here would show as 66% where 67% was true.
      final report = summariseDeposits([
        outcome(DepositChoice.collected),
        outcome(DepositChoice.collected),
        outcome(DepositChoice.declined),
      ]).single;
      expect(report.takeRate, Rational(2, 3));
    });

    test('leaves dismissals out of the denominator', () {
      // Counting them would blame the customer for a conversation that never
      // finished, and make a busy stall look like a bad one.
      final report = summariseDeposits([
        outcome(DepositChoice.collected),
        outcome(DepositChoice.declined),
        outcome(DepositChoice.dismissed),
        outcome(DepositChoice.dismissed),
        outcome(DepositChoice.dismissed),
      ]).single;
      expect(report.takeRate, Rational(1, 2));
    });

    test('is null rather than zero when nothing was answered', () {
      // Zero percent is a claim about a day's selling. "Nobody answered" is
      // not, and the screen has to be able to tell them apart.
      final report = summariseDeposits([
        outcome(DepositChoice.dismissed),
      ]).single;
      expect(report.takeRate, isNull);
    });
  });

  group('grouping', () {
    test('keeps categories apart', () {
      final report = summariseDeposits([
        outcome(DepositChoice.collected, subtotalSen: 100000),
        outcome(
          DepositChoice.declined,
          category: DepositCategory.flooring,
          subtotalSen: 80000,
        ),
      ]);

      expect(report.length, 2);
      final curtain = report.firstWhere(
        (r) => r.category == DepositCategory.curtain,
      );
      final flooring = report.firstWhere(
        (r) => r.category == DepositCategory.flooring,
      );
      expect(curtain.leftOnTheTable, Money.zero);
      expect(flooring.leftOnTheTable, const Money.sen(80000));
    });

    test('reports categories in a fixed order', () {
      // A quiet week must not silently reshuffle the columns, or two weeks
      // cannot be read side by side.
      final report = summariseDeposits([
        outcome(DepositChoice.declined, category: DepositCategory.wallpaper),
        outcome(DepositChoice.declined, category: DepositCategory.curtain),
        outcome(DepositChoice.declined, category: DepositCategory.flooring),
      ]);
      expect(report.map((r) => r.category), DepositCategory.values);
    });

    test('omits a category nobody was asked about', () {
      // Showing it as a row of zeroes would say the question was put and went
      // nowhere, which is a different thing entirely.
      final report = summariseDeposits([outcome(DepositChoice.collected)]);
      expect(report.map((r) => r.category), [DepositCategory.curtain]);
    });
  });
}
