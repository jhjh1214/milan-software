import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/app.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/pricing/models.dart';

/// Walks the demo script from SPEC.md §11 through the real widgets.
///
/// If this suite goes red, the client meeting goes badly. Each test is one
/// numbered step of that script.
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

  Future<void> pumpApp(WidgetTester tester) async {
    // The card is supplied directly rather than loaded from the asset bundle.
    // The screen shows an indeterminate spinner while the future is pending,
    // and an indeterminate spinner never settles, so pumpAndSettle would time
    // out on the loading frame. The real bundle load is covered by
    // rate_card_asset_test.dart.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rateCardProvider.overrideWith((ref) => card)],
        child: const MilanQuoteApp(),
      ),
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
  }

  /// Presses the custom keypad, never the system keyboard — which is the
  /// point of §8.1.
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

  /// Adds a window through the wizard exactly as a part-timer would:
  /// room, then category, then product, then sizes.
  Future<void> addWindow(
    WidgetTester tester, {
    required String room,
    required String category,
    required String product,
    required String width,
    required String height,
  }) async {
    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(room));
    await tester.pumpAndSettle();

    await tester.tap(find.text(category));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text(product),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(product));
    await tester.pumpAndSettle();

    await typeOnKeypad(tester, width);
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();

    await typeOnKeypad(tester, height);
    await tester.pumpAndSettle();

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  }

  testWidgets('step 1 — a 12ft x 9ft night curtain quotes RM552.00', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    expect(find.text('RM 552.00'), findsWidgets);
  });

  testWidgets('step 2 — raising the drop to 10ft 6in makes it RM696.00', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "10'6",
    );
    // The RM144 step. This is the mistake costing them money today.
    expect(find.text('RM 696.00'), findsWidgets);
  });

  testWidgets('step 3 — a width of 12ft 4in shows it billed as 13ft', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'4",
      height: "9'",
    );
    expect(find.textContaining('按 13 尺计'), findsOneWidget);
    expect(find.text('RM 598.00'), findsWidgets);
  });

  testWidgets('step 5 — a small roller blind bills the 18 sqft minimum', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '房间',
      category: '百叶 / 卷帘',
      product: '遮光卷帘',
      width: "3'",
      height: "4'",
    );
    expect(find.textContaining('最低 18'), findsOneWidget);
    // RM162 is below the RM300 deposit, so the quote floors and says so.
    expect(find.text('RM 162.00'), findsOneWidget);
    expect(find.textContaining('最低报价'), findsOneWidget);
    expect(find.text('RM 300.00'), findsOneWidget);
  });

  testWidgets('step 6 — the MVP toggle swaps RM46 for RM40', (tester) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    expect(find.text('RM 552.00'), findsWidgets);

    await tester.tap(find.text('普通价'));
    await tester.pumpAndSettle();

    expect(find.text('RM 480.00'), findsWidgets);
    expect(find.text('RM 552.00'), findsNothing);
  });

  testWidgets('the reference-price disclaimer is always on the quote', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    // SPEC.md §8.5 makes this binding and non-dismissible.
    expect(find.textContaining('价格只会相同或更低'), findsOneWidget);
  });

  testWidgets('the real price list shows no provisional banner', (
    tester,
  ) async {
    // A2a is answered, so the banner must be gone. If it comes back, someone
    // shipped a stand-in card.
    await pumpApp(tester);
    expect(find.textContaining('价格表还没确认'), findsNothing);
  });

  testWidgets('a provisional card is still flagged loudly', (tester) async {
    // The banner has to keep working, or a future stand-in ships silently.
    final standIn = RateCard(
      version: 0,
      provisional: true,
      config: card.config,
      rules: card.rules,
      deliveryZones: card.deliveryZones,
      productRules: card.productRules,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rateCardProvider.overrideWith((ref) => standIn)],
        child: const MilanQuoteApp(),
      ),
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('价格表还没确认'), findsOneWidget);
  });

  testWidgets('deferred material quotes the dearest option, and says so', (
    tester,
  ) async {
    // The client's instruction: at a fair nobody picks J/BL vs TBL, that
    // happens at measurement. TBL is RM15/sqft against J/BL's RM12, and the
    // quote promises the final can only fall, so the dearer one is quoted.
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '百叶 / 卷帘',
      product: '斑马帘 遮光',
      width: "5'",
      height: "6'",
    );
    // 30 sqft x RM15 = RM450, not 30 x RM12 = RM360.
    expect(find.text('RM 450.00'), findsWidgets);
    expect(find.textContaining('料丈量时再选'), findsOneWidget);
  });

  testWidgets('deleting a line offers undo rather than a confirmation', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    expect(find.text('RM 552.00'), findsWidgets);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    // Let the snackbar finish sliding in. Tapping mid-animation lands beside
    // the action rather than on it.
    await tester.pump(const Duration(milliseconds: 750));

    expect(
      find.text('还原'),
      findsOneWidget,
      reason: '§8.1 wants undo, not confirm',
    );

    await tester.tap(find.text('还原'));
    await tester.pumpAndSettle();
    expect(find.text('RM 552.00'), findsWidgets);
  });

  testWidgets('the app switches language without losing the quote', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bahasa Melayu'));
    await tester.pumpAndSettle();

    expect(find.text('Sebut Harga'), findsOneWidget);
    expect(find.text('RM 552.00'), findsWidgets);
    expect(find.textContaining('sama atau lebih rendah'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(find.text('Quotation'), findsOneWidget);
    expect(find.textContaining('same or lower'), findsOneWidget);
  });

  testWidgets('a part-timer never sees a rate while choosing a product', (
    tester,
  ) async {
    // Hard rule 8: they pick a product, the system picks the rate. Nothing
    // selectable is nothing to get wrong.
    await pumpApp(tester);
    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();

    expect(find.textContaining('RM'), findsNothing);
    expect(find.textContaining('46'), findsNothing);
  });

  testWidgets('the running total adds up across several windows', (
    tester,
  ) async {
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    await addWindow(
      tester,
      room: '主人房',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    final priced = container.read(pricedQuoteProvider).value!;
    expect(priced.lines.length, 2);
    expect(priced.totals.total.sen, 110400);
    expect(find.text('RM 1,104.00'), findsOneWidget);
  });
}
