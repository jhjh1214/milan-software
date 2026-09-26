/// Quote state. Riverpod over a Drift database, per CLAUDE.md.
///
/// The database is the source of truth, not this file. Every mutation lands in
/// SQLite before the UI reports success, so a phone call mid-quote, a
/// force-quit, or a dropped handset at a fair costs nothing — SPEC.md §8.1.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/length.dart';
import '../../core/money.dart';
import '../../core/rational.dart';
import '../../data/database.dart';
import '../../data/quote_repository.dart';
import '../../data/rate_card_store.dart';
import '../../data/settings_repository.dart';
import '../../pricing/einvoice_threshold.dart';
import '../../pricing/engine.dart';
import '../../pricing/models.dart';
// `Family` is Riverpod's too. Prefixed so the pricing one can be named where
// both are in scope.
import '../../pricing/models.dart' as models;
import '../../pricing/rate_lock.dart' show Channel;

/// The on-device database. Overridden with an in-memory one in tests.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final quoteRepositoryProvider = Provider<QuoteRepository>(
  (ref) => QuoteRepository(ref.watch(databaseProvider)),
);

/// Where the price list lives. Overridden in tests.
final rateCardStoreProvider = Provider<RateCardStore>((ref) => RateCardStore());

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

/// Whether this handset is at a fair. Defaults to on — see [kFairModeKey].
final fairModeProvider = AsyncNotifierProvider<FairModeNotifier, bool>(
  FairModeNotifier.new,
);

class FairModeNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() =>
      ref.watch(settingsRepositoryProvider).fairModeEnabled();

  Future<void> set(bool enabled) async {
    await ref.read(settingsRepositoryProvider).setFairMode(enabled);
    state = AsyncData(enabled);
    // The channel decides which card prices the quote, so everything derived
    // from it has to be rebuilt rather than left showing yesterday's prices.
    ref.invalidate(activeRateCardProvider);
  }
}

/// The price list in force, which one it is, and the channel that chose it.
///
/// Two conditions, both required: the handset must be in fair mode **and** the
/// fair card's promo window must cover today. §3: "Promo and the 12-month lock
/// are fair-only. Showroom pays standard."
///
/// The store resolves both together, because deciding the channel needs the
/// fair card's window and choosing the list needs the channel. Splitting them
/// across two providers made that circular, and recorded the first quote of a
/// session as `showroom` while the card was still loading.
final activeRateCardProvider = FutureProvider<ActiveRateCard>((ref) async {
  final enabled = await ref.watch(fairModeProvider.future);
  return ref
      .watch(rateCardStoreProvider)
      .loadActiveForHandset(ref.watch(todayProvider), fairModeEnabled: enabled);
});

/// Where a quote started now would be taken.
///
/// Read off the active card rather than computed again, so there is one answer
/// and it cannot drift from the prices on screen.
final channelProvider = Provider<Channel>(
  (ref) =>
      ref.watch(activeRateCardProvider).valueOrNull?.channel ??
      Channel.showroom,
);

/// The card in force. The card is data, never code — CLAUDE.md hard rule 1.
final rateCardProvider = FutureProvider<RateCard>(
  (ref) async => (await ref.watch(activeRateCardProvider.future)).card,
);

/// The fair card itself, whichever list is in force — its promo window is
/// when the fair runs. Rebuilds whenever the active card does, which is
/// what a sync invalidates after pulling a new version of either list.
final fairCardProvider = FutureProvider<RateCard>((ref) async {
  await ref.watch(activeRateCardProvider.future);
  return ref.watch(rateCardStoreProvider).load(PriceList.fair);
});

/// The RM10,000 figures in force, off the card. SPEC.md §10.3: config, not
/// code, so a change reaches every handset by publishing a card.
///
/// Falls back to the law rather than to no check at all while the card is
/// still loading — a screen that renders before the pull finishes must not be
/// a screen where the threshold is off.
final thresholdsProvider = Provider<ThresholdConfig>((ref) {
  final card = ref.watch(rateCardProvider).valueOrNull;
  return card?.config.thresholds ??
      const ThresholdConfig(
        threshold: Money.sen(1000000),
        prompt: Money.sen(800000),
      );
});

