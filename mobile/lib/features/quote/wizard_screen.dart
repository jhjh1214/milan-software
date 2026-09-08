import 'package:flutter/material.dart';
// Riverpod exports a `Family` of its own. `Family` here is the domain term
// from SPEC.md — curtain, blind, track — so Riverpod's is the one that hides.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;

import '../../core/dimension_warnings.dart';
import '../../core/length.dart';
import '../../core/length_parser.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../ui/theme.dart';
import '../../ui/unit_labels.dart';
import '../../ui/widgets/dimension_field.dart';
import '../../ui/widgets/numeric_keypad.dart';
import 'quote_state.dart';

/// The add-a-window wizard.
///
/// SPEC.md §8.1: "One decision per screen. Room, then product, then type, then
/// sizes. Never a form with eight fields. Back always available, never loses
/// input."
class WizardScreen extends ConsumerStatefulWidget {
  const WizardScreen({super.key});

  @override
  ConsumerState<WizardScreen> createState() => _WizardScreenState();
}

/// The real price list carries 77 rows across seven families. A single flat
/// product list would be a 60-item scroll, which is hostile to the four-minute
/// quote §8.4 asks for, so the category comes first and every list stays short.
enum _Step { room, family, product, sizes, upgrade }

enum _Field { width, height }

class _WizardScreenState extends ConsumerState<WizardScreen> {
  _Step _step = _Step.room;

  String? _room;
  Family? _family;
  PricingRule? _product;

  /// True when the chosen variant offers more than one material and the
  /// customer will pick at measurement rather than at the fair.
  bool _deferMaterial = false;

  /// The line the sizes step created, which upgrades attach to.
  String? _parentLineId;

  /// Upgrade variant -> the line id it created, so a second tap removes it.
  final Map<String, String> _addedUpgrades = {};

  String _rawWidth = '';
  String _rawHeight = '';
  LengthUnit _widthUnit = LengthUnit.foot;
  LengthUnit _heightUnit = LengthUnit.foot;
  _Field _focused = _Field.width;

