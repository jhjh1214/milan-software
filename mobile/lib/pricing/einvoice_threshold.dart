/// The RM10,000 rule. SPEC.md §10.2, §10.3, §10.4.
///
/// Since **1 January 2026** any single transaction above RM10,000 must have its
/// own individual e-invoice and cannot go into a monthly consolidated batch.
/// B2C as much as B2B. Penalties run RM200 to RM20,000 **per non-compliant
/// invoice**, and §10.2 is blunt that this is not an edge case here:
///
/// > Full-house curtain orders routinely exceed RM10,000. A meaningful share of
/// > sales legally require buyer identification, not a "General Public"
/// > receipt.
///
/// SQL Account issues the invoice and flags what is over the threshold. **The
/// gap is upstream**: it can only issue an individual e-invoice if somebody
/// captured the buyer's details, and that has to happen while the customer is
/// standing there.
///
/// ## Checked twice, on purpose
///
/// §10.4's timing trap: *"An order estimated at RM8,500 settles at RM11,200."*
///
/// 1. **On the estimate, at the fair** — prompt from RM8,000, not RM10,000, so
///    borderline orders are captured while somebody can still be asked. Below
///    the legal line this only *asks*: refusing a RM300 deposit over paperwork
///    the order does not yet need would lose the sale.
/// 2. **On the final, after measurement** — if crossed, the order cannot
///    advance. §10.4: *"Enforce in the state machine, not the UI."*
///
/// The RM8,000 margin belongs to the estimate alone. An estimate is rough and
/// the margin buys a chance to ask; a final is exact, so an order that measured
/// under the threshold is under it.
///
/// **Both numbers are config on the rate card**, never literals here (§10.3:
/// *"Threshold lives in config, not code. It will change."*). A change to
/// either reaches every handset the way a price change does — by publishing a
/// card, with no rebuild.
///
/// Nothing in this file prints, names or numbers a document. CLAUDE.md hard
/// rule 7 stands: SQL Account is the sole issuer of record.
///
/// Pure. No Flutter, no I/O, no clock.
library;

import '../core/money.dart';

/// Which figure is being checked.
enum ThresholdStage {
  /// At the fair, on the estimate. Carries the RM8,000 margin.
  estimate('estimate'),

  /// After site measurement, on the exact figure. No margin.
  finalPricing('final');

  const ThresholdStage(this.wire);

  final String wire;

  static ThresholdStage fromWire(String wire) =>
      ThresholdStage.values.firstWhere((s) => s.wire == wire);
}

/// Why buyer details are wanted.
enum ThresholdReason {
  /// Inside §10.4's margin — RM8,000 or more, under the legal line. Ask now,
  /// because this may well cross after measurement.
  nearThreshold('near_threshold'),

  /// At or over the legal line. §10.3: not a warning, a required step.
  overThreshold('over_threshold'),

  /// The customer asked for an e-invoice, at any value (§10.3).
  einvoiceRequested('einvoice_requested');

  const ThresholdReason(this.wire);

  final String wire;
}

/// What the threshold rule says about one order.
class ThresholdCheck {
  const ThresholdCheck({
    required this.mustCapture,
    required this.blocksAdvance,
    this.reason,
  });

  /// Buyer details are wanted. Ask.
  final bool mustCapture;

  /// And the order may not go on without them. §10.3: *"Not a warning. A
  /// required step."*
  final bool blocksAdvance;

  /// Null when nothing is wanted.
  final ThresholdReason? reason;

  static const ThresholdCheck none = ThresholdCheck(
    mustCapture: false,
    blocksAdvance: false,
  );
}

/// The two figures, off the rate card. §10.3: config, not code.
class ThresholdConfig {
  const ThresholdConfig({required this.threshold, required this.prompt});

  /// At or over this, buyer details are required. RM10,000.
  final Money threshold;

  /// At or over this, the quote wizard asks. RM8,000, and only on an estimate.
  final Money prompt;
}

/// Whether an order needs buyer details, and whether it may move without them.
///
/// [buyerDetailsComplete] is the only thing that clears it. The requirement is
/// the details, not the ceremony: once they exist the order moves, at any
/// value.
ThresholdCheck checkThreshold({
  required Money total,
  required ThresholdStage stage,
  required ThresholdConfig config,
  bool buyerDetailsComplete = false,
  bool einvoiceRequested = false,
}) {
  if (buyerDetailsComplete) return ThresholdCheck.none;

  // §10.3: required whenever the customer asks, at any value. Checked first
  // because it holds regardless of the amount — a RM552 order for somebody who
  // wants to claim it is as much a compliance obligation as a RM15,000 one.
  if (einvoiceRequested) {
    return const ThresholdCheck(
      mustCapture: true,
      blocksAdvance: true,
      reason: ThresholdReason.einvoiceRequested,
    );
  }

  // At exactly RM10,000, not above it. §10.2 says "above RM10,000" and §10.3
  // says the wizard stops when the total "crosses the threshold"; stopping at
  // the round number is the conservative direction, because capturing details
  // for one order that did not need them costs a minute and missing one costs
  // up to RM20,000.
  if (total.sen >= config.threshold.sen) {
    return const ThresholdCheck(
      mustCapture: true,
      blocksAdvance: true,
      reason: ThresholdReason.overThreshold,
    );
  }

  // The margin is the estimate's alone. A final is exact: an order that
  // measured under the threshold is under it, and asking at that point is
  // friction with no compliance behind it.
  if (stage == ThresholdStage.estimate && total.sen >= config.prompt.sen) {
    return const ThresholdCheck(
      mustCapture: true,
      // Asks, does not stop. The order is not over the legal line, and
      // refusing a deposit over paperwork it does not yet need loses the sale.
      blocksAdvance: false,
      reason: ThresholdReason.nearThreshold,
    );
  }

  return ThresholdCheck.none;
}
