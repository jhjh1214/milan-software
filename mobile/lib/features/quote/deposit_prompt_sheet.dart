/// The category prompt. SPEC.md §6.2.
///
/// > 这单有地板，地板要另外 RM300 才锁到促销价。
/// > `[收 RM300]` `[照原价，不锁]` `[取消这项]`
/// >
/// > Not a silent fallback to full price. Not a silent extension of the
/// > existing lock. This is the moment the second RM300 gets collected, and it
/// > is almost certainly being missed at fairs today.
///
/// Three deliberate choices, and **whichever is pressed is written down** — the
/// declined-deposit report is what tells the boss what fairs are leaving on the
/// table, and it only exists if a decline is recorded as carefully as a sale.
///
/// Dismissing the sheet counts as a fourth outcome rather than as a decline.
/// "They said no" and "nobody asked properly" are different problems, and only
/// one of them is the customer's.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../data/lock_repository.dart';
import '../../data/quote_repository.dart' show newId;
import '../../l10n/app_localizations.dart';
import '../../pricing/deposit_prompt.dart';
import '../../pricing/models.dart';
import '../../pricing/rate_lock.dart';
import '../../ui/theme.dart';
import 'quote_state.dart';

final lockRepositoryProvider = Provider<LockRepository>(
  (ref) => LockRepository(ref.watch(databaseProvider)),
);

/// Which categories on the current quote still need an RM300, minus the ones
/// already asked about.
///
/// Answered rather than paid: a customer who said no once is not asked again
/// three windows later. The decline is still on the record.
final openDepositGapsProvider = FutureProvider<List<DepositGap>>((ref) async {
  final quote = await ref.watch(quoteProvider.future);
  final card = await ref.watch(rateCardProvider.future);
  final locks = await ref
      .watch(lockRepositoryProvider)
      .locksFor(_customerKeyFor(quote));
  final answered = await ref
      .watch(lockRepositoryProvider)
      .answeredOn(quote.quoteId);

  final gaps = depositGaps(
    lines: [
      for (final line in quote.lines)
        LineCategoryInput(
          id: line.id,
          family: card.ruleFor(line.variant)?.family ?? Family.curtain,
          depositCategoryOverride: card
              .ruleFor(line.variant)
              ?.depositCategoryOverride,
          parentFamily: _parentFamilyOf(line, quote, card),
        ),
    ],
    locks: locks,
    channel: quote.channel,
    today: ref.watch(todayProvider),
  );

  return [
    for (final gap in gaps)
      if (!answered.contains(gap.category)) gap,
  ];
});

/// Until Phase 4's customer record exists, a quote is its own customer.
///
/// Deliberately not the phone number: a blank one would make every anonymous
/// quote share a set of locks, and one customer's hold would price another's
/// window.
String _customerKeyFor(QuoteState quote) => quote.quoteId;

Family? _parentFamilyOf(QuoteLine line, QuoteState quote, RateCard card) {
  if (line.parentLineId == null) return null;
  for (final other in quote.lines) {
    if (other.id == line.parentLineId) {
      return card.ruleFor(other.variant)?.family;
    }
  }
  return null;
}

/// Asks about every category on the quote that still needs a deposit.
///
/// Returns when there is nothing left to ask. Safe to call after every line:
/// the gaps list is already filtered to what has not been answered.
Future<void> askForOutstandingDeposits(
  BuildContext context,
  WidgetRef ref,
) async {
  final gaps = await ref.read(openDepositGapsProvider.future);
  for (final gap in gaps) {
    if (!context.mounted) return;
    await _askFor(context, ref, gap);
    ref.invalidate(openDepositGapsProvider);
  }
}

