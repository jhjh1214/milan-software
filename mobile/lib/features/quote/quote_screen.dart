import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../ui/theme.dart';
import '../../ui/unit_labels.dart';
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
            if (priced.expiredPromo != null)
              _ExpiredCardBanner(promo: priced.expiredPromo!),
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

/// Shown whenever the loaded card's promotion has already ended.
///
/// The MITC card is a four-day fair price. Quoting a November walk-in from it
/// undercharges on every sale, and nobody would notice from the screen. Until
/// A3 supplies a standard list, this banner is the only guard.
class _ExpiredCardBanner extends StatelessWidget {
  final CardPromo promo;

  const _ExpiredCardBanner({required this.promo});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Container(
      width: double.infinity,
      color: AppColors.alarmSurface,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          const Icon(Icons.event_busy, color: AppColors.alarm),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              l.expiredCardBanner(promo.code, formatDate(promo.validTo)),
              style: AppText.bodyStrong.copyWith(color: AppColors.alarm),
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
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const WizardScreen(),
                          ),
                        ),
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
