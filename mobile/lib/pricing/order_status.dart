/// The pipeline an order walks after a deposit confirms it. SPEC.md §6.3.
///
/// ```
/// confirmed → measurement_booked → measured → material_selected
///           → in_production → ready → installed → closed
/// ```
///
/// with `cancelled` reachable from anywhere up to and including `ready`, and
/// `closed` and `cancelled` terminal.
///
/// ## Why the machine is strict
///
/// The statuses are not decoration. `order_events` is append-only (CLAUDE.md),
/// and the history it accumulates is what somebody reads a year later to answer
/// what happened to a job. A skipped step is a lie in that history, and a
/// rewound one silently overwrites a visit that really took place.
///
/// So there are no shortcuts and no backwards moves. A remeasure is new
/// dimensions on the same order, not a return to `measurement_booked` — the
/// lines change, the status does not.
///
/// ## Two guards, both about money one stage later
///
/// `measured` requires that every line needing a site visit actually has final
/// dimensions. Five of six windows measured is not a measured order: marking it
/// so hands final pricing a line with no tape behind it, and breaks the
/// variance report that the estimate exists to feed.
///
/// `material_selected` requires that every deferred material has been chosen.
/// SPEC.md §13 B7: at final pricing a missing material raises rather than
/// guessing, because nobody should be invoiced for a material they never
/// picked. Catching it at the status change is far cheaper than catching it at
/// the invoice.
///
/// ## Cancelling needs a reason
///
/// Same rule as a price override (§6.5) and for the same reason. A cancelled
/// order has a customer's deposit sitting against it, and what happens to that
/// RM300 is §13 B3 — still unanswered. Whoever answers it will be reading these
/// rows. "Four characters, trimmed" is the same bar the override takes, so
/// neither an empty string nor a three-letter shrug gets through.
///
/// Nothing here computes a forfeit, a refund or a credit. The status moves; the
/// money is B3's to decide.
///
/// Pure: no clock, no I/O, no Flutter. Everything is passed in.
library;

/// Where an order is. The wire values are the enum in SPEC.md §6.3 and the
/// strings stored in `orders.status`, on both sides of the sync.
enum OrderStatus {
  confirmed('confirmed'),
  measurementBooked('measurement_booked'),
  measured('measured'),
  materialSelected('material_selected'),
  inProduction('in_production'),
  ready('ready'),
  installed('installed'),
  closed('closed'),
  cancelled('cancelled');

  const OrderStatus(this.wire);

  final String wire;

  /// Nothing moves out of these. A cancelled order that comes back is a new
  /// order, not this one reopened.
  bool get isTerminal => this == closed || this == cancelled;

  static OrderStatus fromWire(String wire) => values.firstWhere(
    (s) => s.wire == wire,
    orElse: () => throw UnknownOrderStatus(wire),
  );

  /// The happy path in order, for a progress indicator. `cancelled` is not on
  /// it: it is a branch off the side, not a stage of the job.
  static const List<OrderStatus> pipeline = [
    confirmed,
    measurementBooked,
    measured,
    materialSelected,
    inProduction,
    ready,
    installed,
    closed,
  ];
}

/// A status arrived from a server or an old row that this build does not know.
///
/// Thrown rather than defaulted. Guessing which stage a job is at would put a
/// real order in the wrong column of every report, and quietly.
class UnknownOrderStatus implements Exception {
  const UnknownOrderStatus(this.wire);

  final String wire;

  @override
  String toString() =>
      'UnknownOrderStatus: "$wire" is not a status in SPEC.md §6.3';
}

/// Why a status change was refused. The wire values are what the server sends
/// back and what a test fixture names.
enum StatusRefusal {
  /// The order is already there. Two people tapping the same button, or one
  /// tapping twice on a slow handset — it writes nothing and it is not a
  /// failure worth showing anybody.
  alreadyThere('already_there'),

  /// Closed or cancelled. Nothing moves.
  terminal('terminal'),

  /// Not an edge of the pipeline: a skipped step, a backwards move, or
  /// cancelling something already installed.
  notATransition('not_a_transition'),

  /// A line that needs a site visit still has no final dimensions.
  linesNotMeasured('lines_not_measured'),

  /// A line quoted at the dearest option in its group still has no material
  /// chosen. SPEC.md §13 B7.
  materialNotChosen('material_not_chosen'),

  /// Cancelling with no reason, or with one too short to mean anything.
  noReason('no_reason');

  const StatusRefusal(this.wire);

  final String wire;

  static StatusRefusal fromWire(String wire) =>
      values.firstWhere((r) => r.wire == wire);
}

