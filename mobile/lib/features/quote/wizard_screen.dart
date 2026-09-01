import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

enum _Step { room, product, sizes }

enum _Field { width, height }

class _WizardScreenState extends ConsumerState<WizardScreen> {
  _Step _step = _Step.room;

  String? _room;
  PricingRule? _product;

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
            _Step.product => l.stepProduct,
            _Step.sizes => l.stepSizes,
          }),
        ),
        body: cardAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (card) => switch (_step) {
            _Step.room => _RoomStep(
              onPick: (room) => setState(() {
                _room = room;
                _step = _Step.product;
              }),
            ),
            _Step.product => _ProductStep(
              card: card,
              onPick: (rule) => setState(() {
                _product = rule;
                _widthUnit = _unitFromWire(card.config.defaultUnitWidth);
                _heightUnit = _unitFromWire(card.config.defaultUnitHeight);
                _step = _Step.sizes;
              }),
            ),
            _Step.sizes => _sizesStep(card),
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
    );

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
              isHeight: false,
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
              isHeight: true,
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
                  label: l.height,
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
                onPressed: canAdd ? _add : null,
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
    // §5.5: show entered and billed together, e.g. `12尺 4寸 → 按 13 尺计`.
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
  };

  String _warningAction(L l, DimensionWarning w) => switch (w.kind) {
    DimensionWarningKind.unitLooksWrong => l.warnSwitchTo(
      _unitLabel(l, w.suggestedUnit ?? LengthUnit.mm),
    ),
    _ => '',
  };

  void _applyWarning(DimensionWarning w, _Field field) {
    if (w.kind != DimensionWarningKind.unitLooksWrong) return;
    // One tap to fix, per §5.4.
    setState(() {
      if (field == _Field.width) {
        _widthUnit = w.suggestedUnit ?? LengthUnit.mm;
      } else {
        _heightUnit = w.suggestedUnit ?? LengthUnit.mm;
      }
    });
  }

  void _add() {
    final width = parseLength(_rawWidth, _widthUnit)!;
    final height = parseLength(_rawHeight, _heightUnit)!;
    ref
        .read(quoteProvider.notifier)
        .addLine(
          room: _room!,
          variant: _product!.variant,
          materialKey: _product!.materialKey,
          layer: _product!.layer,
          width: width.length,
          height: height.length,
          rawWidth: width.raw,
          rawHeight: height.raw,
        );
    Navigator.of(context).pop();
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

class _ProductStep extends ConsumerWidget {
  final RateCard card;
  final ValueChanged<PricingRule> onPick;

  const _ProductStep({required this.card, required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(languageProvider);

    // Rates are never shown here. §8.1 and hard rule 8: a part-timer picks a
    // product, the system picks the rate. Nothing selectable is nothing to get
    // wrong.
    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        for (final rule in card.distinctVariants)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: _BigChoice(
              label: rule.labels(language),
              onTap: () => onPick(rule),
            ),
          ),
      ],
    );
  }
}

class _BigChoice extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _BigChoice({required this.label, required this.onTap});

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
              Expanded(child: Text(label, style: AppText.title)),
              const Icon(Icons.chevron_right, color: AppColors.mutedForeground),
            ],
          ),
        ),
      ),
    );
  }
}
