/// Turns engine units into words a customer reads.
///
/// [PriceBasis.unit] and [LengthUnit.symbol] are wire values — `ft`, `sqft` —
/// correct in JSON and in the database, and wrong on screen. A quote that says
/// `按 13 ft 计` to a Chinese customer is half-translated, which reads worse
/// than not translating at all.
library;

import '../core/length.dart';
import '../l10n/app_localizations.dart';
import '../pricing/models.dart';

/// The localised name of an input unit, for the chip beside a dimension field.
String unitLabel(L l, LengthUnit unit) => switch (unit) {
  LengthUnit.foot => l.unitFoot,
  LengthUnit.inch => l.unitInch,
  LengthUnit.mm => l.unitMm,
  LengthUnit.cm => l.unitCm,
  LengthUnit.m => l.unitMetre,
};

/// The localised name of the unit a line is billed in.
String billedUnitLabel(L l, PriceBasis basis) => switch (basis) {
  PriceBasis.perFtWidth => l.unitFoot,
  PriceBasis.perSqft => l.unitSqft,
  PriceBasis.perMLength => l.unitMetre,
  // No customer-facing noun exists for these yet; they arrive with add-ons in
  // Phase 2 and get their own strings then rather than a guessed word now.
  PriceBasis.perPiece => basis.unit,
  PriceBasis.perSet => basis.unit,
  PriceBasis.perRoll => basis.unit,
};
