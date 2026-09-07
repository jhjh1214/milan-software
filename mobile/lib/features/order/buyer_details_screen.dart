/// Taking the buyer's details for the invoice. SPEC.md §10.3, §11 Phase 7.
///
/// The rule and the storage landed in Phase 6; this is the form. Without it an
/// order over RM10,000 is **stuck** — `advanceOrder` refuses to move it and
/// nothing on the handset can supply what it is asking for.
///
/// ## It says why, before it asks
///
/// §10.2 makes this a legal requirement rather than a preference, and the
/// person filling it in is often a part-timer asking a stranger for an IC
/// number. A form that just presents nine boxes gets abandoned, or filled with
/// whatever makes it go away. So the first thing on the screen is the reason,
/// in the reader's own language, and it names the amount.
///
/// ## What is missing is stated all at once
///
/// `missingBuyerDetails` returns everything outstanding in one list, and this
/// screen shows all of it. A form that reveals one missing field at a time is a
/// customer asked three times — and the whole point of §10.2's timing is that
/// there is exactly one conversation in which to get this.
///
/// ## It decides nothing
///
/// Whether the record is complete is `buyerDetailsComplete` in
/// `pricing/einvoice_threshold.dart`, pure and mirrored on the server. This
/// screen only shows what that function says. A second answer here would
/// disagree with `advanceOrder` the first time somebody changed one of them.
///
/// ## Hard rule 7
///
/// Nothing here may say "Tax Invoice" or "e-Invoice" as a label for what this
/// system produces. It says the details are collected **so the accounts system
/// can issue the invoice**, and says plainly that this app does not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../data/database.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/einvoice_threshold.dart';
import '../../ui/theme.dart';
import '../quote/confirm_order.dart' show orderRepositoryProvider;
import '../quote/quote_state.dart' show thresholdsProvider;
import 'order_screen.dart' show orderProvider;

/// The Malaysian identifier kinds MyInvois recognises.
///
/// A fixed list rather than free text: a number filed under a type nobody
/// recognises is a rejected submission weeks later. §13 **C13** asks the
/// accountant which of these MyInvois actually requires; the wire values are
/// what the column stores and must not drift.
const _idTypes = ['nric', 'brn', 'passport', 'army'];

String _idTypeLabel(L l, String wire) => switch (wire) {
  'nric' => l.buyerIdTypeNric,
  'brn' => l.buyerIdTypeBrn,
  'passport' => l.buyerIdTypePassport,
  _ => l.buyerIdTypeArmy,
};

/// What is still outstanding, in words. One line per missing thing.
String buyerMissingMessage(L l, BuyerDetailsMissing missing) =>
    switch (missing) {
      BuyerDetailsMissing.name => l.buyerMissingName,
      BuyerDetailsMissing.identifier => l.buyerMissingIdentifier,
      BuyerDetailsMissing.address => l.buyerMissingAddress,
    };

