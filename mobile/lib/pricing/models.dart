/// Rate card data model.
///
/// PURE. No Flutter imports, no I/O, no clock. Loading the JSON is the caller's
/// job — this file only knows how to read a decoded map. See CLAUDE.md,
/// "The pricing engine is pure".
library;

import '../core/dimension_warnings.dart';
import '../core/length.dart';
import '../core/money.dart';
import '../core/rational.dart';
import 'einvoice_threshold.dart';

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

/// What the **second** dimension of a line actually is. SPEC.md §4.1, §5.
///
/// Every line is two dimensions and the arithmetic is the same either way —
/// `per_sqft` multiplies them, `per_ft_width` charges only the first. What
/// differs is **what a person is being asked to measure**, and that is not
/// cosmetic:
///
/// * A curtain or a blind hangs, so the second dimension is its **drop**. It
///   selects the band (§4.3) and a very short one is worth questioning.
/// * A floor lies flat. The second dimension is the room's **length**. There
///   is no drop, no band, and nothing short about a 300mm strip at a doorway.
/// * Wallpaper covers a wall, so it really is a **height**.
///
/// Labelling a floor's length "height" asks a part-timer for the wrong thing
/// in a room where the wrong thing — a wall height — is also a plausible
/// number they can see. That is the exact confusion §5 exists to prevent.
enum SecondDimension {
  /// A curtain or blind's drop. Bands on it; a short one is questioned.
  drop,

  /// A floor's length. Never bands, and never questioned for being short.
  length,

  /// A wall's height, for wallpaper.
  height,
}

/// What [family] calls its second dimension.
///
/// Add-ons and services inherit their parent's shape, so they follow the
/// commonest case rather than inventing a fourth word.
SecondDimension secondDimensionOf(Family family) => switch (family) {
  Family.flooring => SecondDimension.length,
  Family.wallpaper => SecondDimension.height,
  Family.curtain ||
  Family.blind ||
  Family.track ||
  Family.addon ||
  Family.service => SecondDimension.drop,
};

/// The category an RM300 deposit buys a rate hold on.
enum DepositCategory { curtain, flooring, wallpaper }

/// Raised when a line's deposit category cannot be decided.
///
/// A hard failure rather than a default, because the default would be a guess
/// about money: filing an unparented add-on under curtains could price it at a
/// held curtain rate that its RM300 never bought.
class UnknownDepositCategory implements Exception {
  final String detail;
  const UnknownDepositCategory(this.detail);

  @override
  String toString() => 'UnknownDepositCategory: $detail';
}