Future<void> _askFor(
  BuildContext context,
  WidgetRef ref,
  DepositGap gap,
) async {
  final card = await ref.read(rateCardProvider.future);
  final quote = await ref.read(quoteProvider.future);
  if (!context.mounted) return;

  final minDeposit = Money.sen(card.config.minDepositSen);
  final choice = await showModalBottomSheet<DepositChoice>(
    context: context,
    isDismissible: true,
    backgroundColor: AppColors.surface,
    builder: (_) => _DepositSheet(gap: gap, amount: minDeposit),
  );

  if (!context.mounted) return;
  final l = L.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final repo = ref.read(lockRepositoryProvider);
  final now = ref.read(todayProvider);

  // Dismissal is an outcome, not an absence of one.
  final decided = choice ?? DepositChoice.dismissed;

  await repo.recordPrompt(
    quoteId: quote.quoteId,
    category: gap.category,
    choice: decided,
    categorySubtotalSen: _subtotalFor(ref, gap),
    at: now,
  );

  switch (decided) {
    case DepositChoice.collected:
      // The rule decides whether this is allowed, not the screen. Away from a
      // fair it refuses, and the sheet never appears there anyway.
      final grant = openCategoryLock(
        id: newId(),
        channel: quote.channel,
        category: gap.category,
        depositDate: now,
        depositSen: card.config.minDepositSen,
        minDepositSen: card.config.minDepositSen,
        rateCardVersion: card.version,
        promoPct: card.promoDiscountPct,
      );

      if (grant.lock case final lock?) {
        await repo.store(lock, customerId: _customerKeyFor(quote), at: now);
        ref.invalidate(openDepositGapsProvider);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l.depositCollected(
                minDeposit.format(),
                _categoryLabel(l, gap.category),
                formatDate(lock.heldUntil),
              ),
            ),
          ),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(l.depositNotAtFair)));
      }

    case DepositChoice.declined:
      // No confirmation. Somebody just pressed "no hold" and knows they did;
      // a toast repeating it back is noise, and it would sit on top of the
      // undo action of whatever they do next.
      break;

    case DepositChoice.linesRemoved:
      for (final lineId in gap.lineIds) {
        await ref.read(quoteProvider.notifier).removeLine(lineId);
      }

    case DepositChoice.dismissed:
      break;
  }
}

/// What this category is worth on the quote right now, for the report.
int _subtotalFor(WidgetRef ref, DepositGap gap) {
  final priced = ref.read(pricedQuoteProvider).valueOrNull;
  if (priced == null) return 0;
  var total = 0;
  for (final line in priced.lines) {
    if (!gap.lineIds.contains(line.line.id)) continue;
    total += line.priced?.total.sen ?? 0;
  }
  return total;
}

String _categoryLabel(L l, DepositCategory category) => switch (category) {
  DepositCategory.curtain => l.categoryCurtain,
  DepositCategory.flooring => l.categoryFlooring,
  DepositCategory.wallpaper => l.categoryWallpaper,
};

class _DepositSheet extends StatelessWidget {
  final DepositGap gap;
  final Money amount;

  const _DepositSheet({required this.gap, required this.amount});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final category = _categoryLabel(l, gap.category);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.depositNeededTitle(category), style: AppText.title),
            const SizedBox(height: Space.sm),
            Text(
              l.depositNeededBody(category, amount.format()),
              style: AppText.body,
            ),
            const SizedBox(height: Space.xl),

            // The money button first and largest. §6.2 calls this a revenue
            // feature, and the layout should say so.
            SizedBox(
              width: double.infinity,
              height: Touch.primary,
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(DepositChoice.collected),
                child: Text(l.depositCollect(amount.format())),
              ),
            ),
            const SizedBox(height: Space.md),
            SizedBox(
              width: double.infinity,
              height: Touch.primary,
              child: OutlinedButton(
                onPressed: () =>
                    Navigator.of(context).pop(DepositChoice.declined),
                child: Text(l.depositDecline),
              ),
            ),
            const SizedBox(height: Space.sm),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(DepositChoice.linesRemoved),
              child: Text(
                l.depositRemove(category),
                style: const TextStyle(color: AppColors.destructive),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