class BuyerDetailsScreen extends ConsumerStatefulWidget {
  const BuyerDetailsScreen({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<BuyerDetailsScreen> createState() => _BuyerDetailsScreenState();
}

class _BuyerDetailsScreenState extends ConsumerState<BuyerDetailsScreen> {
  final _controllers = <String, TextEditingController>{};
  String? _idType;
  bool _requested = false;
  bool _loaded = false;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _c(String key, String? initial) =>
      _controllers.putIfAbsent(key, () => TextEditingController(text: initial));

  /// Reads the form back as the rule wants it.
  ///
  /// Straight off the controllers rather than from anything cached, so what is
  /// shown as missing is what is actually typed. `missingBuyerDetails` trims,
  /// so a field holding a single space still reads as absent — which is the
  /// point: a space must not satisfy a legal requirement.
  BuyerDetails get _entered => BuyerDetails(
    name: _controllers['name']?.text,
    tin: _controllers['tin']?.text,
    idType: _idType,
    idNumber: _controllers['idNumber']?.text,
    addressLine1: _controllers['address1']?.text,
    addressLine2: _controllers['address2']?.text,
    city: _controllers['city']?.text,
    state: _controllers['state']?.text,
    postcode: _controllers['postcode']?.text,
  );

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final order = ref.watch(orderProvider(widget.orderId));

    return Scaffold(
      appBar: AppBar(title: Text(l.buyerTitle)),
      body: switch (order) {
        AsyncData(value: final o) => _form(context, l, o),
        AsyncError(error: final e) => Center(child: Text('$e')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _form(BuildContext context, L l, OrderRow order) {
    // Seeded once. Rebuilding the controllers on every frame would move the
    // cursor to the start of whichever field somebody is typing into.
    if (!_loaded) {
      _idType = order.buyerIdType;
      _requested = order.einvoiceRequested;
      _loaded = true;
    }

    final missing = missingBuyerDetails(_entered);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _why(l, order),
        const SizedBox(height: 16),
        _stillNeeded(l, missing),
        const SizedBox(height: 20),

        TextField(
          controller: _c('name', order.customerName),
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: l.buyerName,
            helperText: l.buyerNameHint,
            helperMaxLines: 2,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),

        Text(l.buyerIdentifierSection, style: AppText.title),
        const SizedBox(height: 4),
        Text(l.buyerIdentifierNote, style: AppText.caption),
        const SizedBox(height: 12),
        TextField(
          controller: _c('tin', order.buyerTin),
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: l.buyerTin),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          initialValue: _idType,
          decoration: InputDecoration(labelText: l.buyerIdType),
          items: [
            const DropdownMenuItem<String?>(child: Text('—')),
            for (final type in _idTypes)
              DropdownMenuItem<String?>(
                value: type,
                child: Text(_idTypeLabel(l, type)),
              ),
          ],
          onChanged: (value) => setState(() => _idType = value),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _c('idNumber', order.buyerIdNumber),
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: l.buyerIdNumber),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),

        Text(l.buyerAddressSection, style: AppText.title),
        const SizedBox(height: 12),
        TextField(
          controller: _c('address1', order.buyerAddressLine1),
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: l.buyerAddress1),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _c('address2', order.buyerAddressLine2),
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: l.buyerAddress2),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _c('postcode', order.buyerPostcode),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l.buyerPostcode),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _c('city', order.buyerCity),
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: l.buyerCity),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _c('state', order.buyerState),
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: l.buyerState),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),

        TextField(
          controller: _c('msic', order.buyerMsicCode),
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l.buyerMsic,
            helperText: l.buyerMsicNote,
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _requested,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(l.buyerRequested, style: AppText.body),
          onChanged: (value) => setState(() => _requested = value ?? false),
        ),
        const SizedBox(height: 16),

        // Saving is never gated on completeness. Half the details now beats
        // nothing at all: the customer is standing there, and what is captured
        // is captured. `advanceOrder` is what refuses to move an incomplete
        // order, and it is the only thing that should.
        FilledButton(
          onPressed: () => _save(context, l),
          child: Text(l.buyerSave),
        ),
        const SizedBox(height: 12),
        Text(l.buyerNotAnInvoice, style: AppText.caption),
      ],
    );
  }

  /// Why this is being asked, named with the amount that triggered it.
  ///
  /// Three different reasons, and they are not interchangeable. "Over the
  /// threshold" is a legal requirement now; "near it" is a warning that it will
  /// become one after measurement, when the customer has gone home; "the
  /// customer asked" applies at any amount.
  Widget _why(L l, OrderRow order) {
    final config = ref.watch(thresholdsProvider);
    final total = Money.sen(order.finalTotalSen ?? order.estimateTotalSen);

    final check = checkThreshold(
      total: total,
      // The estimate stage is the one with the RM8,000 margin, so an order
      // still on its quoted figure gets the earlier warning. Once a final
      // exists the check is exact and the margin does not apply.
      stage: order.finalTotalSen == null
          ? ThresholdStage.estimate
          : ThresholdStage.finalPricing,
      config: config,
      einvoiceRequested: order.einvoiceRequested,
    );

    final (text, colour, surface) = switch (check.reason) {
      ThresholdReason.overThreshold => (
        l.buyerWhyOverThreshold(config.threshold.format()),
        AppColors.alarm,
        AppColors.alarmSurface,
      ),
      ThresholdReason.nearThreshold => (
        l.buyerWhyNearThreshold(config.threshold.format()),
        AppColors.warning,
        AppColors.warningSurface,
      ),
      ThresholdReason.einvoiceRequested => (
        l.buyerWhyRequested,
        AppColors.foreground,
        AppColors.muted,
      ),
      // Nothing requires this order's details. Somebody opened the screen
      // anyway, which is allowed — an office taking details early is not a
      // problem — so it explains what the form is for and asks for nothing.
      null => (l.buyerNotAnInvoice, AppColors.mutedForeground, AppColors.muted),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: AppText.body.copyWith(color: colour)),
    );
  }

  /// Everything outstanding, at once. Never one field at a time.
  Widget _stillNeeded(L l, List<BuyerDetailsMissing> missing) {
    if (missing.isEmpty) {
      return Row(
        children: [
          const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(l.buyerComplete, style: AppText.bodyStrong)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.buyerStillNeeded, style: AppText.label),
        const SizedBox(height: 4),
        for (final item in missing)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '• ${buyerMissingMessage(l, item)}',
              style: AppText.body,
            ),
          ),
      ],
    );
  }

  Future<void> _save(BuildContext context, L l) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    await ref
        .read(orderRepositoryProvider)
        .recordBuyerDetails(
          orderId: widget.orderId,
          name: _controllers['name']?.text,
          tin: _controllers['tin']?.text,
          // Cleared to an empty string rather than left absent when nobody
          // picked a type, so removing a wrong one actually removes it. The
          // repository trims empties to null.
          idType: _idType ?? '',
          idNumber: _controllers['idNumber']?.text,
          addressLine1: _controllers['address1']?.text,
          addressLine2: _controllers['address2']?.text,
          city: _controllers['city']?.text,
          state: _controllers['state']?.text,
          postcode: _controllers['postcode']?.text,
          msicCode: _controllers['msic']?.text,
          einvoiceRequested: _requested,
        );

    ref.invalidate(orderProvider(widget.orderId));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.buyerSaved)));
    navigator.pop(true);
  }
}
