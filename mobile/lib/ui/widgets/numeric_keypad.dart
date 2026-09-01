/// The custom dimension keypad.
///
/// SPEC.md §8.1: "Custom numeric keypad, never the system keyboard. Big digits
/// plus dedicated `ft` `in` `'` `"` `mm` keys and `.`. The system keyboard is
/// small, slow, and buries the unit characters two layers deep. **This one
/// widget removes most of the input friction in the app.**"
///
/// It also implements "errors prevented, not reported": a key that would
/// produce input the parser must reject is disabled rather than allowed and
/// then complained about. `7''6` cannot be typed here.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// What a key does when pressed.
enum _KeyKind { digit, decimal, feet, inches, millimetres, backspace, done }

class _KeySpec {
  final String label;
  final _KeyKind kind;

  /// The text this key appends. Empty for actions.
  final String insert;

  final String semanticLabel;

  const _KeySpec(this.label, this.kind, this.insert, this.semanticLabel);
}

/// A keypad for entering one dimension.
///
/// Stateless and controlled: it never owns the text. The field owns it, so a
/// backgrounded app that comes back mid-quote finds its input intact.
class NumericKeypad extends StatelessWidget {
  /// The current raw text of the field being edited.
  final String value;

  /// Called with the new raw text after a key press.
  final ValueChanged<String> onChanged;

  /// Called when the user taps the confirm key.
  final VoidCallback onDone;

  /// Label for the confirm key.
  final String doneLabel;

  /// Localised labels for the unit keys, e.g. 尺 / ft.
  final String feetLabel;
  final String inchesLabel;
  final String millimetresLabel;

  const NumericKeypad({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onDone,
    required this.doneLabel,
    required this.feetLabel,
    required this.inchesLabel,
    required this.millimetresLabel,
  });

  /// True when the text already carries a feet marker.
  bool get _hasFeet => value.contains("'");

  /// True when the text already carries an inches marker.
  bool get _hasInches => value.contains('"');

  bool get _hasMillimetres => value.toLowerCase().contains('mm');

  /// True when the segment currently being typed already has a decimal point.
  bool get _segmentHasDecimal {
    final lastMarker = [
      value.lastIndexOf("'"),
      value.lastIndexOf('"'),
    ].reduce((a, b) => a > b ? a : b);
    return value.substring(lastMarker + 1).contains('.');
  }

  bool _enabled(_KeySpec key) {
    switch (key.kind) {
      case _KeyKind.digit:
        // Nothing may follow a unit suffix like `mm`.
        return !_hasMillimetres;
      case _KeyKind.decimal:
        return value.isNotEmpty && !_segmentHasDecimal && !_hasMillimetres;
      case _KeyKind.feet:
        // A second `'` would produce `7''6`, which §5.3 marks invalid.
        return value.isNotEmpty &&
            !_hasFeet &&
            !_hasInches &&
            !_hasMillimetres &&
            !value.endsWith('.');
      case _KeyKind.inches:
        return value.isNotEmpty &&
            !_hasInches &&
            !_hasMillimetres &&
            !value.endsWith('.') &&
            !value.endsWith("'");
      case _KeyKind.millimetres:
        return value.isNotEmpty &&
            !_hasFeet &&
            !_hasInches &&
            !_hasMillimetres &&
            !value.endsWith('.');
      case _KeyKind.backspace:
        return value.isNotEmpty;
      case _KeyKind.done:
        return value.isNotEmpty;
    }
  }

  void _press(_KeySpec key) {
    HapticFeedback.selectionClick();
    switch (key.kind) {
      case _KeyKind.backspace:
        // `mm` is two characters but one token to the user.
        if (_hasMillimetres && value.toLowerCase().endsWith('mm')) {
          onChanged(value.substring(0, value.length - 2));
        } else {
          onChanged(value.substring(0, value.length - 1));
        }
      case _KeyKind.done:
        onDone();
      default:
        onChanged(value + key.insert);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = <List<_KeySpec>>[
      [
        const _KeySpec('7', _KeyKind.digit, '7', '7'),
        const _KeySpec('8', _KeyKind.digit, '8', '8'),
        const _KeySpec('9', _KeyKind.digit, '9', '9'),
        const _KeySpec('⌫', _KeyKind.backspace, '', 'backspace'),
      ],
      [
        const _KeySpec('4', _KeyKind.digit, '4', '4'),
        const _KeySpec('5', _KeyKind.digit, '5', '5'),
        const _KeySpec('6', _KeyKind.digit, '6', '6'),
        _KeySpec(feetLabel, _KeyKind.feet, "'", feetLabel),
      ],
      [
        const _KeySpec('1', _KeyKind.digit, '1', '1'),
        const _KeySpec('2', _KeyKind.digit, '2', '2'),
        const _KeySpec('3', _KeyKind.digit, '3', '3'),
        _KeySpec(inchesLabel, _KeyKind.inches, '"', inchesLabel),
      ],
      [
        const _KeySpec('.', _KeyKind.decimal, '.', 'decimal point'),
        const _KeySpec('0', _KeyKind.digit, '0', '0'),
        _KeySpec(
          millimetresLabel,
          _KeyKind.millimetres,
          'mm',
          millimetresLabel,
        ),
        _KeySpec(doneLabel, _KeyKind.done, '', doneLabel),
      ],
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Space.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Row(
                  children: [
                    for (final key in row)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.xs,
                          ),
                          child: _Key(
                            spec: key,
                            enabled: _enabled(key),
                            onPressed: () => _press(key),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  final _KeySpec spec;
  final bool enabled;
  final VoidCallback onPressed;

  const _Key({
    required this.spec,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isUnit =
        spec.kind == _KeyKind.feet ||
        spec.kind == _KeyKind.inches ||
        spec.kind == _KeyKind.millimetres;
    final isDone = spec.kind == _KeyKind.done;

    final background = isDone
        ? AppColors.accent
        : isUnit
        ? AppColors.muted
        : AppColors.surface;
    final foreground = isDone
        ? AppColors.onAccent
        : isUnit
        ? AppColors.primary
        : AppColors.foreground;

    return Semantics(
      button: true,
      enabled: enabled,
      label: spec.semanticLabel,
      child: Opacity(
        // Disabled keys stay visible so the layout never shifts under a thumb
        // that is already moving.
        opacity: enabled ? 1.0 : 0.38,
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(Radii.md),
            child: Container(
              height: Touch.key,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(
                  color: isDone ? AppColors.accent : AppColors.border,
                  width: 1,
                ),
              ),
              child: Text(
                spec.label,
                style:
                    (isUnit || isDone
                            ? AppText.keypadUnit
                            : AppText.keypadDigit)
                        .copyWith(color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
