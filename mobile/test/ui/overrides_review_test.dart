/// The weekly override review. SPEC.md §6.5.
///
/// > without it the log is never read and the control does not exist
///
/// So the things worth checking are the ones that would quietly make it stop
/// being a control: a row falling outside the week and vanishing, a week with
/// nothing in it looking like a screen that failed to load, and a reason being
/// summarised into something shorter than what was typed.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/features/order/overrides_review_screen.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/l10n/app_localizations.dart';

void main() {
  late AppDatabase db;

  // Thursday 27 August 2026. Its week runs Monday the 24th to Monday the 31st.
  final thursday = DateTime(2026, 8, 27, 11);
  final monday = DateTime(2026, 8, 24);
  final nextMonday = DateTime(2026, 8, 31);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q1',
            rateCardVersion: 1,
            createdAt: thursday,
            updatedAt: thursday,
          ),
        );
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: 'o1',
            quoteId: 'q1',
            channel: 'fair',
            pinnedRateCardVersion: 1,
            estimateTotalSen: 55200,
            confirmedAt: thursday,
          ),
        );
    await db
        .into(db.orderLines)
        .insert(
          OrderLinesCompanion.insert(
            id: 'l1',
            orderId: 'o1',
            quoteLineId: 'ql1',
            sortOrder: 0,
            room: 'Living room',
            variant: 'night_curtain_sfold',
            layer: 'night',
            estWidthTmm: 36576,
            appliedRuleId: 'rule-1',
            appliedRateCardVersion: 1,
            standardRateSen: 4600,
            rateSen: 4600,
            billedQty: '12',
            billedUnit: 'ft',
            lineTotalSen: 55200,
          ),
        );
  });

  tearDown(() => db.close());

  var seq = 0;
  Future<void> record({
    required DateTime at,
    int before = 55200,
    int after = 50000,
    String reason = 'matched a competitor quote',
    String by = 'u-boss',
  }) => db
      .into(db.priceOverrides)
      .insert(
        PriceOverridesCompanion.insert(
          id: 'ov-${seq++}',
          orderLineId: 'l1',
          orderId: 'o1',
          beforeSen: before,
          afterSen: after,
          reason: reason,
          adminUserId: by,
          at: at,
        ),
      );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          todayProvider.overrideWithValue(thursday),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L.localizationsDelegates,
          supportedLocales: L.supportedLocales,
          home: const OverridesReviewScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('the week runs Monday to Monday', () {
    // Monday because that is how the shop talks about a week. Getting this
    // wrong puts a row in two weeks or in neither.
    expect(weekStart(thursday), monday);
    expect(weekStart(monday), monday);
    expect(weekStart(DateTime(2026, 8, 30, 23, 59)), monday);
    expect(weekStart(nextMonday), nextMonday);
  });

  testWidgets('a week with nothing in it says so in words', (tester) async {
    // An empty list reads as "not loaded yet". This screen has to be
    // trustworthy about a week in which nobody changed anything.
    await pumpScreen(tester);
    expect(find.text('Nobody changed a price this week.'), findsOneWidget);
  });

  testWidgets('it shows who, how much, and why', (tester) async {
    // The three questions the review exists to answer. Anything missing makes
    // the row unusable for the conversation it is meant to start.
    await record(at: thursday, reason: 'customer had a competitor quote');
    await pumpScreen(tester);

    expect(find.text('RM 552.00 to RM 500.00, by u-boss'), findsOneWidget);
    expect(find.text('customer had a competitor quote'), findsOneWidget);
    expect(find.text('RM -52.00'), findsOneWidget);
  });

  testWidgets('the reason is shown as typed, not summarised', (tester) async {
    // Shortening it would lose the thing the review exists to read.
    const long =
        'customer had a written quote from the shop across the road and '
        'would have walked, boss approved matching it';
    await record(at: thursday, reason: long);
    await pumpScreen(tester);
    expect(find.text(long), findsOneWidget);
  });

  testWidgets('a price that went up is shown differently', (tester) async {
    // A discount is the ordinary case. A price going up is the one worth a
    // second look, and a week's worth has to be scannable.
    await record(at: thursday, before: 50000, after: 55200);
    await pumpScreen(tester);
    expect(find.text('RM 52.00'), findsOneWidget);
  });

  testWidgets('the week includes its Monday and excludes the next', (
    tester,
  ) async {
    await record(at: monday.subtract(const Duration(seconds: 1)));
    await record(at: monday, reason: 'the monday one');
    await record(at: thursday, reason: 'the thursday one');
    await record(
      at: nextMonday.subtract(const Duration(seconds: 1)),
      reason: 'the sunday night one',
    );
    await record(at: nextMonday, reason: 'next week already');

    await pumpScreen(tester);

    expect(find.text('the monday one'), findsOneWidget);
    expect(find.text('the thursday one'), findsOneWidget);
    expect(find.text('the sunday night one'), findsOneWidget);
    expect(find.text('next week already'), findsNothing);
    expect(find.text('matched a competitor quote'), findsNothing);
  });

  testWidgets('newest first, so the most recent is not scrolled to', (
    tester,
  ) async {
    await record(at: monday, reason: 'the monday one');
    await record(at: thursday, reason: 'the thursday one');
    await pumpScreen(tester);

    final rows = tester.widgetList<Text>(find.byType(Text)).toList();
    final thursdayAt = rows.indexWhere((t) => t.data == 'the thursday one');
    final mondayAt = rows.indexWhere((t) => t.data == 'the monday one');
    expect(thursdayAt, lessThan(mondayAt));
  });
}
