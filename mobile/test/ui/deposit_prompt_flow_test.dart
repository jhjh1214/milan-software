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
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/data/lock_repository.dart';
import 'package:milan_quote/data/order_repository.dart';
import 'package:milan_quote/data/payment_repository.dart';
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
    // §6.4: how it was paid, before anything is written. The cash-up is
    // expected-versus-held per method, so this cannot be skipped.
    await tester.tap(find.text('现金'));
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

  testWidgets('the RM300 is recorded as money, not only as a hold', (
    tester,
  ) async {
    // §6.4. A hold with no payment behind it is money nobody can find at the
    // end of the day, and the cash-up is what finds it.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);

    await tester.tap(find.text('收 RM 300.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷卡'));
    await tester.pumpAndSettle();

    final quoteId = (await db.latestQuote())!.id;
    final payments = await PaymentRepository(db).forQuote(quoteId);

    expect(payments, hasLength(1));
    expect(payments.single.amountSen, 30000);
    expect(payments.single.method, 'card_terminal');
    expect(payments.single.kind, 'deposit');
    expect(
      payments.single.receiptNo,
      isNull,
      reason: 'the server issues it; the device never invents one',
    );
    expect(
      payments.single.categoryLockId,
      isNotNull,
      reason: 'tied to the hold it bought, so a refund can find it',
    );

    final day = await PaymentRepository(db).cashUp(duringFair);
    expect(day.expectedTotal.sen, 30000);
  });

  testWidgets('the deposit confirms the quote as an order', (tester) async {
    // §3: "ORDER IS CONFIRMED. Not a quote, not a lead. A confirmed sale."
    // The deposit is the only thing that does it — there is no confirm button.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);

    final quoteId = (await db.latestQuote())!.id;
    final orders = OrderRepository(db);
    expect(
      await orders.forQuote(quoteId),
      isNull,
      reason: 'a quote with no money against it is still a quote',
    );

    await tester.tap(find.text('收 RM 300.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('现金'));
    await tester.pumpAndSettle();

    final order = await orders.forQuote(quoteId);
    expect(order, isNotNull);
    expect(
      order!.quoteId,
      quoteId,
      reason: 'the quote is referenced, not consumed',
    );
    expect(order.channel, 'fair');
    expect(order.status, 'confirmed');
    expect(order.estimateTotalSen, 55200);
    expect(order.depositPaidSen, 30000);
    expect(order.balanceDueSen, 25200);
    expect(
      order.orderNo,
      isNull,
      reason: 'server-issued, like a receipt number',
    );
    expect(
      order.hasUnmeasuredLines,
      isTrue,
      reason: 'everything is an estimate until a tape goes near it',
    );
  });

  testWidgets('the quote survives conversion untouched', (tester) async {
    // Client, Sep 2026: "the quote should be recorded as reference to the
    // order, so have rough estimate of what to do." The measurement team reads
    // it, and §6.3's variance report compares the final against it.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);
    await tester.tap(find.text('收 RM 300.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('现金'));
    await tester.pumpAndSettle();

    final quoteId = (await db.latestQuote())!.id;
    final quoteLines = await db.linesFor(quoteId);
    expect(quoteLines, hasLength(1), reason: 'the quote still has its line');

    final order = (await OrderRepository(db).forQuote(quoteId))!;
    final orderLines = await OrderRepository(db).linesOf(order.id);

    expect(orderLines, hasLength(1));
    expect(orderLines.single.quoteLineId, quoteLines.single.id);
    expect(
      orderLines.single.id,
      isNot(quoteLines.single.id),
      reason: 'a copy, so editing one cannot change the other',
    );
    expect(orderLines.single.estWidthTmm, 36576);
    expect(orderLines.single.appliedRuleId, 'night-curtain-lo');
    expect(orderLines.single.rateSen, 4600);
    expect(orderLines.single.lineTotalSen, 55200);
  });

  testWidgets('a second deposit adds to the order, not another one', (
    tester,
  ) async {
    // Two categories at one stall is a normal afternoon. It is one sale.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);
    await tester.tap(find.text('收 RM 300.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('现金'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    final quoteId = (await db.latestQuote())!.id;
    final order = (await OrderRepository(db).forQuote(quoteId))!;

    await OrderRepository(db).recordFurtherPayment(
      orderId: order.id,
      amount: Money.sen(30000),
      at: duringFair,
    );

    final updated = (await OrderRepository(db).forQuote(quoteId))!;
    expect(updated.id, order.id, reason: 'one quote confirms once');
    expect(updated.depositPaidSen, 60000);
    expect(
      updated.estimateTotalSen,
      55200,
      reason: 'the estimate never moves; it is what was quoted',
    );
    expect(
      updated.balanceDueSen,
      0,
      reason: 'overpaid owes nothing, not a negative that reads as a refund',
    );

    final history = await OrderRepository(db).historyOf(order.id);
    expect(history.map((e) => e.event), ['confirmed', 'payment_taken']);
  });

  testWidgets('declining leaves it a quote', (tester) async {
    // No money, no order. Calling it confirmed would put it on the production
    // board with nothing paid against it.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);
    await tester.tap(find.text('不锁价，照今天的价'));
    await tester.pumpAndSettle();

    final quoteId = (await db.latestQuote())!.id;
    expect(await OrderRepository(db).forQuote(quoteId), isNull);
  });

  testWidgets('backing out at the method step records nothing', (tester) async {
    // The customer changed their mind at the till. Nothing should be written:
    // a payment that did not happen is worse than no payment at all.
    await pumpApp(tester, channel: Channel.fair);
    await addACurtain(tester);

    await tester.tap(find.text('收 RM 300.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final quoteId = (await db.latestQuote())!.id;
    expect(await PaymentRepository(db).forQuote(quoteId), isEmpty);
    expect(await LockRepository(db).locksFor(quoteId), isEmpty);
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
    // §6.4: how it was paid, before anything is written. The cash-up is
    // expected-versus-held per method, so this cannot be skipped.
    await tester.tap(find.text('现金'));
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
