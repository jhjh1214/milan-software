/// Moving a line's total by hand. SPEC.md §6.5.
///
/// The sheet is deliberately not the control. §6.5 is blunt about that:
///
/// > An offline PIN is bypassable, and one shared admin password reaches every
/// > part-timer within a month. The real control is the audit log plus a weekly
/// > review screen, not the gate.
///
/// So this asks for a reason and says, on its face, that the change is recorded
/// against the person doing it. That sentence is the deterrent; the disabled
/// button is only a courtesy.
///
/// The rule itself is `pricing/price_override.dart`, taken through the
/// repository. Nothing here decides whether a change is allowed — the button
/// being enabled is a guess about what the rule will say, and when the two
/// disagree the rule wins and its refusal is what the person sees.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../data/database.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/price_override.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../quote/confirm_order.dart';
import '../quote/quote_state.dart';

/// Why an override was refused, in words.
String overrideRefusalMessage(L l, OverrideRefusal refusal) =>
    switch (refusal) {
      OverrideRefusal.notAnAdmin => l.overrideRefusedNotAnAdmin,
      OverrideRefusal.noReason => l.overrideRefusedNoReason,
      OverrideRefusal.negativeTotal => l.overrideRefusedNegativeTotal,
      OverrideRefusal.noChange => l.overrideRefusedNoChange,
      OverrideRefusal.orderFinished => l.overrideRefusedOrderFinished,
    };

/// Asks for a new total and a reason, and applies it. Returns true if it did.
Future<bool> showOverridePriceSheet(
  BuildContext context,
  WidgetRef ref, {
  required OrderLineRow line,
}) async {
  final entered = await showModalBottomSheet<({Money total, String reason})>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _OverrideSheet(line: line),
  );
  if (entered == null) return false;

  if (!context.mounted) return false;
  final l = L.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final who = ref.read(credentialsProvider).valueOrNull?.user;

  final result = await ref
      .read(orderRepositoryProvider)
      .overrideLineTotal(
        orderLineId: line.id,
        newTotal: entered.total,
        reason: entered.reason,
        adminUserId: who?.id,
        isAdmin: who?.role == 'admin',
        at: ref.read(todayProvider),
        // Best effort. Money must not depend on anything that can fail, and
        // reading the device id goes through the Keystore.
        deviceId: ref.read(deviceIdProvider).valueOrNull,
      );

  if (!result.isApplied) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(overrideRefusalMessage(l, result.refusedBecause!)),
      ),
    );
    return false;
  }
  return true;
}

class _OverrideSheet extends StatefulWidget {
  const _OverrideSheet({required this.line});

  final OrderLineRow line;

  @override
  State<_OverrideSheet> createState() => _OverrideSheetState();
}

class _OverrideSheetState extends State<_OverrideSheet> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Pre-filled with what it is now, so the common case — knocking RM50 off —
    // is an edit rather than typing a price from memory.
    _amount.text = Money.sen(widget.line.lineTotalSen).toPlainString();
  }

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Money? get _total => Money.tryParse(_amount.text);

  /// A guess at what the rule will say, so the button can be disabled rather
  /// than tapped into a refusal. The rule is still the rule.
  bool get _ready =>
      _total != null &&
      !_total!.isNegative &&
      _total!.sen != widget.line.lineTotalSen &&
      _reason.text.trim().length >= minReasonLength;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        top: Space.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.overrideTitle, style: AppText.title),
            const SizedBox(height: Space.xs),
            Text(
              l.overrideCurrent(Money.sen(widget.line.lineTotalSen).format()),
              style: AppText.caption,
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: l.overrideNewTotal,
                prefixText: 'RM ',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _reason,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l.overrideReason,
                // The sentence that is the actual deterrent.
                helperText: l.overrideHint,
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(Touch.primary),
                backgroundColor: AppColors.primary,
              ),
              onPressed: _ready
                  ? () => Navigator.of(
                      context,
                    ).pop((total: _total!, reason: _reason.text.trim()))
                  : null,
              child: Text(l.overrideApply),
            ),
          ],
        ),
      ),
    );
  }
}
