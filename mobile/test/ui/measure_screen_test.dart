/// Measurement mode, driven the way a measurer in a house would. §11 Phase 6.
///
/// Nothing here re-tests the pricing rule. What a line bills is decided in
/// `pricing/final_pricing.dart` and pinned by `final_pricing_cases` on both
/// engines. What is checked here is what a person actually sees and does:
///
/// * the estimate beside the field they are typing into, which is what lets
///   somebody catch 1.2m where the fair recorded 12ft;
/// * the variance, before they leave the house;
/// * a total that is **absent**, not zero, while a window is unmeasured;
/// * a held card the handset does not have, said out loud rather than quietly
///   repriced at today's rates;
/// * and that the whole flow runs **with every socket refused**, because §11
///   Phase 6 requires it to work in a house with no signal.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/features/measure/measure_screen.dart';
import 'package:milan_quote/features/order/order_screen.dart'
    show orderLinesProvider, orderProvider;
import 'package:milan_quote/features/order/share_revised_order.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/ui/widgets/dimension_field.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/l10n/app_localizations.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/sync_state.dart';

/// Refuses every socket. Anything that reaches for the network under this
/// throws, which is what "works in a house with no signal" has to mean.
class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw const SocketException('offline: the measurement path must not dial');
  }
}

class _Signed extends CredentialsNotifier {
  _Signed(this._who);
  final Credentials? _who;
  @override
  Future<Credentials?> build() async => _who;
}

const _measurer = Credentials(
  token: 't',
  user: Identity(
    id: 'u-measurer',
    name: 'Ah Meng',
    role: 'staff',
    language: 'en',
  ),
);

