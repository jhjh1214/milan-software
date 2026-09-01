/// Builds the quotation PDF, on the device.
///
/// SPEC.md §9 and the Phase 2 acceptance criteria: the PDF must reach WhatsApp
/// with the phone in airplane mode. Nothing here touches the network — the font
/// is a bundled asset and the layout is computed locally.
///
/// ## The legal constraint
///
/// CLAUDE.md hard rule 7 and SPEC.md §10.1: **nothing this system prints may
/// say "Tax Invoice" or "e-Invoice", or display a UIN or validation QR.** SQL
/// Account is the sole issuer of record. This document says in the reader's own
/// language that it is a quotation and not a tax invoice, and a CI check greps
/// for the forbidden words.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import 'quote_state.dart';

/// Everything the document needs, so building it stays a pure function of its
/// input and can be tested without a screen.
class QuoteDocumentData {
  final PricedQuote priced;
  final String quoteNumber;
  final DateTime date;
  final String? customerName;
  final String? customerPhone;
  final String language;

  const QuoteDocumentData({
    required this.priced,
    required this.quoteNumber,
    required this.date,
    required this.language,
    this.customerName,
    this.customerPhone,
  });
}

/// Loads the embedded CJK face once and keeps it.
///
/// Parsing a 2.2MB font on every share would stall the UI thread on a low-end
/// phone, and §12 budgets 16ms a frame.
class QuoteFonts {
  final pw.Font regular;
  final pw.Font bold;

  const QuoteFonts({required this.regular, required this.bold});

  static QuoteFonts? _cached;

  static Future<QuoteFonts> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    final data = await rootBundle.load('assets/fonts/NotoSansSC-Subset.ttf');
    final font = pw.Font.ttf(data);
    // One weight is bundled. Using it for both roles keeps 2.2MB rather than
    // 4.4MB; emphasis comes from size and colour instead.
    return _cached = QuoteFonts(regular: font, bold: font);
  }
}

/// Renders the quotation.
Future<Uint8List> buildQuotePdf({
  required QuoteDocumentData data,
  required QuoteFonts fonts,
  required L l,
  required String Function(PriceBasis) billedUnit,
  // Object streams are compressed by default, which makes the file smaller and
  // its text unreadable to a grep. Tests turn compression off so the assertion
  // that nothing says "Tax Invoice" inspects the real rendered content rather
  // than passing against a compressed blob — hard rule 7 is a legal
  // constraint, and a test that cannot see the text is worse than none.
  bool compress = true,
}) async {
  final theme = pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold)
      .copyWith(
        defaultTextStyle: pw.TextStyle(font: fonts.regular, fontSize: 9.5),
      );

  final doc = pw.Document(
    title: l.pdfTitle,
    author: l.pdfCompany,
    theme: theme,
    compress: compress,
  );

  final parents = data.priced.lines
      .where((p) => !p.line.isUpgrade)
      .toList(growable: false);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 44),
      header: (context) =>
          context.pageNumber == 1 ? _header(l, data) : pw.SizedBox(),
      footer: (context) => _footer(l, context),
      build: (context) => [
        _customerBlock(l, data),
        pw.SizedBox(height: 14),
        _lineTable(l, data, parents, billedUnit),
        pw.SizedBox(height: 10),
        _totals(l, data),
        pw.SizedBox(height: 16),
        _disclaimer(l),
      ],
    ),
  );

  return doc.save();
}

pw.Widget _header(L l, QuoteDocumentData data) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              l.pdfCompany,
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blueGrey900,
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              l.pdfTitle,
              style: const pw.TextStyle(
                fontSize: 11,
                color: PdfColors.blueGrey600,
              ),
            ),
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              '${l.pdfQuoteNo}: ${data.quoteNumber}',
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              '${l.pdfDate}: ${formatDate(data.date)}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ],
        ),
      ],
    ),
    pw.SizedBox(height: 8),
    pw.Divider(thickness: 1.2, color: PdfColors.blueGrey800),
  ],
);

pw.Widget _customerBlock(L l, QuoteDocumentData data) {
  final name = data.customerName;
  final phone = data.customerPhone;
  if ((name == null || name.isEmpty) && (phone == null || phone.isEmpty)) {
    return pw.SizedBox();
  }
  return pw.Container(
    padding: const pw.EdgeInsets.all(8),
    decoration: const pw.BoxDecoration(color: PdfColors.blueGrey50),
    child: pw.Row(
      children: [
        pw.Text(
          '${l.customerTitle}: ',
          style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
        ),
        pw.Text(
          [
            if (name != null && name.isNotEmpty) name,
            if (phone != null && phone.isNotEmpty) phone,
          ].join('  ·  '),
          style: const pw.TextStyle(fontSize: 9.5),
        ),
      ],
    ),
  );
}

pw.Widget _lineTable(
  L l,
  QuoteDocumentData data,
  List<PricedQuoteLine> parents,
  String Function(PriceBasis) billedUnit,
) {
  final rows = <pw.TableRow>[
    pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
      children: [
        _th(l.pdfRoom),
        _th(l.pdfProduct),
        _th(l.pdfSize),
        _th(l.pdfBilled),
        _th(l.pdfAmount, align: pw.TextAlign.right),
      ],
    ),
  ];

  var striped = false;
  for (final parent in parents) {
    rows.add(_lineRow(l, data, parent, billedUnit, striped, indent: false));
    // Upgrades print under the line they add to, indented, so the customer
    // reads "curtain, plus its track" rather than two unrelated charges.
    for (final child in data.priced.lines.where(
      (c) => c.line.parentLineId == parent.line.id,
    )) {
      rows.add(_lineRow(l, data, child, billedUnit, striped, indent: true));
    }
    striped = !striped;
  }

  return pw.Table(
    border: pw.TableBorder.symmetric(
      inside: const pw.BorderSide(color: PdfColors.blueGrey200, width: 0.5),
    ),
    columnWidths: const {
      0: pw.FlexColumnWidth(1.5),
      1: pw.FlexColumnWidth(3.2),
      2: pw.FlexColumnWidth(2.0),
      3: pw.FlexColumnWidth(1.6),
      4: pw.FlexColumnWidth(1.6),
    },
    children: rows,
  );
}

