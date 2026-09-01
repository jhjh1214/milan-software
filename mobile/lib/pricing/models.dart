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

  /// Square feet one roll or box covers, for `per_roll`.
  final Rational? coverageSqft;

  /// How many units one charge delivers. The Korea wallpaper is a
  /// buy-one-free-one pair: charge 1, deliver 2.
  final int bundleQty;

  /// Overrides the family's deposit category. Flooring services ride the
  /// flooring deposit, not the curtain one.
  final DepositCategory? depositCategoryOverride;

  final bool isAddon;

  /// Variants this add-on may attach to. Null means any.
  final List<String>? attachesTo;

  /// Free text from the price list — series, warranty, openness. Not priced.
  final String? note;

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
    this.coverageSqft,
    this.bundleQty = 1,
    this.depositCategoryOverride,
    this.isAddon = false,
    this.attachesTo,
    this.note,
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
      coverageSqft: json['coverage_sqft'] == null
          ? null
          : Rational.fromInt(json['coverage_sqft'] as int),
      bundleQty: json['bundle_qty'] as int? ?? 1,
      depositCategoryOverride: json['deposit_category'] == null
          ? null
          : DepositCategory.values.byName(json['deposit_category'] as String),
      isAddon: json['is_addon'] as bool? ?? false,
      attachesTo: (json['attaches_to'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(growable: false),
      note: json['note'] as String?,
    );
  }

  /// The deposit category a lock on this line would belong to.
  DepositCategory get depositCategory =>
      depositCategoryOverride ?? depositCategoryOf(family);

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

/// An order-level charge driven by the delivery address, not by any line.
///
/// SPEC.md §4.1: ask for the delivery area early and surface the charge
/// **before** the total, never after the customer has agreed a number.
class DeliveryZone {
  final String id;
  final int chargeSen;

  /// `round_trip` or `transport`. Different words on the printed quote.
  final String chargeKind;

  final List<String> areaLabels;
  final Localised labels;

  const DeliveryZone({
    required this.id,
    required this.chargeSen,
    required this.chargeKind,
    required this.areaLabels,
    required this.labels,
  });

  factory DeliveryZone.fromJson(Map<String, dynamic> json) => DeliveryZone(
    id: json['id'] as String,
    chargeSen: json['charge_sen'] as int,
    chargeKind: json['charge_kind'] as String,
    areaLabels: (json['area_labels'] as List<dynamic>)
        .map((e) => e as String)
        .toList(growable: false),
    labels: Localised.fromJson(json['labels'] as Map<String, dynamic>),
  );
}

/// A constraint rather than a price. "ZIP blinds max 20ft wide" is not
/// something to discover at installation.
class ProductRule {
  final String id;
  final String variant;

  /// `requires`, `excludes`, `max_dimension` or `min_dimension`.
  final String kind;

  final String? target;
  final String? dimension;
  final int? valueTmm;
  final Localised messages;

  const ProductRule({
    required this.id,
    required this.variant,
    required this.kind,
    required this.messages,
    this.target,
    this.dimension,
    this.valueTmm,
  });

  factory ProductRule.fromJson(Map<String, dynamic> json) => ProductRule(
    id: json['id'] as String,
    variant: json['variant'] as String,
    kind: json['kind'] as String,
    target: json['target'] as String?,
    dimension: json['dimension'] as String?,
    valueTmm: json['value_tmm'] as int?,
    messages: Localised.fromJson(json['messages'] as Map<String, dynamic>),
  );
}

/// The promotion a card's rates belong to, and how long they are good for.
///
/// A fair card is a four-day price. Quoting from it in the showroom in
/// November undercharges on every sale, so the window is data the app can
/// check rather than something staff have to remember.
class CardPromo {
  final String code;
  final DateTime validFrom;
  final DateTime validTo;
  final String? note;

  const CardPromo({
    required this.code,
    required this.validFrom,
    required this.validTo,
    this.note,
  });

  factory CardPromo.fromJson(Map<String, dynamic> json) => CardPromo(
    code: json['code'] as String,
    validFrom: DateTime.parse(json['valid_from'] as String),
    validTo: DateTime.parse(json['valid_to'] as String),
    note: json['note'] as String?,
  );