/// The four things about a line that the guards read.
///
/// Deliberately not the line itself. The state machine has no business knowing
/// about rates, and passing the whole row would let it start reading them.
class OrderLineState {
  const OrderLineState({
    required this.needsMeasuring,
    required this.hasFinalDimensions,
    required this.materialDeferred,
    required this.materialChosen,
  });

  /// This line is priced off an estimate and wants a tape on it.
  final bool needsMeasuring;

  /// The site visit has happened for this line.
  final bool hasFinalDimensions;

  /// Quoted at the dearest option in its group, pending a choice. §13 B7.
  final bool materialDeferred;

  /// Somebody has since chosen one.
  final bool materialChosen;
}

/// The outcome of asking an order to move.
class StatusChange {
  const StatusChange.allowed(OrderStatus this.to) : refusedBecause = null;

  const StatusChange.refused(StatusRefusal this.refusedBecause) : to = null;

  /// Where the order ends up, or null when refused.
  final OrderStatus? to;

  final StatusRefusal? refusedBecause;

  bool get isAllowed => to != null;
}

/// The shortest cancellation reason that says anything. §6.5 sets the same bar
/// for a price override.
const int minReasonLength = 4;

/// What each status may become. Everything not listed is refused.
///
/// The two terminal entries are empty and unreachable — [advanceOrder] answers
/// `terminal` before it consults this table, because "nothing moves out of a
/// closed order" is a different thing to tell somebody than "that is not a
/// step". They are kept because the table is the readable statement of the
/// machine, and a test holds the two in step.
const Map<OrderStatus, Set<OrderStatus>> _allowed = {
  OrderStatus.confirmed: {OrderStatus.measurementBooked, OrderStatus.cancelled},
  OrderStatus.measurementBooked: {OrderStatus.measured, OrderStatus.cancelled},
  OrderStatus.measured: {OrderStatus.materialSelected, OrderStatus.cancelled},
  OrderStatus.materialSelected: {
    OrderStatus.inProduction,
    OrderStatus.cancelled,
  },
  OrderStatus.inProduction: {OrderStatus.ready, OrderStatus.cancelled},
  OrderStatus.ready: {OrderStatus.installed, OrderStatus.cancelled},

  // Not cancelled. The curtains are on the customer's wall; taking them down
  // is a return, which this system does not model, and calling it a
  // cancellation would put a fitted job in the cancelled column of every
  // report.
  OrderStatus.installed: {OrderStatus.closed},

  OrderStatus.closed: {},
  OrderStatus.cancelled: {},
};

/// What [from] may become, for a screen deciding which buttons to show.
///
/// Empty for a terminal status. Says nothing about the guards — a move listed
/// here can still be refused because a window is unmeasured.
Set<OrderStatus> allowedFrom(OrderStatus from) =>
    _allowed[from] ?? const <OrderStatus>{};

/// The next step along the happy path, or null at the end of it.
///
/// For the single button a screen wants to show. It says nothing about whether
/// the move is currently *permitted* — ask [advanceOrder] for that.
OrderStatus? nextInPipeline(OrderStatus from) {
  final i = OrderStatus.pipeline.indexOf(from);
  if (i < 0 || i + 1 >= OrderStatus.pipeline.length) return null;
  return OrderStatus.pipeline[i + 1];
}

/// Decides whether an order may move from [from] to [to].
///
/// [reason] is required only when cancelling, and is trimmed before it is
/// measured so whitespace cannot pass for an explanation.
StatusChange advanceOrder({
  required OrderStatus from,
  required OrderStatus to,
  required List<OrderLineState> lines,
  String? reason,
}) {
  // Checked before terminal, so that a double tap on an order that is already
  // closed reads as a no-op rather than as an error somebody has to interpret.
  if (from == to) {
    return const StatusChange.refused(StatusRefusal.alreadyThere);
  }

  if (from.isTerminal) {
    return const StatusChange.refused(StatusRefusal.terminal);
  }

  if (!(_allowed[from] ?? const {}).contains(to)) {
    return const StatusChange.refused(StatusRefusal.notATransition);
  }

  if (to == OrderStatus.cancelled) {
    // Cancellation reads no line state. An order that somehow has no lines
    // must still be closable rather than stuck in confirmed forever.
    final given = (reason ?? '').trim();
    if (given.length < minReasonLength) {
      return const StatusChange.refused(StatusRefusal.noReason);
    }
    return const StatusChange.allowed(OrderStatus.cancelled);
  }

  if (to == OrderStatus.measured &&
      lines.any((l) => l.needsMeasuring && !l.hasFinalDimensions)) {
    return const StatusChange.refused(StatusRefusal.linesNotMeasured);
  }

  if (to == OrderStatus.materialSelected &&
      lines.any((l) => l.materialDeferred && !l.materialChosen)) {
    return const StatusChange.refused(StatusRefusal.materialNotChosen);
  }

  return StatusChange.allowed(to);
}
