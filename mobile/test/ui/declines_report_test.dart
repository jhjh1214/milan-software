/// The declined-deposit report on screen. SPEC.md §6.2, §11 Phase 4.
///
/// The arithmetic is pure and tested in `test/pricing/declines_report_test.dart`.
/// What is checked here is the part only a screen can get wrong: that the number
/// the report exists for is the one on it, that a dismissal is not presented as
/// a refusal, and that a quiet week is distinguishable from a screen that failed
/// to load.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/features/order/declines_report_screen.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/l10n/app_localizations.dart';

void main() {
  late AppDatabase db;

  // Thursday 27 August 2026; its week runs Monday the 24th to Monday the 31st.
  final thursday = DateTime(2026, 8, 27, 11);
  final monday = DateTime(2026, 8, 24);
  final nextMonday = DateTime(2026, 8, 31);

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  var seq = 0;
  Future<void> asked(
    String choice, {
    String category = 'curtain',
    int subtotalSen = 55200,
    DateTime? at,
  }) => db
      .into(db.depositPrompts)
      .insert(
        DepositPromptsCompanion.insert(
          id: 'p-${seq++}',
          quoteId: 'q1',
          category: category,
          choice: choice,
          categorySubtotalSen: Value(subtotalSen),
          at: at ?? thursday,
        ),
      );

  Future<void> pumpScreen(WidgetTester tester, {Locale? locale}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          todayProvider.overrideWithValue(thursday),
        ],
        child: MaterialApp(
          locale: locale ?? const Locale('en'),
          localizationsDelegates: L.localizationsDelegates,
          supportedLocales: L.supportedLocales,
          home: const DeclinesReportScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a week nobody was asked in says so in words', (tester) async {
    // An empty list reads as "failed to load". A week in which the question
    // was never put is a real answer and has to look like one.
    await pumpScreen(tester);
    expect(
      find.text('Nobody was asked for a deposit in this period.'),
      findsOneWidget,
    );
  });

  testWidgets('the headline is what was left on the table', (tester) async {
    // Not the count. A report that only counted refusals would say a stall
    // had a bad day without saying what it cost.
    await asked('declined', subtotalSen: 55200);
    await asked('dismissed', subtotalSen: 30000);
    await asked('collected', subtotalSen: 100000);
    await pumpScreen(tester);

    expect(find.text('RM 852.00 quoted and not deposited on'), findsOneWidget);
  });

  testWidgets('a dismissal is shown apart from a refusal', (tester) async {
    // "They said no" and "nobody got an answer" are different problems, and
    // only one of them is the customer's.
    await asked('declined');
    await asked('dismissed');
    await pumpScreen(tester);

    expect(find.text('1 said no'), findsOneWidget);
    expect(find.text('1 never answered'), findsOneWidget);
  });

  testWidgets('the take rate leaves dismissals out', (tester) async {
    // Two collected, one declined, three never answered. 2 of 3 answers were
    // money; counting the dismissals would report 33% and blame the customer
    // for a conversation that never finished.
    await asked('collected');
    await asked('collected');
    await asked('declined');
    for (var i = 0; i < 3; i++) {
      await asked('dismissed');
    }
    await pumpScreen(tester);

    expect(find.text('67% of the answers were money'), findsOneWidget);
  });

  testWidgets('a week where nothing was answered shows no take rate', (
    tester,
  ) async {
    // Zero percent is a claim about a day's selling. "Nobody answered" is not.
    await asked('dismissed');
    await pumpScreen(tester);

    expect(find.textContaining('of the answers were money'), findsNothing);
    expect(find.text('1 never answered'), findsOneWidget);
  });

  testWidgets('categories are kept apart', (tester) async {
    await asked('collected', category: 'curtain', subtotalSen: 100000);
    await asked('declined', category: 'flooring', subtotalSen: 80000);
    await pumpScreen(tester);

    expect(find.text('RM 0.00 quoted and not deposited on'), findsOneWidget);
    expect(find.text('RM 800.00 quoted and not deposited on'), findsOneWidget);
  });

  testWidgets('the week includes its Monday and excludes the next', (
    tester,
  ) async {
    await asked('declined', at: monday.subtract(const Duration(seconds: 1)));
    await asked('declined', at: monday);
    await asked(
      'declined',
      at: nextMonday.subtract(const Duration(seconds: 1)),
    );
    await asked('declined', at: nextMonday);
    await pumpScreen(tester);

    // Two of the four fall inside: the Monday and the Sunday night.
    expect(find.text('Asked 2 times'), findsOneWidget);
  });

  testWidgets('it reads in Chinese', (tester) async {
    await asked('declined');
    await pumpScreen(tester, locale: const Locale('zh'));
    expect(find.text('问过的订金'), findsOneWidget);
    expect(find.text('1 单说不要'), findsOneWidget);
  });
}