/// Every published card this handset is holding, keyed by version.
///
/// What final pricing needs (§11 Phase 6): a measured line reprices at the
/// version **it** recorded, and if that version is not among these it refuses
/// rather than falling back to today's card. Falling back is exactly what the
/// RM300 was taken to prevent.
///
/// Both lists, not just the active one. An order taken at a fair pinned the
/// fair card; the handset is very likely on the standard list by the time
/// somebody goes out to measure it.
///
/// If both lists happen to sit at the same version the map holds one entry,
/// which is correct — they would be the same card.
final heldCardsProvider = FutureProvider<Map<int, RateCard>>((ref) async {
  final store = ref.watch(rateCardStoreProvider);
  final cards = <int, RateCard>{};
  for (final list in PriceList.values) {
    final card = await store.load(list);
    cards[card.version] = card;
  }
  return cards;
});

/// The user's chosen language. Per user, not per device — SPEC.md §8.3.
final languageProvider = StateProvider<String>((ref) => 'zh');

/// Today's date, injected rather than read at the point of use.
///
/// It decides which price list applies, so a test can quote a November walk-in
/// without waiting for November.
///
/// The pricing engine takes no clock (CLAUDE.md), and overriding this in a test
/// is what lets the expired-fair-rate warning be pinned to a fixed date instead
/// of passing until August 2026 and failing quietly afterwards.
final todayProvider = Provider<DateTime>((ref) => DateTime.now());

/// One window on the quote, as the app works with it.
class QuoteLine {
  final String id;
  final String room;
  final String variant;
  final String? materialKey;
  final Layer layer;

  /// Null only for a [directAreaSqft] line -- a saved room has no real width
  /// or height to give (SPEC.md's property library: an L-shaped room's area
  /// does not reduce to one rectangle), so there is nothing honest to put
  /// here.
  final Length? width;
  final Length? height;

  /// A pre-known area, in square feet, exact. A room-sourced flooring line
  /// prices from this instead of [width] x [height]. Meaningful only for a
  /// `per_sqft` product.
  final Rational? directAreaSqft;
  final int quantity;

  /// Exactly what the user typed, kept so the line can show entered and billed
  /// side by side without inventing precision. §5.5. An empty string already
  /// means "nothing was typed" -- the per_roll default-pack case uses the
  /// same convention.
  final String rawWidth;
  final String rawHeight;

  /// The line this is an upgrade to, if any — a special track on a curtain, a
  /// motor on a blind. Upgrades add to their parent rather than replacing it
  /// (A16).
  final String? parentLineId;

  /// On-device path to this window's photo, if one was taken.
  final String? photoPath;

  /// Where this line's dimensions came from. SPEC.md Phase 8's Property /
  /// Project / Unit Library. Null means typed by hand — true of every line
  /// before this library existed.
  final String? sourceProjectId;
  final String? sourceUnitTypeId;
  final int? sourceVersion;

  const QuoteLine({
    required this.id,
    required this.room,
    required this.variant,
    required this.materialKey,
    required this.layer,
    required this.width,
    required this.height,
    required this.quantity,
    required this.rawWidth,
    required this.rawHeight,
    this.directAreaSqft,
    this.parentLineId,
    this.photoPath,
    this.sourceProjectId,
    this.sourceUnitTypeId,
    this.sourceVersion,
  });

  bool get isUpgrade => parentLineId != null;

  /// Whether the dimensions on this line came from a saved plan rather than
  /// being typed at the moment of quoting.
  bool get isFromLibrary => sourceUnitTypeId != null;

  factory QuoteLine.fromRow(QuoteLineRow row) => QuoteLine(
    id: row.id,
    room: row.room,
    variant: row.variant,
    materialKey: row.materialKey,
    layer: Layer.fromWire(row.layer),
    width: row.widthTmm == null ? null : Length.tenths(row.widthTmm!),
    height: row.heightTmm == null ? null : Length.tenths(row.heightTmm!),
    directAreaSqft: row.directAreaSqft == null
        ? null
        : Rational.tryParse(row.directAreaSqft!),
    quantity: row.quantity,
    rawWidth: row.rawWidth,
    rawHeight: row.rawHeight,
    parentLineId: row.parentLineId,
    photoPath: row.photoPath,
    sourceProjectId: row.sourceProjectId,
    sourceUnitTypeId: row.sourceUnitTypeId,
    sourceVersion: row.sourceVersion,
  );
}

/// The whole quote, as loaded from the database.
class QuoteState {
  final String quoteId;
  final List<QuoteLine> lines;
  final CustomerTier tier;

  /// Null means Melaka town, which carries no travel charge.
  final String? deliveryZoneId;

  final String? customerName;
  final String? customerPhone;

  /// Where the visit will be, if the customer has it (§13 C10). Optional.
  final String? siteAddress;
  final String? sitePostcode;
  final DateTime? siteReadyFrom;

