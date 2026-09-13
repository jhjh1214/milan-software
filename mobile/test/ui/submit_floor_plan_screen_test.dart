/// A part-timer's own floor-plan submission, driven through the real screen.
/// SPEC.md Phase 8's last open item.
///
/// The photo + tap-to-calibrate flow needs a real image and platform image
/// picker channels, which is a job for a manual/integration pass rather than
/// this suite; what is checked here is the part every submission goes
/// through regardless of a photo: picking a cached project, typing openings
/// and rooms, and the fact that submitting queues one outbox row and shows
/// the confirmation -- never blocking on the network, per
/// `queueQuoteForOffice`'s own "this never blocks and never fails visibly."
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/features/library/submit_floor_plan_screen.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/l10n/app_localizations.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/sync_state.dart';

import '../sync/fake_server.dart';

const _signedIn = Credentials(
  token: 'good-token',
  user: Identity(id: 'u1', name: 'Ah Lian', role: 'parttime', language: 'zh'),
);

class _Signed extends CredentialsNotifier {
  @override
  Future<Credentials?> build() async => _signedIn;
}

void main() {
  late AppDatabase db;
  late FakeServer server;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    server = FakeServer(tokens: {'good-token'});
    server.projects = [
      {
        'id': 'p1',
        'name': 'ABC Development',
        'developer': null,
        'area': 'Ayer Keroh',
      },
    ];
  });

  tearDown(() => db.close());

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          credentialsProvider.overrideWith(_Signed.new),
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
          home: const SubmitFloorPlanScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The form is a single scrolling `ListView`, and a `SliverList`'s own
  /// children are lazily kept only near the viewport -- a field several
  /// sections down is not in the tree at all until scrolled to.
  ///
  /// `scrollUntilVisible`'s own default `scrollable` finder (`find.byType
  /// (Scrollable)`) is ambiguous here -- several `TextField`s each carry
  /// their own internal `Scrollable` for cursor positioning -- so this drags
  /// the form's own `ListView` (keyed `lib-scroll`) directly instead of
  /// asking the framework to guess which scrollable to use.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
      await tester.drag(
        find.byKey(const Key('lib-scroll')),
        const Offset(0, -300),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> scrollToAndTap(WidgetTester tester, Finder finder) async {
    await scrollTo(tester, finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> scrollToAndEnterText(
    WidgetTester tester,
    Finder finder,
    String text,
  ) async {
    await scrollTo(tester, finder);
    await tester.enterText(finder, text);
  }

  testWidgets(
    'a project loads from the server, and openings and rooms can be typed in',
    (tester) async {
      await pumpScreen(tester);

      // The screen pulls the project list itself on open -- no separate
      // "refresh" tap should be needed the first time a connection exists.
      expect(find.text('ABC Development'), findsNothing);
      await tester.tap(find.byKey(const Key('lib-project-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ABC Development').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('lib-unit-type-name')),
        'Type C',
      );

      await scrollToAndTap(tester, find.text('Add a window or door'));
      await scrollToAndEnterText(
        tester,
        find.byKey(const Key('opening-0-label')),
        'W1',
      );
      await scrollToAndEnterText(
        tester,
        find.byKey(const Key('opening-0-room')),
        'Living',
      );
      await scrollToAndEnterText(
        tester,
        find.byKey(const Key('opening-0-width')),
        '6',
      );
      await scrollToAndEnterText(
        tester,
        find.byKey(const Key('opening-0-height')),
        '8',
      );

      await scrollToAndTap(tester, find.text('Add a room'));
      await scrollToAndEnterText(
        tester,
        find.byKey(const Key('room-0-name')),
        'Living',
      );
      await scrollToAndEnterText(
        tester,
        find.byKey(const Key('room-0-width')),
        '12',
      );
      await scrollToAndEnterText(
        tester,
        find.byKey(const Key('room-0-length')),
        '15',
      );

      await scrollToAndTap(tester, find.byKey(const Key('lib-submit')));

      expect(
        find.text(
          'Sent. An admin will review it before it can be used in a quote.',
        ),
        findsOneWidget,
      );

      final row = await db.select(db.librarySubmissions).getSingle();
      expect(row.projectId, 'p1');
      expect(row.unitTypeName, 'Type C');
      expect(row.queuedAt, isNotNull);

      final outboxRows = await db.pendingOutbox();
      expect(outboxRows, hasLength(1));
      expect(outboxRows.single.entityType, 'library_submission');
      expect(outboxRows.single.entityId, row.id);

      final body =
          jsonDecode(outboxRows.single.payload) as Map<String, dynamic>;
      expect(body['project_id'], 'p1');
      expect(body['name'], 'Type C');
      final openings = body['openings'] as List;
      expect(openings, hasLength(1));
      expect(openings.single['label'], 'W1');
      // 6ft is exactly 18288 tenths-of-a-millimetre -- the width entered as
      // feet must survive as an exact integer, not a rounded display value.
      expect(openings.single['nominal_w_tmm'], 18288);
      final rooms = body['rooms'] as List;
      expect(rooms, hasLength(1));
      expect(rooms.single['name'], 'Living');
    },
  );

  testWidgets(
    'submitting with no project chosen asks for one instead of queueing',
    (tester) async {
      await pumpScreen(tester);

      await tester.enterText(
        find.byKey(const Key('lib-unit-type-name')),
        'Type C',
      );
      await scrollToAndTap(tester, find.byKey(const Key('lib-submit')));

      expect(
        find.text('Choose a project and name the unit type first.'),
        findsOneWidget,
      );
      expect(await db.pendingOutbox(), isEmpty);
    },
  );

  testWidgets(
    'no connection and no cache says the fetch failed, not that the list is empty',
    (tester) async {
      server.offline = true;
      await pumpScreen(tester);

      expect(find.text('Could not load the project list.'), findsOneWidget);
    },
  );
}
