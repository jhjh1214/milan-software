/// Turning a stored order into what the server expects.
///
/// Field names match the columns on both sides exactly — `*_tmm`, `*_sen` — so
/// there is no translation layer to get wrong. A rename here that is not
/// mirrored in `backend/app/api/schemas.py` is a 422 the device cannot recover
/// from, so the two are deliberately boring and identical.
///
/// ## What is deliberately not sent
///
/// **No `order_no`.** Like a receipt number it is issued by the server, and a
/// device that sent one would be inventing something that goes on a document
/// the customer takes away. There is no field for it here, so no screen can
/// start filling one in.
///
/// **No `confirmed_by_user_id`.** The server takes that from the session that
/// pushed it. A device must not be able to claim the sale was somebody else's.
///
/// ## Two payloads, not one
///
/// An order is pushed once, at confirmation. Every step it takes afterwards is
/// its own small push keyed on the event id, because an order walks the
/// pipeline many times and re-sending the whole thing for each step would make
/// the second legitimate move look like a retry of the first.
library;

import '../core/money.dart';
import '../data/database.dart';

/// Builds the request body for `POST /api/orders`.
///
/// [events] and [overrides] go up with it: they are what happened *before* the
/// first successful sync, which at a fair may be a whole day's work.
Map<String, dynamic> orderPayload({
  required OrderRow order,
  required List<OrderLineRow> lines,
  required List<OrderEventRow> events,
  required List<PriceOverrideRow> overrides,
  String? deviceId,
}) => {
  'id': order.id,
  'quote_id': order.quoteId,
  'channel': order.channel,
  'pinned_rate_card_version': order.pinnedRateCardVersion,
  'customer_name': order.customerName,
  'customer_phone': order.customerPhone,
  'delivery_zone_id': order.deliveryZoneId,
  'delivery_charge_sen': order.deliveryChargeSen,
  'status': order.status,
  'estimate_total_sen': order.estimateTotalSen,
  'deposit_paid_sen': order.depositPaidSen,
  'has_unmeasured_lines': order.hasUnmeasuredLines,
  // UTC on the wire, displayed Asia/Kuala_Lumpur. An order confirmed at 11pm
  // on the last night of a fair must not become the next month in transit —
  // the order number is issued from this date.
  'confirmed_at': order.confirmedAt.toUtc().toIso8601String(),
  'device_id': deviceId,
  'lines': [
    for (final l in lines)
      {
        'id': l.id,
        'quote_line_id': l.quoteLineId,
        'sort_order': l.sortOrder,
        'room': l.room,
        'variant': l.variant,
        'material_key': l.materialKey,
        'layer': l.layer,
        'parent_line_id': l.parentLineId,
        'est_width_tmm': l.estWidthTmm,
        'est_height_tmm': l.estHeightTmm,
        'final_width_tmm': l.finalWidthTmm,
        'final_height_tmm': l.finalHeightTmm,
        'is_site_measured': l.isSiteMeasured,
        'quantity': l.quantity,
        'category_lock_id': l.categoryLockId,
        // The snapshot that keeps the number explainable a year later, after
        // the card has been superseded twice.
        'applied_rule_id': l.appliedRuleId,
        'applied_band_label': l.appliedBandLabel,
        'applied_rate_card_version': l.appliedRateCardVersion,
        'applied_discount_pct': l.appliedDiscountPct,
        'standard_rate_sen': l.standardRateSen,
        'rate_sen': l.rateSen,
        'billed_qty': l.billedQty,
        'billed_unit': l.billedUnit,
        'line_total_sen': l.lineTotalSen,
        'material_deferred': l.materialDeferred,
        'is_overridden': l.isOverridden,
      },
  ],
  'events': [
    for (final e in events)
      {
        'id': e.id,
        'event': e.event,
        'note': e.note,
        'at': e.at.toUtc().toIso8601String(),
      },
  ],
  'overrides': [
    for (final o in overrides)
      {
        'id': o.id,
        'order_line_id': o.orderLineId,
        'before_sen': o.beforeSen,
        'after_sen': o.afterSen,
        'reason': o.reason,
        'admin_user_id': o.adminUserId,
        'device_id': o.deviceId,
        'at': o.at.toUtc().toIso8601String(),
      },
  ],
};

