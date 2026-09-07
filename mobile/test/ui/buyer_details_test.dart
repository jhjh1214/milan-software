/// Taking the buyer's details, driven the way a measurer would. §10.3, Phase 7.
///
/// The rule (`buyerDetailsComplete`) and the storage landed in Phase 6 and are
/// tested against the shared fixtures. Nothing here re-tests them. What is
/// checked is what a person sees and does:
///
/// * that an order the guard has stopped offers the form rather than a dead
///   end — without it, an order over RM10,000 cannot move and nothing on the
///   handset can supply what the refusal is asking for;
/// * that everything outstanding is stated at once, because §10.2 gives one
///   conversation to collect it in;
/// * that a partial record saves, because half the details now beats nothing;
/// * and that the screen never claims to issue an invoice (hard rule 7).
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/features/order/buyer_details_screen.dart';
import 'package:milan_quote/features/order/order_screen.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/l10n/app_localizations.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/sync_state.dart';

class _Signed extends CredentialsNotifier {
  _Signed(this._who);
  final Credentials? _who;
  @override
  Future<Credentials?> build() async => _who;
}

const _staff = Credentials(
  token: 't',
  user: Identity(id: 'u-1', name: 'Ah Meng', role: 'staff', language: 'en'),
);

void main() {
  late AppDatabase db;

  final at = DateTime(2026, 9, 20, 10);
  const orderId = 'o1';

  /// An order at [totalSen], measured, so the pipeline's own guards are out of
  /// the way and the threshold is the only thing that can stop it.
  Future<void> makeOrder({required int totalSen, bool measured = true}) async {
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
            estimateTotalSen: totalSen,
            finalTotalSen: Value(measured ? totalSen : null),
            status: const Value('measured'),
            depositPaidSen: const Value(30000),
            confirmedAt: at,
          ),
        );
    await db
        .into(db.orderLines)
        .insert(
          OrderLinesCompanion.insert(
            id: 'l1',
            orderId: orderId,
            quoteLineId: 'ql1',
            sortOrder: 0,
            room: 'Living room',
            variant: 'night_curtain',
            layer: 'night',
            estWidthTmm: 36576,
            appliedRuleId: 'night-curtain-lo',
            appliedRateCardVersion: 1,
            standardRateSen: 4600,
            rateSen: 4600,
            billedQty: '12',
            billedUnit: 'ft',
            lineTotalSen: totalSen,
            isSiteMeasured: Value(measured),
            finalWidthTmm: Value(measured ? 36576 : null),
            materialDeferred: const Value(false),
          ),
        );
  }

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, Widget home, {Locale? locale}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          todayProvider.overrideWithValue(at),
          credentialsProvider.overrideWith(() => _Signed(_staff)),
        ],
        child: MaterialApp(
          locale: locale ?? const Locale('en'),
          localizationsDelegates: L.localizationsDelegates,
          supportedLocales: L.supportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String label, String value) async {
    await tester.enterText(find.widgetWithText(TextField, label), value);
    await tester.pump();
  }

  group('what the screen says before it asks', () {
    testWidgets('an order over the threshold is told it is the law', (
      tester,
    ) async {
      // §10.2. The person filling this in is often a part-timer asking a
      // stranger for an IC number. Nine unexplained boxes get abandoned or
      // filled with whatever makes them go away.
      await makeOrder(totalSen: 1200000); // RM12,000
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      expect(
        find.textContaining('This order is over RM 10,000.00'),
        findsOneWidget,
      );
      expect(find.textContaining('cannot issue it to'), findsOneWidget);
    });

    testWidgets('an order NEAR the threshold is warned, in different words', (
      tester,
    ) async {
      // §10.4's timing trap: an order quoted at RM8,500 settles at RM11,200,
      // and by then the customer has gone home. The estimate stage carries the
      // RM8,000 margin; a final is exact and carries none.
      await makeOrder(totalSen: 850000, measured: false);
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      expect(find.textContaining('close to'), findsOneWidget);
      expect(find.textContaining('gone home'), findsOneWidget);
      expect(
        find.textContaining('This order is over'),
        findsNothing,
        reason: 'not over it yet — saying so would be a lie',
      );
    });

    testWidgets('a small order can still be filled in, and says why not', (
      tester,
    ) async {
      // The office taking details early is not a problem, so the screen opens
      // and asks for nothing in particular.
      await makeOrder(totalSen: 55200);
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      expect(find.textContaining('This order is over'), findsNothing);
      expect(find.textContaining('close to'), findsNothing);
      expect(find.text('Save details'), findsOneWidget);
    });
  });

  group('what is still needed', () {
    testWidgets('all of it at once, never one field at a time', (tester) async {
      // §10.2 gives one conversation. A form that reveals the next missing
      // field after each save is a customer asked three times.
      await makeOrder(totalSen: 1200000);
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      // The name came off the order, so only the other two are outstanding.
      expect(find.textContaining('TIN, or an ID number'), findsOneWidget);
      expect(find.textContaining('A full address'), findsOneWidget);
      expect(find.text('Still needed'), findsOneWidget);
    });

    testWidgets('it updates as the form is filled, without saving', (
      tester,
    ) async {
      await makeOrder(totalSen: 1200000);
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      expect(find.textContaining('TIN, or an ID number'), findsOneWidget);
      await type(tester, 'TIN', 'C1234567890');
      expect(
        find.textContaining('TIN, or an ID number'),
        findsNothing,
        reason: 'a TIN alone satisfies the identifier',
      );
      expect(find.textContaining('A full address'), findsOneWidget);
    });

    testWidgets('an ID number with no type does not count as an identifier', (
      tester,
    ) async {
      // The rule's own words: a number with no type cannot be filed. Checked
      // here because the form is where somebody would type one and stop.
      await makeOrder(totalSen: 1200000);
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      await type(tester, 'ID number', '900101015555');
      expect(
        find.textContaining('TIN, or an ID number'),
        findsOneWidget,
        reason: 'still outstanding until the type is chosen',
      );
    });

    testWidgets('a field holding only a space is still missing', (
      tester,
    ) async {
      // A space must not satisfy a legal requirement. The rule trims; this
      // checks the screen asks the rule rather than testing the text itself.
      await makeOrder(totalSen: 1200000);
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      await type(tester, 'TIN', '   ');
      expect(find.textContaining('TIN, or an ID number'), findsOneWidget);
    });

    testWidgets('a complete record says so', (tester) async {
      await makeOrder(totalSen: 1200000);
      await pump(tester, const BuyerDetailsScreen(orderId: orderId));

      await type(tester, 'TIN', 'C1234567890');
      await type(tester, 'Address line 1', '12 Jalan Melaka');
      await type(tester, 'City', 'Melaka');
      await type(tester, 'State', 'Melaka');
      await type(tester, 'Postcode', '75000');
      await tester.pumpAndSettle();

      expect(find.text('Everything needed is here.'), findsOneWidget);
      expect(find.text('Still needed'), findsNothing);
    });
  });

  group('saving', () {
    testWidgets('a partial record saves — half now beats nothing', (
      tester,
    ) async {
      // The customer is standing there. What is captured is captured, and
      // `advanceOrder` is the only thing that should refuse an incomplete one.
      await makeOrder(totalSen: 1200000);
      await pump(
        tester,
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const BuyerDetailsScreen(orderId: orderId),
          ),
        ),
      );

      await type(tester, 'TIN', 'C1234567890');
      await tester.tap(find.text('Save details'));
      await tester.pumpAndSettle();

      final row = await (db.select(
        db.orders,
      )..where((o) => o.id.equals(orderId))).getSingle();
      expect(row.buyerTin, 'C1234567890');
      expect(row.buyerCity, isNull, reason: 'nothing was invented');
    });

    testWidgets('trims on the way in, so a space is stored as absent', (
      tester,
    ) async {
      await makeOrder(totalSen: 1200000);
      await pump(
        tester,
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const BuyerDetailsScreen(orderId: orderId),
          ),
        ),
      );

      await type(tester, 'TIN', '  ');
      await type(tester, 'City', '  Melaka  ');
      await tester.tap(find.text('Save details'));
      await tester.pumpAndSettle();

      final row = await (db.select(
        db.orders,
      )..where((o) => o.id.equals(orderId))).getSingle();
      expect(row.buyerTin, isNull);
      expect(row.buyerCity, 'Melaka');
    });

    testWidgets('the e-invoice request is recorded', (tester) async {
      // §10.3: asked for at any value, so it is a reason to capture on its own.
      await makeOrder(totalSen: 55200);
      await pump(
        tester,
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const BuyerDetailsScreen(orderId: orderId),
          ),
        ),
      );

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Save details'));
      await tester.pumpAndSettle();

      final row = await (db.select(
        db.orders,
      )..where((o) => o.id.equals(orderId))).getSingle();
      expect(row.einvoiceRequested, isTrue);
    });
  });

  group('the way out of a refusal', () {
    testWidgets('a blocked order opens the form rather than dead-ending', (
      tester,
    ) async {
      // Without this the order is stuck: `advanceOrder` refuses to move it and
      // nothing on the handset can supply what the refusal is asking for.
      await makeOrder(totalSen: 1200000);
      await pump(tester, const OrderScreen(orderId: orderId));

      await tester.tap(find.text('Mark as Material chosen'));
      await tester.pumpAndSettle();

      expect(find.text('Customer details for the invoice'), findsOneWidget);
      expect(find.text('Save details'), findsOneWidget);
    });

    testWidgets('the form is reachable without being refused first', (
      tester,
    ) async {
      // An order that crosses RM10,000 only after measurement needs these from
      // a customer who has by then gone home, so taking them early is the
      // behaviour to make easy — and it is the only way to see what is already
      // captured.
      await makeOrder(totalSen: 55200);
      await pump(tester, const OrderScreen(orderId: orderId));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Customer details'));
      await tester.pumpAndSettle();

      expect(find.text('Customer details for the invoice'), findsOneWidget);
    });

    testWidgets('once the details are in, the order moves', (tester) async {
      // The whole point. Proved end to end rather than by asserting the guard
      // separately: the guard was already tested, the hole was the way out.
      await makeOrder(totalSen: 1200000);
      await pump(tester, const OrderScreen(orderId: orderId));

      await tester.tap(find.text('Mark as Material chosen'));
      await tester.pumpAndSettle();

      await type(tester, 'TIN', 'C1234567890');
      await type(tester, 'Address line 1', '12 Jalan Melaka');
      await type(tester, 'City', 'Melaka');
      await type(tester, 'State', 'Melaka');
      await type(tester, 'Postcode', '75000');
      await tester.tap(find.text('Save details'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mark as Material chosen'));
      await tester.pumpAndSettle();

      final row = await (db.select(
        db.orders,
      )..where((o) => o.id.equals(orderId))).getSingle();
      expect(row.status, 'material_selected');
    });
  });

  testWidgets('nothing on the screen claims to issue an invoice', (
    tester,
  ) async {
    // CLAUDE.md hard rule 7 and §10.1. SQL Account is the sole issuer of
    // record. The screen collects details SO THAT the accounts system can
    // issue; it must never present itself as the issuer.
    //
    // Two strings are deliberately outside this list, on the same principle
    // that lets the quotation's disclaimer name a tax invoice: they record
    // what the CUSTOMER asked for. "The customer asked for an e-invoice" is a
    // fact about a request, and the office has to be able to read it — the
    // forbidden thing is this system presenting itself as the issuer, not the
    // word appearing anywhere at all. `buyerWhyRequested` and `buyerRequested`
    // are those two, and both are asserted below to be about the request.
    for (final language in ['zh', 'en', 'ms']) {
      final l = await L.delegate.load(Locale(language));
      final labels = [
        l.buyerTitle,
        l.buyerWhyOverThreshold('RM 10,000.00'),
        l.buyerWhyNearThreshold('RM 10,000.00'),
        l.buyerStillNeeded,
        l.buyerComplete,
        l.buyerName,
        l.buyerIdentifierSection,
        l.buyerIdentifierNote,
        l.buyerAddressSection,
        l.buyerSave,
        l.buyerEdit,
      ].join(' ').toLowerCase();

      expect(labels, isNot(contains('tax invoice')));
      expect(labels, isNot(contains('invois cukai')));
      expect(labels, isNot(contains('税务发票')));
      expect(labels, isNot(contains('电子发票')));

      // Neither excluded string may claim this system issues anything: both
      // name the customer as the one doing the asking.
      for (final requested in [l.buyerWhyRequested, l.buyerRequested]) {
        expect(
          requested.toLowerCase(),
          anyOf(contains('customer'), contains('pelanggan'), contains('客户')),
          reason: '$language: this records a REQUEST, not an issuance',
        );
        expect(requested.toLowerCase(), isNot(contains('tax invoice')));
        expect(requested.toLowerCase(), isNot(contains('税务发票')));
      }

      // The denial says what this app does NOT do.
      expect(l.buyerNotAnInvoice, isNotEmpty);
      final denial = l.buyerNotAnInvoice.toLowerCase();
      expect(
        denial.contains('does not issue invoices') ||
            denial.contains('tidak mengeluarkan invois') ||
            denial.contains('不开发票'),
        isTrue,
        reason: '$language must say plainly that this app does not issue',
      );
    }
  });
}
