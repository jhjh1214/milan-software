import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../data/rate_card_store.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/engine.dart';
import '../../pricing/models.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../order/declines_report_screen.dart';
import '../order/order_screen.dart';
import '../order/overrides_review_screen.dart';
import '../../ui/unit_labels.dart';
import '../rates/rate_card_screen.dart';
import '../sync/sync_screen.dart';
import 'confirm_order.dart';
import 'deposit_prompt_sheet.dart';
import 'line_photo.dart';
import 'quote_state.dart';
import 'share_quote.dart';
import 'wizard_screen.dart';

/// The quote. A list of windows, a running total pinned to the bottom, and the
/// reference-price disclaimer that SPEC.md §8.5 makes binding.
class QuoteScreen extends ConsumerWidget {
  const QuoteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final tier =
        ref.watch(quoteProvider).valueOrNull?.tier ?? CustomerTier.standard;
    final pricedAsync = ref.watch(pricedQuoteProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.quoteTitle),
        actions: [
          _TierToggle(tier: tier),
          _LanguageMenu(),
          IconButton(
            icon: const Icon(Icons.price_change_outlined),
            tooltip: l.ratesTitle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RateCardScreen()),
            ),
          ),
          const _OverridesButton(),
          const _SyncButton(),
          const SizedBox(width: Space.sm),
        ],
      ),
      body: pricedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Text('$e', style: AppText.body),
          ),
        ),
        data: (priced) => Column(
          children: [
            if (priced.provisionalCard) const _ProvisionalBanner(),
            const _OrderBanner(),
            _PriceListBanner(priced: priced),
            Expanded(
              child: priced.lines.isEmpty
                  ? const _EmptyState()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                        Space.lg,
                        Space.lg,
                        Space.lg,
                        Space.xxl,
                      ),
                      children: [
                        // Upgrades sit indented under the line they add to, so
                        // a customer reading the quote sees a curtain with a
                        // track rather than two unrelated charges.
                        for (final p in priced.lines)
                          Padding(
                            key: ValueKey(p.line.id),
                            padding: EdgeInsets.only(
                              bottom: Space.md,
                              left: p.line.isUpgrade ? Space.xl : 0,
                            ),
                            child: _LineCard(priced: p),
                          ),
                        // Herringbone with no self levelling, a joint with no
                        // motor. Shown loudly while the customer is still here,
                        // rather than discovered at installation.
                        for (final issue in priced.orderIssues)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Space.md),
                            child: _OrderIssueRow(issue: issue),
                          ),
                        if (priced.totals.anyFloorApplied)
                          _FloorRow(totals: priced.totals),
                        const SizedBox(height: Space.md),
                        // §4.1: the travel charge is surfaced here, above the
                        // total, never sprung on the customer after they have
                        // agreed a number.
                        const _DeliveryRow(),
                        const SizedBox(height: Space.md),
                        const _CustomerRow(),
                        const SizedBox(height: Space.lg),
                        const _Disclaimer(),
                      ],
                    ),
            ),
            _TotalBar(
              total: priced.totals.total,
              hasLines: priced.lines.isNotEmpty,
            ),
          ],
        ),
      ),
    );
  }
}

/// Says that this quote is now a confirmed sale, and **what the deposit
/// bought** — which is a held rate, not a part-payment of a bill.
///
/// Client, Sep 2026: *"no need to say owe how much based on quotation, only say
/// deposit is for fair lock price rate, must have price rate at that time
/// reference for that bill."*
///
/// So no balance is shown. A figure worked out from an estimate is one the
/// customer will remember and the tape will contradict, and §8.5 promises the
/// final can only fall. What is shown instead is the thing that is actually
/// true and actually promised: the rate, the category it covers, the date it
/// runs to, and the list version the eventual bill is worked out from.
///
/// Only appears once money has been taken — §3: the deposit *is* the
/// confirmation.
class _OrderBanner extends ConsumerWidget {
  const _OrderBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final order = ref.watch(currentOrderProvider).valueOrNull;
    if (order == null) return const SizedBox.shrink();

