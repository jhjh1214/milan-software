/// Builds the revised order document, on the device, after site measurement.
///
/// SPEC.md §11 Phase 6: *"Balance calculation, revised order document."* This
/// is the piece of paper the customer is given or sent once the tape has been
/// out — the one that says what the job actually costs and what is left to pay.
///
/// ## It exists to answer one question
///
/// *"Why is this different from the quotation you gave me?"*
///
/// So every line prints **both** numbers side by side: the size given at the
/// fair and the size measured on site, the amount quoted and the amount now.
/// A document showing only the new figure would be arithmetically correct and
/// would still start the argument it exists to prevent.
///
/// ## What it refuses to print
///
/// An order that has not fully priced. `FinalPricing.finalTotal` is null until
/// every line prices, for the reason given there — a total that quietly
/// excluded a line is a balance somebody collects and a window nobody bills
/// for. That refusal has to reach the paper too, or the one place it matters
/// is the one place it does not apply. [buildRevisedOrderPdf] takes a
/// [RevisedOrderData] that cannot be constructed from an incomplete pricing;
/// use [RevisedOrderData.of], which returns null and leaves the caller to show
/// the outstanding list instead.
///
/// ## The legal constraint
///
/// CLAUDE.md hard rule 7 and SPEC.md §10.1: nothing this system prints may say
/// "Tax Invoice" or "e-Invoice", or show a UIN or a validation QR. SQL Account
/// is the sole issuer of record. This document says in the reader's own
/// language that it is a revised order confirmation, and the same CI check that
/// greps the quotation greps this.
///
/// ## Offline
///
/// Nothing here touches the network. The font is a bundled asset and the
/// layout is computed locally, the same as the quotation — §11 Phase 6's
/// fourth criterion is that the whole flow works in a house with no signal,
/// and the document is part of that flow.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/final_pricing.dart';
import '../quote/quote_pdf.dart' show QuoteFonts;

/// One row on the document: the line, and how to name it to this reader.
///
/// The room and the product label are carried in rather than derived, because
/// [FinalLine] holds pricing and not presentation — and the label depends on
/// the language, which is a property of the reader rather than of the order.
class RevisedOrderLine {
  final FinalLine line;
  final String room;
  final String product;

  /// The size given at the fair and the size the tape read, already formatted
  /// for display. Both print, always, on every row.
  final String quotedSize;
  final String measuredSize;

  /// Blank on a parent line. An upgrade prints indented under the line it
  /// attaches to, so the customer reads "curtain, plus its track".
  final bool isUpgrade;

  const RevisedOrderLine({
    required this.line,
    required this.room,
    required this.product,
    required this.quotedSize,
    required this.measuredSize,
    this.isUpgrade = false,
  });
}

/// Everything the document needs.
///
/// Constructing one is the point at which an incomplete order is stopped, so
/// the builder below never has to ask. Building the PDF stays a pure function
/// of this and can be tested without a screen or a database.
class RevisedOrderData {
  final FinalPricing pricing;
  final List<RevisedOrderLine> lines;

  /// Server-issued, so null until the order has synced. Printed as "pending
  /// sync" rather than fabricated — the same rule as a receipt number, and for
  /// the same reason: it goes on paper a customer keeps.
  final String? orderNo;

  final DateTime quotedOn;
  final DateTime measuredOn;

  final String? customerName;
  final String? customerPhone;

  final Money depositPaid;

  /// The card version the order was pinned to when the deposit confirmed it.
  /// Printed so a price stays explainable a year later (§6.7).
  final int pinnedRateCardVersion;

  final String language;

  const RevisedOrderData._({
    required this.pricing,
    required this.lines,
    required this.orderNo,
    required this.quotedOn,
    required this.measuredOn,
    required this.depositPaid,
    required this.pinnedRateCardVersion,
    required this.language,
    this.customerName,
    this.customerPhone,
  });

  /// The final total. Non-null by construction — [of] refused anything else.
  Money get finalTotal => pricing.finalTotal!;

  /// What is left to pay. Never negative.
  ///
  /// A deposit larger than the final total is possible: RM300 opens a lock on
  /// a category that then measures small. §13 **B4** asks what happens to the
  /// difference and is unanswered, so this document shows nothing owing and
  /// says nothing about a refund. Printing a negative balance would be the
  /// system answering B4 on a piece of paper the customer keeps.
  Money get balanceDue {
    final due = finalTotal - depositPaid;
    return due.sen < 0 ? Money.zero : due;
  }

  /// How far the total moved. Negative is the expected direction.
  Money get variance => finalTotal - pricing.estimateTotal;

