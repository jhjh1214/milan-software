/// Changing a price, and the fair's dates, from the handset — driven through
/// the real rate card screen against a fake server.
///
/// What matters: staff can answer a competitor at the fair table (not only an
/// admin), every change carries a reason to the server's audited route rather
/// than a whole card rebuilt on this phone, the handset pulls the published
/// card straight back, a refusal is SAID rather than swallowed, and only an
/// admin can move the fair's dates — which set how long every deposit holds.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/features/rates/fair_dates_sheet.dart';
import 'package:milan_quote/features/rates/rate_card_screen.dart';
import 'package:milan_quote/l10n/app_localizations.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/sync_state.dart';

import '../sync/fake_server.dart';

Identity _as(String role) =>
    Identity(id: 'u1', name: 'Mei', role: role, language: 'en');

class _Signed extends CredentialsNotifier {
  _Signed(this.identity);
  final Identity identity;

  @override
  Future<Credentials?> build() async =>
      Credentials(token: 'good-token', user: identity);
}

void main() {
  late Map<String, String> shipped;
  late AppDatabase db;
  late FakeServer server;
  late RateCardStore store;

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    shipped = {
      'fair': File(
        '${dir.path}/shared/rate-card-fair-2026-08.json',
      ).readAsStringSync(),
      'standard': File(
        '${dir.path}/shared/rate-card-standard.json',
      ).readAsStringSync(),
    };
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    server = FakeServer(
      cards: {
        for (final e in shipped.entries)
          e.key: jsonDecode(e.value) as Map<String, dynamic>,
      },
    );
    store = RateCardStore(
      storage: InMemoryRateCardStorage(),
      bundled: (list) async => shipped[list.id]!,
    );
  });

  tearDown(() => db.close());

  Future<void> pumpScreen(WidgetTester tester, String role) async {
    // `GET /api/auth/me` answers with the same person, so a sync mid-test does
    // not quietly turn an admin back into the fake's default part-timer.
    server.meResponse = _as(role).toJson();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          rateCardStoreProvider.overrideWithValue(store),
          credentialsProvider.overrideWith(() => _Signed(_as(role))),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: Uri.parse('https://example.test'),
              client: server.client,
            ),
          ),
          // During the August fair, so the fair list is the one in force.
          todayProvider.overrideWithValue(DateTime(2026, 8, 29)),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L.localizationsDelegates,
          supportedLocales: L.supportedLocales,
          home: const RateCardScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openNightCurtain(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('edit-one-price')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'night-curtain-lo');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
  }

  Future<void> typeRate(WidgetTester tester, String rate) =>
      tester.enterText(find.byType(TextField).first, rate);

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  group('one price', () {
    testWidgets('staff can change it, and the reason goes with it', (
      tester,
    ) async {
      await pumpScreen(tester, 'staff');
      // Staff get the one-price edit, never the whole-list import.
      expect(find.text('Import edited file'), findsNothing);

      await openNightCurtain(tester);
      await typeRate(tester, '42.00');
      await tester.enterText(
        find.byKey(const Key('rate-reason')),
        'matched the stall opposite',
      );
      await tapSave(tester);

      expect(server.lastPriceEditBody, {
        'rate_sen': 4200,
        'mvp_rate_sen': 4000,
        'reason': 'matched the stall opposite',
      });
      // Through the audited route, never a whole card built on this phone.
      expect(
        server.seen.where((r) => r.url.path == '/api/rate-cards'),
        isEmpty,
      );

      // Pulled straight back: this handset now quotes the published card.
      final fair = await store.load(PriceList.fair);
      expect(fair.version, 102);
      expect(
        fair.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        4200,
      );
    });

    testWidgets('without a reason nothing is sent, and it says why', (
      tester,
    ) async {
      await pumpScreen(tester, 'staff');
      await openNightCurtain(tester);
      await typeRate(tester, '42.00');
      await tapSave(tester);

      expect(find.text('Say why — a few words is enough.'), findsOneWidget);
      expect(server.lastPriceEditBody, isNull);
    });

    testWidgets('an unchanged price is refused before it is sent', (
      tester,
    ) async {
      await pumpScreen(tester, 'staff');
      await openNightCurtain(tester);
      await tester.enterText(
        find.byKey(const Key('rate-reason')),
        'no real change',
      );
      await tapSave(tester);

      expect(find.text('That is already the price.'), findsOneWidget);
      expect(server.lastPriceEditBody, isNull);
    });

    testWidgets('offline, it says a connection is needed', (tester) async {
      await pumpScreen(tester, 'staff');
      await openNightCurtain(tester);
      await typeRate(tester, '42.00');
      await tester.enterText(
        find.byKey(const Key('rate-reason')),
        'matched the stall opposite',
      );
      server.offline = true;
      await tapSave(tester);

      expect(
        find.text(
          'Publishing needs a connection, so that every handset gets the '
          'same list.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a refusal from the office is said, not swallowed', (
      tester,
    ) async {
      server.refuseRateEditBecause = 'not_positive';
      await pumpScreen(tester, 'staff');
      await openNightCurtain(tester);
      await typeRate(tester, '42.00');
      await tester.enterText(
        find.byKey(const Key('rate-reason')),
        'matched the stall opposite',
      );
      await tapSave(tester);

      expect(
        find.text(
          'The office did not accept that change. Check for updates and try '
          'again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a part-timer is never offered it', (tester) async {
      await pumpScreen(tester, 'parttime');
      expect(find.byKey(const Key('edit-one-price')), findsNothing);
    });
  });

  group('fair dates', () {
    testWidgets('everyone sees when the fair runs and when its holds end', (
      tester,
    ) async {
      await pumpScreen(tester, 'parttime');
      expect(find.textContaining('MITC-2026-08'), findsOneWidget);
      expect(
        find.text(
          'Deposits taken at this fair hold their price until 1 Sep 2027.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('staff cannot change them', (tester) async {
      await pumpScreen(tester, 'staff');
      expect(find.byKey(const Key('change-fair-dates')), findsNothing);
    });

    testWidgets('an admin renames the fair, with a reason', (tester) async {
      await pumpScreen(tester, 'admin');
      await tester.tap(find.byKey(const Key('change-fair-dates')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('fair-name')),
        'MITC Mega Home Expo Aug 2026',
      );
      await tester.enterText(
        find.byKey(const Key('fair-reason')),
        'full name for the report',
      );
      await tester.tap(find.byKey(const Key('fair-save')));
      await tester.pumpAndSettle();

      expect(server.lastFairDatesBody, {
        'code': 'MITC Mega Home Expo Aug 2026',
        'valid_from': '2026-08-28',
        'valid_to': '2026-08-31',
        'reason': 'full name for the report',
      });
      expect(find.text('Fair dates saved as version 102'), findsOneWidget);
      expect(
        (await store.load(PriceList.fair)).promo!.code,
        'MITC Mega Home Expo Aug 2026',
      );
    });

    testWidgets('saving the dates unchanged is refused before it is sent', (
      tester,
    ) async {
      await pumpScreen(tester, 'admin');
      await tester.tap(find.byKey(const Key('change-fair-dates')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fair-reason')),
        'just checking',
      );
      await tester.tap(find.byKey(const Key('fair-save')));
      await tester.pumpAndSettle();

      expect(find.text('Those are already the dates.'), findsOneWidget);
      expect(server.lastFairDatesBody, isNull);
    });
  });

  group('picking new fair dates', () {
    // The sheet on its own, with the calendar swapped for a stand-in that
    // answers with December's dates -- what matters is what happens after.
    Future<void> openSheet(WidgetTester tester) async {
      server.meResponse = _as('admin').toJson();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final fair = RateCard.fromJson(
        jsonDecode(shipped['fair']!) as Map<String, dynamic>,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            rateCardStoreProvider.overrideWithValue(store),
            credentialsProvider.overrideWith(() => _Signed(_as('admin'))),
            apiClientProvider.overrideWithValue(
              ApiClient(
                baseUrl: Uri.parse('https://example.test'),
                client: server.client,
              ),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: L.localizationsDelegates,
            supportedLocales: L.supportedLocales,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFairDatesSheet(
                  context,
                  current: fair.promo,
                  pickRange: (_, _) async => DateTimeRange(
                    start: DateTime(2026, 12, 4),
                    end: DateTime(2026, 12, 31),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows when the new holds will end before saving', (
      tester,
    ) async {
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('fair-range')));
      await tester.pumpAndSettle();

      expect(find.text('4 Dec 2026 – 31 Dec 2026'), findsOneWidget);
      // The day after 31 December is in the next year, a year on.
      expect(
        find.text(
          'Deposits taken at this fair hold their price until 1 Jan 2028.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('sends the picked days as calendar dates', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('fair-range')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('fair-name')),
        'MITC-2026-12',
      );
      await tester.enterText(
        find.byKey(const Key('fair-reason')),
        'December fair booked',
      );
      await tester.tap(find.byKey(const Key('fair-save')));
      await tester.pumpAndSettle();

      expect(server.lastFairDatesBody, {
        'code': 'MITC-2026-12',
        'valid_from': '2026-12-04',
        'valid_to': '2026-12-31',
        'reason': 'December fair booked',
      });
    });
  });
}