    final locks = ref.watch(currentLocksProvider).valueOrNull ?? const [];
    final today = ref.watch(todayProvider);

    // The way into the order. Somebody who has just taken a deposit and wants
    // to book the measurement has this banner in front of them already, so it
    // is the one place they will look.
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => OrderScreen(orderId: order.id)),
      ),
      child: Container(
        width: double.infinity,
        color: AppColors.accentSurface,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.check_circle_outline,
              size: 20,
              color: AppColors.accent,
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // The number comes from the server. Saying so beats an empty
                    // space where a reference should be.
                    order.orderNo ??
                        '${l.orderConfirmed} · ${l.orderNoPending}',
                    style: AppText.bodyStrong.copyWith(color: AppColors.accent),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l.orderDepositTaken(
                      Money.sen(order.depositPaidSen).format(),
                    ),
                    style: AppText.caption,
                  ),

                  // What the RM300 actually bought, per category it covers.
                  for (final lock in locks)
                    if (lock.isActiveOn(today))
                      Text(
                        l.orderRateLocked(
                          categoryLabel(l, lock.category),
                          formatDate(lock.heldUntil),
                        ),
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                        ),
                      ),

                  Text(
                    // The reference the eventual bill is worked out from.
                    l.orderRateReference(order.pinnedRateCardVersion),
                    style: AppText.caption.copyWith(
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  Text(
                    l.orderMeasureNext,
                    style: AppText.caption.copyWith(
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: AppColors.accent),
          ],
        ),
      ),
    );
  }
}

class _ProvisionalBanner extends StatelessWidget {
  const _ProvisionalBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.alarmSurface,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.alarm),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              L.of(context).provisionalCardBanner,
              style: AppText.bodyStrong.copyWith(color: AppColors.alarm),
            ),
          ),
        ],
      ),
    );
  }
}

/// Which price list produced these numbers, and the switch that decides it.
///
/// Always on screen. A quote is either a fair price or a standard price, and
/// the difference is 20% on curtains and 50% on blinds — the salesperson
/// holding the phone has to know which they are showing the customer.
///
/// The switch lives here rather than in a settings screen for the same reason:
/// it moves prices, so it belongs where the prices are. It cannot do damage on
/// its own — the promo window on the card is what makes fair mode mean
/// anything, and outside those dates this reads standard however it is set.
class _PriceListBanner extends ConsumerWidget {
  final PricedQuote priced;

  const _PriceListBanner({required this.priced});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final isFair = priced.priceList == PriceList.fair;
    final promo = priced.promo;
    final fairModeOn = ref.watch(fairModeProvider).valueOrNull ?? true;

