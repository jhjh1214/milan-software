/// Which categories on this quote still need an RM300. SPEC.md Â§6.2.
///
/// > This is the moment the second RM300 gets collected, and it is almost
/// > certainly being missed at fairs today.
///
/// Not a silent fallback to full price, and **not a silent extension of the
/// existing lock** â€” that second one is the same expensive bug as Â§6.1, wearing
/// a friendlier face. A customer who paid for curtains and walks away with
/// flooring quoted at held rates has been given twelve months of prices for
/// nothing.
///
/// **Fair-only.** Client, Sep 2026: *"no second rm300 paid later in showroom,
/// only depo at fair can lock price."* Away from a fair there is no second
/// RM300 to offer, because it would not lock anything, and a prompt that
/// collects money for a hold that will not exist is worse than no prompt.
///
/// Pure: no clock, no I/O, no Flutter. Lives beside the resolver so the two
/// cannot drift â€” both answer "does this category have an active lock", and if
/// they ever disagreed the app would ask for money it had already taken, or
/// quietly skip asking.
library;

import '../core/money.dart';
import '../core/rational.dart';
import 'models.dart';
import 'rate_lock.dart';

/// One category the customer has not yet paid a deposit on.
class DepositGap {
  final DepositCategory category;

  /// The lines that put this category on the quote, so the prompt can name
  /// them. "This order has flooring" is easier to act on than "a category is
  /// unlocked".
  final List<String> lineIds;

  const DepositGap({required this.category, required this.lineIds});
}

/// What a line contributes to the question: its family, and its parent's.
class LineCategoryInput {
  final String id;
  final Family family;
  final DepositCategory? depositCategoryOverride;
  final Family? parentFamily;

  const LineCategoryInput({
    required this.id,
    required this.family,
    this.depositCategoryOverride,
    this.parentFamily,
  });
}

/// The categories on this quote with no active lock behind them.
///
/// Returns nothing away from a fair, whatever the locks say â€” see the library
/// note. Ordered by first appearance so the prompt asks about them in the order
/// the customer built the quote, rather than in an order decided by an enum.
List<DepositGap> depositGaps({
  required List<LineCategoryInput> lines,
  required List<CategoryLock> locks,
  required Channel channel,
  required DateTime today,
}) {
  if (channel != Channel.fair) return const [];

  final held = {
    for (final lock in locks)
      if (lock.isActiveOn(today)) lock.category,
  };

  final gaps = <DepositCategory, List<String>>{};
  for (final line in lines) {
    final DepositCategory category;
    try {
      category =
          line.depositCategoryOverride ??
          depositCategoryOf(line.family, parentFamily: line.parentFamily);
    } on UnknownDepositCategory {
      // A line whose category cannot be decided is a data problem, and it is
      // already surfaced where it is priced. Asking for a deposit on "unknown"
      // would be asking for money against nothing.
      continue;
    }

    if (held.contains(category)) continue;
    (gaps[category] ??= []).add(line.id);
  }

  return [
    for (final entry in gaps.entries)
      DepositGap(category: entry.key, lineIds: entry.value),
  ];
}

/// Which button the salesperson pressed. Â§6.2: **log which**.
///
/// The declined-deposit report is the point. It tells the boss what fairs are
/// leaving on the table, and it only exists if the decline is recorded as
/// deliberately as the sale.
enum DepositChoice {
  /// `[æ”¶ RM300]` â€” taken, and a lock opens.
  collected('collected'),

  /// `[ç…§åŽŸä»·ï¼Œä¸é”]` â€” the customer keeps today's fair price and no hold.
  declined('declined'),

  /// `[å–æ¶ˆè¿™é¡¹]` â€” the lines came back off the quote.
  linesRemoved('lines_removed'),

  /// The prompt appeared and was dismissed without an answer. Recorded rather
  /// than treated as a decline: "they said no" and "nobody asked properly" are
  /// different problems, and only one of them is the customer's.
  dismissed('dismissed');

  const DepositChoice(this.wire);

  final String wire;

  static DepositChoice fromWire(String wire) =>
      DepositChoice.values.firstWhere((c) => c.wire == wire);
}

/// One prompt as the report reads it: what was asked, what was answered, and
/// what the category was worth at the time.
class PromptOutcome {
  const PromptOutcome({
    required this.category,
    required this.choice,
    required this.categorySubtotal,
  });

  final DepositCategory category;
  final DepositChoice choice;

  /// What the quote was worth in this category when the question was asked.
  /// The report needs it to say what was *left on the table*, not only how
  /// often somebody said no.
  final Money categorySubtotal;
}

/// What happened in one category over a period.
class CategoryDeclines {
  const CategoryDeclines({
    required this.category,
    required this.asked,
    required this.collected,
    required this.declined,
    required this.dismissed,
    required this.linesRemoved,
    required this.leftOnTheTable,
  });

  final DepositCategory category;

  /// Every time the question was put.
  final int asked;

  final int collected;

  /// They said no.
  final int declined;

  /// Nobody got an answer. Kept apart from [declined] on purpose: "they said
  /// no" and "nobody asked properly" are different problems, and only one of
  /// them is the customer's.
  final int dismissed;

  /// The lines came back off the quote â€” not a lost deposit so much as a lost
  /// line, and worth seeing separately from either.
  final int linesRemoved;

  /// The value of the categories that were quoted and not deposited on. What
  /// the fair left behind.
  final Money leftOnTheTable;

  /// Of the times the question was actually answered, how often with money.
  ///
  /// Dismissals are excluded from the denominator. Counting them would blame
  /// the customer for a conversation that never finished, and make a busy
  /// stall look like a bad one.
  Rational? get takeRate {
    final answered = collected + declined + linesRemoved;
    if (answered == 0) return null;
    return Rational(collected, answered);
  }
}

/// Groups prompts by category. SPEC.md Â§6.2 and Â§11 Phase 4.
///
/// > Declined category deposits appear in a report
///
/// The point is not the count. It is `leftOnTheTable`: what the fair quoted in
/// a category and did not take a deposit on, which is the number that says
/// whether the prompt is worth having at all.
///
/// Pure: no clock, no I/O. The period is chosen by the caller.
List<CategoryDeclines> summariseDeposits(List<PromptOutcome> prompts) {
  final byCategory = <DepositCategory, List<PromptOutcome>>{};
  for (final p in prompts) {
    (byCategory[p.category] ??= []).add(p);
  }

  return [
    // Every category the prompt could have been shown for, in a fixed order,
    // so a quiet week does not silently drop a column and make last week's
    // report look like a different shape.
    for (final category in DepositCategory.values)
      if (byCategory.containsKey(category))
        () {
          final rows = byCategory[category]!;
          int count(DepositChoice c) => rows.where((r) => r.choice == c).length;

          return CategoryDeclines(
            category: category,
            asked: rows.length,
            collected: count(DepositChoice.collected),
            declined: count(DepositChoice.declined),
            dismissed: count(DepositChoice.dismissed),
            linesRemoved: count(DepositChoice.linesRemoved),
            leftOnTheTable: rows
                .where((r) => r.choice != DepositChoice.collected)
                .fold(Money.zero, (sum, r) => sum + r.categorySubtotal),
          );
        }(),
  ];
}
