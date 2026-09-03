/// The category prompt, through the real widgets. SPEC.md §6.2.
///
/// > This is the moment the second RM300 gets collected, and it is almost
/// > certainly being missed at fairs today.
///
/// So this file is about the money: that the question gets asked, that pressing
/// the button opens a real hold, that saying no is written down, and that a
/// showroom quote is never asked at all — because a deposit taken there locks
/// nothing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/app.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/lock_repository.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RateCard card;
  final duringFair = DateTime(2026, 8, 29);

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

  Future<void> pumpApp(WidgetTester tester, {required Channel channel}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeRateCardProvider.overrideWith(
            (ref) async => ActiveRateCard(
              card: card,
              // The card the customer is shown is the fair one either way; the
              // channel is what decides whether an RM300 can hold it.
              list: PriceList.fair,
              channel: channel,
            ),
          ),
          todayProvider.overrideWithValue(duringFair),
        ],
        child: const MilanQuoteApp(),
      ),
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
  }

  Future<void> addACurtain(WidgetTester tester) async {
    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('窗帘'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('夜帘（遮光）'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('夜帘（遮光）'));
    await tester.pumpAndSettle();

    for (final key in ['1', '2', '尺']) {
      await tester.tap(find.widgetWithText(InkWell, key).last);
      await tester.pump();
    }
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    for (final key in ['9', '尺']) {
      await tester.tap(find.widgetWithText(InkWell, key).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    if (find.text('不用，就这样').evaluate().isNotEmpty) {
      await tester.tap(find.text('不用，就这样'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('at a fair, the RM300 gets asked for', (tester) async {
    // The feature. Before this the question depended on a part-timer
    // remembering to ask, which §6.2 says is where the money is going.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);

    expect(find.textContaining('这单有窗帘'), findsOneWidget);
    expect(find.text('收 RM 300.00'), findsOneWidget);
    expect(find.text('不锁价，照今天的价'), findsOneWidget);
    expect(find.text('取消窗帘'), findsOneWidget);
  });

  testWidgets('in the showroom, it is never asked', (tester) async {
    // Client, Sep 2026: "no second rm300 paid later in showroom, only depo at
    // fair can lock price." Collecting RM300 for a hold that will not exist is
    // worse than not asking.
    await pumpApp(tester, channel: Channel.showroom);
    await addACurtain(tester);

    expect(find.textContaining('这单有'), findsNothing);
  });

  testWidgets('taking the RM300 opens a twelve-month hold', (tester) async {
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);

    await tester.tap(find.text('收 RM 300.00'));
    await tester.pumpAndSettle();

    final locks = await LockRepository(db).locksFor(
      // Until Phase 4's customer record exists, the quote is its own customer.
      (await db.latestQuote())!.id,
    );
    expect(locks, hasLength(1));
    expect(locks.single.category, DepositCategory.curtain);
    expect(locks.single.heldRateCardVersion, card.version);
    expect(
      locks.single.heldUntil,
      DateTime(2027, 8, 29),
      reason: 'twelve months from the deposit',
    );
    expect(locks.single.isActiveOn(DateTime(2027, 8, 29)), isTrue);
  });

  testWidgets('saying no opens nothing, and is written down', (tester) async {
    // The declined-deposit report is what tells the boss what fairs are
    // leaving on the table, and it only exists if a decline is recorded as
    // deliberately as a sale.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);

    await tester.tap(find.text('不锁价，照今天的价'));
    await tester.pumpAndSettle();

    final repo = LockRepository(db);
    final quoteId = (await db.latestQuote())!.id;
    expect(await repo.locksFor(quoteId), isEmpty);

    final prompts = await repo.promptsFor(quoteId);
    expect(prompts, hasLength(1));
    expect(prompts.single.choice, 'declined');
    expect(
      prompts.single.categorySubtotalSen,
      55200,
      reason: 'what was left on the table, not just that somebody said no',
    );
  });

  testWidgets('a declined category is not asked about again', (tester) async {
    // Asking a customer who already said no, three windows later, is how a
    // part-timer ends up not asking at all.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);
    await tester.tap(find.text('不锁价，照今天的价'));
    await tester.pumpAndSettle();

    await addACurtain(tester);
    expect(find.textContaining('这单有窗帘'), findsNothing);
  });

  testWidgets('a paid category is not asked about again', (tester) async {
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);
    await tester.tap(find.text('收 RM 300.00'));
    await tester.pumpAndSettle();

    // Let the confirmation clear. It is worth showing — it is the only thing
    // that tells the salesperson the hold was actually opened — but it covers
    // the bottom of the screen while it is up.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await addACurtain(tester);
    expect(find.textContaining('这单有窗帘'), findsNothing);
  });

  testWidgets('cancelling takes the lines back off the quote', (tester) async {
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);
    expect(find.text('RM 552.00'), findsWidgets);

    await tester.tap(find.text('取消窗帘'));
    await tester.pumpAndSettle();

    expect(find.text('RM 552.00'), findsNothing);
  });

  testWidgets('dismissing it is recorded, and asks again next time', (
    tester,
  ) async {
    // "They said no" and "nobody asked properly" are different problems, and
    // only one of them is the customer's.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);

    // Tapping the scrim dismisses a modal bottom sheet.
    await tester.tapAt(const Offset(400, 60));
    await tester.pumpAndSettle();

    final repo = LockRepository(db);
    final quoteId = (await db.latestQuote())!.id;
    expect((await repo.promptsFor(quoteId)).single.choice, 'dismissed');
    expect(await repo.answeredOn(quoteId), isEmpty);

    await addACurtain(tester);
    expect(
      find.textContaining('这单有窗帘'),
      findsOneWidget,
      reason: 'the question is still live',
    );
  });
}
