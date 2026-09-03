/// Turning a stored quote into what the server expects.
///
/// Field names match the columns on both sides exactly — `*_tmm`, `*_sen` —
/// so there is no translation layer to get wrong. A rename here that is not
/// mirrored in `backend/app/api/schemas.py` is a 422 the device cannot recover
/// from, so the two are deliberately boring and identical.
///
/// What is sent is **what was entered**, not what was computed. The server
/// re-prices every line from the dimensions (§9.4), and can only do that if it
/// receives the inputs. The device's own totals go up alongside, so the two can
/// be compared rather than one silently overwriting the other.
library;

import '../data/database.dart';

/// Builds the request body for `POST /api/quotes`.
///
/// [deviceTotalSen] and [lineTotalsSen] are the device's figures. They are
/// passed in rather than recomputed here because the engine is pure and lives
/// somewhere else — this file knows about JSON, not about prices.
Map<String, dynamic> quotePayload({
  required QuoteRow quote,
  required List<QuoteLineRow> lines,
  required int? deviceTotalSen,
  required Map<String, int> lineTotalsSen,
  String? deviceId,
}) => {
  'id': quote.id,
  'rate_card_version': quote.rateCardVersion,
  'tier': quote.tier,
  'language': quote.language,
  'customer_name': quote.customerName,
  'customer_phone': quote.customerPhone,
  'delivery_zone_id': quote.deliveryZoneId,
  'device_total_sen': deviceTotalSen,
  // UTC on the wire, displayed Asia/Kuala_Lumpur. A quote taken at 11pm on the
  // last day of a promo must not become the next day in transit.
  'created_at': quote.createdAt.toUtc().toIso8601String(),
  'updated_at': quote.updatedAt.toUtc().toIso8601String(),
  'device_id': deviceId,
  'lines': [
    for (final line in lines)
      {
        'id': line.id,
        'sort_order': line.sortOrder,
        'room': line.room,
        'variant': line.variant,
        'material_key': line.materialKey,
        'layer': line.layer,
        'parent_line_id': line.parentLineId,
        'width_tmm': line.widthTmm,
        'height_tmm': line.heightTmm,
        'raw_width': line.rawWidth,
        'raw_height': line.rawHeight,
        'quantity': line.quantity,
        'device_total_sen': lineTotalsSen[line.id],
      },
  ],
};
