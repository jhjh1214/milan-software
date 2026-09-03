/// Turning a stored hold, and a stored prompt answer, into what the server
/// expects.
///
/// Field names match the columns on both sides exactly, so there is no
/// translation layer to get wrong. A rename here that is not mirrored in
/// `backend/app/api/schemas.py` is a 422 the device cannot recover from.
///
/// ## Why a hold has to go up at all
///
/// It prices the customer's next visit, and that visit may be to a different
/// handset. Six phones work a fair: the customer deposits on phone 3 and walks
/// into the showroom in March where phone 1 is used. A hold that never left
/// phone 3 is a hold that customer paid RM300 for and cannot use.
library;

import '../data/database.dart';

/// Builds the request body for `POST /api/locks`.
Map<String, dynamic> lockPayload({
  required CategoryLockRow lock,
  String? deviceId,
}) => {
  'id': lock.id,
  // Whose hold it is. A normalised phone, or `quote:<id>` when the customer
  // gave no usable number — see `pricing/customer_key.dart` and §13 B9.
  'customer_key': lock.customerId,
  'category': lock.category,
  'deposit_payment_id': lock.depositPaymentId,
  // Both pinned. Sending only the version would let the server reprice this
  // customer when the promo percentage moves.
  'held_rate_card_version': lock.heldRateCardVersion,
  'held_discount_pct': lock.heldDiscountPct,
  'held_until': lock.heldUntil.toUtc().toIso8601String(),
  'status': lock.status,
  // The device calls it createdAt; the server calls it opened_at, because
  // what it records is the moment the RM300 changed hands.
  'opened_at': lock.createdAt.toUtc().toIso8601String(),
  'device_id': deviceId,
};

/// Builds the request body for `POST /api/deposit-prompts`.
///
/// The declined-deposit report only tells the boss what fairs are leaving on
/// the table if a decline reaches the server as reliably as a sale does.
Map<String, dynamic> depositPromptPayload({
  required DepositPromptRow prompt,
  String? deviceId,
}) => {
  'id': prompt.id,
  'quote_id': prompt.quoteId,
  'category': prompt.category,
  'choice': prompt.choice,
  // What the category was worth when the question was asked. Without it the
  // report can only say how often somebody said no, not what it cost.
  'category_subtotal_sen': prompt.categorySubtotalSen,
  'at': prompt.at.toUtc().toIso8601String(),
  'device_id': deviceId,
};
