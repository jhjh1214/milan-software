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
import '../../pricing/cash_up.dart';
import '../../pricing/customer_key.dart';
import '../../pricing/deposit_prompt.dart';
import '../../pricing/models.dart';
import '../../pricing/rate_lock.dart';
import '../../sync/lock_payload.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../payment/payment_method_sheet.dart';
import 'confirm_order.dart';
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
      .locksFor(customerKeyForQuote(quote));
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

/// Which customer's locks apply here. SPEC.md §6.1, §13 B9.
///
/// This used to be the quote id, to avoid a real problem: *"a blank phone
/// number would make every anonymous quote share a set of locks, and one
/// customer's hold would price another's window."* That concern is right and
/// still holds. What it threw out with it was the returning customer.
///
/// A twelve-month hold exists so somebody can come back — with a *new quote*,
/// and a new id. Keyed on the quote, the lock could never match again: the
/// customer paid RM300 at the fair, returned in March, and was quoted the
/// standard rate. More than the hold they bought, after the app had told them
/// the promo rate was held until next August.
///
/// `customerKeyFor` keeps both properties. A usable phone is the key, so the
/// hold follows the customer; no usable phone falls back to the quote id, so
/// two anonymous quotes still never share. §13 B9 is where the proper customer
/// record gets decided.
String customerKeyForQuote(QuoteState quote) =>
    customerKeyFor(phone: quote.customerPhone, quoteId: quote.quoteId).value;

/// Asks the server what this customer already holds, and stores what comes
/// back. SPEC.md §6.1, §13 B9.
///
/// A hold is bought once and used later, possibly on a different phone. Six
/// handsets work a fair: the customer deposits on phone 3 and walks into the
/// showroom in March where phone 1 is used. Phone 1 has never seen that hold,
/// so without this it quotes the standard rate — more than the customer paid
/// RM300 to be protected from.
///
/// Called when a phone number arrives, because that is the only thing that
/// identifies a returning customer. Best effort and never awaited by a screen:
/// offline is the default (§9), and with no signal the quote is priced from
/// what this handset knows. If a hold exists and could not be fetched the
/// quote is higher than it needs to be, which §8.5 permits and the next sync
/// corrects.
Future<void> pullHeldRatesFor(WidgetRef ref, QuoteState quote) async {
  final credentials = ref.read(credentialsProvider).valueOrNull;
  if (credentials == null) return;

  final key = customerKeyFor(
    phone: quote.customerPhone,
    quoteId: quote.quoteId,
  );
  // Nothing to ask about. A quote-scoped key is this handset's own, and the
  // server has never been told a different name for it.
  if (!key.fromPhone) return;

  try {
    final added = await ref
        .read(lockSyncProvider)
        .pullFor(
          credentials: credentials,
          customerKey: key.value,
          at: ref.read(todayProvider),
        );
    if (added > 0) {
      ref.invalidate(openDepositGapsProvider);
      ref.invalidate(currentLocksProvider);
    }
  } catch (_) {
    // Deliberately silent. See the doc comment.
  }
}

/// Queues a hold for the server, best effort.
///
/// Queued rather than sent: the RM300 is already recorded and §9 makes offline
/// the default. Nothing about the deposit waits on a connection.
Future<void> _queueLock(WidgetRef ref, String lockId) async {
  final row = await ref.read(lockRepositoryProvider).lockRow(lockId);
  if (row == null) return;
  await ref
      .read(outboxerProvider)
      .enqueueLock(
        lockId,
        lockPayload(
          lock: row,
          deviceId: ref.read(deviceIdProvider).valueOrNull,
        ),
      );
  ref.invalidate(outboxDepthProvider);
}

/// Queues one prompt answer for the server.
Future<void> _queuePrompt(WidgetRef ref, String promptId) async {
  final row = await ref.read(lockRepositoryProvider).promptRow(promptId);
  if (row == null) return;
  await ref
      .read(outboxerProvider)
      .enqueueDepositPrompt(
        promptId,
        depositPromptPayload(
          prompt: row,
          deviceId: ref.read(deviceIdProvider).valueOrNull,
        ),
      );
  ref.invalidate(outboxDepthProvider);
}

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

  final promptId = await repo.recordPrompt(
    quoteId: quote.quoteId,
    category: gap.category,
    choice: decided,
    categorySubtotalSen: _subtotalFor(ref, gap),
    at: now,
  );
  await _queuePrompt(ref, promptId);

  switch (decided) {
    case DepositChoice.collected:
      // How it was paid, before anything is written. The cash-up is
      // expected-versus-held **per method**, so a payment with no method
      // cannot be reconciled against anything at the end of the day.
      if (!context.mounted) return;
      final method = await askForPaymentMethod(context);
      if (method == null || !context.mounted) return;

      // The money goes down first. If the app dies between the two writes, a
      // payment with no lock is a customer to call back; a lock with no
      // payment is money nobody can find.
      final payments = ref.read(paymentRepositoryProvider);
      final paymentId = await payments.record(
        id: newId(),
        quoteId: quote.quoteId,
        kind: PaymentKind.deposit,
        method: method,
        amountSen: card.config.minDepositSen,
        takenAt: now,
        // Best effort, never awaited. The device id lives in the Keystore, and
        // recording money must not depend on anything that can fail or take a
        // moment — an audit field is worth less than the payment it labels.
        deviceId: ref.read(deviceIdProvider).valueOrNull,
      );

      // The rule decides whether a hold is allowed, not the screen. Away from
      // a fair it refuses, and the sheet never appears there anyway.
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
        await repo.store(
          lock,
          customerId: customerKeyForQuote(quote),
          at: now,
          depositPaymentId: paymentId,
        );
        await payments.linkToLock(paymentId: paymentId, lockId: lock.id);
        // The hold goes up too. One that never leaves this handset is one the
        // customer paid RM300 for and cannot use on any other phone — which
        // is every phone but this one, in March.
        await _queueLock(ref, lock.id);
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
        // The money is still recorded. It confirms the order; it just does not
        // hold a price.
        messenger.showSnackBar(SnackBar(content: Text(l.depositNotAtFair)));
      }

      // §3: the deposit **is** the confirmation. Not a quote, not a lead, a
      // confirmed sale — and the quote stays exactly as it was, referenced by
      // the order as the rough estimate of what to do.
      await confirmOrderForDeposit(ref, depositJustTaken: minDeposit, at: now);

      // Queued last, so the row it describes is already complete — including
      // the lock it bought. It goes up on the next connection and comes back
      // with the receipt number the server issued.
      await ref
          .read(outboxerProvider)
          .enqueuePayment(
            paymentId,
            payments.pushBodyFor(
              (await payments.forQuote(
                quote.quoteId,
              )).firstWhere((p) => p.id == paymentId),
            ),
          );
      ref.invalidate(outboxDepthProvider);

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

/// Every lock the current quote's customer holds, in whatever state.
///
/// Watched by the order banner, which says what the RM300 actually bought.
final currentLocksProvider = FutureProvider<List<CategoryLock>>((ref) async {
  final quote = await ref.watch(quoteProvider.future);
  return ref.watch(lockRepositoryProvider).locksFor(customerKeyForQuote(quote));
});

/// The category a deposit covers, in the reader's own language.
String categoryLabel(L l, DepositCategory category) => switch (category) {
  DepositCategory.curtain => l.categoryCurtain,
  DepositCategory.flooring => l.categoryFlooring,
  DepositCategory.wallpaper => l.categoryWallpaper,
};

String _categoryLabel(L l, DepositCategory category) =>
    categoryLabel(l, category);

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
