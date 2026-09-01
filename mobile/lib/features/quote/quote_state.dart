/// Quote state. Riverpod over a Drift database, per CLAUDE.md.
///
/// The database is the source of truth, not this file. Every mutation lands in
/// SQLite before the UI reports success, so a phone call mid-quote, a
/// force-quit, or a dropped handset at a fair costs nothing — SPEC.md §8.1.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/length.dart';
import '../../data/database.dart';
import '../../data/quote_repository.dart';
import '../../pricing/engine.dart';
import '../../pricing/models.dart';

/// The on-device database. Overridden with an in-memory one in tests.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final quoteRepositoryProvider = Provider<QuoteRepository>(
  (ref) => QuoteRepository(ref.watch(databaseProvider)),
);

/// Loads the rate card from the bundled asset.
///
/// The card is data, never code. Replacing it must not require a rebuild of
/// anything but the asset — CLAUDE.md hard rule 1.
final rateCardProvider = FutureProvider<RateCard>((ref) async {
  final raw = await rootBundle.loadString(
    'assets/data/rate-card-fair-2026-08.json',
  );
  return RateCard.fromJson(jsonDecode(raw) as Map<String, dynamic>);
});

/// The user's chosen language. Per user, not per device — SPEC.md §8.3.
final languageProvider = StateProvider<String>((ref) => 'zh');

/// Today's date, injected rather than read at the point of use.
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
  final Length width;
  final Length? height;
  final int quantity;

  /// Exactly what the user typed, kept so the line can show entered and billed
  /// side by side without inventing precision. §5.5.
  final String rawWidth;
  final String rawHeight;

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
  });

  factory QuoteLine.fromRow(QuoteLineRow row) => QuoteLine(
    id: row.id,
    room: row.room,
    variant: row.variant,
    materialKey: row.materialKey,
    layer: Layer.fromWire(row.layer),
    width: Length.tenths(row.widthTmm),
    height: row.heightTmm == null ? null : Length.tenths(row.heightTmm!),
    quantity: row.quantity,
    rawWidth: row.rawWidth,
    rawHeight: row.rawHeight,
  );
}

/// The whole quote, as loaded from the database.
class QuoteState {
  final String quoteId;
  final List<QuoteLine> lines;
  final CustomerTier tier;

  const QuoteState({
    required this.quoteId,
    this.lines = const [],
    this.tier = CustomerTier.standard,
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
    );
    return _load(quote.id, quote.tier);
  }

  Future<QuoteState> _load(String quoteId, String tier) async {
    final rows = await _repo.lines(quoteId);
    return QuoteState(
      quoteId: quoteId,
      lines: rows.map(QuoteLine.fromRow).toList(growable: false),
      tier: tier == 'mvp' ? CustomerTier.mvp : CustomerTier.standard,
    );
  }

  Future<void> _refresh() async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(await _load(current.quoteId, current.tier.name));
  }

  Future<void> addLine({
    required String room,
    required String variant,
    required String? materialKey,
    required Layer layer,
    required Length width,
    required Length? height,
    required String rawWidth,
    required String rawHeight,
    int quantity = 1,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;
    await _repo.addLine(
      quoteId: current.quoteId,
      room: room,
      variant: variant,
      materialKey: materialKey,
      layer: layer.wire,
      widthTmm: width.tmm,
      heightTmm: height?.tmm,
      rawWidth: rawWidth,
      rawHeight: rawHeight,
      quantity: quantity,
    );
    await _refresh();
  }

  /// Removes a line and returns the stored row, so an undo can put it back
  /// exactly where it was rather than on the end of the list.
  Future<QuoteLineRow?> removeLine(String id) async {
    final current = state.valueOrNull;
    if (current == null) return null;
    final rows = await _repo.lines(current.quoteId);
    final row = rows.where((r) => r.id == id).firstOrNull;
    if (row == null) return null;
    await _repo.deleteLine(id);
    await _refresh();
    return row;
  }

  Future<void> restoreLine(QuoteLineRow row) async {
    await _repo.restoreLine(row);
    await _refresh();
  }

  Future<void> setTier(CustomerTier tier) async {
    final current = state.valueOrNull;
    if (current == null) return;
    await _repo.setTier(current.quoteId, tier.name);
    state = AsyncData(await _load(current.quoteId, tier.name));
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

  /// The promotion these rates belong to, when it has already ended.
  ///
  /// Non-null means the app is quoting expired fair rates, which undercharges
  /// on every sale until a standard list exists — SPEC.md §13 A3.
  final CardPromo? expiredPromo;

  const PricedQuote({
    required this.lines,
    required this.totals,
    required this.provisionalCard,
    this.expiredPromo,
  });
}

/// Prices the whole quote at the estimate stage.
///
/// A line that cannot be priced does not take the quote down with it: it shows
/// its own error and the rest still totals. A part-timer mid-fair needs the
/// other five windows to keep working.
final pricedQuoteProvider = Provider<AsyncValue<PricedQuote>>((ref) {
  final cardAsync = ref.watch(rateCardProvider);
  final quoteAsync = ref.watch(quoteProvider);
  final today = ref.watch(todayProvider);

  if (cardAsync.isLoading || quoteAsync.isLoading) {
    return const AsyncValue.loading();
  }
  final card = cardAsync.valueOrNull;
  final quote = quoteAsync.valueOrNull;
  if (card == null || quote == null) {
    return AsyncValue.error(
      cardAsync.error ?? quoteAsync.error ?? 'rate card unavailable',
      StackTrace.current,
    );
  }

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
              quantity: line.quantity,
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
      ),
      provisionalCard: card.provisional,
      expiredPromo: card.isExpiredOn(today) ? card.promo : null,
    ),
  );
});
