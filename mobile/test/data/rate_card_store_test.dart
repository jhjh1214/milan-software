import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/pricing/engine.dart';
import 'package:milan_quote/pricing/models.dart';
import 'package:milan_quote/pricing/rate_card_csv.dart';

/// An imported price change has to outlive the app, or the admin edits prices
/// every morning.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late RateCardStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('milan-rates');
    store = RateCardStore(directory: () async => temp);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('with no override, the bundled list is what loads', () async {
    expect(await store.hasOverride(PriceList.fair), isFalse);
    final card = await store.load(PriceList.fair);
    expect(card.version, 1);
    expect(
      card.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
      4600,
    );
  });

  test('an applied change survives a restart', () async {
    final original = await store.loadJson(PriceList.fair);
    final card = RateCard.fromJson(original);

    final import = readRateCardCsv(
      'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
      'night-curtain-lo,Night Curtain,Up to 10ft,ft,50.00,44.00,',
      card,
    );
    await store.save(
      PriceList.fair,
      applyRateCardImportToJson(original, import),
    );

    // A completely fresh store over the same storage: the app restarting.
    final reopened = RateCardStore(directory: () async => temp);
    expect(await reopened.hasOverride(PriceList.fair), isTrue);

    final loaded = await reopened.load(PriceList.fair);
    expect(loaded.version, 2);
    final rule = loaded.rules.firstWhere((r) => r.id == 'night-curtain-lo');
    expect(rule.rateSen, 5000);
    expect(rule.mvpRateSen, 4400);
  });

  test('everything the CSV cannot express survives the round trip', () async {
    // The import edits the card's own JSON rather than serialising a RateCard
    // back out, precisely so nothing gets quietly dropped.
    final original = await store.loadJson(PriceList.fair);
    final before = RateCard.fromJson(original);

    final import = readRateCardCsv(
      'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
      'night-curtain-lo,a,b,ft,50.00,,',
      before,
    );
    await store.save(
      PriceList.fair,
      applyRateCardImportToJson(original, import),
    );
    final after = await store.load(PriceList.fair);

    expect(after.rules, hasLength(before.rules.length));
    expect(after.deliveryZones, hasLength(before.deliveryZones.length));
    expect(after.productRules, hasLength(before.productRules.length));
    expect(after.promo?.code, before.promo?.code);
    expect(after.config.minDepositSen, before.config.minDepositSen);

    final zebra = after.rules.firstWhere((r) => r.id == 'zebra-blackout-tbl');
    expect(zebra.materialKey, 'tbl');
    expect(zebra.minQty, isNotNull);

    final wallpaper = after.rules.firstWhere((r) => r.id == 'korea-wallpaper');
    expect(wallpaper.coverageSqft, isNotNull);
    expect(wallpaper.bundleQty, 2);

    final band = after.rules.firstWhere((r) => r.id == 'night-curtain-lo');
    expect(band.bandMaxTmm, 30481, reason: 'the fencepost must survive');
    expect(band.bandLabels, isNotNull);
  });

  test('the new price is what the engine charges after a restart', () async {
    final original = await store.loadJson(PriceList.fair);
    final import = readRateCardCsv(
      'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
      'night-curtain-lo,a,b,ft,50.00,,',
      RateCard.fromJson(original),
    );
    await store.save(
      PriceList.fair,
      applyRateCardImportToJson(original, import),
    );

    final card = await RateCardStore(
      directory: () async => temp,
    ).load(PriceList.fair);
    final priced = priceLine(
      request: LineRequest(
        variant: 'night_curtain',
        layer: Layer.night,
        width: Length.tenths(36576),
        height: Length.tenths(27432),
      ),
      card: card,
      stage: PricingStage.estimate,
    );
    // The whole point of hard rule 1: the price moved, and no code did.
    expect(priced.total.format(), 'RM 600.00');
  });

  test(
    'restoring throws the edit away and brings back the shipped list',
    () async {
      final original = await store.loadJson(PriceList.fair);
      await store.save(
        PriceList.fair,
        applyRateCardImportToJson(
          original,
          readRateCardCsv(
            'id,product,band,unit,rate_rm,mvp_rate_rm,min_qty\n'
            'night-curtain-lo,a,b,ft,99.00,,',
            RateCard.fromJson(original),
          ),
        ),
      );
      expect((await store.load(PriceList.fair)).version, 2);

      await store.restoreBundled(PriceList.fair);

      // A mistaken import at 9am must not cost the whole fair day.
      expect(await store.hasOverride(PriceList.fair), isFalse);
      final card = await store.load(PriceList.fair);
      expect(card.version, 1);
      expect(
        card.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        4600,
      );
    },
  );

  test('a corrupt override falls back rather than bricking the app', () async {
    // Mid-fair, an unreadable file must not stop someone quoting.
    File('${temp.path}/rate-card-fair.json').writeAsStringSync('{ not json');
    final card = await store.load(PriceList.fair);
    expect(card.version, 1);
    expect(
      await store.hasOverride(PriceList.fair),
      isFalse,
      reason: 'the bad file is cleared so it cannot fail twice',
    );
  });

  test(
    'an override that is valid JSON but not a card also falls back',
    () async {
      File(
        '${temp.path}/rate-card-current.json',
      ).writeAsStringSync(jsonEncode({'hello': 'world'}));
      expect((await store.load(PriceList.fair)).version, 1);
    },
  );
}
