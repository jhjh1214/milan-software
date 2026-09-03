/// Cancelling an order, with the reason that makes it a record. SPEC.md §6.3.
///
/// The reason is not a formality. What happens to the RM300 is §13 B3 and still
/// unanswered — forfeit, partial or credit — and whoever answers it will be
/// reading these rows. Four characters after trimming, the same bar a price
/// override takes, so neither an empty string nor a three-letter shrug gets
/// through.
///
/// The sheet says plainly that the deposit stays on the record. A screen that
/// went quiet about the money would leave somebody guessing whether cancelling
/// had just refunded it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/order_status.dart';
import '../../sync/order_payload.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../quote/confirm_order.dart';
import '../quote/quote_state.dart';
import 'order_screen.dart' show refusalMessage;

/// Queues every status event that has not gone up yet.
///
/// Per event, because an order walks the pipeline many times and each step is
/// its own row. Queued rather than sent: the move is already recorded locally
/// and §9 makes offline the default.
Future<void> queueStatusChanges(WidgetRef ref, String orderId) async {
  final orders = ref.read(orderRepositoryProvider);
  final outboxer = ref.read(outboxerProvider);

  for (final event in await orders.historyOf(orderId)) {
    if (event.syncedAt != null) continue;
    // Only the pipeline steps go to the status endpoint. `confirmed`,
    // `payment_taken` and `price_overridden` travel with the order itself.
    if (!OrderStatus.values.any((s) => s.wire == event.event)) continue;
    if (event.event == OrderStatus.confirmed.wire) continue;

    await outboxer.enqueueStatusChange(
      event.id,
      statusChangePayload(orderId: orderId, event: event),
    );
  }
  ref.invalidate(outboxDepthProvider);
}

/// Asks for a reason and cancels, or does nothing.
///
/// Returns true when the order was cancelled.
Future<bool> showCancelOrderSheet(
  BuildContext context,
  WidgetRef ref, {
  required OrderRow order,
}) async {
  final reason = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _CancelSheet(order: order),
  );
  if (reason == null) return false;

  if (!context.mounted) return false;
  final l = L.of(context);
  final messenger = ScaffoldMessenger.of(context);

  final result = await ref
      .read(orderRepositoryProvider)
      .advanceStatus(
        orderId: order.id,
        to: OrderStatus.cancelled,
        at: ref.read(todayProvider),
        byUserId: ref.read(credentialsProvider).valueOrNull?.user.id,
        reason: reason,
      );

  if (!result.isAllowed) {
    final message = refusalMessage(l, result.refusedBecause!);
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
    return false;
  }

  await queueStatusChanges(ref, order.id);
  return true;
}

class _CancelSheet extends StatefulWidget {
  const _CancelSheet({required this.order});

  final OrderRow order;

  @override
  State<_CancelSheet> createState() => _CancelSheetState();
}

class _CancelSheetState extends State<_CancelSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The same bar the rule enforces, checked here only so the button can be
  /// disabled rather than tapped into a refusal. The rule is still the rule.
  bool get _enough => _controller.text.trim().length >= minReasonLength;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        top: Space.lg,
        // Above the keyboard, or the field it belongs to is behind it.
        bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.orderCancelTitle, style: AppText.title),
            const SizedBox(height: Space.md),
            Text(
              l.orderCancelDepositNote,
              style: AppText.caption.copyWith(color: AppColors.warning),
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l.orderCancelReason,
                helperText: l.orderCancelHint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(Touch.primary),
                backgroundColor: AppColors.destructive,
                foregroundColor: AppColors.onDestructive,
              ),
              onPressed: _enough
                  ? () => Navigator.of(context).pop(_controller.text.trim())
                  : null,
              child: Text(l.orderCancelConfirm),
            ),
            const SizedBox(height: Space.sm),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(Touch.min),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l.orderKeep),
            ),
          ],
        ),
      ),
    );
  }
}
