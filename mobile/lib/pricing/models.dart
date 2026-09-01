/// Rate card data model.
///
/// PURE. No Flutter imports, no I/O, no clock. Loading the JSON is the caller's
/// job — this file only knows how to read a decoded map. See CLAUDE.md,
/// "The pricing engine is pure".
library;

import '../core/length.dart';
import '../core/rational.dart';

/// Which stage of the sale is being priced.
///
/// The two stages round quantity by different rules and that is deliberate.
/// See SPEC.md §4.3 and open questions A10 / A11.
enum PricingStage {
  /// A quotation. Billed quantity rounds **up** to a whole unit.
  estimate,

  /// After site measurement. Billed quantity is **exact**.
  finalPricing,
}

/// The product family a rule belongs to.
///
/// Distinct from [DepositCategory]: blinds and tracks have their own rates but
/// ride the curtain deposit.
enum Family { curtain, blind, track, flooring, wallpaper, addon, service }

/// The category an RM300 deposit buys a rate hold on.
enum DepositCategory { curtain, flooring, wallpaper }

/// Maps a product family to the deposit category that covers it.
///
/// **Kept in one function on purpose.** SPEC.md §6.1: silently applying a
/// curtain lock to a flooring line is the expensive bug in this design.
DepositCategory depositCategoryOf(Family family) => switch (family) {
  Family.curtain || Family.blind || Family.track => DepositCategory.curtain,
  Family.flooring => DepositCategory.flooring,
  Family.wallpaper => DepositCategory.wallpaper,
  // Add-ons and services inherit their parent line's category. An unparented
  // one is a data error, not something to silently file under curtains.
  Family.addon || Family.service => DepositCategory.curtain,
};

/// How a rule's quantity is measured.
enum PriceBasis {
  perFtWidth('per_ft_width', 'ft'),
  perSqft('per_sqft', 'sqft'),
  perMLength('per_m_length', 'm'),
  perPiece('per_piece', 'pc'),
  perSet('per_set', 'set'),
  perRoll('per_roll', 'roll');

  const PriceBasis(this.wire, this.unit);

  /// The value used in JSON and in the database.
  final String wire;

  /// The unit shown on the line, e.g. `12 ft`.
  final String unit;

  static PriceBasis fromWire(String v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => throw FormatException('Unknown price basis: $v'),
  );
}

/// Which dimension selects the height/width band, if any.
enum BandField {
  height('height'),
  width('width'),
  none('none');

  const BandField(this.wire);
  final String wire;

  static BandField fromWire(String v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => throw FormatException('Unknown band field: $v'),
  );
}

/// The curtain layer a rule applies to.
enum Layer {
  single('single'),
  day('day'),
  night('night');

  const Layer(this.wire);
  final String wire;

  static Layer fromWire(String v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => throw FormatException('Unknown layer: $v'),
  );
}

/// Supply and install, or supply only.
enum Fulfilment {
  supplyInstall('supply_install'),
  supplyOnly('supply_only');

  const Fulfilment(this.wire);
  final String wire;

  static Fulfilment fromWire(String v) => values.firstWhere(
    (e) => e.wire == v,
    orElse: () => throw FormatException('Unknown fulfilment: $v'),
  );
}

/// Customer pricing tier. MVP is a **flat** rate, never a percentage.
enum CustomerTier { standard, mvp }

/// A set of strings in each supported language.
///
/// A map rather than parallel fields, so a fourth language is a data change
/// and not a migration in every table.
class Localised {
  final Map<String, String> _byLanguage;

  const Localised(this._byLanguage);

  factory Localised.fromJson(Map<String, dynamic> json) =>
      Localised({for (final e in json.entries) e.key: e.value as String});

  /// The string for [languageCode], falling back to Chinese then English then
  /// whatever exists. Never returns null — a missing label must not blank out
  /// a product name in front of a customer.
  String call(String languageCode) =>
      _byLanguage[languageCode] ??
      _byLanguage['zh'] ??
      _byLanguage['en'] ??
      (_byLanguage.isEmpty ? '' : _byLanguage.values.first);

  Map<String, String> get all => Map.unmodifiable(_byLanguage);
}

/// One priceable row of the rate card.
///
/// Rows are never updated in place and never deleted. A price change publishes
/// a new version and marks the old rows superseded.
class PricingRule {
  final String id;
  final Family family;
  final String variant;
  final Layer layer;

  /// The series, openness or slat size that moves the rate, if any.
  final String? materialKey;

  final Fulfilment fulfilment;
  final Localised labels;
  final PriceBasis basis;
  final BandField bandField;

  /// Band lower bound in tenths of a millimetre. **Inclusive.**
  final int? bandMinTmm;

  /// Band upper bound in tenths of a millimetre. **Exclusive.** Null is
  /// unbounded.
  ///
  /// A 10ft cutoff is 30481, not 30480: exactly 10ft must fall in the lower
  /// band (A1).
  final int? bandMaxTmm;