    return Container(
      width: double.infinity,
      color: isFair ? AppColors.muted : AppColors.warningSurface,
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.md,
        Space.sm,
        Space.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isFair ? Icons.celebration_outlined : Icons.storefront_outlined,
            size: 20,
            color: isFair ? AppColors.primary : AppColors.warning,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isFair && promo != null
                      ? '${l.listFair(promo.code)} · ${formatDate(promo.validFrom)} – ${formatDate(promo.validTo)}'
                      : l.listStandard,
                  style: AppText.bodyStrong.copyWith(
                    color: isFair ? AppColors.primary : AppColors.warning,
                  ),
                ),
                // Fair mode on while the prices are standard is confusing
                // enough to make somebody re-enter a quote, so it says which
                // one is true rather than leaving the switch to imply it.
                if (fairModeOn && !isFair && promo != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    l.atFairEnded(formatDate(promo.validTo)),
                    style: AppText.caption.copyWith(color: AppColors.warning),
                  ),
                ],
                // The standard list is derived, not printed. Say so until a
                // real one exists — §13 A3.
                if (!isFair) ...[
                  const SizedBox(height: 2),
                  Text(
                    l.listStandardProvisional,
                    style: AppText.caption.copyWith(color: AppColors.warning),
                  ),
                ],
              ],
            ),
          ),
          Semantics(
            label: l.atFair,
            child: Switch(
              value: fairModeOn,
              onChanged: (on) => ref.read(fairModeProvider.notifier).set(on),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    // §8.2: no empty state without a next action.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.window_outlined,
              size: 56,
              color: AppColors.mutedForeground,
            ),
            const SizedBox(height: Space.lg),
            Text(l.emptyQuoteTitle, style: AppText.title),
            const SizedBox(height: Space.sm),
            Text(
              l.emptyQuoteAction,
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _LineCard extends ConsumerWidget {
  final PricedQuoteLine priced;

  const _LineCard({required this.priced});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final language = ref.watch(languageProvider);
    final line = priced.line;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // §8.1: one tap from inside the line. Only on the window itself —
              // an upgrade is a charge on the same window, not a second thing
              // to photograph.
              if (!line.isUpgrade) ...[
                LinePhoto(lineId: line.id, path: line.photoPath),
                const SizedBox(width: Space.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line.room, style: AppText.caption),
                    const SizedBox(height: 2),
                    Text(
                      priced.priced?.rule.labels(language) ?? line.variant,
                      style: AppText.title,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _delete(context, ref, line.id),
                icon: const Icon(Icons.close),
                iconSize: 22,
                color: AppColors.mutedForeground,
                tooltip: l.delete,
                constraints: const BoxConstraints(
                  minWidth: Touch.min,
                  minHeight: Touch.min,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),

          if (priced.hasError)
            Text(
              l.errorNoRate,
              style: AppText.body.copyWith(color: AppColors.destructive),
            )
          else
            _LineDetail(priced: priced.priced!, line: line, language: language),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String id) async {
    final l = L.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // Capture the notifier, not the ref. Deleting the line unmounts this card,
    // and a WidgetRef belonging to a dead widget cannot be read — the undo
    // action would fire into nothing. The notifier is owned by the
    // ProviderScope and outlives the card. The messenger is captured for the
    // same reason: it is looked up before the await, not after.
    final notifier = ref.read(quoteProvider.notifier);
    // Deleting a curtain takes its special track with it, so `removed` may
    // hold several rows. Undo puts them all back.
    final removed = await notifier.removeLine(id);
    if (removed.isEmpty) return;

    // §8.1: undo, not confirm. A modal gets tapped through blindly.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l.deleted),
          duration: Motion.undoWindow,
          action: SnackBarAction(
            label: l.undo,
            // The stored rows carry their own sort order, so undo puts the
            // line and its upgrades back where they were, not on the end.
            onPressed: () => notifier.restoreLines(removed),
          ),
        ),
      );
  }
}

class _LineDetail extends StatelessWidget {
  final dynamic priced;
  final QuoteLine line;
  final String language;

  const _LineDetail({
    required this.priced,
    required this.line,
    required this.language,
  });

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final p = priced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // §5.5 and §8.3: entered and billed, always together.
        Text(
          '${l.enteredAs('${line.rawWidth} × ${line.rawHeight}')}  ·  '
          '${l.billedAs(p.billedQty.toString(), billedUnitLabel(l, p.rule.basis))}',
          style: AppText.caption,
        ),
        if (p.rule.bandLabels != null) ...[
          const SizedBox(height: Space.xs),
          Text(p.rule.bandLabels!(language), style: AppText.caption),
        ],
        if (p.materialDeferred) ...[
          const SizedBox(height: Space.xs),
          Text(
            '${l.materialLater} · ${l.materialLaterNote}',
            style: AppText.caption.copyWith(color: AppColors.accent),
          ),
        ],
        if (p.minQtyApplied) ...[
          const SizedBox(height: Space.xs),
          Text(
            l.minQtyApplied(
              p.rule.minQty.toString(),
              billedUnitLabel(l, p.rule.basis),
            ),
            style: AppText.caption.copyWith(color: AppColors.warning),
          ),
        ],
        if (p.quantity > 1) ...[
          const SizedBox(height: Space.xs),
          Text(l.sameWindows(p.quantity), style: AppText.caption),
        ],
        const SizedBox(height: Space.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (p.tierRateApplied)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.muted,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(l.tierMvp, style: AppText.caption),
              )
            else
              const SizedBox.shrink(),
            Text((p.total as Money).format(), style: AppText.money),
          ],
        ),
      ],
    );
  }
}