pw.TableRow _lineRow(
  L l,
  QuoteDocumentData data,
  PricedQuoteLine p,
  String Function(PriceBasis) billedUnit,
  bool striped, {
  required bool indent,
}) {
  final priced = p.priced;
  final label = priced?.rule.labels(data.language) ?? p.line.variant;

  final notes = <String>[
    if (priced != null && priced.rule.bandLabels != null)
      priced.rule.bandLabels!(data.language),
    if (priced != null && priced.minQtyApplied)
      l.minQtyApplied(
        priced.rule.minQty.toString(),
        billedUnit(priced.rule.basis),
      ),
    if (priced != null && priced.materialDeferred) l.materialLater,
    if (priced != null && priced.tierRateApplied) l.tierMvp,
  ];

  return pw.TableRow(
    decoration: pw.BoxDecoration(
      color: striped ? PdfColors.blueGrey50 : PdfColors.white,
    ),
    children: [
      _td(indent ? '' : p.line.room),
      _td(
        '${indent ? '+ ' : ''}$label',
        note: notes.isEmpty ? null : notes.join(' · '),
      ),
      // §5.5 and §8.3: entered and billed always travel together, so the
      // customer can check the number against their own tape.
      _td('${p.line.rawWidth} × ${p.line.rawHeight}'),
      _td(
        priced == null
            ? '—'
            : '${priced.billedQty} ${billedUnit(priced.rule.basis)}',
      ),
      _td(
        priced == null ? l.errorNoRate : priced.total.format(),
        align: pw.TextAlign.right,
      ),
    ],
  );
}

pw.Widget _th(String text, {pw.TextAlign align = pw.TextAlign.left}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );

pw.Widget _td(
  String text, {
  String? note,
  pw.TextAlign align = pw.TextAlign.left,
}) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
  child: pw.Column(
    crossAxisAlignment: align == pw.TextAlign.right
        ? pw.CrossAxisAlignment.end
        : pw.CrossAxisAlignment.start,
    children: [
      pw.Text(text, textAlign: align, style: const pw.TextStyle(fontSize: 9.5)),
      if (note != null && note.isNotEmpty) ...[
        pw.SizedBox(height: 1.5),
        pw.Text(
          note,
          style: const pw.TextStyle(
            fontSize: 7.5,
            color: PdfColors.blueGrey600,
          ),
        ),
      ],
    ],
  ),
);

pw.Widget _totals(L l, QuoteDocumentData data) {
  final totals = data.priced.totals;
  final rows = <pw.Widget>[];

  if (totals.anyFloorApplied) {
    final uplift = totals.categoryFloorUplift.values.fold(
      Money.zero,
      (Money a, Money b) => a + b,
    );
    rows.add(
      _totalRow(
        l.depositFloorRow(const Money.sen(30000).format()),
        '+${uplift.format()}',
      ),
    );
  }
  if (!totals.deliveryCharge.isZero && totals.deliveryZone != null) {
    rows.add(
      _totalRow(
        '${l.deliveryTitle}: ${totals.deliveryZone!.labels(data.language)}',
        '+${totals.deliveryCharge.format()}',
      ),
    );
  }

  return pw.Container(
    alignment: pw.Alignment.centerRight,
    child: pw.SizedBox(
      width: 260,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          ...rows,
          pw.Divider(thickness: 1, color: PdfColors.blueGrey800),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                l.runningTotal,
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                totals.total.format(),
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

pw.Widget _totalRow(String label, String amount) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 2),
  child: pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Expanded(
        child: pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
      ),
      pw.Text(amount, style: const pw.TextStyle(fontSize: 9)),
    ],
  ),
);

/// The reference-price promise and the not-a-tax-invoice statement.
///
/// SPEC.md §8.5 makes the first binding and non-dismissible; §10.1 makes the
/// second a legal requirement rather than a courtesy.
pw.Widget _disclaimer(L l) => pw.Container(
  width: double.infinity,
  padding: const pw.EdgeInsets.all(10),
  decoration: pw.BoxDecoration(
    color: PdfColors.amber50,
    border: pw.Border.all(color: PdfColors.amber200, width: 0.8),
  ),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        l.disclaimerTitle,
        style: pw.TextStyle(
          fontSize: 9.5,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.brown800,
        ),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        l.disclaimerBody,
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.brown800),
      ),
      pw.SizedBox(height: 5),
      pw.Text(
        l.pdfNotAnInvoice,
        style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.blueGrey700),
      ),
    ],
  ),
);

pw.Widget _footer(L l, pw.Context context) => pw.Container(
  alignment: pw.Alignment.centerRight,
  margin: const pw.EdgeInsets.only(top: 8),
  child: pw.Text(
    l.pdfPage(context.pageNumber, context.pagesCount),
    style: const pw.TextStyle(fontSize: 8, color: PdfColors.blueGrey500),
  ),
);
