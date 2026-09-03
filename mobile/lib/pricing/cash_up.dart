/// Money taken, and the end-of-day reconciliation. SPEC.md §6.4.
///
/// > **Daily cash-up screen.** End of day, per user: expected total by method
/// > versus what they actually hold. Small to build, catches most of what goes
/// > wrong with cash at a fair.
///
/// Pure: no clock, no I/O, no Flutter. The rows are handed in, so a day can be
/// reconciled in a test without waiting for one.
library;

import '../core/money.dart';

/// What a payment is for. §6.4.
enum PaymentKind {
  /// The RM300 that confirms an order and, at a fair, buys a rate hold.
  deposit('deposit'),

  /// Money between the deposit and the balance.
  progress('progress'),

  /// The rest, after site measurement has settled the real figure.
  balance('balance'),

  /// Money going back. A **new row**, never an edit to the one it reverses:
  /// the cash-up has to reconcile what happened, not what the drawer looks
  /// like now.
  refund('refund');

  const PaymentKind(this.wire);

  final String wire;

  /// Whether this kind adds to what a person is holding, or takes away.
  int get sign => this == PaymentKind.refund ? -1 : 1;

  static PaymentKind fromWire(String wire) =>
      PaymentKind.values.firstWhere((k) => k.wire == wire);
}

/// How it was paid. §6.4 — the system **records**, it does not process.
enum PaymentMethod {
  /// The only one where a person is physically holding something at the end of
  /// the day, and the only one the count can disagree with.
  cash('cash'),

  cardTerminal('card_terminal'),
  duitnow('duitnow'),
  bankTransfer('bank_transfer'),
  cheque('cheque');

  const PaymentMethod(this.wire);

  final String wire;

  /// Whether a person can be asked to count this at the end of the day.
  ///
  /// Only cash. A card total is what the terminal says it is, and asking
  /// someone to "count" their DuitNow would invite a made-up number.
  bool get isCounted => this == PaymentMethod.cash;

  static PaymentMethod fromWire(String wire) =>
      PaymentMethod.values.firstWhere((m) => m.wire == wire);
}

/// One payment, as the cash-up sees it.
class CashUpEntry {
  final PaymentKind kind;
  final PaymentMethod method;
  final int amountSen;

  const CashUpEntry({
    required this.kind,
    required this.method,
    required this.amountSen,
  });
}

/// What one method should come to, and what was actually held.
class MethodTotal {
  final PaymentMethod method;

  /// Deposits and balances less refunds, in the order they happened.
  final Money expected;

  /// What the person counted. Null when they have not counted yet, or when the
  /// method is not countable.
  final Money? counted;

  const MethodTotal({
    required this.method,
    required this.expected,
    this.counted,
  });

  /// Held minus expected. Positive is a surplus, negative is short.
  ///
  /// Null when nothing was counted — which is **not** the same as zero. A
  /// method nobody counted is an open question, and showing it as balanced
  /// would answer it wrongly.
  Money? get variance =>
      counted == null ? null : Money.sen(counted!.sen - expected.sen);

  bool get isBalanced => variance != null && variance!.sen == 0;
}

/// The end of one person's day.
class CashUp {
  final List<MethodTotal> byMethod;

  const CashUp({required this.byMethod});

  /// Everything taken, whatever the method.
  Money get expectedTotal =>
      Money.sen(byMethod.fold(0, (sum, m) => sum + m.expected.sen));

  /// Methods that were counted and did not match.
  List<MethodTotal> get discrepancies => [
    for (final m in byMethod)
      if (m.variance != null && m.variance!.sen != 0) m,
  ];

  bool get anyDiscrepancy => discrepancies.isNotEmpty;

  /// Countable methods nobody has counted yet.
  ///
  /// Surfaced separately from a discrepancy, because "nobody checked" and
  /// "checked and it was wrong" need different conversations.
  List<MethodTotal> get uncounted => [
    for (final m in byMethod)
      if (m.method.isCounted && m.counted == null) m,
  ];
}

/// Totals one person's day, method by method.
///
/// Every method that saw money appears, including one that nets to zero —
/// three RM300 deposits and three RM300 refunds is not the same day as no
/// payments at all, and a cash-up that hid it would hide the thing worth
/// asking about.
CashUp cashUpFor(
  List<CashUpEntry> entries, {
  Map<PaymentMethod, Money> counted = const {},
}) {
  final totals = <PaymentMethod, int>{};
  for (final entry in entries) {
    totals[entry.method] =
        (totals[entry.method] ?? 0) + entry.amountSen * entry.kind.sign;
  }

  return CashUp(
    byMethod: [
      // Ordered by the enum rather than by how much came in, so the screen
      // looks the same every evening and a missing row is noticeable.
      for (final method in PaymentMethod.values)
        if (totals.containsKey(method))
          MethodTotal(
            method: method,
            expected: Money.sen(totals[method]!),
            counted: counted[method],
          ),
    ],
  );
}