class _FloorRow extends StatelessWidget {
  final dynamic totals;

  const _FloorRow({required this.totals});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    // The floor is its own labelled row. SPEC.md §4.3 forbids folding it into
    // the lines — that would be the dishonesty the disclaimer exists to stop.
    final uplift = (totals.categoryFloorUplift as Map<DepositCategory, Money>);
    final total = uplift.values.fold(Money.zero, (Money a, Money b) => a + b);

    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: AppColors.muted,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l.depositFloorRow(const Money.sen(30000).format()),
                  style: AppText.bodyStrong,
                ),
              ),
              Text('+${total.format()}', style: AppText.money),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(l.depositFloorExplain, style: AppText.caption),
        ],
      ),
    );
  }
}

/// A rule the quote as a whole breaks.
///
/// Herringbone SPC requires self levelling; an intermediate joint requires a
/// motor. Neither is knowable from one line, and neither is a reason to refuse
/// the quote — refusing loses the sale, and staying quiet means finding out at
/// installation. So it is shown, in the reader's language, while the customer
/// is still standing there.
class _OrderIssueRow extends ConsumerWidget {
  final OrderRuleViolation issue;

  const _OrderIssueRow({required this.issue});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(languageProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: AppColors.warningSurface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: AppColors.warning, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.rule, color: AppColors.warning),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              issue.rule.messages(language),
              style: AppText.bodyStrong.copyWith(color: AppColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who the quote is for.
///
/// Optional, and deliberately so: at a fair the job is to lock the deposit, and
/// a required name field is one more thing standing between a part-timer and a
/// four-minute quote. A full customer record with TIN and address arrives in
/// Phase 4, where the RM10,000 threshold makes some of it mandatory.
class _CustomerRow extends ConsumerWidget {
  const _CustomerRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final quote = ref.watch(quoteProvider).valueOrNull;
    if (quote == null) return const SizedBox.shrink();

    final name = quote.customerName;
    final phone = quote.customerPhone;
    final filled =
        (name != null && name.isNotEmpty) ||
        (phone != null && phone.isNotEmpty);

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: () => _edit(context, ref, name, phone),
        child: Container(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.person_outline,
                color: AppColors.mutedForeground,
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.customerTitle, style: AppText.label),
                    const SizedBox(height: 2),
                    Text(
                      filled
                          ? [
                              if (name != null && name.isNotEmpty) name,
                              if (phone != null && phone.isNotEmpty) phone,
                            ].join('  ·  ')
                          : l.customerOptional,
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.mutedForeground),
            ],
          ),
        ),
      ),
    );
  }

  void _edit(BuildContext context, WidgetRef ref, String? name, String? phone) {
    final l = L.of(context);
    final notifier = ref.read(quoteProvider.notifier);
    final nameController = TextEditingController(text: name ?? '');
    final phoneController = TextEditingController(text: phone ?? '');

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheet).viewInsets.bottom,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.customerTitle, style: AppText.title),
                const SizedBox(height: Space.lg),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: l.customerName,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: phoneController,
                  // The one place the system keyboard is right: a phone number
                  // is not a dimension, and the phone pad is what people know.
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: l.customerPhone,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Space.lg),
                FilledButton(
                  onPressed: () {
                    notifier.setCustomer(
                      name: nameController.text.trim().isEmpty
                          ? null
                          : nameController.text.trim(),
                      phone: phoneController.text.trim().isEmpty
                          ? null
                          : phoneController.text.trim(),
                    );
                    Navigator.of(sheet).pop();
                  },
                  child: Text(l.save),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The delivery area, and the travel charge it carries.
///
/// SPEC.md §4.1: "Ask for the delivery area early and surface the charge before
/// the total, never after the customer has agreed a number." So it sits above
/// the total on the quote, tappable, with the charge shown on its face.
class _DeliveryRow extends ConsumerWidget {
  const _DeliveryRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final language = ref.watch(languageProvider);
    final cardAsync = ref.watch(rateCardProvider);
    final quote = ref.watch(quoteProvider).valueOrNull;
    final card = cardAsync.valueOrNull;
    if (card == null || quote == null || card.deliveryZones.isEmpty) {
      return const SizedBox.shrink();
    }

    final zone = card.deliveryZones
        .where((z) => z.id == quote.deliveryZoneId)
        .firstOrNull;

    return Material(
      color: zone == null ? AppColors.surface : AppColors.muted,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: () => _pick(context, ref, card, quote.deliveryZoneId),
        child: Container(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.local_shipping_outlined,
                color: AppColors.mutedForeground,
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.deliveryTitle, style: AppText.label),
                    const SizedBox(height: 2),
                    Text(
                      zone == null ? l.deliveryNone : zone.labels(language),
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              if (zone != null)
                Text(
                  '+${Money.sen(zone.chargeSen).format()}',
                  style: AppText.money,
                ),
              const SizedBox(width: Space.sm),
              const Icon(Icons.chevron_right, color: AppColors.mutedForeground),
            ],
          ),
        ),
      ),
    );
  }

  void _pick(
    BuildContext context,
    WidgetRef ref,
    RateCard card,
    String? current,
  ) {
    final l = L.of(context);
    final language = ref.read(languageProvider);
    final notifier = ref.read(quoteProvider.notifier);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.deliveryTitle, style: AppText.title),
                  const SizedBox(height: Space.xs),
                  Text(l.deliveryAskEarly, style: AppText.caption),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              minTileHeight: Touch.min,
              title: Text(l.deliveryNone, style: AppText.body),
              trailing: current == null
                  ? const Icon(Icons.check, color: AppColors.accent)
                  : null,
              onTap: () {
                notifier.setDeliveryZone(null);
                Navigator.of(sheet).pop();
              },
            ),
            for (final zone in card.deliveryZones)
              ListTile(
                minTileHeight: Touch.min,
                title: Text(zone.labels(language), style: AppText.body),
                subtitle: Text(
                  '+${Money.sen(zone.chargeSen).format()}',
                  style: AppText.caption,
                ),
                trailing: current == zone.id
                    ? const Icon(Icons.check, color: AppColors.accent)
                    : null,
                onTap: () {
                  notifier.setDeliveryZone(zone.id);
                  Navigator.of(sheet).pop();
                },
              ),
            const SizedBox(height: Space.md),
          ],
        ),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    // Binding, per SPEC.md §8.5. Not dismissible, not a footnote.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: AppColors.warningSurface,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.verified_outlined,
                size: 20,
                color: AppColors.warning,
              ),
              const SizedBox(width: Space.sm),
              Text(
                l.disclaimerTitle,
                style: AppText.bodyStrong.copyWith(color: AppColors.warning),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Text(
            l.disclaimerBody,
            style: AppText.body.copyWith(color: AppColors.warning),
          ),
        ],
      ),
    );
  }
}

