/// Parses the dimensions people actually type.
///
/// SPEC.md §5.1 rejects guessing the unit from magnitude: `84` is a plausible
/// inch drop and a plausible centimetre width, and the ambiguous 50-300 band is
/// where most real input lands. So the unit comes from an explicit suffix, or
/// failing that from the field's unit chip. Never from the size of the number.
///
/// SPEC.md §5.3 is the contract. Anything the table marks null returns null
/// here and shows an inline error. **There is no fallback guess.**
library;

import 'length.dart';
import 'rational.dart';

/// A dimension the user typed, kept alongside what it parsed to.
///
/// The raw text is retained because §5.5 forbids showing more precision than
/// was entered: someone who typed `7'6` sees `7尺6寸`, not `2286mm`.
class ParsedLength {
  /// Exactly what the user typed, trimmed.
  final String raw;

  /// The resolved dimension.
  final Length length;

  /// The unit the input was read as, after suffixes and the chip.
  final LengthUnit unit;

  /// True when the input carried its own unit suffix and the chip was ignored.
  final bool unitWasExplicit;

  const ParsedLength({
    required this.raw,
    required this.length,
    required this.unit,
    required this.unitWasExplicit,
  });

  @override
  String toString() => '$raw -> ${length.mm}mm (${unit.symbol})';
}

/// Suffixes that name a unit, longest first so `mm` wins over `m` and `inch`
/// over `in`. Chinese units are the trade's, not the historical 市尺.
const Map<String, LengthUnit> _suffixes = {
  'mm': LengthUnit.mm,
  'cm': LengthUnit.cm,
  'inch': LengthUnit.inch,
  'in': LengthUnit.inch,
  'ft': LengthUnit.foot,
  'm': LengthUnit.m,
  '米': LengthUnit.m,
  '公分': LengthUnit.cm,
  '厘米': LengthUnit.cm,
  '毫米': LengthUnit.mm,
  '尺': LengthUnit.foot,
  '寸': LengthUnit.inch,
  '"': LengthUnit.inch,
  "'": LengthUnit.foot,
};

/// `7'6"`, `7ft 6in`, `7尺6寸`, `7ft6`, `12'0` — feet and inches together.
///
/// This is how the trade talks and SPEC.md §5.3 marks it "must work".
final RegExp _feetInches = RegExp(
  r"^(\d+(?:\.\d+)?)\s*(?:'|ft|尺)\s*(\d+(?:\.\d+)?)\s*(?:\x22|in|inch|寸)?$",
  caseSensitive: false,
);

/// A number with an optional unit suffix.
final RegExp _plain = RegExp(
  r"^(\d+(?:\.\d+)?)\s*(mm|cm|inch|in|ft|m|米|公分|厘米|毫米|尺|寸|\x22|')?$",
  caseSensitive: false,
);

/// Parses [input] into a dimension, using [defaultUnit] only when the input
/// carries no unit of its own.
///
/// Returns null for empty input and for anything unparseable. A null result is
/// an inline error in the UI, never a fallback to a guessed value.
ParsedLength? parseLength(String input, LengthUnit defaultUnit) {
  final raw = input.trim();
  if (raw.isEmpty) return null;

  final feetInchMatch = _feetInches.firstMatch(raw);
  if (feetInchMatch != null) {
    final feet = Rational.tryParseDecimal(feetInchMatch.group(1)!);
    final inches = Rational.tryParseDecimal(feetInchMatch.group(2)!);
    if (feet == null || inches == null) return null;

    // `7.5ft6in` is not a measurement anyone means to write. Reject rather than
    // pick one of the two readings — §5.2, never fall back to a guess.
    if (!feet.isInteger) return null;

    final tenths =
        (feet * Rational.fromInt(LengthUnit.foot.tenthsPerUnit)) +
        (inches * Rational.fromInt(LengthUnit.inch.tenthsPerUnit));
    if (tenths.isZero || tenths.isNegative) return null;
    return ParsedLength(
      raw: raw,
      length: Length.tenths(tenths.roundHalfUpToInt()),
      unit: LengthUnit.foot,
      unitWasExplicit: true,
    );
  }

  final plainMatch = _plain.firstMatch(raw);
  if (plainMatch == null) return null;

  final value = Rational.tryParseDecimal(plainMatch.group(1)!);
  if (value == null || value.isZero) return null;

  final suffix = plainMatch.group(2);
  final explicit = suffix != null && suffix.isNotEmpty;
  final unit = explicit
      ? (_suffixes[suffix.toLowerCase()] ?? defaultUnit)
      : defaultUnit;

  final length = Length.of(value, unit);
  if (length.isZero) return null;

  return ParsedLength(
    raw: raw,
    length: length,
    unit: unit,
    unitWasExplicit: explicit,
  );
}
