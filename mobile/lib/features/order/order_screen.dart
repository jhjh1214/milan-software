/// Where an order is, and what may happen to it next. SPEC.md §6.3.
///
/// The screen shows one thing plainly: which stage the job is at, and the one
/// button that moves it to the next. Everything else — the history, the lines —
/// is arrangement around that.
///
/// ## It never decides anything itself
///
/// Which move is legal is `pricing/order_status.dart`, taken through the
/// repository against the line state actually stored. A screen that worked out
/// for itself whether an order could be marked measured would be a second
/// answer beside the first, and the two would drift.
///
/// A refusal is shown as a sentence, not an error. "Some windows still have no
/// measurements" tells a measurer what to do; a red exception does not. The one
/// refusal shown as nothing at all is `alreadyThere` — somebody tapped twice on
/// a slow handset, which is not a failure worth interrupting them for.
///
/// ## Pending sync is not a blank
///
/// Until the server issues the order number the header says so, in words. A
/// blank would read as a bug, and a number invented here would collide with
/// every other handset offline at the same fair.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../data/database.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/order_status.dart';
import '../../ui/theme.dart';
import '../../sync/sync_state.dart';
import '../quote/confirm_order.dart';
import '../quote/quote_state.dart';
import 'cancel_order_sheet.dart';
import 'override_price_sheet.dart';

/// The translated name of a status.
///
/// A switch rather than a map so that adding a status to the enum fails to
/// compile here — a stage with no name would show as an empty chip on the one
/// screen whose job is to say where the job is.
String statusLabel(L l, OrderStatus status) => switch (status) {
  OrderStatus.confirmed => l.statusConfirmed,
  OrderStatus.measurementBooked => l.statusMeasurementBooked,
  OrderStatus.measured => l.statusMeasured,
  OrderStatus.materialSelected => l.statusMaterialSelected,
  OrderStatus.inProduction => l.statusInProduction,
  OrderStatus.ready => l.statusReady,
  OrderStatus.installed => l.statusInstalled,
  OrderStatus.closed => l.statusClosed,
  OrderStatus.cancelled => l.statusCancelled,
};

/// Why a move was refused, in words somebody can act on.
///
/// [StatusRefusal.alreadyThere] returns null: the order is where they wanted
/// it, and telling somebody off for tapping twice is noise.
String? refusalMessage(L l, StatusRefusal refusal) => switch (refusal) {
  StatusRefusal.alreadyThere => null,
  StatusRefusal.terminal => l.orderRefusedTerminal,
  StatusRefusal.notATransition => l.orderRefusedNotATransition,
  StatusRefusal.linesNotMeasured => l.orderRefusedLinesNotMeasured,
  StatusRefusal.materialNotChosen => l.orderRefusedMaterialNotChosen,
  StatusRefusal.noReason => l.orderRefusedNoReason,
};

