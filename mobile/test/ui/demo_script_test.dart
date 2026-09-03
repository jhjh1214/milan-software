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

/// Walks the demo script from SPEC.md §11 through the real widgets.
///
/// If this suite goes red, the client meeting goes badly. Each test is one
/// numbered step of that script.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RateCard card;
  late String cardJson;

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    cardJson = File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).readAsStringSync();
    card = RateCard.fromJson(jsonDecode(cardJson) as Map<String, dynamic>);
  });

  /// A date inside the MITC fair, so the expired-rates banner stays quiet in
  /// the tests that are not about it. Pinned rather than DateTime.now(), or
  /// every test would change behaviour depending on the day it runs.
  final duringFair = DateTime(2026, 8, 29);

  late AppDatabase db;

  setUp(() {
    // A fresh in-memory database per test. The real one writes to app storage
    // via path_provider, which does not exist under `flutter test`, and tests
    // that shared a database would leak each other's quotes.
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester, {DateTime? today}) async {
    // The card is supplied directly rather than loaded from the asset bundle.
    // The screen shows an indeterminate spinner while the future is pending,
    // and an indeterminate spinner never settles, so pumpAndSettle would time
    // out on the loading frame. The real bundle load is covered by
    // rate_card_asset_test.dart.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeRateCardProvider.overrideWith(
            (ref) async => ActiveRateCard(card: card, list: PriceList.fair),
          ),
          todayProvider.overrideWithValue(today ?? duringFair),
        ],
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
    List<String> upgrades = const [],
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

    // The upgrade step. It only appears where the card actually offers
    // something, and declining is the default — the normal track is already in
    // the curtain rate, so nothing is added unless asked for.
    if (find.text('不用，就这样').evaluate().isNotEmpty || upgrades.isNotEmpty) {
      for (final upgrade in upgrades) {
        await tester.scrollUntilVisible(
          find.text(upgrade),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(upgrade));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(upgrades.isEmpty ? '不用，就这样' : '完成'));
      await tester.pumpAndSettle();
    }
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
    // SPEC.md §8.5 makes this binding and non-dismissible. It sits at the foot
    // of the quote, so the list is scrolled to reach it.
    await tester.scrollUntilVisible(
      find.textContaining('价格只会相同或更低'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('价格只会相同或更低'), findsOneWidget);
  });

  testWidgets('a special track ADDS to the curtain, it does not replace it', (
    tester,
  ) async {
    // A16. The curtain rate covers the fabric and standard hardware; an S-Track
    // is an extra RM80/ft on top. 12ft x RM46 = RM552, plus 12ft x RM80 = RM960,
    // giving RM1,512 — not RM960.
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
      upgrades: ['S 轨道（夜帘）'],
    );

    expect(find.text('RM 552.00'), findsOneWidget, reason: 'the curtain');
    expect(find.text('RM 960.00'), findsOneWidget, reason: 'the S-Track');
    expect(find.text('RM 1,512.00'), findsOneWidget, reason: 'the total');
  });

  testWidgets('a curtain with no upgrade costs the fabric rate alone', (
    tester,
  ) async {
    // §4.1, corrected. The normal track is already in the price, so nothing is
    // added unless asked for. Auto-adding a track here would put RM108 on this
    // window.
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
    expect(find.text('RM 660.00'), findsNothing, reason: 'no Doso track added');
    expect(
      find.text('RM 672.00'),
      findsNothing,
      reason: 'no Meyer track added',
    );
  });

  testWidgets('deleting a curtain takes its upgrade with it', (tester) async {
    // An orphaned RM960 track line left on the quote would be wrong and nearly
    // invisible to a part-timer.
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
      upgrades: ['S 轨道（夜帘）'],
    );
    expect(find.text('RM 1,512.00'), findsOneWidget);

    // The parent card's delete button is the first one.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(find.text('RM 960.00'), findsNothing, reason: 'the track went too');
    expect(find.text('RM 552.00'), findsNothing);

    // And undo brings both back.
    await tester.tap(find.text('还原'));
    await tester.pumpAndSettle();
    expect(find.text('RM 1,512.00'), findsOneWidget);
  });

  testWidgets('the delivery charge appears before the total, not after', (
    tester,
  ) async {
    // §4.1: "Ask for the delivery area early and surface the charge before the
    // total, never after the customer has agreed a number."
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
    expect(find.text('马六甲市区（不加钱）'), findsOneWidget);

    await tester.tap(find.text('马六甲市区（不加钱）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('吉隆坡 / 芙蓉 / 森美兰'));
    await tester.pumpAndSettle();

    // RM552 + RM300 round trip.
    expect(find.text('+RM 300.00'), findsOneWidget);
    expect(find.text('RM 852.00'), findsOneWidget, reason: 'the running total');
  });

  testWidgets('travel is not dragged up by the RM300 deposit floor', (
    tester,
  ) async {
    // The floor is per deposit category and travel is not a product, so a
    // RM100 transport charge must stay RM100.
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '房间',
      category: '百叶 / 卷帘',
      product: '遮光卷帘',
      width: "3'",
      height: "4'",
    );
    await tester.tap(find.text('马六甲市区（不加钱）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('麻坡 / 东甲 / 亚罗牙也 / 淡边'));
    await tester.pumpAndSettle();

    // RM162 floors to RM300, plus RM100 travel = RM400. Not RM600.
    expect(find.text('+RM 100.00'), findsOneWidget);
    expect(find.text('RM 400.00'), findsOneWidget);
  });

  testWidgets('the customer name is optional and survives a restart', (
    tester,
  ) async {
    // Optional on purpose: a required name field stands between a part-timer
    // and the four-minute quote §8.4 asks for.
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    expect(find.text('可以不填，之后再补'), findsOneWidget);

    await tester.tap(find.text('可以不填，之后再补'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '陈大文');
    await tester.enterText(find.byType(TextField).last, '012-3456789');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('陈大文'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester);
    expect(find.textContaining('陈大文'), findsOneWidget);
    expect(find.textContaining('012-3456789'), findsOneWidget);
  });

  /// A store over memory with an injected bundle.
  ///
  /// Real file I/O and `rootBundle` both hang inside `flutter test`'s
  /// fake-async zone, so without these seams none of this flow is testable.
  RateCardStore memoryStore(InMemoryRateCardStorage storage) =>
      RateCardStore(storage: storage, bundled: (list) async => cardJson);

  Future<void> pumpWithStore(WidgetTester tester, RateCardStore store) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          rateCardStoreProvider.overrideWithValue(store),
          todayProvider.overrideWithValue(duringFair),
        ],
        child: const MilanQuoteApp(),
      ),
      duration: Duration.zero,
    );
    // The store reads the bundled asset, so the screen shows an indeterminate
    // spinner for a frame or two. pumpAndSettle would wait for that spinner
    // forever, so pump a bounded number of frames until it is gone instead.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a price published by the office is what the next quote charges', (
    tester,
  ) async {
    // Hard rule 1, end to end and through the real UI: the price moves and no
    // code does. Since Phase 3 the move happens at the office and arrives by
    // sync, rather than being typed into this handset — that is the whole
    // point, because six handsets each holding their own edited list is six
    // handsets quoting six different prices at one fair.
    final storage = InMemoryRateCardStorage();
    final store = memoryStore(storage);

    await pumpWithStore(tester, store);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    expect(find.text('RM 552.00'), findsWidgets);

    // The office publishes version 2 and this handset pulls it.
    final published = jsonDecode(cardJson) as Map<String, dynamic>;
    published['version'] = 2;
    for (final rule
        in (published['rules'] as List).cast<Map<String, dynamic>>()) {
      if (rule['id'] == 'night-curtain-lo') rule['rate_sen'] = 5000;
    }
    await store.adoptServerCard(
      PriceList.fair,
      published,
      at: DateTime.utc(2026, 8, 29),
    );

    // Unmounted first. Pumping another ProviderScope at the same position
    // updates the existing one rather than replacing it, so its cached card
    // would survive and this would silently test nothing.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    // 12ft x RM50, on the quote that was already saved. The price moved and no
    // code did, and it survives a restart because it is stored rather than
    // held in memory.
    await pumpWithStore(tester, memoryStore(storage));
    expect(find.text('RM 600.00'), findsWidgets);
    expect(find.text('RM 552.00'), findsNothing);
  });

  testWidgets('with nobody signed in, prices are read-only', (tester) async {
    // §3 and Phase 3: staff see rates and cannot edit them, and the editing
    // controls are not there to be found. The server refuses too — this is the
    // courtesy, not the control.
    await pumpWithStore(tester, memoryStore(InMemoryRateCardStorage()));
    await tester.tap(find.byIcon(Icons.price_change_outlined));
    await tester.pumpAndSettle();

    expect(find.text('改单项价格'), findsNothing);
    expect(find.text('发布给所有人'), findsNothing);
    expect(find.text('只有公司可以更改价格。'), findsOneWidget);
    // The honest line about where today's prices came from is still there.
    expect(find.textContaining('随程序附带'), findsOneWidget);
  });

  testWidgets('a quote survives a force-quit and reopens with its lines', (
    tester,
  ) async {
    // Phase 2 acceptance: "Quote survives force-quit, reopens at the exact
    // window." A dropped phone mid-fair must cost nothing.
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
      category: '百叶 / 卷帘',
      product: '遮光卷帘',
      width: "5'",
      height: "6'",
    );
    expect(find.text('RM 552.00'), findsWidgets);

    // The force-quit: tear the whole widget tree down, losing every provider
    // and all in-memory state. Only the database survives, exactly as it would
    // if Android killed the process.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(find.text('RM 552.00'), findsNothing);

    // Reopening.
    await pumpApp(tester);

    expect(find.text('客厅'), findsOneWidget);
    expect(find.text('主人房'), findsOneWidget);
    expect(find.text('RM 552.00'), findsWidgets);
    expect(find.text('RM 270.00'), findsWidgets, reason: '30 sqft x RM9');
  });

  testWidgets('an MVP quote reopens as an MVP quote after a force-quit', (
    tester,
  ) async {
    // The tier lives on the quote row, not in memory. Losing it on restart
    // would silently reprice an MVP customer at standard rates.
    await pumpApp(tester);
    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    await tester.tap(find.text('普通价'));
    await tester.pumpAndSettle();
    expect(find.text('RM 480.00'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester);

    expect(find.text('RM 480.00'), findsWidgets);
    expect(find.text('RM 552.00'), findsNothing);
  });

  testWidgets('a November walk-in is quoted standard prices, not fair', (
    tester,
  ) async {
    // §3: the showroom pays standard, no promo, no lock. The date decides,
    // not a switch someone has to remember. RM46 becomes RM55.20, so the same
    // 12ft curtain is RM662.40 rather than RM552.
    var dir = Directory.current;
    while (!File('${dir.path}/shared/rate-card-standard.json').existsSync()) {
      dir = dir.parent;
    }
    final standardJson = File(
      '${dir.path}/shared/rate-card-standard.json',
    ).readAsStringSync();

    final store = RateCardStore(
      storage: InMemoryRateCardStorage(),
      bundled: (list) async => list == PriceList.fair ? cardJson : standardJson,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          rateCardStoreProvider.overrideWithValue(store),
          todayProvider.overrideWithValue(DateTime(2026, 11, 15)),
        ],
        child: const MilanQuoteApp(),
      ),
      duration: Duration.zero,
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();

    expect(find.text('平时价（非展会）'), findsOneWidget);
    expect(find.textContaining('MITC-2026-08'), findsNothing);

    await addWindow(
      tester,
      room: '客厅',
      category: '窗帘',
      product: '夜帘（遮光）',
      width: "12'",
      height: "9'",
    );
    expect(find.text('RM 662.40'), findsWidgets);
    expect(find.text('RM 552.00'), findsNothing);
  });

  testWidgets('the fair banner names the promo and its dates', (tester) async {
    // Always on screen, so whoever is holding the phone knows which list they
    // are showing the customer. The difference is 20% on curtains.
    await pumpApp(tester, today: DateTime(2026, 8, 29));
    expect(find.textContaining('MITC-2026-08'), findsOneWidget);
    expect(find.textContaining('31 Aug 2026'), findsOneWidget);
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
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeRateCardProvider.overrideWith(
            (ref) async => ActiveRateCard(card: standIn, list: PriceList.fair),
          ),
          todayProvider.overrideWithValue(duringFair),
        ],
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
    await tester.scrollUntilVisible(
      find.textContaining('sama atau lebih rendah'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('sama atau lebih rendah'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(find.text('Quotation'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('same or lower'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
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
