/// Starting a line from a saved plan, driven through the real wizard.
/// SPEC.md Phase 8.
///
/// > A salesperson hears "ABC Development, Type B", picks the development,
/// > picks the unit type, and the known windows... load. They choose
/// > products and a reference quotation exists in seconds.
///
/// What matters most here is not re-testing the wizard's own room/family/
/// product steps (`demo_script_test.dart` already does that) but the two
/// things Phase 8 actually adds: the picked opening's *exact*
/// tenths-of-a-millimetre dimensions land on the line untouched by any
/// display rounding, and the line carries the provenance that says where it
/// came from.
library;

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
  late RateCard card;
  late AppDatabase db;
  late FakeServer server;

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    final cardJson = File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).readAsStringSync();
    card = RateCard.fromJson(jsonDecode(cardJson) as Map<String, dynamic>);
  });

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
    server.unitTypesByProject['p1'] = [
      {
        'id': 'ut1',
        'project_id': 'p1',
        'project_name': 'ABC Development',
        'name': 'Type B',
        'status': 'approved',
      },
    ];
    server.unitTypeDetails['ut1'] = {
      'unit_type': {'id': 'ut1'},
      'versions': [
        {
          'id': 'v1',
          'version': 3,
          'approved_at': '2026-08-01T09:00:00Z',
          'openings': [
            // 18000 tmm is 5.905511...ft, and 24000 tmm is 7.874015...ft --
            // neither is a round number in feet, which is exactly the point:
            // a lossy display-string round-trip would be caught here.
            {
              'id': 'o1',
              'label': 'W1',
              'room': 'Living',
              'nominal_w_tmm': 18000,
              'nominal_h_tmm': 24000,
            },
          ],
        },
      ],
    };
  });

  tearDown(() => db.close());

  /// Mirrors `demo_script_test.dart`'s own `pumpApp` exactly, plus the
  /// credentials and API client this feature needs. The wizard is reached
  /// from the real quote screen, not pumped on its own -- `quoteProvider`
  /// is lazily built on first read, and the quote screen is what warms it
  /// up in the real app before the wizard ever touches it. Skipping that
  /// step silently no-ops every `addLine` call, which cost real time to
  /// track down.
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeRateCardProvider.overrideWith(
            (ref) async => ActiveRateCard(card: card, list: PriceList.fair),
          ),
          todayProvider.overrideWithValue(DateTime(2026, 8, 29)),
          credentialsProvider.overrideWith(_Signed.new),
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: Uri.parse('https://example.test'),
              client: server.client,
            ),
          ),
        ],
        child: const MilanQuoteApp(),
      ),
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the exact tenths-of-a-millimetre value survives, not a rounded one',
    (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('加窗口'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('从已存的户型开始'));
      await tester.pumpAndSettle();
      expect(
        find.text('找项目'),
        findsOneWidget,
        reason: 'step 1: project picker',
      );

      expect(
        find.text('ABC Development'),
        findsOneWidget,
        reason: 'step 1b: project listed',
      );
      await tester.tap(find.text('ABC Development'));
      await tester.pumpAndSettle();
      expect(
        find.text('选户型'),
        findsOneWidget,
        reason: 'step 2: unit type picker',
      );

      expect(
        find.text('Type B'),
        findsOneWidget,
        reason: 'step 2b: unit type listed',
      );
      await tester.tap(find.text('Type B'));
      await tester.pumpAndSettle();
      expect(
        find.text('选窗户'),
        findsOneWidget,
        reason: 'step 3: opening picker',
      );

      // The room and both dimensions came from the plan -- displayed to one
      // decimal, which is fine, since nothing here re-parses this text.
      expect(
        find.textContaining('W1'),
        findsOneWidget,
        reason: 'step 3b: opening listed',
      );
      await tester.tap(find.textContaining('W1'));
      await tester.pumpAndSettle();

      // Landed on the family step directly, room already known -- this
      // step is where the wizard normally starts.
      expect(
        find.text('哪一类？'),
        findsOneWidget,
        reason: 'step 4: back on the wizard, family step',
      );
      await tester.tap(find.text('窗帘'));
      await tester.pumpAndSettle();
      expect(
        find.text('什么产品？'),
        findsOneWidget,
        reason: 'step 5: product step',
      );
      await tester.tap(find.text('夜帘（遮光）'));
      await tester.pumpAndSettle();
      expect(find.text('尺寸'), findsOneWidget, reason: 'step 6: sizes step');

      // The sizes step, pre-filled -- Done is already enabled.
      final doneButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '完成'),
      );
      expect(doneButton.onPressed, isNotNull);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      final quote = await db.latestQuote();
      final lines = await db.linesFor(quote!.id);
      final line = lines.single;

      expect(line.room, 'Living');
      expect(
        line.widthTmm,
        18000,
        reason: 'the exact opening width, not a re-parsed 5.9ft',
      );
      expect(
        line.heightTmm,
        24000,
        reason: 'the exact opening height, not a re-parsed 7.9ft',
      );
      expect(line.sourceProjectId, 'p1');
      expect(line.sourceUnitTypeId, 'ut1');
      expect(line.sourceVersion, 3);
    },
  );

  testWidgets('editing the pre-filled width clears the plan\'s provenance', (
    tester,
  ) async {
    // SPEC.md Phase 8, this codebase's own flagged design call: once the
    // salesperson types their own number over the plan's, the honest
    // provenance is that they typed it -- not that the plan said so.
    await pumpApp(tester);

    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('从已存的户型开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ABC Development'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type B'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('W1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('窗帘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('夜帘（遮光）'));
    await tester.pumpAndSettle();

    // Clears the pre-filled "5.9" (three characters) via the real keypad's
    // backspace, then types "20" -- exactly as a salesperson correcting a
    // number would, never by reaching around the widget.
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.widgetWithText(InkWell, '⌫').last);
      await tester.pump();
    }
    for (final digit in '20'.split('')) {
      await tester.tap(find.widgetWithText(InkWell, digit).last);
      await tester.pump();
    }

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final quote = await db.latestQuote();
    final line = (await db.linesFor(quote!.id)).single;
    expect(line.sourceUnitTypeId, null);
    expect(line.sourceProjectId, null);
  });
}