  void _back() {
    if (_step == _Step.room) {
      Navigator.of(context).pop();
      return;
    }
    // Back never loses input — it only moves the step.
    setState(() {
      _step = _Step.values[_step.index - 1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final cardAsync = ref.watch(rateCardProvider);

    return PopScope(
      canPop: _step == _Step.room,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _back,
            tooltip: l.back,
          ),
          title: Text(switch (_step) {
            _Step.room => l.stepRoom,
            _Step.family => l.stepFamily,
            _Step.product => l.stepProduct,
            _Step.sizes => l.stepSizes,
            _Step.upgrade => l.stepUpgrade,
          }),
        ),
        body: cardAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (card) => switch (_step) {
            _Step.room => _RoomStep(
              onPick: (room) => setState(() {
                _room = room;
                _step = _Step.family;
              }),
            ),
            _Step.family => _FamilyStep(
              card: card,
              onPick: (family) => setState(() {
                _family = family;
                _step = _Step.product;
              }),
            ),
            _Step.product => _ProductStep(
              card: card,
              family: _family!,
              onPick: (rule) => setState(() {
                _product = rule;
                // `rule` is only a representative of its variant — the first
                // row, which carries a material key. Passing that key on would
                // silently pick one material (the cheaper one, as it happens)
                // and defeat the deferral the client asked for. When the
                // variant offers a choice, the line carries no material at all.
                _deferMaterial = card.materialsFor(rule.variant).length > 1;
                _widthUnit = _unitFromWire(card.config.defaultUnitWidth);
                _heightUnit = _unitFromWire(card.config.defaultUnitHeight);
                _step = _Step.sizes;
              }),
            ),
            _Step.sizes => _sizesStep(card),
            _Step.upgrade => _UpgradeStep(
              card: card,
              parent: _product!,
              added: _addedUpgrades,
              onToggle: _toggleUpgrade,
              onDone: () => Navigator.of(context).pop(),
            ),
          },
        ),
      ),
    );
  }

  static LengthUnit _unitFromWire(String s) => switch (s) {
    'mm' => LengthUnit.mm,
    'cm' => LengthUnit.cm,
    'm' => LengthUnit.m,
    'in' => LengthUnit.inch,
    _ => LengthUnit.foot,
  };

  Widget _sizesStep(RateCard card) {
    final l = L.of(context);
    final language = ref.watch(languageProvider);
    final product = _product!;

    final widthParsed = parseLength(_rawWidth, _widthUnit);
    final heightParsed = parseLength(_rawHeight, _heightUnit);

    // The band boundaries this product actually uses, so the nudge only fires
    // where a boundary really exists.
    final bandEdges = <int>[
      for (final r in card.rules)
        if (r.variant == product.variant &&
            r.materialKey == product.materialKey &&
            r.bandMaxTmm != null)
          r.bandMaxTmm!,
    ];

    final thresholds = WarningThresholds(
      bandEdgeWarnTmm: card.config.bandEdgeWarnTmm,
      plausibleByCategory: card.config.plausibleByCategory,
    );

    // §5.5: a plausible range is a property of the field IN ITS CATEGORY. A
    // six-metre drop is a double-height living room; a six-metre flooring run
    // is a corridor.
    final category = depositCategoryOf(product.family).name;

    // What the second dimension actually is. A floor lies flat: it has a
    // LENGTH, and asking a part-timer standing in a room for its "height"
    // invites them to type the wall.
    final second = secondDimensionOf(product.family);
    final secondLabel = switch (second) {
      SecondDimension.drop => l.height,
      SecondDimension.length => l.lengthDimension,
      SecondDimension.height => l.height,
    };

    final widthState = DimensionFieldState(
      raw: _rawWidth,
      chipUnit: _widthUnit,
      parsed: widthParsed,
      warnings: widthParsed == null
          ? const []
          : checkDimension(
              value: widthParsed.length,
              enteredUnit: widthParsed.unit,
              unitWasExplicit: widthParsed.unitWasExplicit,
              isSecondDimension: false,
              secondIsDrop: second == SecondDimension.drop,
              depositCategory: category,
              bandEdgesTmm: product.bandField == BandField.width
                  ? bandEdges
                  : const [],
              thresholds: thresholds,
            ),
    );

    final heightState = DimensionFieldState(
      raw: _rawHeight,
      chipUnit: _heightUnit,
      parsed: heightParsed,
      warnings: heightParsed == null
          ? const []
          : checkDimension(
              value: heightParsed.length,
              enteredUnit: heightParsed.unit,
              unitWasExplicit: heightParsed.unitWasExplicit,
              isSecondDimension: true,
              secondIsDrop: second == SecondDimension.drop,
              depositCategory: category,
              bandEdgesTmm: product.bandField == BandField.height
                  ? bandEdges
                  : const [],
              thresholds: thresholds,
            ),
    );

    final canAdd = widthParsed != null && heightParsed != null;

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: AppColors.muted,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.sm,
          ),
          child: Text(
            '${_room!} · ${product.labels(language)}',
            style: AppText.caption,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DimensionField(
                  label: l.width,
                  state: widthState,
                  isFocused: _focused == _Field.width,
                  onTap: () => setState(() => _focused = _Field.width),
                  onUnitChanged: (u) => setState(() => _widthUnit = u),
                  unitChoices: const [
                    LengthUnit.foot,
                    LengthUnit.inch,
                    LengthUnit.mm,
                    LengthUnit.cm,
                  ],
                  unitLabel: (u) => _unitLabel(l, u),
                  invalidMessage: l.errorInvalidDimension,
                  warningMessage: (w) => _warningMessage(l, w),
                  warningActionLabel: (w) => _warningAction(l, w),
                  onWarningAction: (w) => _applyWarning(w, _Field.width),
                  billedNote: widthParsed == null
                      ? null
                      : _billedNote(l, product, widthParsed, heightParsed),
                ),
                const SizedBox(height: Space.xl),
                DimensionField(
                  label: secondLabel,
                  state: heightState,
                  isFocused: _focused == _Field.height,
                  onTap: () => setState(() => _focused = _Field.height),
                  onUnitChanged: (u) => setState(() => _heightUnit = u),
                  unitChoices: const [
                    LengthUnit.foot,
                    LengthUnit.inch,
                    LengthUnit.mm,
                    LengthUnit.cm,
                  ],
                  unitLabel: (u) => _unitLabel(l, u),
                  invalidMessage: l.errorInvalidDimension,
                  warningMessage: (w) => _warningMessage(l, w),
                  warningActionLabel: (w) => _warningAction(l, w),
                  onWarningAction: (w) => _applyWarning(w, _Field.height),
                ),
              ],
            ),
          ),
        ),
        NumericKeypad(
          value: _focused == _Field.width ? _rawWidth : _rawHeight,
          doneLabel: l.keypadDone,
          feetLabel: _unitLabel(l, LengthUnit.foot),
          inchesLabel: _unitLabel(l, LengthUnit.inch),
          millimetresLabel: _unitLabel(l, LengthUnit.mm),
          onChanged: (v) => setState(() {
            if (_focused == _Field.width) {
              _rawWidth = v;
            } else {
              _rawHeight = v;
            }
          }),
          onDone: () => setState(() {
            // Moving to the next empty field is one fewer tap per window.
            if (_focused == _Field.width && _rawHeight.isEmpty) {
              _focused = _Field.height;
            }
          }),
        ),
        Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: FilledButton(
                onPressed: canAdd ? () => _add(card) : null,
                child: Text(l.done),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _billedNote(
    L l,
    PricingRule product,
    ParsedLength width,
    ParsedLength? height,
  ) {
    // §5.6: show entered and billed together, e.g. `12尺 4寸 → 按 13 尺计`.
    final unit = billedUnitLabel(l, product.basis);
    return switch (product.basis) {
      PriceBasis.perFtWidth => l.billedAs('${width.length.feetCeil}', unit),
      PriceBasis.perSqft =>
        height == null
            ? ''
            : l.billedAs(
                '${areaSqft(width.length, height.length).ceilToInt()}',
                unit,
              ),
      _ => '',
    };
  }

  String _unitLabel(L l, LengthUnit u) => unitLabel(l, u);

  String _warningMessage(L l, DimensionWarning w) => switch (w.kind) {
    DimensionWarningKind.unitLooksWrong => l.warnUnitLooksWrong(
      _focused == _Field.width ? _rawWidth : _rawHeight,
      _unitLabel(l, _focused == _Field.width ? _widthUnit : _heightUnit),
      '${(_focused == _Field.width ? parseLength(_rawWidth, _widthUnit) : parseLength(_rawHeight, _heightUnit))?.length.mm ?? 0}mm',
      _unitLabel(l, w.suggestedUnit ?? LengthUnit.mm),
    ),
    DimensionWarningKind.dropVeryShort => l.warnDropVeryShort(
      '${parseLength(_rawHeight, _heightUnit)?.length.mm ?? 0}mm',
    ),
    DimensionWarningKind.nearBandEdge => l.warnNearBandEdge(
      '${(w.bandEdgeTmm ?? 0) ~/ 3048} ${l.unitFoot}',
    ),
    // §5.5: say the number back in metres. "8000in" reads as a plausible
    // number; "203m" does not, and that is the whole point of showing it.
    DimensionWarningKind.implausibleForCategory => l.warnImplausibleSize(
      _metresOf(
        _focused == _Field.width ? _rawWidth : _rawHeight,
        _focused == _Field.width ? _widthUnit : _heightUnit,
      ),
    ),
  };

  /// A length written in metres to one decimal, for a message whose whole job
  /// is to make an absurd number look absurd.
  String _metresOf(String raw, LengthUnit chip) {
    final parsed = parseLength(raw, chip);
    if (parsed == null) return '';
    return '${(parsed.length.tmm / 10000).toStringAsFixed(1)}m';
  }

  String _warningAction(L l, DimensionWarning w) => switch (w.kind) {
    DimensionWarningKind.unitLooksWrong => l.warnSwitchTo(
      _unitLabel(l, w.suggestedUnit ?? LengthUnit.mm),
    ),
    _ => '',
  };

  void _applyWarning(DimensionWarning w, _Field field) {
    if (w.kind != DimensionWarningKind.unitLooksWrong) return;
    // One tap to fix, per §5.5.
    setState(() {
      if (field == _Field.width) {
        _widthUnit = w.suggestedUnit ?? LengthUnit.mm;
      } else {
        _heightUnit = w.suggestedUnit ?? LengthUnit.mm;
      }
    });
  }

  Future<void> _add(RateCard card) async {
    final width = parseLength(_rawWidth, _widthUnit)!;
    final height = parseLength(_rawHeight, _heightUnit)!;
    final id = await ref
        .read(quoteProvider.notifier)
        .addLine(
          room: _room!,
          variant: _product!.variant,
          materialKey: _deferMaterial ? null : _product!.materialKey,
          layer: _product!.layer,
          width: width.length,
          height: height.length,
          rawWidth: width.raw,
          rawHeight: height.raw,
        );
    if (!mounted) return;

    _parentLineId = id;

    // Offer upgrades only where the card actually has some. A step that says
    // "nothing to add" is a tap the part-timer pays for on every window.
    final upgrades = card.upgradesFor(_product!);
    if (id == null || upgrades.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    // A must, not an offer. The stainless steel side guide is what holds an
    // outdoor roller blind, so the blind cannot go up without it — leaving
    // RM400 to a tick box means the one product that needs it is the one
    // somebody forgets. Added here and shown as required, never as a choice.
    for (final required in upgrades.where((r) => r.mandatory)) {
      await _addUpgrade(card, required);
      if (!mounted) return;
    }

    setState(() => _step = _Step.upgrade);
  }

  /// Adds or removes one upgrade line.
  ///
  /// A mandatory upgrade cannot be removed: the product does not exist without
  /// it, so a tap that took it off would leave a quote for something nobody
  /// can install.
  Future<void> _toggleUpgrade(RateCard card, PricingRule upgrade) async {
    if (upgrade.mandatory) return;

    final existing = _addedUpgrades[upgrade.variant];
    if (existing != null) {
      await ref.read(quoteProvider.notifier).removeLine(existing);
      if (!mounted) return;
      setState(() => _addedUpgrades.remove(upgrade.variant));

      // What it brought with it goes too. A motor track left behind after the
      // motor came off is RM40 a foot for something nobody is driving.
      for (final variant in upgrade.autoAdds) {
        final brought = _addedUpgrades[variant];
        if (brought == null) continue;
        await ref.read(quoteProvider.notifier).removeLine(brought);
        if (!mounted) return;
        setState(() => _addedUpgrades.remove(variant));
      }
      return;
    }

    await _addUpgrade(card, upgrade);
    if (!mounted) return;

    // A motorised curtain needs a motor track, charged on the curtain's own
    // width. Choosing the motor and forgetting the track quotes a motor with
    // nothing to drive, so the track comes with it rather than being
    // remembered.
    for (final variant in upgrade.autoAdds) {
      if (_addedUpgrades.containsKey(variant)) continue;
      final rule = card
          .upgradesFor(_product!)
          .where((r) => r.variant == variant);
      if (rule.isEmpty) continue;
      await _addUpgrade(card, rule.first);
      if (!mounted) return;
    }
  }

  /// Adds one upgrade line on top of the parent.
  ///
  /// The upgrade carries a copy of the parent's dimensions, so a per-foot track
  /// bills the curtain's width and dismantling an old floor bills the same
  /// square footage as the floor going over it. Instantiated, not referenced —
  /// editing the parent later must not silently reprice a line already agreed.
  Future<void> _addUpgrade(RateCard card, PricingRule upgrade) async {
    final width = parseLength(_rawWidth, _widthUnit)!;
    final height = parseLength(_rawHeight, _heightUnit)!;
    final id = await ref
        .read(quoteProvider.notifier)
        .addLine(
          room: _room!,
          variant: upgrade.variant,
          materialKey: card.materialsFor(upgrade.variant).length > 1
              ? null
              : upgrade.materialKey,
          layer: upgrade.layer,
          width: width.length,
          height: height.length,
          rawWidth: width.raw,
          rawHeight: height.raw,
          parentLineId: _parentLineId,
        );
    if (!mounted || id == null) return;
    setState(() => _addedUpgrades[upgrade.variant] = id);
  }
}

class _RoomStep extends StatelessWidget {
  final ValueChanged<String> onPick;

  const _RoomStep({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final rooms = [
      l.roomLiving,
      l.roomMaster,
      l.roomBedroom,
      l.roomKitchen,
      l.roomBalcony,
      l.roomStudy,
      l.roomOther,
    ];

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        for (final room in rooms)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: _BigChoice(label: room, onTap: () => onPick(room)),
          ),
      ],
    );
  }
}