  /// Lines whose tape came in above the estimate — §8.5 says this cannot be a
  /// rounding artefact, so each is a real discrepancy the customer is told
  /// about rather than one they find in the arithmetic.
  List<RevisedOrderLine> get overEstimate =>
      lines.where((l) => l.line.isOverEstimate).toList(growable: false);

  /// Builds the data, or returns **null** when the order is not fully priced.
  ///
  /// The null is the refusal. Callers must show `pricing.outstanding` instead;
  /// there is deliberately no way to force a document past it.
  static RevisedOrderData? of({
    required FinalPricing pricing,
    required List<RevisedOrderLine> lines,
    required String? orderNo,
    required DateTime quotedOn,
    required DateTime measuredOn,
    required Money depositPaid,
    required int pinnedRateCardVersion,
    required String language,
    String? customerName,
    String? customerPhone,
  }) {
    if (!pricing.isComplete || pricing.finalTotal == null) return null;
    return RevisedOrderData._(
      pricing: pricing,
      lines: lines,
      orderNo: orderNo,
      quotedOn: quotedOn,
      measuredOn: measuredOn,
      depositPaid: depositPaid,
      pinnedRateCardVersion: pinnedRateCardVersion,
      language: language,
      customerName: customerName,
      customerPhone: customerPhone,
    );
  }
}

/// Renders the revised order.
Future<Uint8List> buildRevisedOrderPdf({
  required RevisedOrderData data,
  required QuoteFonts fonts,
  required L l,
  // Compression is off in tests so the assertion that nothing says "Tax
  // Invoice" reads the real rendered text rather than passing against a
  // compressed blob. Hard rule 7 is a legal constraint, and a test that cannot
  // see the words it forbids is worse than no test.
  bool compress = true,
}) async {
  final theme = pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold)
      .copyWith(
        defaultTextStyle: pw.TextStyle(font: fonts.regular, fontSize: 9.5),
      );

  final doc = pw.Document(
    title: l.revisedTitle,
    author: l.pdfCompany,
    theme: theme,
    compress: compress,
  );

  final over = data.overEstimate;

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
        _lineTable(l, data),
        pw.SizedBox(height: 10),
        _totals(l, data),
        pw.SizedBox(height: 14),
        // The over-estimate notice goes ABOVE the reference-price promise, not
        // below it. The promise says the price can only fall; where it did not,
        // the customer must read why before they read the promise, or the two
        // together look like a lie.
        if (over.isNotEmpty) ...[
          _overEstimateNotice(l, data, over),
          pw.SizedBox(height: 10),
        ],
        _whyBlock(l, data),
      ],
    ),
  );

  return doc.save();
}

