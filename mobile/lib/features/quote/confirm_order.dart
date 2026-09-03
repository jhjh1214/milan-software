/// The moment a quote becomes a sale. SPEC.md §6.3, §3.
///
/// > customer pays RM300 minimum deposit PER PRODUCT CATEGORY
/// > → ORDER IS CONFIRMED. Not a quote, not a lead. A confirmed sale.
///
/// So this runs when money is taken, and nowhere else. There is no "confirm"
/// button, because pressing one without a deposit would create an order the
/// business does not recognise.
///
/// The quote is kept exactly as it was. Client, Sep 2026: *"the quote should be
/// recorded as reference to the order, so have rough estimate of what to do."*
library;

import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;

import '../../core/money.dart';
import '../../data/order_repository.dart';
import '../../data/quote_repository.dart' show newId;
import '../../pricing/conversion.dart';
import '../../pricing/models.dart';
import '../../pricing/rate_lock.dart';
import '../payment/payment_method_sheet.dart';
import 'deposit_prompt_sheet.dart' show lockRepositoryProvider;
import 'quote_state.dart';

final orderRepositoryProvider = Provider<OrderRepository>(
  (ref) => OrderRepository(ref.watch(databaseProvider)),
);

/// The order confirmed from the quote on screen, if there is one yet.
final currentOrderProvider = FutureProvider((ref) async {
  final quote = await ref.watch(quoteProvider.future);
  return ref.watch(orderRepositoryProvider).forQuote(quote.quoteId);
});

/// Confirms the current quote as an order, or adds to the one already
/// confirmed from it.
///
/// Returns why it could not, or null when it did. A refusal is not an error to
/// throw at somebody mid-fair — the money is already recorded either way, and
/// the deposit is what the customer came to pay.
Future<ConversionRefusal?> confirmOrderForDeposit(
  WidgetRef ref, {
  required Money depositJustTaken,
  required DateTime at,
}) async {
  final quote = await ref.read(quoteProvider.future);
  final orders = ref.read(orderRepositoryProvider);

  // One quote confirms once. A second RM300 on the same quote is a second
  // category, not a second order.
  final existing = await orders.forQuote(quote.quoteId);
  if (existing != null) {
    await orders.recordFurtherPayment(
      orderId: existing.id,
      amount: depositJustTaken,
      at: at,
    );
    ref.invalidate(currentOrderProvider);
    return null;
  }

  final priced = ref.read(pricedQuoteProvider).valueOrNull;
  final card = await ref.read(rateCardProvider.future);
  if (priced == null) return ConversionRefusal.noLines;

  // Everything taken against this quote so far, not just the payment that
  // triggered this. Two categories deposited back to back at one stall is a
  // normal afternoon.
  final payments = await ref
      .read(paymentRepositoryProvider)
      .forQuote(quote.quoteId);
  final paid = Money.sen(payments.fold(0, (sum, p) => sum + p.amountSen));

  final locks = await ref.read(lockRepositoryProvider).locksFor(quote.quoteId);

  final result = confirmQuoteAsOrder(
    orderId: newId(),
    quoteId: quote.quoteId,
    channel: quote.channel,
    pinnedRateCardVersion: card.version,
    estimateTotal: priced.totals.total,
    depositPaid: paid,
    at: at,
    newLineId: newId,
    customerName: quote.customerName,
    customerPhone: quote.customerPhone,
    deliveryZoneId: quote.deliveryZoneId,
    deliveryCharge: priced.totals.deliveryCharge,
    lines: [
      for (final line in priced.lines)
        ConvertibleLine(
          id: line.line.id,
          sortOrder: priced.lines.indexOf(line),
          room: line.line.room,
          layer: line.line.layer.wire,
          parentLineId: line.line.parentLineId,
          width: line.line.width,
          height: line.line.height,
          priced: line.priced,
          // The same resolver the pricing side uses, so an order can never
          // record a basis the quote was not priced on.
          basis: resolveRateBasis(
            family: card.ruleFor(line.line.variant)!.family,
            depositCategoryOverride: card
                .ruleFor(line.line.variant)
                ?.depositCategoryOverride,
            parentFamily: _parentFamilyOf(line.line, priced, card),
            locks: locks,
            channel: quote.channel,
            currentRateCardVersion: card.version,
            currentPromoPct: card.promoDiscountPct,
            orderPinnedRateCardVersion: card.version,
            today: at,
          ),
        ),
    ],
  );

  if (result.order case final order?) {
    await orders.store(order);
    ref.invalidate(currentOrderProvider);
    return null;
  }
  return result.refusedBecause;
}

/// The family of the line an add-on hangs off, so it takes its parent's
/// deposit category rather than defaulting to one of its own.
Family? _parentFamilyOf(QuoteLine line, PricedQuote priced, RateCard card) {
  if (line.parentLineId == null) return null;
  for (final other in priced.lines) {
    if (other.line.id == line.parentLineId) {
      return card.ruleFor(other.line.variant)?.family;
    }
  }
  return null;
}
