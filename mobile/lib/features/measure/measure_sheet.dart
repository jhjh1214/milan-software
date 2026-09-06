/// Where the tape is entered, for one line. SPEC.md §11 Phase 6.
///
/// **The estimate is on screen the whole time**, beside the field being typed
/// into. §11 asks for that, and the reason is concrete: it is what lets
/// somebody notice they are recording 1.2m where the fair recorded 12ft, while
/// there is still a window in front of them to put a tape back on.
///
/// The material choice lives here too. §13 B7 defers it to measurement, and
/// this is measurement — the line was quoted at the dearest option in its
/// group, so choosing can only bring the price down.
///
/// Nothing here works out a price. `MeasurementRepository` does, from the pure
/// rule, and this sheet shows what it returns.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dimension_warnings.dart';
import '../../core/length.dart';
import '../../core/length_parser.dart';
import '../../data/database.dart';
import '../../data/measurement_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/models.dart';
import '../../ui/theme.dart';
import '../../ui/unit_labels.dart';
import '../../ui/widgets/dimension_field.dart';
import '../../ui/widgets/numeric_keypad.dart';
import '../../sync/sync_state.dart' show credentialsProvider;
import '../quote/quote_state.dart';
import 'measure_screen.dart' show measurementRepositoryProvider;

/// A length as somebody standing in a house reads it.
String displayLength(int tmm) {
  final length = Length.tenths(tmm);
  final feet = length.displayFeet;
  final inches = length.displayInches;
  return inches == 0 ? "$feet'" : "$feet' $inches\"";
}

class MeasureSheet extends ConsumerStatefulWidget {
  const MeasureSheet({
    super.key,
    required this.line,
    required this.cards,
    required this.orderId,
  });

  final OrderLineRow line;
  final Map<int, RateCard> cards;
  final String orderId;

  @override
  ConsumerState<MeasureSheet> createState() => _MeasureSheetState();
}

enum _Field { width, height }

class _MeasureSheetState extends ConsumerState<MeasureSheet> {
  String _rawWidth = '';
  String _rawHeight = '';
  LengthUnit _widthUnit = LengthUnit.foot;
  LengthUnit _heightUnit = LengthUnit.foot;
  _Field _focused = _Field.width;
  String? _material;
  bool _saving = false;

  /// The card this line was priced at, if the handset is holding it.
  ///
  /// Null means final pricing will refuse — deliberately, rather than reaching
  /// for today's card. Said out loud rather than hidden: the fix is a
  /// connection, and somebody needs to know that before they drive home.
  RateCard? get _card => widget.cards[widget.line.appliedRateCardVersion];