pw.Widget _header(L l, RevisedOrderData data) => pw.Column(
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
              l.revisedTitle,
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
              '${l.revisedOrderNo}: ${data.orderNo ?? l.revisedPendingSync}',
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              '${l.revisedQuotedOn}: ${formatDate(data.quotedOn)}',
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              '${l.revisedMeasuredOn}: ${formatDate(data.measuredOn)}',
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

pw.Widget _customerBlock(L l, RevisedOrderData data) {
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

/// Both sizes and both amounts on every row.
///
/// Six columns rather than the quotation's five. The extra width comes out of
/// the product column, because a customer checking a number reads across the
/// row and the product name is the part they already know.
pw.Widget _lineTable(L l, RevisedOrderData data) {
  final rows = <pw.TableRow>[
    pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
      children: [
        _th(l.pdfRoom),
        _th(l.pdfProduct),
        _th(l.revisedColQuoted),
        _th(l.revisedColMeasured),
        _th(l.revisedColQuotedAmount, align: pw.TextAlign.right),
        _th(l.revisedColFinalAmount, align: pw.TextAlign.right),
      ],
    ),
  ];

  var striped = false;
  for (final row in data.lines) {
    rows.add(_lineRow(l, row, striped));
    if (!row.isUpgrade) striped = !striped;
  }

  return pw.Table(
    border: pw.TableBorder.symmetric(
      inside: const pw.BorderSide(color: PdfColors.blueGrey200, width: 0.5),
    ),
    columnWidths: const {
      0: pw.FlexColumnWidth(1.3),
      1: pw.FlexColumnWidth(2.4),
      2: pw.FlexColumnWidth(1.7),
      3: pw.FlexColumnWidth(1.7),
      4: pw.FlexColumnWidth(1.4),
      5: pw.FlexColumnWidth(1.4),
    },
    children: rows,
  );
}

pw.TableRow _lineRow(L l, RevisedOrderLine row, bool striped) {
  final line = row.line;
  // Non-null by construction: RevisedOrderData.of refused an incomplete order.
  final total = line.finalTotal!;
  final up = line.isOverEstimate;

  return pw.TableRow(
    decoration: pw.BoxDecoration(
      color: up
          // The one row a customer must not skim past.
          ? PdfColors.amber50
          : (striped ? PdfColors.blueGrey50 : PdfColors.white),
    ),
    children: [
      _td(row.isUpgrade ? '' : row.room),
      _td('${row.isUpgrade ? '+ ' : ''}${row.product}'),
      _td(row.quotedSize),
      _td(row.measuredSize),
      _td(line.estimateTotal.format(), align: pw.TextAlign.right),
      _td(
        total.format(),
        align: pw.TextAlign.right,
        emphasis: up ? PdfColors.brown800 : null,
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
  pw.TextAlign align = pw.TextAlign.left,
  PdfColor? emphasis,
}) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
  child: pw.Text(
    text,
    textAlign: align,
    style: pw.TextStyle(
      fontSize: 9.5,
      color: emphasis,
      fontWeight: emphasis == null ? null : pw.FontWeight.bold,
    ),
  ),
);

/// Quoted total, final total, what moved, then the money.
///
/// The quoted total stays on the document. Dropping it would leave the customer
/// with a number and no way to check it against the paper they already have,
/// which is the whole reason this document is a *revision* rather than a fresh
/// order.
pw.Widget _totals(L l, RevisedOrderData data) {
  final variance = data.variance;

  return pw.Container(
    alignment: pw.Alignment.centerRight,
    child: pw.SizedBox(
      width: 280,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _totalRow(
            l.revisedEstimateTotal,
            data.pricing.estimateTotal.format(),
          ),
          _totalRow(
            variance.isZero ? l.revisedNoChange : l.revisedYouSave,
            variance.isZero
                ? '—'
                // Shown as the size of the reduction, not as a negative. "-RM31.20"
                // beside "Reduced by" reads as a double negative on paper.
                : (variance.sen < 0
                      ? Money.sen(-variance.sen).format()
                      : '+${variance.format()}'),
          ),
          pw.Divider(thickness: 1, color: PdfColors.blueGrey800),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                l.revisedFinalTotal,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                data.finalTotal.format(),
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 4),
          _totalRow(l.revisedDepositPaid, '- ${data.depositPaid.format()}'),
          pw.Divider(thickness: 1, color: PdfColors.blueGrey800),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                l.revisedBalanceDue,
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                data.balanceDue.format(),
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

/// Named, itemised, and above the promise it appears to break.
pw.Widget _overEstimateNotice(
  L l,
  RevisedOrderData data,
  List<RevisedOrderLine> over,
) => pw.Container(
  width: double.infinity,
  padding: const pw.EdgeInsets.all(10),
  decoration: pw.BoxDecoration(
    color: PdfColors.amber50,
    border: pw.Border.all(color: PdfColors.amber400, width: 1),
  ),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        l.revisedOverTitle,
        style: pw.TextStyle(
          fontSize: 9.5,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.brown800,
        ),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        l.revisedOverBody,
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.brown800),
      ),
      pw.SizedBox(height: 5),
      for (final row in over)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 1.5),
          child: pw.Text(
            // Composed here rather than as a three-placeholder message.
            // gen-l10n orders positional placeholders alphabetically, so
            // `(room, product, amount)` would generate `(amount, product,
            // room)` — and a room name printed where an amount belongs looks
            // like a typo rather than a bug. The room and product are data;
            // only the amount phrase is translated.
            '${row.room} — ${row.product}: '
            // variance is non-null here: the line priced.
            '${l.revisedOverAmount(row.line.variance!.format())}',
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.brown800),
          ),
        ),
    ],
  ),
);

/// Why the number moved, which card priced it, and that this is not an invoice.
pw.Widget _whyBlock(L l, RevisedOrderData data) => pw.Container(
  width: double.infinity,
  padding: const pw.EdgeInsets.all(10),
  decoration: pw.BoxDecoration(
    color: PdfColors.blueGrey50,
    border: pw.Border.all(color: PdfColors.blueGrey200, width: 0.8),
  ),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        l.revisedWhyTitle,
        style: pw.TextStyle(
          fontSize: 9.5,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.blueGrey800,
        ),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        l.revisedWhyBody,
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.blueGrey800),
      ),
      pw.SizedBox(height: 5),
      pw.Text(
        l.revisedPricedAt(data.pinnedRateCardVersion),
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.blueGrey600),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        l.revisedNotAnInvoice,
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