/// Offers the upgrades that may be added on top of a line.
///
/// A16: everything adds on, so this is where a special track, a motor or a box
/// gets charged. §4.1 is emphatic that the system never adds one on the
/// customer's behalf — the normal track is already in the curtain rate, and
/// auto-adding would put RM9–10/ft on every window.
///
/// Declining is the default: the primary button says "no, that is all", and
/// nothing is selected when the step opens.
class _UpgradeStep extends ConsumerWidget {
  final RateCard card;
  final PricingRule parent;
  final Map<String, String> added;
  final Future<void> Function(RateCard, PricingRule) onToggle;
  final VoidCallback onDone;

  const _UpgradeStep({
    required this.card,
    required this.parent,
    required this.added,
    required this.onToggle,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final language = ref.watch(languageProvider);
    final upgrades = card.upgradesFor(parent);

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: AppColors.muted,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.md,
          ),
          child: Text(l.upgradeIncluded, style: AppText.caption),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Space.lg),
            children: [
              for (final rule in upgrades)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: _UpgradeChoice(
                    label: rule.labels(language),
                    // A required add-on says why it is there instead of what
                    // is still to be decided about it. It is on the quote, it
                    // is charged, and nothing about it is a choice.
                    //
                    // Where there IS a choice, name it. Somfy and AOK are the
                    // same motor at two qualities, and "material chosen at
                    // measurement" does not tell a customer asking what their
                    // options are. Composed here rather than as a message with
                    // a placeholder — CLAUDE.md, three times over.
                    subtitle: rule.mandatory
                        ? l.upgradeRequired
                        : switch (card.materialsFor(rule.variant)) {
                            final options when options.length > 1 =>
                              '${l.materialLater}: ${options.join(' / ')}',
                            _ => null,
                          },
                    selected: added.containsKey(rule.variant),
                    locked: rule.mandatory,
                    onTap: () => onToggle(card, rule),
                  ),
                ),
            ],
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: FilledButton(
                onPressed: onDone,
                child: Text(added.isEmpty ? l.upgradeNone : l.done),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UpgradeChoice extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool selected;

  /// Required, so there is nothing to tap. The product cannot go up without
  /// it and a tap that removed it would quote something nobody can install.
  final bool locked;

  final VoidCallback onTap;

  const _UpgradeChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.muted : AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        onTap: locked ? null : onTap,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Container(
          constraints: const BoxConstraints(minHeight: Touch.primary),
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                locked
                    ? Icons.lock
                    : selected
                    ? Icons.check_circle
                    : Icons.add_circle_outline,
                color: selected ? AppColors.accent : AppColors.mutedForeground,
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppText.title),
                    if (subtitle != null) ...[
                      const SizedBox(height: Space.xs),
                      Text(subtitle!, style: AppText.caption),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FamilyStep extends StatelessWidget {
  final RateCard card;
  final ValueChanged<Family> onPick;

  const _FamilyStep({required this.card, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    // Only families the card actually carries. An empty category is a dead end.
    final present = <Family>[
      for (final f in Family.values)
        if (card.selectableProducts.any((r) => r.family == f)) f,
    ];

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        for (final family in present)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: _BigChoice(
              label: familyLabel(l, family),
              onTap: () => onPick(family),
            ),
          ),
      ],
    );
  }
}

