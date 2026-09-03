/// Money, held as integer sen.
///
/// CLAUDE.md: "Money is integer sen. RM46.00 is 4600. `double` for currency is
/// forbidden." Rounding happens half-up, once, at the line total — never on an
/// intermediate.
library;

import 'rational.dart';

/// An amount in Malaysian sen. 100 sen to the ringgit.
class Money implements Comparable<Money> {
  /// The amount in whole sen. May be negative — refunds exist from Phase 4.
  final int sen;

  const Money.sen(this.sen);

  static const Money zero = Money.sen(0);

  /// Parses what a person types: `46`, `46.00`, `RM46.00`, `1,500.00`.
  ///
  /// Exact, via [Rational] — never `double.parse`. `0.1 + 0.2` is the classic
  /// demonstration of why, and this is a till.
  ///
  /// Returns null rather than zero when the text is not a number: zero is a
  /// real amount somebody might mean, and silently reading "abc" as RM0.00
  /// would balance a cash-up that should not balance.
  ///
  /// A negative is refused too, so this does not round-trip
  /// [toPlainString] for one. Both callers read an amount that cannot be
  /// negative -- a rate card cell and counted cash -- and the CSV importer
  /// depends on the refusal being loud, reporting "not a price" and rejecting
  /// the row rather than letting a minus sign become a credit.
  static Money? tryParse(String text) {
    final cleaned = text.trim().replaceAll(',', '').replaceAll('RM', '').trim();
    if (cleaned.isEmpty) return null;
    final value = Rational.tryParseDecimal(cleaned);
    if (value == null) return null;
    return Money.sen((value * const Rational.fromInt(100)).roundHalfUpToInt());
  }

  /// Builds an amount from ringgit and sen, e.g. `Money.rm(46, 50)` is RM46.50.
  const Money.rm(int ringgit, [int sen = 0]) : sen = ringgit * 100 + sen;

  /// Rounds an exact amount to the nearest sen, half away from zero.
  ///
  /// **Call this once per line total and never on an intermediate.** Rounding
  /// a quantity, then a unit rate, then a total compounds three errors that no
  /// customer can reproduce on a calculator.
  factory Money.roundFrom(Rational exactSen) =>
      Money.sen(exactSen.roundHalfUpToInt());

  Money operator +(Money o) => Money.sen(sen + o.sen);
  Money operator -(Money o) => Money.sen(sen - o.sen);
  Money operator *(int factor) => Money.sen(sen * factor);
  Money operator -() => Money.sen(-sen);

  bool get isZero => sen == 0;
  bool get isNegative => sen < 0;

  Money max(Money o) => sen >= o.sen ? this : o;
  Money min(Money o) => sen <= o.sen ? this : o;

  /// The ringgit part, truncated. For display only — use [format].
  int get ringgit => sen ~/ 100;

  /// Formats as `RM 1,234.50`.
  ///
  /// Always two decimals with the RM prefix, per SPEC.md §8.3 — never a bare
  /// number. Grouping is by thousands with a comma, which is what Malaysian
  /// invoices use in all three languages.
  String format({bool withSymbol = true}) {
    final negative = sen < 0;
    final abs = sen.abs();
    final whole = abs ~/ 100;
    final cents = abs % 100;
    final grouped = _group(whole);
    final body = '$grouped.${cents.toString().padLeft(2, '0')}';
    final signed = negative ? '-$body' : body;
    return withSymbol ? 'RM $signed' : signed;
  }

  /// `1500.00` — two decimals, no grouping, no symbol.
  ///
  /// For machine-readable output. [format] groups thousands with a comma, which
  /// is right on a quote and wrong in a CSV cell, where the comma splits the
  /// field and the row silently loses a column.
  String toPlainString() {
    final negative = sen < 0;
    final abs = sen.abs();
    final body = '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
    return negative ? '-$body' : body;
  }

  static String _group(int value) {
    final digits = value.toString();
    if (digits.length <= 3) return digits;
    final buffer = StringBuffer();
    final lead = digits.length % 3;
    if (lead > 0) buffer.write(digits.substring(0, lead));
    for (var i = lead; i < digits.length; i += 3) {
      if (buffer.isNotEmpty) buffer.write(',');
      buffer.write(digits.substring(i, i + 3));
    }
    return buffer.toString();
  }

  @override
  int compareTo(Money other) => sen.compareTo(other.sen);

  bool operator <(Money o) => sen < o.sen;
  bool operator <=(Money o) => sen <= o.sen;
  bool operator >(Money o) => sen > o.sen;
  bool operator >=(Money o) => sen >= o.sen;

  @override
  bool operator ==(Object other) => other is Money && other.sen == sen;

  @override
  int get hashCode => sen.hashCode;

  @override
  String toString() => format();
}