/// Builds the request body for `POST /api/orders/status`.
///
/// Keyed on the **event id**, which is the row the move already wrote locally.
/// That is what makes a retry harmless without blocking the next step.
Map<String, dynamic> statusChangePayload({
  required String orderId,
  required OrderEventRow event,
}) => {
  'order_id': orderId,
  'event_id': event.id,
  'to': event.event,
  // The cancellation reason is stored as the event's note, so it travels with
  // the move rather than in a field of its own. §13 B3 will be settled from
  // these rows.
  'reason': event.note,
  'at': event.at.toUtc().toIso8601String(),
};

/// Builds the request body for `POST /api/orders/buyer`. §10.3.
///
/// Its own payload rather than fields on [orderPayload], because an order goes
/// up **once at confirmation** and these are captured after measurement — by
/// which point that body was sent days ago.
///
/// Every field is sent, including the ones that are null. Null on the wire is
/// "leave what is there" and the server merges on that basis, so a handset
/// that only knows half the record cannot blank the half another one captured
/// — the measurer takes the TIN at the house, somebody else adds the address,
/// and both survive.
///
/// **What this cannot do is clear a field on the server.** The device stores a
/// blank as null and null on the wire means "leave it", so a wrong IC number
/// removed on the handset stays on the server. That is the deliberate choice
/// between two imperfect ones: merging fails toward keeping too much, and
/// replacing fails toward losing what a colleague collected. §10.2's penalty
/// is for **missing** details, not for spare ones.
///
/// Recorded as §13 **C14**, because the real fix is a distinguishable "cleared"
/// signal or an office write path, and neither should be guessed at here.
Map<String, dynamic> buyerDetailsPayload({
  required OrderRow order,
  required DateTime capturedAt,
}) => {
  'order_id': order.id,
  // UTC on the wire, displayed Asia/Kuala_Lumpur. This is the only ordering
  // signal the server has when several handsets can capture for one order
  // offline, so a local time here would make a correction look stale.
  'captured_at': capturedAt.toUtc().toIso8601String(),
  'name': order.customerName,
  'tin': order.buyerTin,
  'id_type': order.buyerIdType,
  'id_number': order.buyerIdNumber,
  'address_line1': order.buyerAddressLine1,
  'address_line2': order.buyerAddressLine2,
  'city': order.buyerCity,
  'state': order.buyerState,
  'postcode': order.buyerPostcode,
  'msic_code': order.buyerMsicCode,
  'einvoice_requested': order.einvoiceRequested,
};

/// Builds the request body for `POST /api/orders/measurement`.
///
/// Its own push, for the same reason buyer details get one: an order is
/// pushed **once at confirmation**, before the site visit happens. Without
/// this the server's `is_site_measured` never leaves the `False` it was
/// pushed with, and `advance_order_status`'s `measured` guard refuses every
/// order forever regardless of what is actually done in the field.
///
/// [deviceFinalTotal] is this line's own freshly-repriced total, carried only
/// so the server can compare and log a disagreement (hard rule 4) rather than
/// silently trust either number — never stored back from it.
Map<String, dynamic> measurementPayload({
  required String orderId,
  required OrderLineRow line,
  required DateTime measuredAt,
  Money? deviceFinalTotal,
}) => {
  'order_id': orderId,
  'line_id': line.id,
  // UTC on the wire. The only ordering signal the server has when a line can
  // be remeasured, or two handsets race on the same order offline.
  'measured_at': measuredAt.toUtc().toIso8601String(),
  'final_width_tmm': line.finalWidthTmm,
  'final_height_tmm': line.finalHeightTmm,
  'material_key': line.materialKey,
  'device_final_total_sen': deviceFinalTotal?.sen,
};
