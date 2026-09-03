/// Which categories on this quote still need an RM300. SPEC.md §6.2.
///
/// > This is the moment the second RM300 gets collected, and it is almost
/// > certainly being missed at fairs today.
///
/// Not a silent fallback to full price, and **not a silent extension of the
/// existing lock** — that second one is the same expensive bug as §6.1, wearing
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
/// cannot drift — both answer "does this category have an active lock", and if
/// they ever disagreed the app would ask for money it had already taken, or
/// quietly skip asking.
library;

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
/// Returns nothing away from a fair, whatever the locks say — see the library
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

/// Which button the salesperson pressed. §6.2: **log which**.
///
/// The declined-deposit report is the point. It tells the boss what fairs are
/// leaving on the table, and it only exists if the decline is recorded as
/// deliberately as the sale.
enum DepositChoice {
  /// `[收 RM300]` — taken, and a lock opens.
  collected('collected'),

  /// `[照原价，不锁]` — the customer keeps today's fair price and no hold.
  declined('declined'),

  /// `[取消这项]` — the lines came back off the quote.
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
