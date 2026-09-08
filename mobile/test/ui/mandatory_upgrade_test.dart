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

/// A required add-on is added by the app, not by remembering to tick it.
///
/// Client, Sep 2026: the stainless steel side guide is a **must** on an
/// outdoor roller blind — it is what the blind runs in — and it is still
/// charged at RM400 a set. Left as an optional tick box it is RM400 the shop
/// eats on the one product that cannot go up without it, and a part-timer at a
/// fair is exactly who forgets.
///
/// Driven through the real widgets, because the whole claim is about what
/// happens when nobody taps anything. A test that called `_addUpgrade` would
/// prove the method works and say nothing about whether it is ever reached.
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

  /// Walks the wizard to the upgrade step for one product and stops there.
  Future<void> reachUpgrades(
    WidgetTester tester, {
    required String family,
    required String product,
  }) async {
    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(family));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text(product),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(product));
    await tester.pumpAndSettle();

    await typeOnKeypad(tester, "8'");
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    await typeOnKeypad(tester, "6'");
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  }

  /// Every variant on the quote, in the order the lines were written.
  Future<List<String>> variantsOnTheQuote() async {
    final quotes = await db.select(db.quotes).get();
    if (quotes.isEmpty) return const [];
    final lines = await db.linesFor(quotes.first.id);
    return lines.map((l) => l.variant).toList();
  }

  testWidgets('an outdoor roller blind arrives with its side guide', (
    tester,
  ) async {
    await pumpApp(tester);
    await reachUpgrades(tester, family: '百叶 / 卷帘', product: '户外卷帘布');

    // Nobody has tapped an upgrade. The line is there because the blind
    // cannot be installed without it.
    expect(await variantsOnTheQuote(), [
      'outdoor_roller_fabric',
      'side_guide_cable',
    ]);
  });

  testWidgets('it says why it is there, rather than offering it', (
    tester,
  ) async {
    await pumpApp(tester);
    await reachUpgrades(tester, family: '百叶 / 卷帘', product: '户外卷帘布');

    expect(find.text('这个产品一定要配，价钱已算在下面'), findsOneWidget);
  });

  testWidgets('tapping it does not take it off the quote', (tester) async {
    // A tap that removed it would quote a blind nobody can install, and the
    // person tapping would have no way of knowing.
    await pumpApp(tester);
    await reachUpgrades(tester, family: '百叶 / 卷帘', product: '户外卷帘布');

    await tester.tap(find.text('不锈钢侧导线（左右）'));
    await tester.pumpAndSettle();

    expect(await variantsOnTheQuote(), contains('side_guide_cable'));
  });

  testWidgets('a product with no required add-on gets no extra line', (
    tester,
  ) async {
    // The flag must not spread. §4.1: the wizard offers, the customer chooses,
    // and auto-adding a track would put RM9–10/ft on every curtain.
    await pumpApp(tester);
    await reachUpgrades(tester, family: '窗帘', product: '夜帘（遮光）');

    expect(await variantsOnTheQuote(), ['night_curtain']);
  });

  group('a motorised curtain brings its track', () {
    // Client, Sep 2026: "for the motorised track should be auto added". RM40
    // a running foot, on the curtain's own width. A motor with no track is a
    // motor with nothing to drive, and the person who forgets is the one at a
    // fair with a customer waiting.

    Future<void> tapMotor(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.text('马达'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('马达'));
      await tester.pumpAndSettle();
    }

    testWidgets('choosing the motor adds the motor track too', (tester) async {
      await pumpApp(tester);
      await reachUpgrades(tester, family: '窗帘', product: '夜帘（遮光）');
      await tapMotor(tester);

      expect(await variantsOnTheQuote(), [
        'night_curtain',
        'motor',
        'motor_track',
      ]);
    });

    testWidgets('taking the motor off takes its track with it', (tester) async {
      // Otherwise the quote keeps RM40 a foot for a track driving nothing,
      // and it is the line nobody looks at twice.
      await pumpApp(tester);
      await reachUpgrades(tester, family: '窗帘', product: '夜帘（遮光）');
      await tapMotor(tester);
      expect(await variantsOnTheQuote(), hasLength(3));

      await tapMotor(tester);

      expect(await variantsOnTheQuote(), ['night_curtain']);
    });
  });
}
