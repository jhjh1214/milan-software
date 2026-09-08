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

/// The band-edge nudge must say which side of the edge the entered value is
/// actually on. SPEC.md §5.5 calls this "the highest-value validation in the
/// app" for a reason — a curtain drop wrong by an inch either side of 10ft is
/// a real RM144 swing on a 12ft window, and a message pointing the correction
/// the wrong way is worse than no message.
///
/// A1's fencepost: `band_max_tmm` is the EXCLUSIVE upper bound, so exactly
/// 10ft is still the lower band. `dimension_warnings.dart`'s `isAboveEdge`
/// always computed this correctly — the bug was that the wizard's rendered
/// message hardcoded "just over" regardless of it.
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

  /// Reaches the night curtain sizes step, types the width, and focuses the
  /// height field ready for a drop to be typed.
  Future<void> reachHeightField(WidgetTester tester) async {
    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('窗帘'));
    await tester.pumpAndSettle();

    const product = '夜帘（遮光）';
    await tester.scrollUntilVisible(
      find.text(product),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(product));
    await tester.pumpAndSettle();

    await typeOnKeypad(tester, "6'");
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
  }

  testWidgets('exactly 10ft is reported as under the edge, not over it', (
    tester,
  ) async {
    await pumpApp(tester);
    await reachHeightField(tester);

    // band_max_tmm is 30481 (A1's fencepost) — exactly 10ft (30480) is
    // still the lower band, one tenth of a millimetre short of it.
    await typeOnKeypad(tester, "10'");
    await tester.pump();

    expect(find.textContaining('刚刚不到'), findsOneWidget);
    expect(find.textContaining('刚刚超过'), findsNothing);
  });

  testWidgets('genuinely over 10ft is reported as over the edge', (
    tester,
  ) async {
    await pumpApp(tester);
    await reachHeightField(tester);

    await typeOnKeypad(tester, "10'1\"");
    await tester.pump();

    expect(find.textContaining('刚刚超过'), findsOneWidget);
    expect(find.textContaining('刚刚不到'), findsNothing);
  });
}