void main() {
  late AppDatabase db;
  late Directory temp;

  final at = DateTime(2026, 9, 20, 10, 30);
  const orderId = 'o1';

  /// The real cards, loaded once outside the widget-test zone.
  ///
  /// Read here rather than through `RateCardStore` inside the pumped tree:
  /// real file I/O never completes inside `flutter test`'s fake-async zone, so
  /// a screen waiting on it sits on a spinner forever. What is under test is
  /// the screen, not the store — the store has its own tests.
  late Map<int, RateCard> cards;

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }

    cards = {};
    for (final name in const [
      'rate-card-fair-2026-08.json',
      'rate-card-standard.json',
    ]) {
      final card = RateCard.fromJson(
        jsonDecode(File('${dir.path}/shared/$name').readAsStringSync())
            as Map<String, dynamic>,
      );
      cards[card.version] = card;
    }
  });

  Future<void> addLine(
    String id, {
    int estWidthTmm = 36576,
    int? estHeightTmm = 27432,
    int lineTotalSen = 55200,
    int version = 1,
    int sortOrder = 0,
    String variant = 'night_curtain',
    String layer = 'night',
    bool materialDeferred = false,
    String appliedRuleId = 'night-curtain-lo',
    int standardRateSen = 4600,
    int rateSen = 4600,
    String billedQty = '12',
    String billedUnit = 'ft',
  }) => db
      .into(db.orderLines)
      .insert(
        OrderLinesCompanion.insert(
          id: id,
          orderId: orderId,
          quoteLineId: 'ql-$id',
          sortOrder: sortOrder,
          room: 'Living room',
          variant: variant,
          layer: layer,
          estWidthTmm: Value(estWidthTmm),
          estHeightTmm: Value(estHeightTmm),
          appliedRuleId: appliedRuleId,
          appliedRateCardVersion: version,
          standardRateSen: standardRateSen,
          rateSen: rateSen,
          billedQty: billedQty,
          billedUnit: billedUnit,
          lineTotalSen: lineTotalSen,
          materialDeferred: Value(materialDeferred),
        ),
      );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('milan_measure');
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
  });

  tearDown(() async {
    await db.close();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // A locked temp dir is not worth masking a real failure.
    }
  });

  /// Lets the real work finish, then draws.
  ///
  /// The screen reads the rate cards off disk. `pump` alone never lets real
  /// file I/O complete, and `pumpAndSettle` hangs on the loading spinner's
  /// endless animation rather than failing — so neither on its own is any use
  /// here.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pump(WidgetTester tester) async {
    // A phone, not the 800x600 default. The sheet carries two dimension
    // fields and a full keypad, and on the default surface the height field
    // is off-screen — which is a test artefact, not something a measurer
    // would ever see on a real handset.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          todayProvider.overrideWithValue(at),
          credentialsProvider.overrideWith(() => _Signed(_measurer)),
          heldCardsProvider.overrideWith((_) async => cards),
          // Queuing a measurement touches this provider, and `ApiClient`'s
          // default constructor builds a real `dart:io` `HttpClient()`
          // eagerly — which is exactly what `_NoNetwork` below makes throw,
          // even though nothing here ever issues a request. A `MockClient`
          // never goes near `dart:io`, so it proves the same thing the real
          // test cares about (no socket is dialled) without that construction
          // quirk.
          apiClientProvider.overrideWithValue(
            ApiClient(
              baseUrl: Uri.parse('https://example.test'),
              client: MockClient((_) async => http.Response('{}', 200)),
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L.localizationsDelegates,
          supportedLocales: L.supportedLocales,
          home: const MeasureScreen(orderId: orderId),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String raw) async {
    for (final ch in raw.split('')) {
      await tester.tap(find.widgetWithText(InkWell, ch).last);
      await tester.pump();
    }
  }

  /// Enters a width and a height, then saves.
  ///
  /// Both, always: `night_curtain` bands on the **drop**, so a line with no
  /// height has no band and the engine refuses it — correctly. Height selects
  /// the band and never multiplies (§4.3).
  Future<void> measure(
    WidgetTester tester, {
    required String width,
    required String height,
  }) async {
    await type(tester, width);
    // The second dimension field. Tapping the label alone does not move focus.
    await tester.tap(find.byType(DimensionField).last);
    await tester.pump();
    await type(tester, height);

    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    // Saving writes to the database and reprices the order, both real async
    // work, then the sheet closes and the screen reloads.
    await settle(tester);
    await tester.pumpAndSettle();
    await settle(tester);
  }

  group('what the measurer sees on the way in', () {
    testWidgets('the quoted total, and no final until it is earned', (
      tester,
    ) async {
      await addLine('l1');
      await pump(tester);

      expect(find.text('RM 552.00'), findsWidgets, reason: 'the quote');
      expect(
        find.text('Not yet priced'),
        findsOneWidget,
        reason:
            'a total that quietly excluded an unmeasured window would be a '
            'balance somebody collects and a window nobody bills for',
      );
    });

    testWidgets('every line, with what it was quoted at', (tester) async {
      await addLine('l1');
      await addLine('l2', sortOrder: 1);
      await pump(tester);

      expect(find.text('Measure'), findsNWidgets(2));
      expect(find.textContaining('1 / 2'), findsOneWidget);
      expect(find.textContaining('2 / 2'), findsOneWidget);
    });

    testWidgets('what is still outstanding, and why', (tester) async {
      await addLine('l1');
      await pump(tester);

      expect(find.text('Not measured yet.'), findsOneWidget);
      expect(find.text('1 line still to finish'), findsOneWidget);
    });
  });

  group('the revised order document', () {
    /// The share button, whatever its label reads in this locale.
    Finder shareButton() =>
        find.widgetWithText(FilledButton, 'Share revised order');

    testWidgets('cannot be shared while a line is still unmeasured', (
      tester,
    ) async {
      // Disabled rather than hidden: a button that vanishes leaves somebody
      // hunting for it, and the outstanding list above already says why.
      await addLine('l1');
      await pump(tester);

      expect(shareButton(), findsOneWidget);
      expect(
        tester.widget<FilledButton>(shareButton()).onPressed,
        isNull,
        reason: 'an order with an unpriced line has no document',
      );
    });

    testWidgets('becomes available once every line has priced', (tester) async {
      await addLine('l1');
      await pump(tester);
      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();
      await measure(tester, width: '11', height: '9');

      expect(
        tester.widget<FilledButton>(shareButton()).onPressed,
        isNotNull,
        reason: 'the measurer hands this over before they leave',
      );
    });

    testWidgets('one measured line of two is still not a document', (
      tester,
    ) async {
      // The order total is what gates it, not the line. A document built from
      // the lines that happened to price would be a balance somebody collects
      // and a window nobody bills for.
      await addLine('l1');
      await addLine('l2', sortOrder: 1);
      await pump(tester);

      await tester.tap(find.text('Measure').first);
      await tester.pumpAndSettle();
      await measure(tester, width: '11', height: '9');

      expect(tester.widget<FilledButton>(shareButton()).onPressed, isNull);
    });

    testWidgets('carries the product name, not the variant key', (
      tester,
    ) async {
      // Printing "night_curtain" on a customer's paper is worse than printing
      // nothing: it looks like the system is broken. And the size must be the
      // one the measurer read on screen, from the same formatter.
      await addLine('l1');
      await pump(tester);
      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();
      await measure(tester, width: '11', height: '9');

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MeasureScreen)),
      );
      final data = revisedOrderDataFor(
        order: (await container.read(orderProvider(orderId).future))!,
        lines: await container.read(orderLinesProvider(orderId).future),
        pricing: await container.read(orderPricingProvider(orderId).future),
        language: 'en',
        fallbackMeasuredOn: at,
        l: lookupL(const Locale('en')),
      )!;

      final row = data.lines.single;
      expect(row.product, isNot(contains('_')));
      expect(row.product.toLowerCase(), contains('curtain'));
      expect(row.quotedSize, "12' × 9'");
      expect(row.measuredSize, "11' × 9'");

      // Both amounts, so the customer can check the new figure against the
      // paper they already hold.
      expect(row.line.estimateTotal.sen, 55200);
      expect(row.line.finalTotal!.sen, 50600);
      expect(data.balanceDue.sen, 50600 - 30000);
    });
  });

  group('recording the tape', () {
    testWidgets('the estimate is on screen while the field is typed into', (
      tester,
    ) async {
      // §11 Phase 6. This is what lets somebody notice they are recording
      // 1.2m where the fair recorded 12ft, while the window is still there.
      await addLine('l1');
      await pump(tester);

      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();

      // Width first, then height. It rendered them the wrong way round once —
      // the generator orders placeholders alphabetically, so `height` came
      // first — which is why this asserts the whole string.
      expect(find.text("Quoted as 12' × 9'"), findsOneWidget);
      expect(find.textContaining("Quoted 12'"), findsWidgets);
      expect(find.textContaining("Quoted 9'"), findsWidgets);
    });

    testWidgets('a measured line prices, and the variance is visible', (
      tester,
    ) async {
      await addLine('l1');
      await pump(tester);

      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();
      await measure(tester, width: '11', height: '9');

      // 11ft x RM46 = RM506, against RM552 quoted. The drop is §8.5's promise
      // being kept, and the measurer sees it before leaving.
      expect(find.text('RM 506.00'), findsWidgets);
      expect(find.text('RM 46.00 below the quote'), findsOneWidget);
    });

    testWidgets(
      'saving queues the measurement to go up, offline, same as everything '
      'else — FINDINGS.md #1',
      (tester) async {
        await addLine('l1');
        await pump(tester);

        await tester.tap(find.text('Measure'));
        await tester.pumpAndSettle();
        await measure(tester, width: '11', height: '9');

        final rows = await db.pendingOutbox();
        final queued = rows.where((r) => r.entityType == 'measurement');
        expect(queued, hasLength(1));

        final body = jsonDecode(queued.single.payload) as Map<String, dynamic>;
        expect(body['order_id'], orderId);
        expect(body['line_id'], 'l1');
        expect(body['final_width_tmm'], 33528);
        expect(body['final_height_tmm'], 27432);
        // The freshly-repriced total, for the server's own agreement check —
        // never trusted back, only compared.
        expect(body['device_final_total_sen'], 50600);
      },
    );

    testWidgets('the measured size sits beside the quoted one, not over it', (
      tester,
    ) async {
      // §6.3 keeps both. Losing the estimate leaves the variance report with
      // nothing to compare and a customer with no answer to "but you said".
      await addLine('l1');
      await pump(tester);

      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();
      await measure(tester, width: '11', height: '9');

      expect(find.text('Quoted'), findsWidgets);
      expect(find.text("12' × 9'"), findsOneWidget, reason: 'what was quoted');
      expect(find.text('Measured'), findsOneWidget);
      expect(
        find.text("11' × 9'"),
        findsOneWidget,
        reason: 'what the tape said',
      );
    });

    testWidgets('saving is refused until there is a width and a height', (
      tester,
    ) async {
      // A banded product with no drop has no band, so a half-filled line
      // cannot price. The button says so by being unavailable rather than by
      // failing after the fact.
      await addLine('l1');
      await pump(tester);

      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();

      FilledButton save() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save').last,
      );

      expect(save().onPressed, isNull, reason: 'nothing entered');

      // Width only. Here the missing DROP is the sole reason it cannot price,
      // so this is what pins that condition.
      await type(tester, '11');
      expect(save().onPressed, isNull, reason: 'a width but no drop');

      await tester.tap(find.byType(DimensionField).last);
      await tester.pump();
      await type(tester, '9');
      expect(save().onPressed, isNotNull, reason: 'both, so it can price');
    });

    testWidgets('a drop with no width cannot be saved either', (tester) async {
      // The other order, and it has to be its own test: with a width already
      // entered the drop condition would be doing the refusing, and the
      // missing-width condition would never be the one under test.
      await addLine('l1');
      await pump(tester);

      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DimensionField).last);
      await tester.pump();
      await type(tester, '9');

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save').last,
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'a wallpaper line quoted with no height still asks for one here',
      (tester) async {
        // §13 A25: the fair let this line default to one pack with no wall
        // size recorded (estHeightTmm null). Final pricing must still see the
        // real wall — a `needsHeight` derived from "did the quote happen to
        // record one" would silently skip the field for exactly this line.
        await addLine(
          'l1',
          variant: 'korea_wallpaper',
          estWidthTmm: 0,
          estHeightTmm: null,
          lineTotalSen: 80000,
          appliedRuleId: 'korea-wallpaper',
          standardRateSen: 80000,
          rateSen: 80000,
          billedQty: '1',
          billedUnit: 'roll',
        );
        await pump(tester);

        await tester.tap(find.text('Measure'));
        await tester.pumpAndSettle();

        // Both fields present — a missing height on a per_roll line must not
        // read as "this product has no second dimension".
        expect(find.byType(DimensionField), findsNWidgets(2));

        FilledButton save() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Save').last,
        );
        await type(tester, '20');
        expect(save().onPressed, isNull, reason: 'width only, no real wall');

        await tester.tap(find.byType(DimensionField).last);
        await tester.pump();
        await type(tester, '10');
        expect(save().onPressed, isNotNull, reason: 'both, so it can price');
      },
    );

    testWidgets('a tape above the estimate is flagged, not hidden', (
      tester,
    ) async {
      // §8.5's promise is about rounding, not about the customer's own wrong
      // dimensions. Somebody has to say so before the bill arrives.
      await addLine('l1');
      await pump(tester);

      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();
      await measure(tester, width: '15', height: '9');

      expect(find.textContaining('ABOVE the quote'), findsOneWidget);
    });

    testWidgets('one measured line does not price a two-line order', (
      tester,
    ) async {
      await addLine('l1');
      await addLine('l2', sortOrder: 1);
      await pump(tester);

      await tester.tap(find.text('Measure').first);
      await tester.pumpAndSettle();
      await measure(tester, width: '11', height: '9');

      expect(find.text('Not yet priced'), findsOneWidget);
      expect(find.text('1 line still to finish'), findsOneWidget);
    });
  });

  group('the held card', () {
    testWidgets('a version this handset does not have refuses, out loud', (
      tester,
    ) async {
      // Falling back to today's card is exactly what the RM300 was taken to
      // prevent, and it is the fallback that looks most reasonable.
      await addLine('l1', version: 99);
      await pump(tester);

      // On the way in the line reads as unmeasured, which is the honest first
      // answer: nothing can be said about the card until somebody has taken a
      // tape to it.
      expect(find.text('Not measured yet.'), findsOneWidget);
      expect(find.text('Not yet priced'), findsOneWidget);

      // The warning belongs in the sheet, where the measurer is standing with
      // a tape — before they waste the trip, not after.
      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('does not have the price list'),
        findsOneWidget,
      );
    });
  });

  group('offline — §11 Phase 6', () {
    testWidgets('the whole flow runs with every socket refused', (
      tester,
    ) async {
      // Not a source scan: any code path that dials out throws under this.
      final previous = HttpOverrides.current;
      HttpOverrides.global = _NoNetwork();
      addTearDown(() => HttpOverrides.global = previous);

      await addLine('l1');
      await pump(tester);

      await tester.tap(find.text('Measure'));
      await tester.pumpAndSettle();
      await measure(tester, width: '11', height: '9');

      expect(find.text('RM 506.00'), findsWidgets);

      // And it really was stored, not just drawn.
      final line = await (db.select(
        db.orderLines,
      )..where((l) => l.id.equals('l1'))).getSingle();
      expect(line.isSiteMeasured, isTrue);
      expect(line.finalLineTotalSen, 50600);
      expect(
        line.lineTotalSen,
        55200,
        reason: 'the estimate is untouched — §6.3 keeps both',
      );
    });
  });
}