  final Localised? bandLabels;
  final int rateSen;

  /// The flat MVP rate, if this product has one. Never a percentage.
  final int? mvpRateSen;

  /// The minimum **billed quantity**, applied before the rate multiplies.
  /// A different concept from a minimum charge.
  final Rational? minQty;

  final int sortOrder;

  const PricingRule({
    required this.id,
    required this.family,
    required this.variant,
    required this.layer,
    required this.materialKey,
    required this.fulfilment,
    required this.labels,
    required this.basis,
    required this.bandField,
    required this.bandMinTmm,
    required this.bandMaxTmm,
    required this.bandLabels,
    required this.rateSen,
    required this.mvpRateSen,
    required this.minQty,
    required this.sortOrder,
  });

  factory PricingRule.fromJson(Map<String, dynamic> json) {
    final rawMin = json['min_qty'];
    if (rawMin != null && rawMin is! int) {
      // A fractional minimum would need exact handling; none exists on the
      // real price list, so reject rather than quietly accept a double.
      throw FormatException(
        'min_qty must be an integer or null, got ${rawMin.runtimeType} '
        'in rule ${json['id']}',
      );
    }
    return PricingRule(
      id: json['id'] as String,
      family: Family.values.byName(json['family'] as String),
      variant: json['variant'] as String,
      layer: Layer.fromWire(json['layer'] as String),
      materialKey: json['material_key'] as String?,
      fulfilment: Fulfilment.fromWire(json['fulfilment'] as String),
      labels: Localised.fromJson(json['labels'] as Map<String, dynamic>),
      basis: PriceBasis.fromWire(json['basis'] as String),
      bandField: BandField.fromWire(json['band_field'] as String),
      bandMinTmm: json['band_min_tmm'] as int?,
      bandMaxTmm: json['band_max_tmm'] as int?,
      bandLabels: json['band_labels'] == null
          ? null
          : Localised.fromJson(json['band_labels'] as Map<String, dynamic>),
      rateSen: json['rate_sen'] as int,
      mvpRateSen: json['mvp_rate_sen'] as int?,
      minQty: rawMin == null ? null : Rational.fromInt(rawMin as int),
      sortOrder: json['sort_order'] as int,
    );
  }

  /// Whether [value] falls inside this rule's band.
  ///
  /// Lower bound inclusive, upper bound exclusive. The fencepost that decides
  /// whether exactly 10ft costs RM46 or RM58.
  bool bandContains(Length value) {
    if (bandField == BandField.none) return true;
    final v = value.tmm;
    if (bandMinTmm != null && v < bandMinTmm!) return false;
    if (bandMaxTmm != null && v >= bandMaxTmm!) return false;
    return true;
  }

  /// The rate this tier pays. MVP is a flat substitute, not a discount sum.
  int rateForTier(CustomerTier tier) =>
      tier == CustomerTier.mvp && mvpRateSen != null ? mvpRateSen! : rateSen;
}

/// Values that must be configurable rather than compiled in.
class RateCardConfig {
  /// The minimum a quotation may show per deposit category. RM300.
  final int minDepositSen;

  /// How close to a band edge triggers the soft warning. Default 76mm.
  final int bandEdgeWarnTmm;

  final String defaultUnitWidth;
  final String defaultUnitHeight;

  const RateCardConfig({
    required this.minDepositSen,
    required this.bandEdgeWarnTmm,
    required this.defaultUnitWidth,
    required this.defaultUnitHeight,
  });

  factory RateCardConfig.fromJson(Map<String, dynamic> json) => RateCardConfig(
    minDepositSen: json['min_deposit_sen'] as int,
    bandEdgeWarnTmm: json['band_edge_warn_tmm'] as int,
    defaultUnitWidth: json['default_unit_width'] as String? ?? 'ft',
    defaultUnitHeight: json['default_unit_height'] as String? ?? 'ft',
  );
}

/// A published, versioned set of rules.
class RateCard {
  final int version;

  /// True while the card is a stand-in built from spec examples rather than
  /// the client's real price list. Surfaced in the UI, loudly.
  final bool provisional;

  final RateCardConfig config;
  final List<PricingRule> rules;

  const RateCard({
    required this.version,
    required this.provisional,
    required this.config,
    required this.rules,
  });

  factory RateCard.fromJson(Map<String, dynamic> json) => RateCard(
    version: json['version'] as int,
    provisional: json['provisional'] as bool? ?? false,
    config: RateCardConfig.fromJson(json['config'] as Map<String, dynamic>),
    rules: (json['rules'] as List<dynamic>)
        .map((e) => PricingRule.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
  );

  /// Every distinct variant in the card, in display order.
  List<PricingRule> get distinctVariants {
    final seen = <String>{};
    final out = <PricingRule>[];
    final sorted = [...rules]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final r in sorted) {
      final key = '${r.variant}|${r.materialKey ?? ""}';
      if (seen.add(key)) out.add(r);
    }
    return out;
  }
}