  /// Where this quote was taken, fixed when it started. It decides whether an
  /// RM300 can lock anything (§13 B1) and whether the category prompt appears
  /// at all (§6.2).
  final Channel channel;

  const QuoteState({
    required this.quoteId,
    this.lines = const [],
    this.tier = CustomerTier.standard,
    this.deliveryZoneId,
    this.customerName,
    this.customerPhone,
    this.siteAddress,
    this.sitePostcode,
    this.siteReadyFrom,
    this.channel = Channel.showroom,
  });
}

final quoteProvider = AsyncNotifierProvider<QuoteNotifier, QuoteState>(
  QuoteNotifier.new,
);

class QuoteNotifier extends AsyncNotifier<QuoteState> {
  QuoteRepository get _repo => ref.read(quoteRepositoryProvider);

  @override
  Future<QuoteState> build() async {
    final card = await ref.watch(rateCardProvider.future);
    final language = ref.watch(languageProvider);
    final quote = await _repo.ensureDraft(
      rateCardVersion: card.version,
      language: language,
      channel: ref.watch(channelProvider).wire,
    );
    return _load(quote);
  }

  Future<QuoteState> _load(QuoteRow quote) async {
    final rows = await _repo.lines(quote.id);
    return QuoteState(
      quoteId: quote.id,
      lines: rows.map(QuoteLine.fromRow).toList(growable: false),
      tier: quote.tier == 'mvp' ? CustomerTier.mvp : CustomerTier.standard,
      deliveryZoneId: quote.deliveryZoneId,
      customerName: quote.customerName,
      customerPhone: quote.customerPhone,
      siteAddress: quote.siteAddress,
      sitePostcode: quote.sitePostcode,
      siteReadyFrom: quote.siteReadyFrom,
      channel: Channel.fromWire(quote.channel),
    );
  }

  /// Reloads everything from the database rather than patching state in place.
  ///
  /// The database is the source of truth, so state is always a projection of
  /// it. Patching in memory is how the two drift apart.
  Future<void> _refresh() async {
    final quote = await _repo.currentQuote();
    if (quote == null) return;
    state = AsyncData(await _load(quote));
  }

