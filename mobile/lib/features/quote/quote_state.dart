/// Quote state. Riverpod, per CLAUDE.md.
///
/// Phase 1 keeps nothing between launches — SPEC.md is explicit that
/// persistence arrives with Drift in Phase 2. State does survive backgrounding
/// within a session, which §8.1 requires ("the app will be backgrounded
/// mid-quote by a phone call").
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/length.dart';
import '../../pricing/engine.dart';
import '../../pricing/models.dart';

/// One window on the quote.
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

  QuoteLine copyWith({int? quantity}) => QuoteLine(
    id: id,
    room: room,
    variant: variant,
    materialKey: materialKey,
    layer: layer,
    width: width,
    height: height,
    quantity: quantity ?? this.quantity,
    rawWidth: rawWidth,
    rawHeight: rawHeight,
  );
}

/// The whole quote.
class QuoteState {
  final List<QuoteLine> lines;
  final CustomerTier tier;

  const QuoteState({this.lines = const [], this.tier = CustomerTier.standard});

  QuoteState copyWith({List<QuoteLine>? lines, CustomerTier? tier}) =>
      QuoteState(lines: lines ?? this.lines, tier: tier ?? this.tier);
}

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
/// Phase 1 has no user record, so this is session state.
final languageProvider = StateProvider<String>((ref) => 'zh');

final quoteProvider = NotifierProvider<QuoteNotifier, QuoteState>(
  QuoteNotifier.new,
);

class QuoteNotifier extends Notifier<QuoteState> {
  var _sequence = 0;

  @override
  QuoteState build() => const QuoteState();

  String _nextId() => 'line-${_sequence++}';

  void addLine({
    required String room,
    required String variant,
    required String? materialKey,
    required Layer layer,
    required Length width,
    required Length? height,
    required String rawWidth,
    required String rawHeight,
    int quantity = 1,
  }) {
    state = state.copyWith(
      lines: [
        ...state.lines,
        QuoteLine(
          id: _nextId(),
          room: room,
          variant: variant,
          materialKey: materialKey,
          layer: layer,
          width: width,
          height: height,
          quantity: quantity,
          rawWidth: rawWidth,
          rawHeight: rawHeight,
        ),
      ],
    );
  }

  /// Removes a line, returning it and its position so an undo can restore it
  /// exactly where it was. §8.1 prefers undo over a confirmation dialog, which
  /// gets tapped through blindly under pressure.
  (QuoteLine, int)? removeLine(String id) {
    final index = state.lines.indexWhere((l) => l.id == id);
    if (index == -1) return null;
    final line = state.lines[index];
    state = state.copyWith(lines: [...state.lines]..removeAt(index));
    return (line, index);
  }

  void restoreLine(QuoteLine line, int index) {
    final lines = [...state.lines];
    lines.insert(index.clamp(0, lines.length), line);
    state = state.copyWith(lines: lines);
  }

  void setTier(CustomerTier tier) => state = state.copyWith(tier: tier);

  void clear() => state = const QuoteState();
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

  const PricedQuote({
    required this.lines,
    required this.totals,
    required this.provisionalCard,
  });
}

/// Prices the whole quote at the estimate stage.
///
/// A line that cannot be priced does not take the quote down with it: it shows
/// its own error and the rest still totals. A part-timer mid-fair needs the
/// other five windows to keep working.
final pricedQuoteProvider = Provider<AsyncValue<PricedQuote>>((ref) {
  final cardAsync = ref.watch(rateCardProvider);
  final quote = ref.watch(quoteProvider);

  return cardAsync.whenData((card) {
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

    return PricedQuote(
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
    );
  });
});
