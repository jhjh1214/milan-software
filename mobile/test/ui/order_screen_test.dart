/// The order screen, driven the way somebody in the shop would. SPEC.md §6.3.
///
/// What is checked here is what a person actually sees: which stage the job is
/// at, that one button moves it on, that a refusal comes back as a sentence
/// they can act on rather than an error, and that cancelling asks for a reason
/// and says what happens to the deposit.
///
/// Nothing here re-tests the rules. Which move is legal lives in
/// `pricing/order_status.dart` and is checked against the shared fixtures.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/features/order/order_screen.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/l10n/app_localizations.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/sync_state.dart';

/// A signed-in session, without the Keystore the real notifier reads from.
class _Signed extends CredentialsNotifier {
  _Signed(this._who);

  final Credentials? _who;

  @override
  Future<Credentials?> build() async => _who;
}

const admin = Credentials(
  token: 't',
  user: Identity(id: 'u-boss', name: 'Boss', role: 'admin', language: 'en'),
);

const partTimer = Credentials(
  token: 't',
  user: Identity(
    id: 'u-ah-lian',
    name: 'Ah Lian',
    role: 'parttime',
    language: 'en',
  ),
);

void main() {
  late AppDatabase db;

  final at = DateTime(2026, 8, 29, 14);
  const orderId = 'o1';
  const lineId = 'l1';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q1',
            rateCardVersion: 1,
            channel: const Value('fair'),
            createdAt: at,
            updatedAt: at,
          ),
        );
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: orderId,
            quoteId: 'q1',
            channel: 'fair',
            pinnedRateCardVersion: 1,
            customerName: const Value('Ah Lian'),
            estimateTotalSen: 55200,
            depositPaidSen: const Value(30000),
            confirmedAt: at,
          ),
        );
    await db
        .into(db.orderLines)
        .insert(
          OrderLinesCompanion.insert(
            id: lineId,
            orderId: orderId,
            quoteLineId: 'ql1',
            sortOrder: 0,
            room: 'Living room',
            variant: 'night_curtain_sfold',
            layer: 'night',
            estWidthTmm: const Value(36576),
            appliedRuleId: 'rule-1',
            appliedRateCardVersion: 1,
            standardRateSen: 4600,
            rateSen: 4600,
            billedQty: '12',
            billedUnit: 'ft',
            lineTotalSen: 55200,
          ),
        );
    await db
        .into(db.orderEvents)
        .insert(
          OrderEventsCompanion.insert(
            id: 'ev1',
            orderId: orderId,
            event: 'confirmed',
            at: at,
          ),
        );
  });

  tearDown(() => db.close());

  Future<void> pumpScreen(
    WidgetTester tester, {
    Locale? locale,
    Credentials? signedInAs,
  }) async {
    // A phone, not the 800x600 default. The order screen is a working list —
    // status, actions, lines, history — and on the default surface the lines
    // fall below the fold, which is a test artefact rather than anything a
    // person holding a handset would meet.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          todayProvider.overrideWithValue(at),
          credentialsProvider.overrideWith(() => _Signed(signedInAs)),
        ],
        child: MaterialApp(
          locale: locale ?? const Locale('en'),
          localizationsDelegates: L.localizationsDelegates,
          supportedLocales: L.supportedLocales,
          home: const OrderScreen(orderId: orderId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> measureEverything() =>
      (db.update(db.orderLines)..where((l) => l.orderId.equals(orderId))).write(
        const OrderLinesCompanion(isSiteMeasured: Value(true)),
      );

  testWidgets('it says where the order is and what comes next', (tester) async {
    await pumpScreen(tester);

    // Twice on purpose: the chip says where the order is now, and the history
    // says how it got there. Both are worth having on one screen.
    expect(find.text('Confirmed'), findsNWidgets(2));
    expect(find.text('Ah Lian'), findsOneWidget);
    expect(find.text('RM 552.00'), findsWidgets);
    expect(find.text('Mark as Measurement booked'), findsOneWidget);
  });

  testWidgets('a missing order number says so rather than showing a blank', (
    tester,
  ) async {
    // A blank reads as a bug, and a number invented here would collide with
    // every other handset offline at the same fair.
    await pumpScreen(tester);
    expect(find.text('Order number pending sync'), findsOneWidget);
  });

  testWidgets('the issued number replaces the pending line', (tester) async {
    await db.settleOrder(orderId: orderId, orderNo: 'MLK-2608-0001', at: at);
    await pumpScreen(tester);

    expect(find.text('MLK-2608-0001'), findsOneWidget);
    expect(find.text('Order number pending sync'), findsNothing);
  });

  testWidgets('the button moves the order on, and the history follows', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Mark as Measurement booked'));
    await tester.pumpAndSettle();

    expect(find.text('Measurement booked'), findsWidgets);
    expect(find.text('Mark as Measured'), findsOneWidget);

    final events = await (db.select(
      db.orderEvents,
    )..where((e) => e.orderId.equals(orderId))).get();
    expect(events.map((e) => e.event), ['confirmed', 'measurement_booked']);
  });

  testWidgets('a refusal is a sentence somebody can act on', (tester) async {
    // "Some windows still have no measurements" tells a measurer what to do.
    // A red exception does not.
    await pumpScreen(tester);
    await tester.tap(find.text('Mark as Measurement booked'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark as Measured'));
    await tester.pumpAndSettle();

    expect(
      find.text('Some windows still have no measurements.'),
      findsOneWidget,
    );
    expect(find.text('Mark as Measured'), findsOneWidget);

    await measureEverything();
    await pumpScreen(tester);
    await tester.tap(find.text('Mark as Measured'));
    await tester.pumpAndSettle();
    expect(find.text('Mark as Material chosen'), findsOneWidget);
  });

  testWidgets('cancelling asks for a reason and says where the money stands', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Cancel this order'));
    await tester.pumpAndSettle();

    expect(find.text('Cancel this order?'), findsOneWidget);
    expect(
      find.textContaining('The deposit stays on the record'),
      findsOneWidget,
      reason:
          'going quiet about the money leaves somebody guessing whether '
          'cancelling refunded it',
    );

    // Nothing to cancel with until a real reason is written.
    final confirm = find.widgetWithText(FilledButton, 'Cancel the order');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'ord');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'customer bought elsewhere');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    final order = await (db.select(
      db.orders,
    )..where((o) => o.id.equals(orderId))).getSingle();
    expect(order.status, 'cancelled');
    expect(
      order.depositPaidSen,
      30000,
      reason:
          '§13 B3 is unanswered; zeroing it would be a decision nobody made',
    );

    final events = await (db.select(
      db.orderEvents,
    )..where((e) => e.orderId.equals(orderId))).get();
    expect(events.last.note, 'customer bought elsewhere');
  });

  testWidgets('keeping it changes nothing', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Cancel this order'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'customer bought elsewhere');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Keep it'));
    await tester.pumpAndSettle();

    final order = await (db.select(
      db.orders,
    )..where((o) => o.id.equals(orderId))).getSingle();
    expect(order.status, 'confirmed');
  });

  testWidgets('a cancelled order offers nothing further', (tester) async {
    await (db.update(db.orders)..where((o) => o.id.equals(orderId))).write(
      const OrdersCompanion(status: Value('cancelled')),
    );
    await pumpScreen(tester);

    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Cancel this order'), findsNothing);
    expect(find.textContaining('Mark as'), findsNothing);
    expect(find.textContaining('Nothing left to do'), findsOneWidget);
  });

  testWidgets('an overridden line says so on its face', (tester) async {
    // §6.5: the marker is visible on screen and on the printed quote, and is
    // never cleared.
    await (db.update(db.orderLines)..where((l) => l.id.equals(lineId))).write(
      const OrderLinesCompanion(isOverridden: Value(true)),
    );
    await pumpScreen(tester);
    expect(find.text('Price changed by hand'), findsOneWidget);
  });

  testWidgets('it reads in Chinese', (tester) async {
    // §8: no string is ever hardcoded in a widget, and the default is zh.
    await pumpScreen(tester, locale: const Locale('zh'));
    expect(find.text('已确认'), findsNWidgets(2));
    expect(find.text('标记为已约量尺'), findsOneWidget);
    expect(find.text('取消这张订单'), findsOneWidget);
  });

  testWidgets('it reads in Malay', (tester) async {
    // A part-timer who reads only Malay has to be able to work this screen.
    await pumpScreen(tester, locale: const Locale('ms'));
    expect(find.text('Disahkan'), findsNWidgets(2));
    expect(find.text('Tandakan sebagai Ukuran ditempah'), findsOneWidget);
    expect(find.text('Batalkan pesanan ini'), findsOneWidget);
  });

  group('overriding a price', () {
    testWidgets('an admin can, and the change is recorded against them', (
      tester,
    ) async {
      await pumpScreen(tester, signedInAs: admin);
      await tester.tap(find.text('Living room'));
      await tester.pumpAndSettle();

      expect(find.text('Change this price'), findsOneWidget);
      expect(
        find.textContaining('recorded against your name'),
        findsOneWidget,
        reason: '§6.5: the sentence is the deterrent, not the gate',
      );

      // Pre-filled with what it is now, so knocking RM50 off is an edit rather
      // than typing a price from memory.
      expect(find.widgetWithText(TextField, '552.00'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '552.00'),
        '500.00',
      );
      await tester.pumpAndSettle();

      final apply = find.widgetWithText(FilledButton, 'Change it');
      expect(
        tester.widget<FilledButton>(apply).onPressed,
        isNull,
        reason: 'no reason written yet',
      );

      await tester.enterText(
        find.byType(TextField).last,
        'matched a competitor quote',
      );
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await tester.pumpAndSettle();

      final line = (await db.select(db.orderLines).get()).single;
      expect(line.lineTotalSen, 50000);
      expect(line.isOverridden, isTrue);

      final audit = (await db.select(db.priceOverrides).get()).single;
      expect(audit.beforeSen, 55200);
      expect(audit.afterSen, 50000);
      expect(audit.reason, 'matched a competitor quote');
      expect(audit.adminUserId, 'u-boss');

      expect(find.text('Price changed by hand'), findsOneWidget);
    });

    testWidgets('a part-timer is not even offered it', (tester) async {
      // Hard rule 8: a part-timer never sees a rate, a cost or a margin, and
      // never a control for changing one. The rule refuses them anyway; not
      // showing the tap target is so nobody is invited to try.
      await pumpScreen(tester, signedInAs: partTimer);
      await tester.tap(find.text('Living room'));
      await tester.pumpAndSettle();

      expect(find.text('Change this price'), findsNothing);
      expect((await db.select(db.priceOverrides).get()), isEmpty);
    });

    testWidgets('a price that has not moved cannot be applied', (tester) async {
      // A row saying RM552 became RM552 is noise, and noise is what stops the
      // weekly review being read at all.
      await pumpScreen(tester, signedInAs: admin);
      await tester.tap(find.text('Living room'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'checked the card');
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Change it'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('a cancelled order refuses, and says why', (tester) async {
      // The rule is the rule. The button being enabled is only a guess about
      // what it will say, and when the two disagree the rule wins.
      await (db.update(db.orders)..where((o) => o.id.equals(orderId))).write(
        const OrdersCompanion(status: Value('cancelled')),
      );
      await pumpScreen(tester, signedInAs: admin);
      await tester.tap(find.text('Living room'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '500.00');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'matched a competitor quote',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Change it'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Its prices no longer move'), findsOneWidget);
      expect((await db.select(db.priceOverrides).get()), isEmpty);
      expect((await db.select(db.orderLines).get()).single.lineTotalSen, 55200);
    });
  });

  group('where the visit is (§13 C10)', () {
    Future<void> openSite(WidgetTester tester) async {
      await pumpScreen(tester, signedInAs: partTimer);
      await tester.scrollUntilVisible(
        find.byKey(const Key('order-site-row')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('order-site-row')));
      await tester.pumpAndSettle();
    }

    testWidgets('an address sent after the fair is saved and queued', (
      tester,
    ) async {
      await openSite(tester);
      await tester.enterText(
        find.byKey(const Key('site-address')),
        '3 Jalan Bunga',
      );
      await tester.enterText(find.byKey(const Key('site-postcode')), '75450');
      await tester.tap(find.byKey(const Key('site-save')));
      await tester.pumpAndSettle();

      final order = await (db.select(
        db.orders,
      )..where((o) => o.id.equals(orderId))).getSingle();
      expect(order.siteAddress, '3 Jalan Bunga');
      expect(order.sitePostcode, '75450');
      expect(order.siteCapturedAt, isNotNull);

      final queued = await db.pendingOutbox();
      expect(queued.map((r) => r.entityType), contains('site_details'));
      expect(find.textContaining('75450'), findsOneWidget);
    });

    testWidgets('a postcode that is not five digits is not saved', (
      tester,
    ) async {
      await openSite(tester);
      await tester.enterText(find.byKey(const Key('site-postcode')), '7545');
      await tester.tap(find.byKey(const Key('site-save')));
      await tester.pumpAndSettle();

      expect(find.text('A postcode is five digits.'), findsOneWidget);
      final order = await (db.select(
        db.orders,
      )..where((o) => o.id.equals(orderId))).getSingle();
      expect(order.sitePostcode, isNull);
      expect(await db.pendingOutbox(), isEmpty);
    });
  });
}