class _TotalBar extends ConsumerWidget {
  final Money total;
  final bool hasLines;

  const _TotalBar({required this.total, required this.hasLines});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    // §8.1: the running total is the most-looked-at number in the app, and
    // primary actions live in the bottom third where a thumb reaches.
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(l.runningTotal, style: AppText.label),
                  Text(total.format(), style: AppText.totalDisplay),
                ],
              ),
              const SizedBox(height: Space.md),
              Builder(
                builder: (context) => Row(
                  children: [
                    if (hasLines) ...[
                      Expanded(
                        child: SizedBox(
                          height: Touch.primary,
                          child: OutlinedButton.icon(
                            onPressed: () => shareQuotePdf(context, ref),
                            icon: const Icon(Icons.ios_share, size: 20),
                            label: Text(l.share),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.md),
                    ],
                    Expanded(
                      flex: hasLines ? 1 : 2,
                      child: FilledButton.icon(
                        onPressed: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const WizardScreen(),
                            ),
                          );
                          // §6.2, asked here rather than inside the wizard: the
                          // question is about the whole order, and a customer
                          // who has just watched a window priced is the person
                          // to ask. Away from a fair it asks nothing.
                          if (context.mounted) {
                            await askForOutstandingDeposits(context, ref);
                          }
                        },
                        icon: const Icon(Icons.add),
                        label: Text(l.addWindow),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The way to the sync screen, carrying the queue depth as a badge.
///
/// The badge is the whole point of putting it here. A part-timer who can see
/// "3 waiting" understands a dead connection; one who cannot assumes the orders
/// vanished, and starts writing them on paper as well.
/// The way into the weekly override review. Admin only, and hidden otherwise.
///
/// §6.5 puts the entire control on this screen being read: *"without it the log
/// is never read and the control does not exist."* Somewhere findable is
/// therefore part of the control, not a convenience — a review screen three
/// menus deep is one nobody opens on a Monday morning.
class _OverridesButton extends ConsumerWidget {
  const _OverridesButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final isAdmin =
        ref.watch(credentialsProvider).valueOrNull?.user.role == 'admin';
    if (!isAdmin) return const SizedBox.shrink();

    return PopupMenuButton<int>(
      icon: const Icon(Icons.fact_check_outlined),
      tooltip: l.overridesThisWeek,
      itemBuilder: (context) => [
        PopupMenuItem(value: 0, child: Text(l.overridesThisWeek)),
        PopupMenuItem(value: 1, child: Text(l.declinesTitle)),
      ],
      onSelected: (which) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => which == 0
              ? const OverridesReviewScreen()
              : const DeclinesReportScreen(),
        ),
      ),
    );
  }
}

class _SyncButton extends ConsumerWidget {
  const _SyncButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final queued = ref.watch(outboxDepthProvider).valueOrNull ?? 0;

    return IconButton(
      tooltip: l.syncTitle,
      icon: Badge(
        isLabelVisible: queued > 0,
        label: Text('$queued'),
        child: const Icon(Icons.cloud_sync_outlined),
      ),
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
    );
  }
}

class _TierToggle extends ConsumerWidget {
  final CustomerTier tier;

  const _TierToggle({required this.tier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final isMvp = tier == CustomerTier.mvp;
    return TextButton(
      onPressed: () => ref
          .read(quoteProvider.notifier)
          .setTier(isMvp ? CustomerTier.standard : CustomerTier.mvp),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.onPrimary,
        minimumSize: const Size(Touch.min, Touch.min),
      ),
      child: Text(
        isMvp ? l.tierMvp : l.tierStandard,
        style: TextStyle(fontWeight: isMvp ? FontWeight.w700 : FontWeight.w400),
      ),
    );
  }
}

class _LanguageMenu extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.language),
      tooltip: l.language,
      onSelected: (code) => ref.read(languageProvider.notifier).state = code,
      itemBuilder: (context) => [
        PopupMenuItem(value: 'zh', child: Text(l.languageChinese)),
        PopupMenuItem(value: 'en', child: Text(l.languageEnglish)),
        PopupMenuItem(value: 'ms', child: Text(l.languageMalay)),
      ],
    );
  }
}
