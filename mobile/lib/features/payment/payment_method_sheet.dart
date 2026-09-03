/// How the money came in. SPEC.md §6.4.
///
/// Asked every time, and it cannot be skipped: the daily cash-up is
/// expected-versus-held **per method**, and a payment with no method cannot be
/// reconciled against anything at the end of the day.
///
/// Cash first, because at a fair most of it is cash and the list should not
/// make the common case the longest reach.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/payment_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/cash_up.dart';
import '../../ui/theme.dart';
import '../quote/quote_state.dart';

final paymentRepositoryProvider = Provider<PaymentRepository>(
  (ref) => PaymentRepository(ref.watch(databaseProvider)),
);

/// Asks how a payment was made. Null if the person backs out.
///
/// Backing out is a real answer: the customer changed their mind at the till,
/// and nothing should be recorded.
Future<PaymentMethod?> askForPaymentMethod(BuildContext context) =>
    showModalBottomSheet<PaymentMethod>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => const _MethodSheet(),
    );

String paymentMethodLabel(L l, PaymentMethod method) => switch (method) {
  PaymentMethod.cash => l.methodCash,
  PaymentMethod.cardTerminal => l.methodCard,
  PaymentMethod.duitnow => l.methodDuitnow,
  PaymentMethod.bankTransfer => l.methodTransfer,
  PaymentMethod.cheque => l.methodCheque,
};

class _MethodSheet extends StatelessWidget {
  const _MethodSheet();

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    // Scrollable, because five 56px buttons plus a title do not fit inside a
    // bottom sheet's default height on a short phone, or on any phone in
    // landscape. A sheet that overflows hides the last method, and the last
    // method is the one somebody eventually needs.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.paymentMethodTitle, style: AppText.title),
            const SizedBox(height: Space.lg),
            for (final method in PaymentMethod.values)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: SizedBox(
                  width: double.infinity,
                  height: Touch.primary,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(method),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(paymentMethodLabel(l, method)),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: Space.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l.cancel),
            ),
          ],
        ),
      ),
    );
  }
}
