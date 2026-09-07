import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/features/order/revised_order_pdf.dart';
import 'package:milan_quote/features/quote/quote_pdf.dart' show QuoteFonts;
import 'package:milan_quote/l10n/app_localizations.dart';
import 'package:milan_quote/pricing/final_pricing.dart';
import 'package:milan_quote/pricing/models.dart';

/// The revised order document. SPEC.md §11 Phase 6.
///
/// The paper the customer gets after the tape has been out. It exists to answer
/// *"why is this different from the quotation you gave me?"*, so the tests here
/// are mostly about what it REFUSES to leave out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RateCard card;

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    card = RateCard.fromJson(
      jsonDecode(
            File(
              '${dir.path}/shared/rate-card-fair-2026-08.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
  });

  /// A 12ft × 9ft night curtain quoted at 12ft and measured at 11ft 6in, plus a
  /// 3ft × 4ft roller blind measured exactly as quoted.
  ///
  /// The curtain is the ordinary case: rounded up on the quote, exact on the
  /// bill, so the price falls.
  FinalPricing pricing({
    Length? curtainWidth,
    Money curtainEstimate = const Money.sen(55200),
  }) => repriceOrder(
    lines: [
      MeasuredLine(
        id: 'line-curtain',
        variant: 'night_curtain',
        layer: Layer.night,
        estimateTotal: curtainEstimate,
        appliedRateCardVersion: card.version,
        // 11ft 6in. The quote charged a whole 12ft.
        finalWidth: curtainWidth ?? Length.tenths(35052),
        finalHeight: Length.tenths(27432),
      ),
      MeasuredLine(
        id: 'line-blind',
        variant: 'roller_blackout',
        estimateTotal: const Money.sen(16200),
        appliedRateCardVersion: card.version,
        finalWidth: Length.tenths(9144),
        finalHeight: Length.tenths(12192),
      ),
    ],
    cards: {card.version: card},
  );

  List<RevisedOrderLine> rowsFor(FinalPricing p) => [
    RevisedOrderLine(
      line: p.lines[0],
      room: '客厅',
      product: '夜帘',
      quotedSize: "12' × 9'",
      measuredSize: "11'6\" × 9'",
    ),
    RevisedOrderLine(
      line: p.lines[1],
      room: '房间',
      product: '卷帘',
      quotedSize: "3' × 4'",
      measuredSize: "3' × 4'",
    ),
  ];

  RevisedOrderData? dataFor(
    FinalPricing p, {
    String language = 'zh',
    Money deposit = const Money.sen(30000),
    String? orderNo = 'MLK-2609-0007',
  }) => RevisedOrderData.of(
    pricing: p,
    lines: rowsFor(p),
    orderNo: orderNo,
    quotedOn: DateTime(2026, 8, 29),
    measuredOn: DateTime(2026, 9, 12),
    depositPaid: deposit,
    pinnedRateCardVersion: card.version,
    language: language,
    customerName: '陈大文',
    customerPhone: '012-3456789',
  );

  Future<L> load(WidgetTester tester, String language) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: L.supportedLocales,
        localizationsDelegates: const [
          L.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();
    return L.delegate.load(Locale(language));
  }

  group('what it refuses to print', () {
    test('an order with a line the tape has not reached', () {
      // The whole reason `FinalPricing.finalTotal` is null rather than zero: a
      // total that quietly excluded a line is a balance somebody collects and
      // a window nobody bills for. That refusal has to reach the paper too, or
      // the one place it matters is the one place it does not apply.
      final unmeasured = repriceOrder(
        lines: [
          MeasuredLine(
            id: 'line-curtain',
            variant: 'night_curtain',
            layer: Layer.night,
            estimateTotal: const Money.sen(55200),
            appliedRateCardVersion: card.version,
            // No tape.
          ),
        ],
        cards: {card.version: card},
      );
      expect(unmeasured.isComplete, isFalse);
      expect(unmeasured.finalTotal, isNull);

      expect(
        RevisedOrderData.of(
          pricing: unmeasured,
          lines: const [],
          orderNo: 'MLK-2609-0007',
          quotedOn: DateTime(2026, 8, 29),
          measuredOn: DateTime(2026, 9, 12),
          depositPaid: const Money.sen(30000),
          pinnedRateCardVersion: card.version,
          language: 'zh',
        ),
        isNull,
        reason:
            'there must be no way to force a document past an unpriced line',
      );
    });

    test('a pricing that claims a total while saying it is incomplete', () {
      // `repriceOrder` never produces this: it sets `finalTotal` non-null
      // exactly when `isComplete`. But `FinalPricing`'s constructor is public,
      // so the two could disagree in a value built by hand or by a future
      // caller — and this document is the last thing between that and a
      // customer's paper. Checking both is not redundant here; it is the
      // difference between trusting a total and verifying it was earned.
      final inconsistent = FinalPricing(
        lines: [
          FinalLine(
            id: 'line-curtain',
            estimateTotal: const Money.sen(55200),
            refusal: FinalPricingRefusal.notMeasured,
          ),
        ],
        estimateTotal: const Money.sen(55200),
        finalTotal: const Money.sen(55200),
        isComplete: false,
      );

      expect(
        RevisedOrderData.of(
          pricing: inconsistent,
          lines: const [],
          orderNo: 'MLK-2609-0007',
          quotedOn: DateTime(2026, 8, 29),
          measuredOn: DateTime(2026, 9, 12),
          depositPaid: const Money.sen(30000),
          pinnedRateCardVersion: card.version,
          language: 'zh',
        ),
        isNull,
        reason: 'isComplete is the authority, not the presence of a number',
      );
    });

    test('an order with no lines at all', () {
      final empty = repriceOrder(lines: const [], cards: {card.version: card});
      expect(
        RevisedOrderData.of(
          pricing: empty,
          lines: const [],
          orderNo: null,
          quotedOn: DateTime(2026, 8, 29),
          measuredOn: DateTime(2026, 9, 12),
          depositPaid: Money.zero,
          pinnedRateCardVersion: card.version,
          language: 'zh',
        ),
        isNull,
        reason: 'RM0.00 due is a worse answer than "not priced"',
      );
    });
  });

  group('the arithmetic on the page', () {
    test('the balance is the final less the deposit', () {
      final data = dataFor(pricing())!;
      expect(data.balanceDue, data.finalTotal - const Money.sen(30000));
    });

    test(
      'a deposit larger than the final shows nothing owing, not a refund',
      () {
        // §13 B4 is unanswered: RM300 opens a lock on a category that then
        // measures small, and what happens to the difference is a decision
        // nobody has made. Printing a negative balance would be this document
        // answering it, on paper the customer keeps.
        final data = dataFor(pricing(), deposit: const Money.sen(9999999))!;
        expect(data.balanceDue, Money.zero);
        expect(data.balanceDue.sen, isNonNegative);
      },
    );

    test('the final comes in below the quote, and both are on the page', () {
      final p = pricing();
      final data = dataFor(p)!;
      expect(data.finalTotal.sen, lessThan(p.estimateTotal.sen));
      expect(data.variance.sen, isNegative);
      // The quoted total stays. Without it the customer has a number and no
      // way to check it against the paper they already have.
      expect(data.pricing.estimateTotal.sen, greaterThan(0));
    });

    test('a line measured larger than quoted is named, not averaged away', () {
      // §8.5's promise is about rounding, not about the customer's own wrong
      // dimensions — so this is flagged rather than refused, and the customer
      // reads which window it was.
      final p = pricing(
        // Measured 14ft against a 12ft quote.
        curtainWidth: Length.tenths(42672),
      );
      final data = dataFor(p)!;
      expect(data.overEstimate, hasLength(1));
      expect(data.overEstimate.single.room, '客厅');
      expect(data.overEstimate.single.line.variance!.sen, isPositive);
    });

    test('nothing is flagged when every line came in at or below', () {
      expect(dataFor(pricing())!.overEstimate, isEmpty);
    });

    testWidgets('the deposit floor is a visible row, not a silent gap', (
      tester,
    ) async {
      // §13 A21d. One small blind alone: RM108 exact — the printed 18 sqft
      // minimum is a quotation device — floored to the RM300 already
      // deposited. Without a row saying so, the lines add to RM108 and the
      // total says RM300 — on the one document whose job is letting a customer
      // check the arithmetic against the paper they already hold.
      final small = repriceOrder(
        lines: [
          MeasuredLine(
            id: 'line-blind',
            variant: 'roller_blackout',
            estimateTotal: const Money.sen(16200),
            appliedRateCardVersion: card.version,
            finalWidth: Length.tenths(9144),
            finalHeight: Length.tenths(12192),
          ),
        ],
        cards: {card.version: card},
      );
      expect(small.categoryFloorUplift.sen, 19200);
      expect(small.finalTotal!.sen, 30000);
      expect(
        small.lines.single.finalTotal!.sen,
        10800,
        reason: 'the LINE still says what the product measured and cost',
      );

      final l = await load(tester, 'en');
      final data = RevisedOrderData.of(
        pricing: small,
        lines: [
          RevisedOrderLine(
            line: small.lines.single,
            room: 'Bedroom',
            product: 'Roller blackout',
            quotedSize: "3' × 4'",
            measuredSize: "3' × 4'",
          ),
        ],
        orderNo: 'MLK-2609-0008',
        quotedOn: DateTime(2026, 8, 29),
        measuredOn: DateTime(2026, 9, 12),
        depositPaid: const Money.sen(30000),
        pinnedRateCardVersion: card.version,
        language: 'en',
      )!;

      // Nothing owing: they paid RM300 and the order bills RM300.
      expect(data.balanceDue, Money.zero);

      final bytes = await buildRevisedOrderPdf(
        data: data,
        fonts: await QuoteFonts.load(),
        l: l,
        compress: false,
      );
      Directory('build/test-pdfs').createSync(recursive: true);
      File('build/test-pdfs/revised-floor.pdf').writeAsBytesSync(bytes);
      expect(bytes.take(5).toList(), [0x25, 0x50, 0x44, 0x46, 0x2D]);
    });
  });

  for (final language in ['zh', 'en', 'ms']) {
    testWidgets('the revised order renders in $language', (tester) async {
      final l = await load(tester, language);
      final data = dataFor(pricing(), language: language)!;
      final bytes = await buildRevisedOrderPdf(
        data: data,
        fonts: await QuoteFonts.load(),
        l: l,
        compress: false,
      );

      // %PDF-
      expect(bytes.take(5).toList(), [0x25, 0x50, 0x44, 0x46, 0x2D]);
      expect(bytes.length, greaterThan(4000), reason: 'a real document');

      final text = latin1.decode(bytes, allowInvalid: true);
      // The font must be EMBEDDED or the customer opens the one document they
      // took away and sees tofu.
      expect(text, contains('/FontFile2'), reason: 'font not embedded');
      expect(text, contains('/Type/Page'));

      // Written out for `tool/check_pdf_text.py`, which extracts the real text.
      // The bytes here are glyph indices, so a grep over them proves nothing.
      Directory('build/test-pdfs').createSync(recursive: true);
      File('build/test-pdfs/revised-$language.pdf').writeAsBytesSync(bytes);
    });
  }

  testWidgets('an over-estimate document also renders, in every language', (
    tester,
  ) async {
    // The amber notice and its itemised list are a different page shape. A
    // document that only ever renders in the happy case is the one that throws
    // on the day somebody's window measured bigger.
    for (final language in ['zh', 'en', 'ms']) {
      final l = await load(tester, language);
      final data = dataFor(
        pricing(curtainWidth: Length.tenths(42672)),
        language: language,
      )!;
      expect(data.overEstimate, isNotEmpty);
      final bytes = await buildRevisedOrderPdf(
        data: data,
        fonts: await QuoteFonts.load(),
        l: l,
        compress: false,
      );
      expect(bytes.take(5).toList(), [0x25, 0x50, 0x44, 0x46, 0x2D]);

      Directory('build/test-pdfs').createSync(recursive: true);
      File(
        'build/test-pdfs/revised-over-$language.pdf',
      ).writeAsBytesSync(bytes);
    }
  });

  testWidgets('an unsynced order says pending sync, never a made-up number', (
    tester,
  ) async {
    // `order_no` is server-issued for the same reason a receipt number is: it
    // goes on a document the customer takes away, and two part-timers offline
    // at one fair would invent the same one.
    final l = await load(tester, 'en');
    final data = dataFor(pricing(), language: 'en', orderNo: null)!;
    expect(data.orderNo, isNull);

    final bytes = await buildRevisedOrderPdf(
      data: data,
      fonts: await QuoteFonts.load(),
      l: l,
      compress: false,
    );
    Directory('build/test-pdfs').createSync(recursive: true);
    File('build/test-pdfs/revised-pending.pdf').writeAsBytesSync(bytes);
    expect(l.revisedPendingSync, isNotEmpty);
  });

  testWidgets('no string the document can print claims to be a tax invoice', (
    tester,
  ) async {
    // CLAUDE.md hard rule 7 and SPEC.md §10.1. SQL Account is the sole issuer
    // of record; two systems issuing for one sale produces two validated UINs
    // and a 72-hour cancellation problem. Legal, not cosmetic.
    //
    // Asserted over the localised strings rather than the bytes: an embedded
    // subset font stores text as glyph indices, so grepping the file would
    // pass whether or not the words were printed. `tool/check_pdf_text.py`
    // does the end-to-end check by extracting the rendered text.
    for (final language in ['zh', 'en', 'ms']) {
      final l = await load(tester, language);

      // Every heading and label the document prints. The denial sentence is
      // excluded: it is the one string that MAY name a tax invoice, because
      // its whole job is to say this is not one.
      final labels = [
        l.revisedTitle,
        l.pdfCompany,
        l.revisedOrderNo,
        l.revisedPendingSync,
        l.revisedQuotedOn,
        l.revisedMeasuredOn,
        l.pdfRoom,
        l.pdfProduct,
        l.revisedColQuoted,
        l.revisedColMeasured,
        l.revisedColQuotedAmount,
        l.revisedColFinalAmount,
        l.revisedEstimateTotal,
        l.revisedFinalTotal,
        l.revisedYouSave,
        l.revisedNoChange,
        l.revisedDepositPaid,
        l.revisedBalanceDue,
        l.revisedWhyTitle,
        l.revisedWhyBody,
        l.revisedOverTitle,
        l.revisedOverBody,
        l.customerTitle,
      ].join(' ').toLowerCase();

      expect(labels, isNot(contains('tax invoice')));
      expect(labels, isNot(contains('e-invoice')));
      expect(labels, isNot(contains('einvoice')));
      expect(labels, isNot(contains('invois cukai')));
      expect(labels, isNot(contains('税务发票')));
      expect(labels, isNot(contains('电子发票')));

      // The title says what it IS, in the reader's language.
      expect(l.revisedTitle.toLowerCase(), isNot(contains('invoice')));

      final denial = l.revisedNotAnInvoice.toLowerCase();
      expect(
        denial.contains('not a tax invoice') ||
            denial.contains('bukan invois cukai') ||
            denial.contains('非税务发票'),
        isTrue,
        reason: '$language must positively deny being a tax invoice',
      );
    }
  });

  test(
    'the document needs no network — it renders in a house with no signal',
    () {
      // §11 Phase 6's fourth criterion. Guarded structurally rather than by
      // mocking a radio: the only inputs are a bundled font and the in-memory
      // pricing, so there is nothing to fetch. If someone later adds an http
      // call, this file's imports change and this fails.
      final source = File(
        'lib/features/order/revised_order_pdf.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('package:http')));
      expect(source, isNot(contains('HttpClient')));
      expect(source, isNot(contains('NetworkImage')));
    },
  );
}
