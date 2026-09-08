import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/app.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/pricing/models.dart';

/// §13 A25: Korea wallpaper does not have to be measured to be quoted.
///
/// Client, Sep 2026: "normally just do one set of two rolls, but still have
/// the calculator there to suggest how many rolls needed, but not a must."
/// Leaving the wall unmeasured must default to one pack (RM800); measuring a
/// wall that needs more must auto-bill the larger number, not merely suggest
/// it. Driven through the real widgets — the wizard's Done button gating and
/// the quote screen's display are exactly what this rule changed.
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

  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeRateCardProvider.overrideWith(
            (ref) async => ActiveRateCard(card: card, list: PriceList.fair),
          ),
          todayProvider.overrideWithValue(DateTime(2026, 8, 29)),
        ],
        child: const MilanQuoteApp(),
      ),
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
  }

  Future<void> typeOnKeypad(WidgetTester tester, String input) async {
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      final label = switch (ch) {
        "'" => '尺',
        '"' => '寸',
        _ => ch,
      };
      await tester.tap(find.widgetWithText(InkWell, label).last);
      await tester.pump();
    }
  }

  /// Walks the wizard to the wallpaper sizes step and stops there.
  Future<void> reachWallpaperSizes(WidgetTester tester) async {
    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('壁纸'));
    await tester.pumpAndSettle();

    const product = '韩国壁纸（买一送一）14尺x10尺';
    await tester.scrollUntilVisible(
      find.text(product),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(product));
    await tester.pumpAndSettle();
  }

  Future<List<QuoteLineRow>> linesOnTheQuote() async {
    final quotes = await db.select(db.quotes).get();
    if (quotes.isEmpty) return const [];
    return db.linesFor(quotes.first.id);
  }

  testWidgets('the Done button is already enabled with nothing measured', (
    tester,
  ) async {
    await pumpApp(tester);
    await reachWallpaperSizes(tester);

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '完成'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'skipping measurement bills exactly one pack, RM800, and no upgrade step',
    (tester) async {
      await pumpApp(tester);
      await reachWallpaperSizes(tester);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      // wallpaper-dismantle is a real offered upgrade on this product
      // (product_scope_test.dart) — reaching the quote screen instead of the
      // upgrade step proves the skip, not just an empty upgrade list.
      final lines = await linesOnTheQuote();
      expect(lines, hasLength(1));
      expect(lines.single.variant, 'korea_wallpaper');
      expect(lines.single.heightTmm, isNull);

      expect(find.text('RM 800.00'), findsWidgets);
      expect(find.textContaining('未丈量'), findsOneWidget);
    },
  );

  testWidgets('measuring a small wall still bills one pack', (tester) async {
    await pumpApp(tester);
    await reachWallpaperSizes(tester);

    // 10ft x 10ft = 100sqft, under the 280sqft one pack covers.
    await typeOnKeypad(tester, "10'");
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    await typeOnKeypad(tester, "10'");
    await tester.pumpAndSettle();

    // The calculator note already says one pack before Done is even
    // tapped — "make it clear", per the client.
    expect(find.textContaining('按 1 包计'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // A measured wallpaper line reaches the upgrade step (dismantling is
    // a real offered upgrade) — decline it to get back to the quote.
    await tester.tap(find.text('不用，就这样'));
    await tester.pumpAndSettle();

    expect(find.text('RM 800.00'), findsWidgets);
  });

  testWidgets(
    'measuring a large wall auto-bills two packs, not a suggestion left alone',
    (tester) async {
      await pumpApp(tester);
      await reachWallpaperSizes(tester);

      // 30ft x 10ft = 300sqft, just over one 280sqft pack.
      await typeOnKeypad(tester, "30'");
      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();
      await typeOnKeypad(tester, "10'");
      await tester.pumpAndSettle();

      expect(find.textContaining('按 2 包计'), findsOneWidget);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不用，就这样'));
      await tester.pumpAndSettle();

      expect(find.text('RM 1,600.00'), findsWidgets);
    },
  );
}
