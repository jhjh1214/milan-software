/// A single dimension input: a big readable value, an always-visible unit chip,
/// and inline feedback.
///
/// SPEC.md §5.2: "Per-field default unit, set by admin. Always-visible tappable
/// unit chip beside every dimension field. Suffix parsing overrides the chip.
/// Magnitude used only as a soft warning, never as a decision."
library;

import 'package:flutter/material.dart';

import '../../core/dimension_warnings.dart';
import '../../core/length.dart';
import '../../core/length_parser.dart';
import '../theme.dart';

/// Everything the field needs to render one dimension.
class DimensionFieldState {
  final String raw;
  final LengthUnit chipUnit;
  final ParsedLength? parsed;
  final List<DimensionWarning> warnings;

  const DimensionFieldState({
    required this.raw,
    required this.chipUnit,
    required this.parsed,
    required this.warnings,
  });

  bool get hasInput => raw.trim().isNotEmpty;
  bool get isInvalid => hasInput && parsed == null;
}

class DimensionField extends StatelessWidget {
  final String label;
  final DimensionFieldState state;
  final bool isFocused;
  final VoidCallback onTap;

  /// Cycles the unit chip. Tappable per §5.2.
  final ValueChanged<LengthUnit> onUnitChanged;

  /// The units offered on the chip, in cycle order.
  final List<LengthUnit> unitChoices;

  /// Localised unit names for the chip.
  final String Function(LengthUnit) unitLabel;

  /// Localised error and warning strings, resolved by the caller so this
  /// widget stays free of localisation lookups.
  final String invalidMessage;
  final String Function(DimensionWarning) warningMessage;
  final String Function(DimensionWarning) warningActionLabel;
  final void Function(DimensionWarning) onWarningAction;

  /// Renders the billed value beside the entered one, e.g. `按 13 尺计`.
  final String? billedNote;

  const DimensionField({
    super.key,
    required this.label,
    required this.state,
    required this.isFocused,
    required this.onTap,
    required this.onUnitChanged,
    required this.unitChoices,
    required this.unitLabel,
    required this.invalidMessage,
    required this.warningMessage,
    required this.warningActionLabel,
    required this.onWarningAction,
    this.billedNote,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = state.isInvalid
        ? AppColors.destructive
        : isFocused
        ? AppColors.secondary
        : AppColors.border;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.label),
        const SizedBox(height: Space.sm),
        Semantics(
          textField: true,
          label: label,
          value: state.raw,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.md),
            child: Container(
              constraints: const BoxConstraints(minHeight: Touch.primary),
              padding: const EdgeInsets.symmetric(
                horizontal: Space.lg,
                vertical: Space.md,
              ),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(
                  color: borderColor,
                  width: isFocused || state.isInvalid ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.hasInput ? state.raw : '—',
                      style: AppText.totalDisplay.copyWith(
                        fontSize: 26,
                        color: state.hasInput
                            ? AppColors.foreground
                            : AppColors.mutedForeground,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  _UnitChip(
                    unit: state.chipUnit,
                    label: unitLabel(state.chipUnit),
                    // A suffix in the text overrides the chip, so show that the
                    // chip is no longer deciding anything.
                    overridden: state.parsed?.unitWasExplicit ?? false,
                    onTap: () {
                      final i = unitChoices.indexOf(state.chipUnit);
                      onUnitChanged(unitChoices[(i + 1) % unitChoices.length]);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        if (state.isInvalid) ...[
          const SizedBox(height: Space.sm),
          _Inline(
            icon: Icons.error_outline,
            color: AppColors.destructive,
            background: Colors.transparent,
            text: invalidMessage,
          ),
        ],
        if (billedNote != null && !state.isInvalid) ...[
          const SizedBox(height: Space.sm),
          Text(billedNote!, style: AppText.caption),
        ],
        for (final warning in state.warnings) ...[
          const SizedBox(height: Space.sm),
          _WarningRow(
            message: warningMessage(warning),
            actionLabel: warningActionLabel(warning),
            onAction: () => onWarningAction(warning),
          ),
        ],
      ],
    );
  }
}

class _UnitChip extends StatelessWidget {
  final LengthUnit unit;
  final String label;
  final bool overridden;
  final VoidCallback onTap;

  const _UnitChip({
    required this.unit,
    required this.label,
    required this.overridden,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: overridden ? AppColors.muted : AppColors.primary,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Container(
            constraints: const BoxConstraints(
              minWidth: Touch.min,
              minHeight: Touch.min,
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Text(
              label,
              style: AppText.bodyStrong.copyWith(
                color: overridden
                    ? AppColors.mutedForeground
                    : AppColors.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _WarningRow({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: AppColors.warningSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.info_outline,
                size: 20,
                color: AppColors.warning,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  message,
                  style: AppText.body.copyWith(color: AppColors.warning),
                ),
              ),
            ],
          ),
          if (actionLabel.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            SizedBox(
              height: Touch.min,
              child: OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.warning,
                  side: const BorderSide(color: AppColors.warning, width: 1.5),
                ),
                child: Text(actionLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Inline extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color background;
  final String text;

  const _Inline({
    required this.icon,
    required this.color,
    required this.background,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(text, style: AppText.body.copyWith(color: color)),
        ),
      ],
    );
  }
}
