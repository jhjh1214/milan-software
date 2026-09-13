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

  testWidgets(
    'picking a saved room seeds a flooring line from its area, no sizes step',
    (tester) async {
      // SPEC.md's property library: "auto-calculate a full SPC flooring
      // quote". A room has only a stored total area -- 9,290,304 mm² is
      // exactly 100 sqft, picked so the assertion below is exact rather
      // than a rounded decimal.
      server.unitTypeDetails['ut1'] = {
        'unit_type': {'id': 'ut1'},
        'versions': [
          {
            'id': 'v1',
            'version': 3,
            'approved_at': '2026-08-01T09:00:00Z',
            'openings': [
              {
                'id': 'o1',
                'label': 'W1',
                'room': 'Living',
                'nominal_w_tmm': 18000,
                'nominal_h_tmm': 24000,
              },
            ],
            'rooms': [
              {
                'id': 'r1',
                'name': 'Living',
                'nominal_area_mm2': 9290304,
                'skirting_run_tmm': null,
              },
            ],
          },
        ],
      };

      await pumpApp(tester);

      await tester.tap(find.text('加窗口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从已存的户型开始'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ABC Development'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Type B'));
      await tester.pumpAndSettle();

      // Both a window and a room exist for this unit type, so the broader
      // title is the one shown, and both sections are on screen.
      expect(find.text('选窗户或房间'), findsOneWidget);
      expect(find.textContaining('W1'), findsOneWidget);
      expect(
        find.textContaining('100.0'),
        findsOneWidget,
        reason: 'the room lists its area, not a width and a height',
      );

      await tester.tap(find.text('Living').last);
      await tester.pumpAndSettle();

      // Landed on the product step directly -- a room can only ever price
      // a flooring line, so there is no family step to show, and no sizes
      // step either: the area is already known.
      expect(
        find.text('什么产品？'),
        findsOneWidget,
        reason: 'family skipped -- a room is always flooring',
      );
      await tester.tap(find.text('SPC 地板 4mm+1mm'));
      await tester.pumpAndSettle();

      // spc_4mm_1mm offers two optional add-ons (dismantle, self levelling),
      // so the upgrade step shows rather than popping straight back out.
      expect(find.text('要加什么吗？'), findsOneWidget);
      await tester.tap(find.text('不用，就这样'));
      await tester.pumpAndSettle();

      final quote = await db.latestQuote();
      final line = (await db.linesFor(quote!.id)).single;
      expect(line.room, 'Living');
      expect(line.widthTmm, null);
      expect(line.heightTmm, null);
      expect(
        line.directAreaSqft,
        '100',
        reason: 'exact, from the stored area -- never a float',
      );
      expect(line.sourceProjectId, 'p1');
      expect(line.sourceUnitTypeId, 'ut1');
      expect(line.sourceVersion, 3);
    },
  );

  testWidgets(
    'a room-sourced add-on bills on the room\'s own area, not a phantom width',
    (tester) async {
      // The upgrade-flow twin of the test above: dismantling old flooring
      // is billed "on the same square footage" as the flooring it attaches
      // to (CLAUDE.md), and a room-sourced parent has no width to copy --
      // only its area.
      server.unitTypeDetails['ut1'] = {
        'unit_type': {'id': 'ut1'},
        'versions': [
          {
            'id': 'v1',
            'version': 3,
            'approved_at': '2026-08-01T09:00:00Z',
            'openings': [],
            'rooms': [
              {
                'id': 'r1',
                'name': 'Living',
                'nominal_area_mm2': 9290304,
                'skirting_run_tmm': null,
              },
            ],
          },
        ],
      };

      await pumpApp(tester);

      await tester.tap(find.text('加窗口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从已存的户型开始'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ABC Development'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Type B'));
      await tester.pumpAndSettle();

      // No openings this time, so the room-specific title shows rather than
      // asking for a window that is not there.
      expect(find.text('选房间'), findsOneWidget);
      await tester.tap(find.text('Living').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('SPC 地板 4mm+1mm'));
      await tester.pumpAndSettle();
      expect(find.text('要加什么吗？'), findsOneWidget);

      await tester.tap(find.text('拆除旧 SPC'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      final quote = await db.latestQuote();
      final lines = await db.linesFor(quote!.id);
      expect(lines, hasLength(2), reason: 'the flooring line, and the add-on');

      final addOn = lines.firstWhere((l) => l.variant == 'dismantle_old_spc');
      expect(addOn.widthTmm, null);
      expect(
        addOn.directAreaSqft,
        '100',
        reason: 'the parent room\'s own area, not a crash and not a guess',
      );
      expect(addOn.parentLineId, lines.first.id);
    },
  );

  testWidgets('accepting the skirting offer adds it as its own line', (
    tester,
  ) async {
    // Skirting is priced per_ft_width, not per_sqft, so it is offered
    // separately from the flooring line rather than folded into it --
    // 137160 tmm is exactly 45.0ft, picked so the sheet's own text is
    // exact rather than a rounded decimal.
    server.unitTypeDetails['ut1'] = {
      'unit_type': {'id': 'ut1'},
      'versions': [
        {
          'id': 'v1',
          'version': 3,
          'approved_at': '2026-08-01T09:00:00Z',
          'openings': [],
          'rooms': [
            {
              'id': 'r1',
              'name': 'Living',
              'nominal_area_mm2': 9290304,
              'skirting_run_tmm': 137160,
            },
          ],
        },
      ],
    };

    await pumpApp(tester);

    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从已存的户型开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ABC Development'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Living').last);
    await tester.pumpAndSettle();

    // The offer appears before the product step -- asked while the room
    // that recorded it is still what is on screen.
    expect(find.text('这个房间有存踢脚线资料'), findsOneWidget);
    expect(find.textContaining('45.0'), findsOneWidget);
    await tester.tap(find.text('加踢脚线'));
    await tester.pumpAndSettle();

    // Landed on the product step, same as ever -- accepting the offer
    // does not change what happens next.
    expect(find.text('什么产品？'), findsOneWidget);
    await tester.tap(find.text('SPC 地板 4mm+1mm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不用，就这样'));
    await tester.pumpAndSettle();

    final quote = await db.latestQuote();
    final lines = await db.linesFor(quote!.id);
    expect(
      lines,
      hasLength(2),
      reason:
          'the skirting line, added before the flooring product was '
          'even chosen, and the flooring line itself',
    );

    final skirting = lines.firstWhere((l) => l.variant == 'skirting');
    expect(skirting.widthTmm, 137160, reason: 'the exact recorded length');
    expect(skirting.directAreaSqft, null);
    expect(skirting.parentLineId, null, reason: 'its own line, not an add-on');
    expect(skirting.sourceUnitTypeId, 'ut1');
  });

  testWidgets('declining the skirting offer adds nothing for it', (
    tester,
  ) async {
    server.unitTypeDetails['ut1'] = {
      'unit_type': {'id': 'ut1'},
      'versions': [
        {
          'id': 'v1',
          'version': 3,
          'approved_at': '2026-08-01T09:00:00Z',
          'openings': [],
          'rooms': [
            {
              'id': 'r1',
              'name': 'Living',
              'nominal_area_mm2': 9290304,
              'skirting_run_tmm': 137160,
            },
          ],
        },
      ],
    };

    await pumpApp(tester);

    await tester.tap(find.text('加窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从已存的户型开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ABC Development'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Living').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('先不要'));
    await tester.pumpAndSettle();

    expect(find.text('什么产品？'), findsOneWidget);
    await tester.tap(find.text('SPC 地板 4mm+1mm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不用，就这样'));
    await tester.pumpAndSettle();

    final quote = await db.latestQuote();
    final lines = await db.linesFor(quote!.id);
    expect(lines, hasLength(1), reason: 'the flooring line only');
    expect(lines.single.variant, isNot('skirting'));
  });
}