  @override
  void initState() {
    super.initState();
    _material = widget.line.materialKey;
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final line = widget.line;
    final card = _card;

    final widthParsed = parseLength(_rawWidth, _widthUnit);
    final heightParsed = parseLength(_rawHeight, _heightUnit);

    final needsHeight = line.estHeightTmm != null;
    final materials = card?.materialsFor(line.variant) ?? const <String>[];
    final mustChooseMaterial = line.materialDeferred && materials.length > 1;

    final ready =
        widthParsed != null &&
        (!needsHeight || heightParsed != null) &&
        (!mustChooseMaterial || _material != null) &&
        !_saving;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${line.room} · ${line.variant}', style: AppText.title),
              const SizedBox(height: Space.xs),
              Text(
                // One placeholder, composed here. Two would be ordered
                // alphabetically by the generator, which silently rendered
                // `9' × 12'` for a 12ft-wide window — on the one screen whose
                // whole job is to catch a wrong dimension.
                l.measureQuotedAs(
                  line.estHeightTmm == null
                      ? displayLength(line.estWidthTmm)
                      : '${displayLength(line.estWidthTmm)} × '
                            '${displayLength(line.estHeightTmm!)}',
                ),
                style: AppText.caption,
              ),

              if (card == null) ...[
                const SizedBox(height: Space.md),
                Text(
                  l.measureRefusedNoCard,
                  style: AppText.caption.copyWith(color: AppColors.destructive),
                ),
              ],

              const SizedBox(height: Space.md),
              _field(
                l,
                l.width,
                _Field.width,
                _rawWidth,
                _widthUnit,
                widthParsed,
                line.estWidthTmm,
              ),
              if (needsHeight) ...[
                const SizedBox(height: Space.sm),
                _field(
                  l,
                  l.height,
                  _Field.height,
                  _rawHeight,
                  _heightUnit,
                  heightParsed,
                  line.estHeightTmm,
                ),
              ],

              if (mustChooseMaterial) ...[
                const SizedBox(height: Space.lg),
                Text(l.measureChooseMaterial, style: AppText.label),
                const SizedBox(height: Space.xs),
                Wrap(
                  spacing: Space.sm,
                  children: [
                    for (final m in materials)
                      ChoiceChip(
                        label: Text(m),
                        selected: _material == m,
                        onSelected: (_) => setState(() => _material = m),
                      ),
                  ],
                ),
              ],

              const SizedBox(height: Space.md),
              NumericKeypad(
                value: _focused == _Field.width ? _rawWidth : _rawHeight,
                onChanged: (v) => setState(() {
                  if (_focused == _Field.width) {
                    _rawWidth = v;
                  } else {
                    _rawHeight = v;
                  }
                }),
                onDone: () {
                  if (ready) _save(context);
                },
                doneLabel: l.save,
                feetLabel: l.unitFoot,
                inchesLabel: l.unitInch,
                millimetresLabel: l.unitMm,
              ),

              const SizedBox(height: Space.md),
              SizedBox(
                width: double.infinity,
                height: Touch.primary,
                child: FilledButton(
                  onPressed: ready ? () => _save(context) : null,
                  child: Text(l.save),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    L l,
    String label,
    _Field field,
    String raw,
    LengthUnit unit,
    ParsedLength? parsed,
    int? estimateTmm,
  ) {
    final state = DimensionFieldState(
      raw: raw,
      chipUnit: unit,
      parsed: parsed,
      warnings: parsed == null
          ? const []
          : checkDimension(
              value: parsed.length,
              enteredUnit: parsed.unit,
              unitWasExplicit: parsed.unitWasExplicit,
              isHeight: field == _Field.height,
              depositCategory: _categoryOf(),
              thresholds: WarningThresholds(
                plausibleByCategory:
                    _card?.config.plausibleByCategory ?? const {},
              ),
            ),
    );

    return DimensionField(
      label: label,
      state: state,
      isFocused: _focused == field,
      onTap: () => setState(() => _focused = field),
      onUnitChanged: (u) => setState(() {
        if (field == _Field.width) {
          _widthUnit = u;
        } else {
          _heightUnit = u;
        }
      }),
      unitChoices: const [LengthUnit.foot, LengthUnit.inch, LengthUnit.mm],
      unitLabel: (u) => unitLabel(l, u),
      invalidMessage: l.errorInvalidDimension,
      warningMessage: (w) => _warning(l, w),
      warningActionLabel: (_) => '',
      onWarningAction: (_) {},
      // §11 Phase 6: the estimate, beside the field being measured.
      billedNote: estimateTmm == null
          ? null
          : l.measureWasQuoted(displayLength(estimateTmm)),
    );
  }

  String _warning(L l, DimensionWarning w) => switch (w.kind) {
    DimensionWarningKind.implausibleForCategory => l.warnImplausibleSize(
      _metres(_focused == _Field.width ? _rawWidth : _rawHeight),
    ),
    DimensionWarningKind.dropVeryShort => l.warnDropVeryShort(
      _metres(_rawHeight),
    ),
    // The unit-slip nudge and the band-edge nudge both belong to quoting. Here
    // the tape is the truth and the band it lands in is not a decision.
    _ => '',
  };

  String _metres(String raw) {
    final parsed = parseLength(
      raw,
      _focused == _Field.width ? _widthUnit : _heightUnit,
    );
    return parsed == null
        ? ''
        : '${(parsed.length.tmm / 10000).toStringAsFixed(1)}m';
  }

  /// The deposit category of the rule that priced this line, for §5.4's
  /// category-aware plausibility check.
  String? _categoryOf() {
    final card = _card;
    if (card == null) return null;
    for (final rule in card.rules) {
      if (rule.id == widget.line.appliedRuleId) {
        return depositCategoryOf(rule.family).name;
      }
    }
    return null;
  }

  Future<void> _save(BuildContext context) async {
    final width = parseLength(_rawWidth, _widthUnit);
    if (width == null) return;
    final height = parseLength(_rawHeight, _heightUnit);

    setState(() => _saving = true);

    final outcome = await ref
        .read(measurementRepositoryProvider)
        .recordMeasurement(
          orderId: widget.orderId,
          lineId: widget.line.id,
          width: width.length,
          height: height?.length,
          cards: widget.cards,
          at: ref.read(todayProvider),
          byUserId: ref.read(credentialsProvider).valueOrNull?.user.id,
          materialKey: _material,
        );

    if (!context.mounted) return;
    if (!outcome.isRecorded) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(refusalMessage(L.of(context), outcome.refusal!)),
        ),
      );
      return;
    }
    Navigator.of(context).pop(outcome);
  }
}

String refusalMessage(L l, MeasurementRefusal refusal) => switch (refusal) {
  MeasurementRefusal.notAMeasurement => l.measureRefusedZero,
  MeasurementRefusal.orderIsTerminal => l.measureRefusedTerminal,
  MeasurementRefusal.noSuchLine => l.measureRefusedNoLine,
};