/// Maps a product family to the deposit category that covers it.
///
/// **Kept in one function on purpose.** SPEC.md §6.1: silently applying a
/// curtain lock to a flooring line is the expensive bug in this design.
///
/// Add-ons and services take their **parent line's** category. A motor is
/// charged on top of the blind it drives; it has no category of its own because
/// it cannot exist on its own. A rule may also name its category outright —
/// self-levelling is family `service` and deposit category `flooring` — and
/// that answer wins, because a service belongs to the work it prepares.
DepositCategory depositCategoryOf(Family family, {Family? parentFamily}) =>
    switch (family) {
      Family.curtain || Family.blind || Family.track => DepositCategory.curtain,
      Family.flooring => DepositCategory.flooring,
      Family.wallpaper => DepositCategory.wallpaper,
      Family.addon || Family.service => switch (parentFamily) {
        null => throw UnknownDepositCategory(
          'a ${family.name} line has no parent and no deposit_category; '
          'it cannot be priced against a lock',
        ),
        // One level only. An add-on hanging off an add-on is not a shape this
        // card produces, and allowing it would hide the same bug one level
        // deeper.
        Family.addon || Family.service => throw UnknownDepositCategory(
          'a ${family.name} line hangs off another ${parentFamily.name} line',
        ),
        final parent => depositCategoryOf(parent),
      },
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

  /// True when the rate on this row is a **placeholder**, not a real price.
  ///
  /// A row can exist before its price does -- stairs and landings were added
  /// as soon as the shape was known, with the rates still to come. The engine
  /// REFUSES to price a provisional row rather than quoting the placeholder,
  /// because a placeholder that reaches a customer is worse than a product
  /// that is not offered yet.
  ///
  /// Clearing the flag and setting the rate is a data edit: no code change and
  /// no rebuild (hard rule 1).
  final bool provisional;

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
    this.provisional = false,
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
      provisional: json['provisional'] as bool? ?? false,
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

  /// At or over this, buyer details are legally required. RM10,000, since
  /// 1 January 2026. SPEC.md §10.2 — Malaysian law, not this shop's policy.
  final int einvoiceThresholdSen;

  /// At or over this, the quote wizard asks. RM8,000, and only on an estimate:
  /// §10.4's timing trap is that an order quoted at RM8,500 settles at
  /// RM11,200, and by then the customer has gone home.
  final int einvoicePromptSen;

  /// What each deposit category can physically measure, per field. §5.5.
  /// Empty means no plausibility warning anywhere, which is the safe default.
  final Map<String, CategoryPlausibility> plausibleByCategory;

  const RateCardConfig({
    required this.minDepositSen,
    required this.bandEdgeWarnTmm,
    required this.defaultUnitWidth,
    required this.defaultUnitHeight,
    this.einvoiceThresholdSen = 1000000,
    this.einvoicePromptSen = 800000,
    this.plausibleByCategory = const {},
  });

  factory RateCardConfig.fromJson(Map<String, dynamic> json) => RateCardConfig(
    minDepositSen: json['min_deposit_sen'] as int,
    bandEdgeWarnTmm: json['band_edge_warn_tmm'] as int,
    defaultUnitWidth: json['default_unit_width'] as String? ?? 'ft',
    defaultUnitHeight: json['default_unit_height'] as String? ?? 'ft',
    // Defaulted rather than required, so a handset still holding a card
    // published before this keeps working — and defaults to the law rather
    // than to no check at all. A missing threshold that meant "never ask"
    // would be silent non-compliance on exactly the oldest handsets.
    einvoiceThresholdSen: json['einvoice_threshold_sen'] as int? ?? 1000000,
    einvoicePromptSen: json['einvoice_prompt_sen'] as int? ?? 800000,
    plausibleByCategory: _plausibleFromJson(json['plausible_dimensions']),
  );

  /// The two figures as the threshold rule wants them.
  ThresholdConfig get thresholds => ThresholdConfig(
    threshold: Money.sen(einvoiceThresholdSen),
    prompt: Money.sen(einvoicePromptSen),
  );
}

/// Reads §5.5's plausible ranges off the card.
///
/// A missing block, a missing category or a missing bound all mean "do not
/// warn". A config that is absent must never invent a limit that blocks a real
/// order.
Map<String, CategoryPlausibility> _plausibleFromJson(Object? raw) {
  if (raw is! Map) return const {};

  PlausibleRange? range(Map<dynamic, dynamic> c, String prefix) {
    final min = c['${prefix}_min_tmm'] as int?;
    final max = c['${prefix}_max_tmm'] as int?;
    return min == null && max == null
        ? null
        : PlausibleRange(minTmm: min, maxTmm: max);
  }

  // The second dimension is named for what it is: a curtain has a `drop`, a
  // floor a `length`, a wall a `height`. Whichever the category uses is read.
  // Naming it `height` everywhere would be the same mistake the screens used
  // to make — asking for the height of a floor.
  PlausibleRange? second(Map<dynamic, dynamic> c) =>
      range(c, 'drop') ?? range(c, 'length') ?? range(c, 'height');

  return {
    for (final entry in raw.entries)
      if (entry.value is Map)
        entry.key as String: CategoryPlausibility(
          width: range(entry.value as Map, 'width'),
          second: second(entry.value as Map),
        ),
  };
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

  /// Any rule for [variant], for the things that are true of every band of a
  /// product — its family, and the deposit category it names.
  ///
  /// The first match is enough: bands of one variant differ only in their
  /// rate and their band edge, never in what kind of thing they are.
  PricingRule? ruleFor(String variant) {
    for (final rule in rules) {
      if (rule.variant == variant) return rule;
    }
    return null;
  }

  /// The promo percentage a lock taken today would pin.
  ///
  /// **Zero, and deliberately so.** These *are* the printed fair prices, not a
  /// discount applied to a standard list — see the note in
  /// `rate-card-fair-2026-08.json`. The field exists because CLAUDE.md requires
  /// a lock to pin the percentage as well as the version: the day the client
  /// runs "fair price and another 10% off", a held order must not move when
  /// that promotion ends.
  Rational get promoDiscountPct => Rational.zero;

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
