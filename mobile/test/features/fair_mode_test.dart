/// Fair mode: a toggle bounded by the promo window.
///
/// Client, Sep 2026: *"Quotation normally is only at fair anyway, but make a
/// toggle I guess with date window."*
///
/// The point of the window is that the switch cannot do damage on its own. Left
/// on for a year it quotes standard prices from 1 September; turned off it
/// quotes standard prices during the fair. There is no state that gives a price
/// away by accident, which is why the toggle can default to on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/data/settings_repository.dart';
import 'package:milan_quote/features/quote/fair_mode.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RateCard fairCard;
  late String fairJson;
  late String standardJson;

  final duringFair = DateTime(2026, 8, 29);
  final afterFair = DateTime(2026, 9, 1);
  final lastDay = DateTime(2026, 8, 31);

  setUpAll(() {
    var dir = Directory.current;
    while (!File('${dir.path}/shared/rate-card-standard.json').existsSync()) {
      dir = dir.parent;
    }
    fairJson = File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).readAsStringSync();
    standardJson = File(
      '${dir.path}/shared/rate-card-standard.json',
    ).readAsStringSync();
    fairCard = RateCard.fromJson(jsonDecode(fairJson) as Map<String, dynamic>);
  });

  RateCardStore store() => RateCardStore(
    storage: InMemoryRateCardStorage(),
    bundled: (list) async => list == PriceList.fair ? fairJson : standardJson,
  );

  group('the window is the guard, not the switch', () {
    test('on, inside the window, is a fair', () {
      expect(
        channelFor(
          fairModeEnabled: true,
          fairCard: fairCard,
          today: duringFair,
        ),
        Channel.fair,
      );
    });

    test('on, after the window, is the showroom', () {
      // The failure this prevents: nobody turns the switch off in September and
      // the handset quotes promo rates for a month.
      expect(
        channelFor(fairModeEnabled: true, fairCard: fairCard, today: afterFair),
        Channel.showroom,
      );
    });

    test('off, inside the window, is the showroom', () {
      // A showroom walk-in during the four days of the fair. This is the case
      // the toggle exists for.
      expect(
        channelFor(
          fairModeEnabled: false,
          fairCard: fairCard,
          today: duringFair,
        ),
        Channel.showroom,
      );
    });

    test('the final day of the fair is still the fair', () {
      // The fencepost. A customer at the stall on the last afternoon was
      // promised fair prices.
      expect(
        channelFor(fairModeEnabled: true, fairCard: fairCard, today: lastDay),
        Channel.fair,
      );
    });

    test('the day before it opens is not the fair yet', () {
      expect(
        channelFor(
          fairModeEnabled: true,
          fairCard: fairCard,
          today: DateTime(2026, 8, 27),
        ),
        Channel.showroom,
      );
    });

    test('a switch left on for a year never quotes fair again', () {
      // A sweep rather than one date, because "it expires" is the whole
      // argument for defaulting the switch to on.
      var day = DateTime(2026, 9, 1);
      while (day.isBefore(DateTime(2027, 9, 1))) {
        expect(
          channelFor(fairModeEnabled: true, fairCard: fairCard, today: day),
          Channel.showroom,
          reason: '$day',
        );
        day = day.add(const Duration(days: 1));
      }
    });
  });

  group('what the screen says it is doing', () {
    test('on and inside the window is active', () {
      expect(
        fairModeState(
          fairModeEnabled: true,
          fairCard: fairCard,
          today: duringFair,
        ),
        FairModeState.active,
      );
    });

    test('on and outside it is called out, not just silently standard', () {
      // "Fair mode is on but these are standard prices" is confusing enough to
      // make someone re-enter a quote.
      expect(
        fairModeState(
          fairModeEnabled: true,
          fairCard: fairCard,
          today: afterFair,
        ),
        FairModeState.outsideWindow,
      );
    });

    test('off is off', () {
      expect(
        fairModeState(
          fairModeEnabled: false,
          fairCard: fairCard,
          today: duringFair,
        ),
        FairModeState.off,
      );
    });
  });

  group('the card the handset actually prices with', () {
    test('fair mode on, during the fair, gives the fair card', () async {
      final active = await store().loadActiveForHandset(
        duringFair,
        fairModeEnabled: true,
      );
      expect(active.list, PriceList.fair);
      expect(active.channel, Channel.fair);
      expect(active.card.version, 1);
    });

    test('fair mode off, during the fair, gives the standard card', () async {
      final active = await store().loadActiveForHandset(
        duringFair,
        fairModeEnabled: false,
      );
      expect(active.list, PriceList.standard);
      expect(active.channel, Channel.showroom);
      expect(active.card.version, 101);
    });

    test('fair mode on, after the fair, gives the standard card', () async {
      final active = await store().loadActiveForHandset(
        afterFair,
        fairModeEnabled: true,
      );
      expect(active.list, PriceList.standard);
      expect(active.channel, Channel.showroom);
    });
  });

  group('the setting survives a restart', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('it defaults to on, because the window makes that safe', () async {
      expect(await SettingsRepository(db).fairModeEnabled(), isTrue);
    });

    test('turning it off is remembered', () async {
      await SettingsRepository(db).setFairMode(false);
      // A fresh repository over the same storage: the app restarting.
      expect(await SettingsRepository(db).fairModeEnabled(), isFalse);
    });

    test('turning it back on is remembered too', () async {
      final repo = SettingsRepository(db);
      await repo.setFairMode(false);
      await repo.setFairMode(true);
      expect(await repo.fairModeEnabled(), isTrue);
    });
  });
}