  /// Adds a line and returns its id, so an upgrade can attach to it.
  ///
  /// [width] is null only for a room-sourced flooring line, which prices
  /// from [directAreaSqft] instead (SPEC.md's property library).
  Future<String?> addLine({
    required String room,
    required String variant,
    required String? materialKey,
    required Layer layer,
    required Length? width,
    required Length? height,
    required String rawWidth,
    required String rawHeight,
    Rational? directAreaSqft,
    int quantity = 1,
    String? parentLineId,
    String? sourceProjectId,
    String? sourceUnitTypeId,
    int? sourceVersion,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return null;
    final id = await _repo.addLine(
      quoteId: current.quoteId,
      room: room,
      variant: variant,
      materialKey: materialKey,
      layer: layer.wire,
      widthTmm: width?.tmm,
      heightTmm: height?.tmm,
      rawWidth: rawWidth,
      rawHeight: rawHeight,
      directAreaSqft: directAreaSqft?.toString(),
      quantity: quantity,
      parentLineId: parentLineId,
      sourceProjectId: sourceProjectId,
      sourceUnitTypeId: sourceUnitTypeId,
      sourceVersion: sourceVersion,
    );
    await _refresh();
    return id;
  }

  /// Removes a line **and its upgrades**, returning the rows so an undo can put
  /// them all back exactly where they were.
  ///
  /// Deleting a curtain must take its special track with it. An orphaned
  /// RM80/ft track line left on the quote is both wrong and nearly invisible.
  Future<List<QuoteLineRow>> removeLine(String id) async {
    final current = state.valueOrNull;
    if (current == null) return const [];
    final removed = await _repo.deleteLineWithChildren(id);
    await _refresh();
    return removed;
  }

  Future<void> restoreLines(List<QuoteLineRow> rows) async {
    await _repo.restoreLines(rows);
    await _refresh();
  }

  Future<void> setTier(CustomerTier tier) async {
    final current = state.valueOrNull;
    if (current == null) return;
    await _repo.setTier(current.quoteId, tier.name);
    await _refresh();
  }

  /// Sets the delivery area, or clears it for Melaka town.
  ///
  /// §4.1: asked early and surfaced before the total, never after the customer
  /// has agreed a number.
  Future<void> setDeliveryZone(String? zoneId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    await _repo.setDeliveryZone(current.quoteId, zoneId);
    await _refresh();
  }

  /// Attaches or clears a window's photo.
  Future<void> setLinePhoto(String lineId, String? path) async {
    await _repo.setLinePhoto(lineId, path);
    await _refresh();
  }

  Future<void> setCustomer({String? name, String? phone}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    await _repo.setCustomer(current.quoteId, name, phone);
    await _refresh();
  }

  /// Where the visit will be. All optional; copied onto the order when the
  /// deposit confirms it.
  Future<void> setSite({
    String? address,
    String? postcode,
    DateTime? readyFrom,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;
    await _repo.setSite(
      current.quoteId,
      address: address,
      postcode: postcode,
      readyFrom: readyFrom,
    );
    await _refresh();
  }

  Future<void> clear() async {
    await _repo.clearAll();
    ref.invalidateSelf();
  }
}

/// A line together with the price the engine gave it, or the error it raised.
class PricedQuoteLine {
  final QuoteLine line;
  final PricedLine? priced;
  final Object? error;

  const PricedQuoteLine({required this.line, this.priced, this.error});

  bool get hasError => error != null;
}

/// Everything the quote screen needs, priced.
class PricedQuote {
  final List<PricedQuoteLine> lines;
  final QuoteTotals totals;
  final bool provisionalCard;

  /// Rules the quote as a whole breaks — a herringbone floor with no self
  /// levelling, an intermediate joint with no motor. Surfaced, never used to
  /// refuse the quote: refusing loses the sale, staying silent loses the floor.
  final List<OrderRuleViolation> orderIssues;

  /// Which price list produced these numbers, and its promo if it is the fair
  /// one.
  ///
  /// Always shown. A quote is either a fair price or a standard price, and the
  /// salesperson holding the phone has to know which — §3 makes the difference
  /// a 20% one on curtains.
  final PriceList priceList;
  final CardPromo? promo;

  const PricedQuote({
    required this.lines,
    required this.totals,
    required this.provisionalCard,
    required this.priceList,
    this.orderIssues = const [],
    this.promo,
  });
}

/// Prices the whole quote at the estimate stage.
///
/// A line that cannot be priced does not take the quote down with it: it shows
/// its own error and the rest still totals. A part-timer mid-fair needs the
/// other five windows to keep working.
final pricedQuoteProvider = Provider<AsyncValue<PricedQuote>>((ref) {
  final activeAsync = ref.watch(activeRateCardProvider);
  final quoteAsync = ref.watch(quoteProvider);

  if (activeAsync.isLoading || quoteAsync.isLoading) {
    return const AsyncValue.loading();
  }
  final active = activeAsync.valueOrNull;
  final quote = quoteAsync.valueOrNull;
  if (active == null || quote == null) {
    return AsyncValue.error(
      activeAsync.error ?? quoteAsync.error ?? 'rate card unavailable',
      StackTrace.current,
    );
  }
  final card = active.card;

  // What family each line belongs to, so an add-on can be told whose it is.
  // A motor has no deposit category of its own — it takes the curtain's — and
  // without this the total raises rather than guessing (hard rule 6). Built
  // once for the whole quote rather than looked up per line.
  final familyOfLine = <String, models.Family>{
    for (final line in quote.lines)
      for (final rule in card.rules)
        if (rule.variant == line.variant) line.id: rule.family,
  };

  final priced = <PricedQuoteLine>[];
  for (final line in quote.lines) {
    try {
      priced.add(
        PricedQuoteLine(
          line: line,
          priced: priceLine(
            request: LineRequest(
              variant: line.variant,
              materialKey: line.materialKey,
              layer: line.layer,
              width: line.width,
              height: line.height,
              directAreaSqft: line.directAreaSqft,
              quantity: line.quantity,
              parentFamily: line.parentLineId == null
                  ? null
                  : familyOfLine[line.parentLineId],
            ),
            card: card,
            stage: PricingStage.estimate,
            tier: quote.tier,
          ),
        ),
      );
    } catch (e) {
      priced.add(PricedQuoteLine(line: line, error: e));
    }
  }

  return AsyncValue.data(
    PricedQuote(
      lines: priced,
      totals: totalQuote(
        lines: [
          for (final p in priced)
            if (p.priced != null) p.priced!,
        ],
        card: card,
        stage: PricingStage.estimate,
        deliveryZoneId: quote.deliveryZoneId,
      ),
      orderIssues: checkOrderRules(
        lines: [
          for (final p in priced)
            if (p.priced != null) p.priced!,
        ],
        card: card,
      ),
      provisionalCard: card.provisional,
      priceList: active.list,
      promo: card.promo,
    ),
  );
});
