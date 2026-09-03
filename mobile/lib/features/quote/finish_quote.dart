/// Queueing a finished quote for the office. §9.2.
///
/// "Finished" means the customer has been given the number — the moment the
/// PDF is shared. Before that a quote is a draft on somebody's phone and the
/// office has no use for it; after it, it is a price a customer is holding, and
/// the office needs to know it exists whether or not the deposit follows.
///
/// This never blocks and never fails visibly. It writes a row to the outbox and
/// returns; the row goes up on the next connection, which at a fair might be
/// that evening in the car.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sync/quote_payload.dart';
import '../../sync/sync_state.dart';
import 'quote_state.dart';

/// Puts the current quote on the outbox, with the totals the customer was
/// shown.
///
/// The device's own figures go up alongside the inputs so the server can
/// re-price and **compare** rather than take the device's word for it (§9.4).
Future<void> queueQuoteForOffice(WidgetRef ref) async {
  final priced = ref.read(pricedQuoteProvider).valueOrNull;
  final quote = ref.read(quoteProvider).valueOrNull;
  if (priced == null || quote == null || priced.lines.isEmpty) return;

  final db = ref.read(databaseProvider);
  final row = await (db.select(
    db.quotes,
  )..where((q) => q.id.equals(quote.quoteId))).getSingleOrNull();
  if (row == null) return;

  await ref
      .read(outboxerProvider)
      .enqueueQuote(
        quote.quoteId,
        quotePayload(
          quote: row,
          lines: await db.linesFor(quote.quoteId),
          deviceTotalSen: priced.totals.total.sen,
          lineTotalsSen: {
            // Lines the engine could not price are left out rather than sent
            // as zero. A zero would look like agreement with a server that
            // priced them properly, and the discrepancy report is the only
            // place that drift is ever noticed.
            for (final p in priced.lines)
              if (p.priced case final priced?) p.line.id: priced.total.sen,
          },
          deviceId: await ref.read(deviceIdProvider.future),
        ),
      );

  // The other place the queue moves. Without this the badge in the app bar
  // would not tick over until the next sync, and a part-timer would have no
  // sign the quote was kept.
  ref.invalidate(outboxDepthProvider);
}