class _ProductStep extends ConsumerWidget {
  final RateCard card;
  final Family family;
  final ValueChanged<PricingRule> onPick;

  const _ProductStep({
    required this.card,
    required this.family,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final language = ref.watch(languageProvider);
    final products = card.selectableProducts
        .where((r) => r.family == family)
        .toList(growable: false);

    // Rates are never shown here. §8.1 and hard rule 8: a part-timer picks a
    // product, the system picks the rate. Nothing selectable is nothing to get
    // wrong.
    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        for (final rule in products)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: _BigChoice(
              label: rule.labels(language),
              // Material is chosen at measurement, not at the fair. Say so on
              // the choice itself so nobody goes hunting for a series picker.
              subtitle: card.materialsFor(rule.variant).length > 1
                  ? l.materialLater
                  : null,
              onTap: () => onPick(rule),
            ),
          ),
      ],
    );
  }
}

class _BigChoice extends StatelessWidget {
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _BigChoice({required this.label, required this.onTap, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Container(
          constraints: const BoxConstraints(minHeight: Touch.primary),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.lg,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppText.title),
                    if (subtitle != null) ...[
                      const SizedBox(height: Space.xs),
                      Text(subtitle!, style: AppText.caption),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.mutedForeground),
            ],
          ),
        ),
      ),
    );
  }
}
