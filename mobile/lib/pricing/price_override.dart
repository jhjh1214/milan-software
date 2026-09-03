/// An admin moving a line's total by hand. SPEC.md §6.5.
///
/// ```
/// overrideLinePrice(lineId, newTotalSen, reason, adminSession)
/// ```
///
/// ## The gate is not the control
///
/// The spec is blunt about this, and it is worth repeating where the code is:
///
/// > An offline PIN is bypassable, and one shared admin password reaches every
/// > part-timer within a month. The real control is the audit log plus a weekly
/// > review screen, not the gate. Individual PINs so the log names a person, and
/// > build the "overrides this week" screen — without it the log is never read
/// > and the control does not exist.
///
/// So the admin check here is a speed bump, and the row it writes is the point.
/// Two rules follow from that, and both are about the review staying readable:
///
/// - an override must **name a person**. `is_admin` with no user id behind it is
///   refused, because an override nobody can be asked about is a number that
///   changed, not an audit trail;
/// - an override that **changes nothing** is refused. A row saying RM552 became
///   RM552 is noise, and noise is what stops the weekly review being read at
///   all.
///
/// ## What it will not do
///
/// A negative total is refused: a refund is a payment of kind `refund` (§6.4),
/// not a line that costs less than nothing. Zero is allowed — a write-off, a
/// remake at our cost — because the spec sets no floor and the audit row is
/// what makes that survivable.
///
/// A finished order is refused. Closed or cancelled, its number is on a
/// document the customer already has, and changing it now would make the paper
/// and the database disagree with nothing on either saying which came second.
///
/// Pure: no clock, no I/O, no Flutter. The row is described, not written.
library;

import '../core/money.dart';

/// The shortest reason that says anything. SPEC.md §6.5: *"reason mandatory,
/// minimum 4 characters. No empty-string bypass."*
///
/// Cancelling an order borrows this bar, for the same reason.
const int minReasonLength = 4;

/// Why an override was refused.
enum OverrideRefusal {
  /// Not an admin, or an admin the log cannot name.
  notAnAdmin('not_an_admin'),

  /// Missing, or too short to mean anything once trimmed.
  noReason('no_reason'),

  /// A line that costs less than nothing.
  negativeTotal('negative_total'),

  /// The total is already that. Nothing to record.
  noChange('no_change'),

  /// The order is closed or cancelled.
  orderFinished('order_finished');

  const OverrideRefusal(this.wire);

  final String wire;

  static OverrideRefusal fromWire(String wire) =>
      values.firstWhere((r) => r.wire == wire);
}

/// The audit row an accepted override calls for. SPEC.md §6.5.
///
/// Append-only, never deletable from the app. The `id` and the clock are the
/// caller's — this module reads neither.
class OverrideRecord {
  const OverrideRecord({
    required this.before,
    required this.after,
    required this.reason,
    required this.adminUserId,
  });

  final Money before;
  final Money after;

  /// Trimmed, and guaranteed at least [minReasonLength] characters.
  final String reason;

  /// Never null. The whole control is that this names somebody.
  final String adminUserId;

  /// What the line moved by. Negative when the override brought it down.
  Money get delta => after - before;
}

/// The outcome of asking to override a line.
class OverrideDecision {
  const OverrideDecision.applied(OverrideRecord this.record)
    : refusedBecause = null;

  const OverrideDecision.refused(OverrideRefusal this.refusedBecause)
    : record = null;

  final OverrideRecord? record;
  final OverrideRefusal? refusedBecause;

  bool get isApplied => record != null;
}

/// Decides whether a line's total may be moved by hand, and to what.
///
/// [adminUserId] is the signed-in user; null when nobody is. [isAdmin] is their
/// role. Both are needed and neither is enough: the role decides whether the
/// power exists, the id decides whether the log can name who used it.
///
/// [orderIsTerminal] is `OrderStatus.isTerminal` for the order the line belongs
/// to, passed in rather than imported so that this module stays independent of
/// the state machine.
OverrideDecision overrideLinePrice({
  required Money before,
  required Money after,
  required String? reason,
  required String? adminUserId,
  required bool isAdmin,
  required bool orderIsTerminal,
}) {
  // Authority first. Somebody who may not do this at all should be told that,
  // not sent off to write a longer reason for a refusal that is already
  // certain.
  if (!isAdmin || adminUserId == null || adminUserId.isEmpty) {
    return const OverrideDecision.refused(OverrideRefusal.notAnAdmin);
  }

  if (orderIsTerminal) {
    return const OverrideDecision.refused(OverrideRefusal.orderFinished);
  }

  final given = (reason ?? '').trim();
  if (given.length < minReasonLength) {
    return const OverrideDecision.refused(OverrideRefusal.noReason);
  }

  if (after.isNegative) {
    return const OverrideDecision.refused(OverrideRefusal.negativeTotal);
  }

  if (after == before) {
    return const OverrideDecision.refused(OverrideRefusal.noChange);
  }

  return OverrideDecision.applied(
    OverrideRecord(
      before: before,
      after: after,
      reason: given,
      adminUserId: adminUserId,
    ),
  );
}
