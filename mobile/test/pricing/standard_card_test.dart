import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/pricing/engine.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_lock.dart' show Channel;

/// The standard (non-fair) price list.
///
/// PROVISIONAL — SPEC.md §13 A3. The client's placeholder answer, Sep 2026:
/// curtains +20%, blinds +50% over the fair rate, to be revised.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RateCard fair;
  late RateCard standard;
  late String fairJson;
  late String standardJson;

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
    fair = RateCard.fromJson(jsonDecode(fairJson) as Map<String, dynamic>);
    standard = RateCard.fromJson(
      jsonDecode(standardJson) as Map<String, dynamic>,
    );
  });

  PricingRule ruleOf(RateCard card, String id) =>
      card.rules.firstWhere((r) => r.id == id);

  group('the markups the client specified', () {
    test('curtains are 20% dearer', () {
      // RM46 -> RM55.20, exactly. No rounding involved.
      expect(ruleOf(standard, 'night-curtain-lo').rateSen, 5520);
      expect(ruleOf(standard, 'night-curtain-hi').rateSen, 6960);
      expect(ruleOf(standard, 'day-curtain-lo').rateSen, 4320);
      expect(ruleOf(standard, 'day-curtain-hi').rateSen, 5760);
    });

    test('blinds are 50% dearer', () {
      expect(ruleOf(standard, 'roller-blackout').rateSen, 1350);
      expect(ruleOf(standard, 'zebra-blackout-jbl').rateSen, 1800);
      expect(ruleOf(standard, 'zebra-blackout-tbl').rateSen, 2250);
    });

    test('every marked-up rate lands on a whole sen', () {
      // 20% and 50% of whole-ringgit prices are exact, so nothing rounds and
      // nothing drifts. If a future rate breaks that, this catches it.
      for (final rule in standard.rules) {
        final fairRule = ruleOf(fair, rule.id);
        if (rule.family == Family.curtain) {
          expect(rule.rateSen * 5, fairRule.rateSen * 6, reason: rule.id);
        } else if (rule.family == Family.blind) {
          expect(rule.rateSen * 2, fairRule.rateSen * 3, reason: rule.id);
        }
      }
    });

    test('MVP keeps its flat differential rather than being marked up', () {
      // §4.1: MVP is "a FLAT discount, not a percentage. Constant sen off."
      // Marking RM40 up by 20% would turn RM6 off into RM7.20 off and quietly
      // make MVP a percentage.
      for (final rule in standard.rules.where((r) => r.mvpRateSen != null)) {
        final fairRule = ruleOf(fair, rule.id);
        expect(
          rule.rateSen - rule.mvpRateSen!,
          fairRule.rateSen - fairRule.mvpRateSen!,
          reason: '${rule.id} must keep the same sen off',
        );
      }
      expect(ruleOf(standard, 'night-curtain-lo').mvpRateSen, 4920);
    });
  });

  group('what the client did NOT specify', () {
    test('tracks, flooring, wallpaper, add-ons and services are unchanged', () {
      // Not a bug — inventing a markup would be inventing a price. But it does
      // mean the showroom currently sells all of these at fair price, which is
      // flagged in the card and in §13 A3a.
      const untouched = {
        Family.track,
        Family.flooring,
        Family.wallpaper,
        Family.addon,
        Family.service,
      };
      var count = 0;
      for (final rule in standard.rules) {
        if (!untouched.contains(rule.family)) continue;
        expect(rule.rateSen, ruleOf(fair, rule.id).rateSen, reason: rule.id);
        count++;
      }
      expect(count, 33, reason: '33 of 77 rows carry no markup');
    });

    test('an S-Fold curtain is marked up like any other curtain', () {
      // It is a curtain, not hardware: the rate is the whole made-up curtain
      // in that heading style, railing included. Leaving it at fair price
      // would have sold an S-Fold window at a fair discount all year.
      expect(ruleOf(standard, 's-track-night-lo').rateSen, 9600);
      expect(ruleOf(standard, 'night-curtain-lo').rateSen, 5520);
    });

    test('real track hardware is still unchanged', () {
      // The rods and tracks sold on their own or added to a curtain. The
      // client named curtains and blinds; nothing else moves.
      expect(ruleOf(standard, 'motor-track').rateSen, 4000);
      expect(ruleOf(standard, 'doso-track').rateSen, 900);
      expect(ruleOf(standard, 'iron-rod-19').rateSen, 2000);
    });
  });

  group('the list is honest about what it is', () {
    test('it is flagged provisional and carries no promo window', () {
      expect(standard.provisional, isTrue, reason: 'derived, not printed');
      expect(standard.promo, isNull, reason: 'standard prices do not expire');
      expect(standard.isExpiredOn(DateTime(2099, 1, 1)), isFalse);
    });

    test('it has its own version lineage, distinct from the fair card', () {
      // A quote records its rate_card_version, and that must never be ambiguous
      // about which list priced it.
      expect(standard.version, isNot(fair.version));
      expect(standard.version, 101);
    });

    test('it carries the same products, zones and rules as the fair list', () {
      expect(standard.rules, hasLength(fair.rules.length));
      expect(standard.deliveryZones, hasLength(fair.deliveryZones.length));
      expect(standard.productRules, hasLength(fair.productRules.length));
      expect(standard.config.minDepositSen, fair.config.minDepositSen);
      // The fencepost has to survive the derivation.
      expect(ruleOf(standard, 'night-curtain-lo').bandMaxTmm, 30481);
    });
  });

  group('the date picks the list', () {
    RateCardStore store() => RateCardStore(
      storage: InMemoryRateCardStorage(),
      bundled: (list) async => list == PriceList.fair ? fairJson : standardJson,
    );

    test('inside the fair window, at a fair, fair rates apply', () async {
      final active = await store().loadActive(
        DateTime(2026, 8, 29),
        Channel.fair,
      );
      expect(active.list, PriceList.fair);
      expect(active.isFair, isTrue);
      expect(ruleOf(active.card, 'night-curtain-lo').rateSen, 4600);
    });

    test('the day after the fair, standard rates apply', () async {
      // §3: the showroom pays standard, no promo, no lock. The promo window on
      // the card is the guard, so a handset left in fair mode cannot quote
      // promo rates through September.
      final active = await store().loadActive(
        DateTime(2026, 9, 1),
        Channel.fair,
      );
      expect(active.list, PriceList.standard);
      expect(ruleOf(active.card, 'night-curtain-lo').rateSen, 5520);
    });

    test('a November walk-in is quoted standard, not fair', () async {
      final active = await store().loadActive(
        DateTime(2026, 11, 15),
        Channel.showroom,
      );
      expect(active.list, PriceList.standard);
    });

    test('the day before the fair opens is still standard', () async {
      final active = await store().loadActive(
        DateTime(2026, 8, 27),
        Channel.fair,
      );
      expect(active.list, PriceList.standard);
    });

    test('a showroom walk-in DURING the fair still pays standard', () async {
      // The reason the channel is stored rather than read off the calendar.
      // Reading the date alone quoted this customer fair prices, and once
      // locks exist it would have handed them a twelve-month hold they never
      // bought.
      for (final channel in Channel.values) {
        final active = await store().loadActive(DateTime(2026, 8, 29), channel);
        expect(
          active.list,
          channel == Channel.fair ? PriceList.fair : PriceList.standard,
          reason: channel.wire,
        );
      }
    });
  });

  group('what a customer actually pays', () {
    test('a 12ft x 9ft night curtain: RM552 at the fair, RM662.40 after', () {
      LineRequest request() => LineRequest(
        variant: 'night_curtain',
        layer: Layer.night,
        width: Length.tenths(36576),
        height: Length.tenths(27432),
      );

      expect(
        priceLine(
          request: request(),
          card: fair,
          stage: PricingStage.estimate,
        ).total.format(),
        'RM 552.00',
      );
      expect(
        priceLine(
          request: request(),
          card: standard,
          stage: PricingStage.estimate,
        ).total.format(),
        'RM 662.40',
      );
    });

    test('a 3ft x 4ft roller blind: RM162 at the fair, RM243 after', () {
      LineRequest request() => LineRequest(
        variant: 'roller_blackout',
        width: Length.tenths(9144),
        height: Length.tenths(12192),
      );

      // The 18 sqft minimum applies on both.
      expect(
        priceLine(
          request: request(),
          card: fair,
          stage: PricingStage.estimate,
        ).total.format(),
        'RM 162.00',
      );
      expect(
        priceLine(
          request: request(),
          card: standard,
          stage: PricingStage.estimate,
        ).total.format(),
        'RM 243.00',
      );
    });
  });
}
