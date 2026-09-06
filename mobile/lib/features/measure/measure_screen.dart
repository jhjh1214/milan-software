/// Measurement mode. SPEC.md §11 Phase 6.
///
/// > Measurement mode: open a confirmed order, work through its lines ·
/// > Estimated size shown alongside the field being measured · Fair photo
/// > displayed while measuring · Variance surfaced immediately, per line and
/// > per order · Material and series finalised here
///
/// **This screen is used in somebody's house, standing up, often with no
/// signal.** Everything it needs was pulled before the visit and nothing here
/// touches the network. The push goes through the same outbox as everything
/// else, whenever the phone next has a bar.
///
/// **It decides nothing about money.** Every number comes from
/// `pricing/final_pricing.dart` through `MeasurementRepository`, which is pure,
/// mirrored on the server and pinned by `final_pricing_cases`. A screen that
/// worked out its own total would be a second answer nobody checks.
///
/// The estimate sits beside the field being measured the whole time. That is
/// not decoration: it is what lets a measurer notice they are about to record
/// 1.2m where the fair recorded 12ft, while they can still put a tape back on
/// the window.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../data/database.dart';
import '../../data/measurement_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/final_pricing.dart';
import '../../ui/theme.dart';
import '../order/order_screen.dart' show orderLinesProvider, orderProvider;
import '../quote/quote_state.dart';
import 'measure_sheet.dart';

final measurementRepositoryProvider = Provider<MeasurementRepository>(
  (ref) => MeasurementRepository(ref.watch(databaseProvider)),
);

/// The order as it now prices, recomputed from what is stored.
///
/// Read-only: `priceOrder` never writes. The screen reads this on the way in
/// and after every measurement, so what is on screen is always what the rule
/// says rather than what the screen last remembered.
final orderPricingProvider = FutureProvider.family<FinalPricing, String>((
  ref,
  orderId,
) async {
  final cards = await ref.watch(heldCardsProvider.future);
  return ref
      .watch(measurementRepositoryProvider)
      .priceOrder(orderId: orderId, cards: cards);
});

/// The fair photo for a line, looked up through the quote line it was copied
/// from. §11 Phase 6 wants it on screen while measuring — it is how somebody
/// standing in a hallway knows which window this row is.
final linePhotoProvider = FutureProvider.family<String?, String>((
  ref,
  quoteLineId,
) async {
  final db = ref.watch(databaseProvider);
  final row =
      await (db.select(db.quoteLines)
            ..where((l) => l.id.equals(quoteLineId))
            ..limit(1))
          .getSingleOrNull();
  return row?.photoPath;
});

class MeasureScreen extends ConsumerWidget {
  const MeasureScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final order = ref.watch(orderProvider(orderId));
    final lines = ref.watch(orderLinesProvider(orderId));
    final pricing = ref.watch(orderPricingProvider(orderId));

    return Scaffold(
      appBar: AppBar(title: Text(l.measureTitle)),
      body: switch ((order, lines, pricing)) {
        (
          AsyncData(value: final o),
          AsyncData(value: final ls),
          AsyncData(value: final p),
        ) =>
          _Body(order: o, lines: ls, pricing: p),
        (AsyncError(error: final e), _, _) ||
        (_, AsyncError(error: final e), _) ||
        (_, _, AsyncError(error: final e)) => Center(child: Text('$e')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.order,
    required this.lines,
    required this.pricing,
  });

  final OrderRow order;
  final List<OrderLineRow> lines;
  final FinalPricing pricing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final byId = {for (final line in pricing.lines) line.id: line};

    return Column(
      children: [
        _Summary(pricing: pricing),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: lines.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final line = lines[i];
              return _LineCard(
                line: line,
                priced: byId[line.id],
                position: '${i + 1} / ${lines.length}',
                onMeasure: () => _measure(context, ref, line),
              );
            },
          ),
        ),
        // §11: the variance has to be visible before they leave the house, and
        // the outstanding list is what tells them they cannot yet.
        if (pricing.outstanding.isNotEmpty)
          _Outstanding(outstanding: pricing.outstanding, l: l),
      ],
    );
  }

  Future<void> _measure(
    BuildContext context,
    WidgetRef ref,
    OrderLineRow line,
  ) async {
    final cards = await ref.read(heldCardsProvider.future);
    if (!context.mounted) return;

    final result = await showModalBottomSheet<MeasurementOutcome>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => MeasureSheet(line: line, cards: cards, orderId: order.id),
    );

    if (result == null) return;
    ref
      ..invalidate(orderLinesProvider(order.id))
      ..invalidate(orderPricingProvider(order.id))
      ..invalidate(orderProvider(order.id));
  }
}

/// The order-level answer, pinned above the list. §11 Phase 6.
class _Summary extends StatelessWidget {
  const _Summary({required this.pricing});