  /// Whether [now] falls inside the promotion. Inclusive of the final day.
  ///
  /// [now] is passed in, never read from the system clock — CLAUDE.md keeps the
  /// engine free of clock reads so a test can pin the date.
  bool coversDate(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return !day.isBefore(validFrom) && !day.isAfter(validTo);
  }
}

/// A published, versioned set of rules.
class RateCard {
  final int version;

  /// True while the card is a stand-in built from spec examples rather than
  /// the client's real price list. Surfaced in the UI, loudly.
  final bool provisional;

  final RateCardConfig config;
  final List<PricingRule> rules;
  final List<DeliveryZone> deliveryZones;
  final List<ProductRule> productRules;

  /// The promotion these rates belong to, if they are promotional at all.
  final CardPromo? promo;

  const RateCard({
    required this.version,
    required this.provisional,
    required this.config,
    required this.rules,
    this.deliveryZones = const [],
    this.productRules = const [],
    this.promo,
  });

  /// True when this card's rates are promotional and the promotion has ended.
  ///
  /// Quoting from an expired fair card is not a rounding error — it is every
  /// sale undercharged until someone notices. Until A3 supplies a standard
  /// list, this is the only thing standing between a fair price and a November
  /// walk-in.
  bool isExpiredOn(DateTime now) => promo != null && !promo!.coversDate(now);

  factory RateCard.fromJson(Map<String, dynamic> json) => RateCard(
    version: json['version'] as int,
    provisional: json['provisional'] as bool? ?? false,
    promo: json['promo'] == null
        ? null
        : CardPromo.fromJson(json['promo'] as Map<String, dynamic>),
    config: RateCardConfig.fromJson(json['config'] as Map<String, dynamic>),
    rules: (json['rules'] as List<dynamic>)
        .map((e) => PricingRule.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    deliveryZones:
        (json['delivery_zones'] as List<dynamic>?)
            ?.map((e) => DeliveryZone.fromJson(e as Map<String, dynamic>))
            .toList(growable: false) ??
        const [],
    productRules:
        (json['product_rules'] as List<dynamic>?)
            ?.map((e) => ProductRule.fromJson(e as Map<String, dynamic>))
            .toList(growable: false) ??
        const [],
  );

  /// Every rule for one variant, whatever its band or material.
  List<PricingRule> forVariant(String variant) =>
      rules.where((r) => r.variant == variant).toList(growable: false);

  /// One entry per product a user can pick, in display order.
  ///
  /// Keyed on the variant alone, not on variant-and-material: at a fair the
  /// customer picks "Zebra Blackout", not "Zebra Blackout TBL". Material is
  /// chosen at measurement — see [PricingStage] and the deferred-material
  /// handling in the engine.
  ///
  /// Add-ons are excluded; they attach to a parent line rather than start one.
  List<PricingRule> get selectableProducts {
    final seen = <String>{};
    final out = <PricingRule>[];
    final sorted = [...rules]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final r in sorted) {
      if (r.isAddon) continue;
      if (seen.add(r.variant)) out.add(r);
    }
    return out;
  }

  /// Upgrades that may be added on top of [variant].
  ///
  /// A16: everything adds on. The curtain rate covers the fabric and standard
  /// hardware; a special track, rod, motor or box is an extra line. So this
  /// offers the track family to curtains, and any add-on whose `attaches_to`
  /// admits the variant.
  ///
  /// **Never called to add something automatically.** §4.1 — the wizard offers,
  /// the customer chooses. Auto-adding a track would put RM9–10/ft on every
  /// curtain that already includes one.
  List<PricingRule> upgradesFor(PricingRule parent) {
    final seen = <String>{};
    final out = <PricingRule>[];
    final sorted = [...rules]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    for (final r in sorted) {
      if (r.variant == parent.variant) continue;

      final isTrackForCurtain =
          r.family == Family.track && parent.family == Family.curtain;
      final isAddonForThis =
          r.isAddon &&
          (r.attachesTo == null || r.attachesTo!.contains(parent.variant));

      if (!isTrackForCurtain && !isAddonForThis) continue;
      if (seen.add(r.variant)) out.add(r);
    }
    return out;
  }

  /// The material keys offered for [variant], excluding the null that means
  /// "this product has no material choice".
  List<String> materialsFor(String variant) {
    final keys = <String>{
      for (final r in rules)
        if (r.variant == variant && r.materialKey != null) r.materialKey!,
    };
    return keys.toList(growable: false)..sort();
  }
}
