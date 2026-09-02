import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/features/quote/quote_pdf.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/l10n/app_localizations.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/ui/unit_labels.dart';

/// The quotation PDF actually renders, in all three languages, offline.
///
/// Phase 2 acceptance: "Quote PDF reaches WhatsApp with the phone in airplane
/// mode" and "every line prints entered size, billed size, band applied, rate".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RateCard card;
  late AppDatabase db;

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

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// Builds a quote with a curtain, its S-Track upgrade and a small blind,
  /// then renders it in [language].
  Future<(List<int> bytes, L l)> render(
    WidgetTester tester,
    String language,
  ) async {
    late ProviderContainer container;
    late L l;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeRateCardProvider.overrideWith(
            (ref) async => ActiveRateCard(card: card, list: PriceList.fair),
          ),
          todayProvider.overrideWithValue(DateTime(2026, 8, 29)),
        ],
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: L.supportedLocales,
          localizationsDelegates: const [
            L.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              l = L.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    container.read(languageProvider.notifier).state = language;
    final notifier = container.read(quoteProvider.notifier);
    await container.read(quoteProvider.future);

    final parent = await notifier.addLine(
      room: '客厅',
      variant: 'night_curtain',
      materialKey: null,
      layer: Layer.night,
      width: Length.tenths(36576),
      height: Length.tenths(27432),
      rawWidth: "12'",
      rawHeight: "9'",
    );
    await notifier.addLine(
      room: '客厅',
      variant: 's_track_night',
      materialKey: null,
      layer: Layer.single,
      width: Length.tenths(36576),
      height: Length.tenths(27432),
      rawWidth: "12'",
      rawHeight: "9'",
      parentLineId: parent,
    );
    await notifier.addLine(
      room: '房间',
      variant: 'roller_blackout',
      materialKey: null,
      layer: Layer.single,
      width: Length.tenths(9144),
      height: Length.tenths(12192),
      rawWidth: "3'",
      rawHeight: "4'",
    );
    await notifier.setCustomer(name: '陈大文', phone: '012-3456789');
    await notifier.setDeliveryZone('zone-kl');

    final priced = container.read(pricedQuoteProvider).value!;
    final fonts = await QuoteFonts.load();
    final bytes = await buildQuotePdf(
      data: QuoteDocumentData(
        priced: priced,
        quoteNumber: 'DEMO1234',
        date: DateTime(2026, 8, 29),
        customerName: '陈大文',
        customerPhone: '012-3456789',
        language: language,
      ),
      fonts: fonts,
      l: l,
      billedUnit: (basis) => billedUnitLabel(l, basis),
      compress: false,
    );
    return (bytes, l);
  }

  for (final language in ['zh', 'en', 'ms']) {
    testWidgets('the quotation renders in $language', (tester) async {
      final (bytes, _) = await render(tester, language);

      // %PDF-
      expect(bytes.take(5).toList(), [0x25, 0x50, 0x44, 0x46, 0x2D]);
      expect(bytes.length, greaterThan(4000), reason: 'a real document');

      final text = latin1.decode(bytes, allowInvalid: true);
      // A font must be actually EMBEDDED, or the customer opens the one
      // document they took away and sees tofu. FontFile2 is the embedded
      // TrueType stream. The pdf package subsets it again to the glyphs this
      // document uses, which is why the file is tens of kilobytes rather than
      // the 2.2MB of the bundled asset.
      expect(text, contains('/FontFile2'), reason: 'font not embedded');
      expect(text, contains('/Type/Page'));

      // Written out so `tool/check_pdf_text.py` can extract the real text and
      // assert on it. The bytes themselves are glyph indices, not readable
      // characters, so a grep over them proves nothing either way.
      Directory('build/test-pdfs').createSync(recursive: true);
      File('build/test-pdfs/quote-$language.pdf').writeAsBytesSync(bytes);
    });
  }

  testWidgets('no string the document can print claims to be a tax invoice', (
    tester,
  ) async {
    // CLAUDE.md hard rule 7 and SPEC.md §10.1. SQL Account is the sole issuer
    // of record; two systems issuing for one sale produces two validated UINs
    // and a 72-hour cancellation problem. Legal, not cosmetic.
    //
    // Asserted over the localised strings rather than the PDF bytes: an
    // embedded subset font stores text as glyph indices, so grepping the file
    // for "Tax Invoice" would pass whether or not the words were printed. That
    // is a test that cannot fail, which is worse than no test.
    // `tool/check_pdf_text.py` does the end-to-end check by extracting the
    // rendered text.
    for (final language in ['zh', 'en', 'ms']) {
      await render(tester, language);
      final l = await L.delegate.load(Locale(language));

      // Every heading and label the document prints. The disclaimer is
      // deliberately excluded: it is the one string that MAY name a tax
      // invoice, because its whole job is to say this is not one.
      final labels = [
        l.pdfTitle,
        l.pdfCompany,
        l.pdfQuoteNo,
        l.pdfDate,
        l.pdfRoom,
        l.pdfProduct,
        l.pdfSize,
        l.pdfBilled,
        l.pdfRate,
        l.pdfAmount,
        l.disclaimerTitle,
        l.disclaimerBody,
        l.runningTotal,
        l.customerTitle,
      ].join(' ').toLowerCase();

      expect(labels, isNot(contains('tax invoice')));
      expect(labels, isNot(contains('e-invoice')));
      expect(labels, isNot(contains('einvoice')));
      expect(labels, isNot(contains('invois cukai')));
      expect(labels, isNot(contains('税务发票')));

      // The title says what it IS, in the reader's language.
      expect(l.pdfTitle.toLowerCase(), isNot(contains('invoice')));

      // And the document states plainly that it is not a tax document.
      expect(l.pdfNotAnInvoice, isNotEmpty);
      final denial = l.pdfNotAnInvoice.toLowerCase();
      expect(
        denial.contains('not a tax invoice') ||
            denial.contains('bukan invois cukai') ||
            denial.contains('不是税务发票'),
        isTrue,
        reason: '$language must positively deny being a tax invoice',
      );
    }
  });

  testWidgets('the PDF needs no network — it renders in airplane mode', (
    tester,
  ) async {
    // Guarded structurally rather than by mocking a radio: the only inputs are
    // a bundled font asset and the in-memory quote, so there is nothing to
    // fetch. If someone later adds an http call, this file's imports change.
    final source = File('lib/features/quote/quote_pdf.dart').readAsStringSync();
    expect(source, isNot(contains('package:http')));
    expect(source, isNot(contains('HttpClient')));
    expect(source, isNot(contains('NetworkImage')));
    expect(source, contains('rootBundle'));
  });

  testWidgets('a bigger quote still renders and pages', (tester) async {
    // Chinese font embedding and page breaks are what SPEC.md warns take
    // longer than expected, so a multi-page document is exercised.
    late ProviderContainer container;
    late L l;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeRateCardProvider.overrideWith(
            (ref) async => ActiveRateCard(card: card, list: PriceList.fair),
          ),
          todayProvider.overrideWithValue(DateTime(2026, 8, 29)),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: L.supportedLocales,
          localizationsDelegates: const [
            L.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              l = L.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await container.read(quoteProvider.future);
    final notifier = container.read(quoteProvider.notifier);

    for (var i = 0; i < 30; i++) {
      await notifier.addLine(
        room: '房间 $i',
        variant: 'night_curtain',
        materialKey: null,
        layer: Layer.night,
        width: Length.tenths(36576),
        height: Length.tenths(27432),
        rawWidth: "12'",
        rawHeight: "9'",
      );
    }

    final priced = container.read(pricedQuoteProvider).value!;
    expect(priced.lines, hasLength(30));

    final bytes = await buildQuotePdf(
      data: QuoteDocumentData(
        priced: priced,
        quoteNumber: 'DEMO9999',
        date: DateTime(2026, 8, 29),
        language: 'zh',
      ),
      fonts: await QuoteFonts.load(),
      l: l,
      billedUnit: (basis) => billedUnitLabel(l, basis),
      compress: false,
    );
    final text = latin1.decode(bytes, allowInvalid: true);
    expect(text, contains('/FontFile2'));
    File('build/test-pdfs/quote-long.pdf').writeAsBytesSync(bytes);
    // 30 windows will not fit on one A4 page, so the document must have paged.
    final pageCount = RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
    expect(pageCount, greaterThan(1), reason: 'should span several pages');
  });
}