  final FinalPricing pricing;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final variance = pricing.variance;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: AppColors.muted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.measureEstimated, style: AppText.label),
          Text(pricing.estimateTotal.format(), style: AppText.body),
          const SizedBox(height: 8),
          Text(l.measureFinal, style: AppText.label),
          // Absent, not zero, until every line has priced. A total that
          // excluded an unmeasured window is a balance somebody collects and a
          // window nobody bills for.
          Text(
            pricing.finalTotal?.format() ?? l.measureNotYetPriced,
            style: AppText.money,
          ),
          if (variance != null) ...[
            const SizedBox(height: 8),
            _VarianceChip(variance: variance),
          ],
        ],
      ),
    );
  }
}

/// The variance, said in a way that cannot be read backwards.
///
/// §8.5 promises the final will be the same or lower. A drop is the promise
/// being kept and is shown plainly; a rise is not a rounding artefact and is
/// flagged, because it means the customer's own fair dimensions were wrong and
/// somebody has to say so before the bill arrives.
class _VarianceChip extends StatelessWidget {
  const _VarianceChip({required this.variance});

  final Money variance;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final over = variance.sen > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: over ? AppColors.destructive : AppColors.secondary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        over
            ? l.measureOverEstimate(variance.format())
            : l.measureUnderEstimate(Money.sen(-variance.sen).format()),
        style: AppText.body.copyWith(color: AppColors.onPrimary),
      ),
    );
  }
}

class _LineCard extends ConsumerWidget {
  const _LineCard({
    required this.line,
    required this.priced,
    required this.position,
    required this.onMeasure,
  });

  final OrderLineRow line;
  final FinalLine? priced;
  final String position;
  final VoidCallback onMeasure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final photo = ref.watch(linePhotoProvider(line.quoteLineId)).valueOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // The fair photo, so somebody in a hallway knows which window
                // this row is without reading a label. §11 Phase 6.
                if (photo != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      File(photo),
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                if (photo != null) const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$position · ${line.room}', style: AppText.label),
                      Text(line.variant, style: AppText.body),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Estimate and tape side by side, always. §6.3 keeps both.
            _SizeRow(
              label: l.measureEstimatedSize,
              width: line.estWidthTmm,
              height: line.estHeightTmm,
              total: Money.sen(line.lineTotalSen),
            ),
            if (line.isSiteMeasured)
              _SizeRow(
                label: l.measureMeasuredSize,
                width: line.finalWidthTmm,
                height: line.finalHeightTmm,
                total: line.finalLineTotalSen == null
                    ? null
                    : Money.sen(line.finalLineTotalSen!),
                emphasise: true,
              ),

            if (priced?.refusal != null) ...[
              const SizedBox(height: 8),
              Text(
                _refusalMessage(l, priced!.refusal!),
                style: AppText.caption.copyWith(color: AppColors.warning),
              ),
            ],

            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onMeasure,
                child: Text(
                  line.isSiteMeasured ? l.measureAgain : l.measureThis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _refusalMessage(L l, FinalPricingRefusal refusal) => switch (refusal) {
  FinalPricingRefusal.notMeasured => l.measureRefusedNotMeasured,
  FinalPricingRefusal.materialNotChosen => l.measureRefusedMaterial,
  // Both of these mean the handset cannot price this line at all. Said plainly
  // rather than dressed up: the fix is a connection, not a tape.
  FinalPricingRefusal.cardUnavailable => l.measureRefusedNoCard,
  FinalPricingRefusal.noApplicableRate => l.measureRefusedNoRate,
};

class _SizeRow extends StatelessWidget {
  const _SizeRow({
    required this.label,
    required this.width,
    required this.height,
    required this.total,
    this.emphasise = false,
  });

  final String label;
  final int? width;
  final int? height;
  final Money? total;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final size = width == null
        ? '—'
        : height == null
        ? _display(width!)
        : '${_display(width!)} × ${_display(height!)}';

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(label, style: AppText.label)),
          Expanded(
            child: Text(
              size,
              style: emphasise ? AppText.bodyStrong : AppText.body,
            ),
          ),
          Text(
            total?.format() ?? '—',
            style: emphasise ? AppText.bodyStrong : AppText.body,
          ),
        ],
      ),
    );
  }
}

/// A length as somebody standing in a house reads it.
///
/// Shared with the sheet, so the estimate reads identically in both places —
/// two spellings of one number is how somebody talks themselves into believing
/// they differ.
String _display(int tmm) => displayLength(tmm);

class _Outstanding extends StatelessWidget {
  const _Outstanding({required this.outstanding, required this.l});

  final List<FinalLine> outstanding;
  final L l;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: AppColors.warningSurface,
      child: Text(
        l.measureOutstanding(outstanding.length),
        style: AppText.caption.copyWith(color: AppColors.warning),
      ),
    );
  }
}
