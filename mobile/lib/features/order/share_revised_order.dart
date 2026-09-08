/// Renders the revised order document and hands it to whatever the phone can
/// share with.
///
/// SPEC.md §11 Phase 6. The measurer is standing in a house, often with no
/// signal — the font is a bundled asset, the layout is computed on device, and
/// the file is written to local temp. Nothing here needs a network.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/money.dart';
import '../../data/database.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/final_pricing.dart';
import '../measure/measure_screen.dart' show orderPricingProvider;
// The same formatter the measurer reads on screen, so the size on the paper
// and the size in their hand are produced by one function rather than two that
// agree today. It sits in a widget file for now; `core/formatters` is where it
// belongs, and moving it is a refactor of its own.
import '../measure/measure_sheet.dart' show displayLength;
import '../quote/quote_pdf.dart' show QuoteFonts;
import '../quote/quote_state.dart' show languageProvider;
import 'order_screen.dart' show orderLinesProvider, orderProvider;
import 'revised_order_pdf.dart';

/// Assembles the document's rows from the order and its pricing.
///
/// Pure, and separate from the sharing so it can be tested without a share
/// sheet. Returns null for exactly the reasons [RevisedOrderData.of] does: an
/// order that has not fully priced has no document.
///
/// The rows follow the ORDER's line order, not the pricing's, so what the
/// customer reads matches what the measurer worked down. They are the same
/// list today; relying on that silently is how they stop being the same list.
RevisedOrderData? revisedOrderDataFor({
  required OrderRow order,
  required List<OrderLineRow> lines,
  required FinalPricing pricing,
  required String language,
  required DateTime fallbackMeasuredOn,
  required L l,
}) {
  final byId = {for (final priced in pricing.lines) priced.id: priced};

  final rows = <RevisedOrderLine>[];
  for (final line in lines) {
    final priced = byId[line.id];
    if (priced == null) return null;
    rows.add(
      RevisedOrderLine(
        line: priced,
        room: line.room,
        // The rule's own label, in the reader's language. `line.variant` is a
        // key -- printing "night_curtain" on a customer's paper is worse than
        // printing nothing, because it looks like the system is broken.
        product: priced.priced?.rule.labels(language) ?? line.variant,
        // §13 A25: a per_roll line quoted at the fair can carry no height at
        // all -- the wall was never asked for, so there is no size to print
        // on the "quoted" side.
        quotedSize: line.estHeightTmm == null
            ? l.wallpaperUnmeasured
            : _size(line.estWidthTmm, line.estHeightTmm),
        measuredSize: _size(line.finalWidthTmm, line.finalHeightTmm),
        isUpgrade: line.parentLineId != null,
      ),
    );
  }

  // The latest tape on the order. An order measured over two visits is dated
  // by the one that finished it, which is what the customer was there for.
  final measured = lines
      .map((l) => l.measuredAt)
      .whereType<DateTime>()
      .fold<DateTime?>(
        null,
        (latest, at) => latest == null || at.isAfter(latest) ? at : latest,
      );

  return RevisedOrderData.of(
    pricing: pricing,
    lines: rows,
    orderNo: order.orderNo,
    quotedOn: order.confirmedAt,
    measuredOn: measured ?? fallbackMeasuredOn,
    depositPaid: Money.sen(order.depositPaidSen),
    pinnedRateCardVersion: order.pinnedRateCardVersion,
    language: language,
    customerName: order.customerName,
    customerPhone: order.customerPhone,
  );
}

String _size(int? widthTmm, int? heightTmm) {
  if (widthTmm == null) return '—';
  final width = displayLength(widthTmm);
  return heightTmm == null ? width : '$width × ${displayLength(heightTmm)}';
}

/// Builds the document and opens the system share sheet.
///
/// Does nothing when the order has not fully priced. The screen's own button is
/// disabled in that case and says why; this is the second guard, because a
/// document is the one artefact that leaves the building.
Future<void> shareRevisedOrder(
  BuildContext context,
  WidgetRef ref,
  String orderId,
) async {
  final l = L.of(context);
  final messenger = ScaffoldMessenger.of(context);

  final order = ref.read(orderProvider(orderId)).valueOrNull;
  final lines = ref.read(orderLinesProvider(orderId)).valueOrNull;
  final pricing = ref.read(orderPricingProvider(orderId)).valueOrNull;
  if (order == null || lines == null || pricing == null) return;

  final data = revisedOrderDataFor(
    order: order,
    lines: lines,
    pricing: pricing,
    language: ref.read(languageProvider),
    fallbackMeasuredOn: DateTime.now(),
    l: l,
  );
  if (data == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l.revisedIncomplete(pricing.outstanding.length)),
        ),
      );
    return;
  }

  try {
    final bytes = await buildRevisedOrderPdf(
      data: data,
      fonts: await QuoteFonts.load(),
      l: l,
    );

    final dir = await getTemporaryDirectory();
    final name = order.orderNo ?? order.id.substring(0, 8);
    final file = File('${dir.path}/order-$name.pdf');
    await file.writeAsBytes(bytes, flush: true);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf')],
        subject: l.revisedTitle,
      ),
    );
  } catch (e) {
    // A failed share must not take the measurement down with it. The tape is
    // already in the database; they can try again from the order screen.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$e')));
  }
}
