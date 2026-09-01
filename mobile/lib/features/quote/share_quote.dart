/// Renders the quotation and hands it to whatever the phone can share with.
///
/// SPEC.md §9 and the Phase 2 acceptance criteria: this must work with the
/// phone in airplane mode. The font is a bundled asset, the layout is computed
/// on device, and the file is written to local temp — nothing here needs a
/// network.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/unit_labels.dart';
import 'quote_pdf.dart';
import 'quote_state.dart';

/// Builds the PDF and opens the system share sheet.
Future<void> shareQuotePdf(BuildContext context, WidgetRef ref) async {
  final l = L.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final priced = ref.read(pricedQuoteProvider).valueOrNull;
  final quote = ref.read(quoteProvider).valueOrNull;
  if (priced == null || quote == null || priced.lines.isEmpty) return;

  final language = ref.read(languageProvider);
  final today = ref.read(todayProvider);

  try {
    final fonts = await QuoteFonts.load();
    final bytes = await buildQuotePdf(
      data: QuoteDocumentData(
        priced: priced,
        // A short, human-readable reference. A real order number arrives with
        // Phase 4, where it is {branch}-{yymm}-{seq} and client-generated.
        quoteNumber: quote.quoteId.substring(0, 8).toUpperCase(),
        date: today,
        customerName: quote.customerName,
        customerPhone: quote.customerPhone,
        language: language,
      ),
      fonts: fonts,
      l: l,
      billedUnit: (basis) => billedUnitLabel(l, basis),
    );

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/quote-${quote.quoteId.substring(0, 8)}.pdf');
    await file.writeAsBytes(bytes, flush: true);

    await Share.shareXFiles([
      XFile(file.path, mimeType: 'application/pdf'),
    ], subject: l.pdfTitle);
  } catch (e) {
    // A failed share must not take the quote down with it. The part-timer can
    // keep working and try again.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$e')));
  }
}