/// One order, by id.
final orderProvider = FutureProvider.family<OrderRow, String>((ref, id) async {
  final db = ref.watch(databaseProvider);
  return (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle();
});

final orderLinesProvider = FutureProvider.family<List<OrderLineRow>, String>(
  (ref, id) => ref.watch(orderRepositoryProvider).linesOf(id),
);

final orderHistoryProvider = FutureProvider.family<List<OrderEventRow>, String>(
  (ref, id) => ref.watch(orderRepositoryProvider).historyOf(id),
);

class OrderScreen extends ConsumerWidget {
  const OrderScreen({required this.orderId, super.key});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final order = ref.watch(orderProvider(orderId));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(l.orderTitle)),
      body: order.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (row) => _Body(order: row),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.order});

  final OrderRow order;

  Future<void> _advance(BuildContext context, WidgetRef ref) async {
    final l = L.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final next = nextInPipeline(OrderStatus.fromWire(order.status));
    if (next == null) return;

    final result = await ref
        .read(orderRepositoryProvider)
        .advanceStatus(
          orderId: order.id,
          to: next,
          at: ref.read(todayProvider),
          byUserId: ref.read(credentialsProvider).valueOrNull?.user.id,
        );

    _refresh(ref);
    await queueStatusChanges(ref, order.id);

    if (!result.isAllowed) {
      final message = refusalMessage(l, result.refusedBecause!);
      if (message != null) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(orderProvider(order.id));
    ref.invalidate(orderHistoryProvider(order.id));
    ref.invalidate(orderLinesProvider(order.id));
    ref.invalidate(currentOrderProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final status = OrderStatus.fromWire(order.status);
    final next = nextInPipeline(status);
    final canCancel = allowedFrom(status).contains(OrderStatus.cancelled);

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        _Header(order: order, status: status),
        const SizedBox(height: Space.xl),

        if (next != null)
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(Touch.primary),
              backgroundColor: AppColors.primary,
            ),
            onPressed: () => _advance(context, ref),
            child: Text(l.orderAdvanceTo(statusLabel(l, next))),
          )
        else
          Text(l.orderNothingLeft, style: AppText.body),

        if (canCancel) ...[
          const SizedBox(height: Space.md),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size.fromHeight(Touch.min),
              foregroundColor: AppColors.destructive,
            ),
            onPressed: () async {
              await showCancelOrderSheet(context, ref, order: order);
              _refresh(ref);
            },
            child: Text(l.orderCancelAction),
          ),
        ],

        const SizedBox(height: Space.xl),
        _Section(
          title: l.orderHistory,
          child: _History(orderId: order.id),
        ),
        const SizedBox(height: Space.xl),
        _Section(
          title: l.orderLines,
          child: _Lines(orderId: order.id),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.order, required this.status});

  final OrderRow order;
  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Words, never a blank. A missing number reads as a bug, and one
        // invented here would collide with every other handset at the fair.
        Text(
          order.orderNo ?? l.orderNoPending,
          style: order.orderNo == null
              ? AppText.body.copyWith(color: AppColors.mutedForeground)
              : AppText.headline,
        ),
        const SizedBox(height: Space.sm),
        if (order.customerName != null)
          Text(order.customerName!, style: AppText.body),
        const SizedBox(height: Space.md),
        _StatusChip(status: status),
        const SizedBox(height: Space.md),
        Text(Money.sen(order.estimateTotalSen).format(), style: AppText.money),
        Text(l.orderDueNote, style: AppText.caption),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    // Cancelled is the one that has to look different at a glance. Everything
    // else is a stage of a job going well.
    final cancelled = status == OrderStatus.cancelled;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      decoration: BoxDecoration(
        color: cancelled ? AppColors.alarmSurface : AppColors.accentSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        statusLabel(L.of(context), status),
        style: AppText.bodyStrong.copyWith(
          color: cancelled ? AppColors.alarm : AppColors.accent,
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: AppText.label),
      const SizedBox(height: Space.sm),
      child,
    ],
  );
}

class _History extends ConsumerWidget {
  const _History({required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final history = ref.watch(orderHistoryProvider(orderId));

    return history.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (events) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Oldest first, which is the order somebody reads a story in.
          for (final event in events)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_eventLabel(l, event.event), style: AppText.bodyStrong),
                  Text(formatDateTime(event.at), style: AppText.caption),
                  if (event.note != null)
                    Text(event.note!, style: AppText.caption),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A status event carries the status's own name. Anything else — a payment,
  /// an override — already wrote a sentence into its note, so the raw event
  /// name is the honest label rather than an invented one.
  String _eventLabel(L l, String event) {
    for (final status in OrderStatus.values) {
      if (status.wire == event) return statusLabel(l, status);
    }
    return event;
  }
}

class _Lines extends ConsumerWidget {
  const _Lines({required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final lines = ref.watch(orderLinesProvider(orderId));

    // §8 hard rule 8: a part-timer never sees a rate, a cost or a margin, and
    // never a control for changing one. The rule refuses them anyway; not
    // showing the tap target is so nobody is invited to try.
    final isAdmin =
        ref.watch(credentialsProvider).valueOrNull?.user.role == 'admin';

    return lines.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (rows) => Column(
        children: [
          for (final line in rows)
            InkWell(
              onTap: isAdmin
                  ? () async {
                      final changed = await showOverridePriceSheet(
                        context,
                        ref,
                        line: line,
                      );
                      if (changed) {
                        ref.invalidate(orderLinesProvider(orderId));
                        ref.invalidate(orderHistoryProvider(orderId));
                      }
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(line.room, style: AppText.body),
                          // §6.5: the marker is visible on screen and on the
                          // printed quote, and is never cleared.
                          if (line.isOverridden)
                            Text(
                              l.overrideMarker,
                              style: AppText.caption.copyWith(
                                color: AppColors.warning,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      Money.sen(line.lineTotalSen).format(),
                      style: AppText.money,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
