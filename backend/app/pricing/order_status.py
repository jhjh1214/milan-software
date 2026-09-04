"""The pipeline an order walks after a deposit confirms it. SPEC.md §6.3.

Mirrors ``mobile/lib/pricing/order_status.dart`` decision for decision, and the
two are held together by ``shared/pricing-fixtures.json`` under
``order_status_cases``.

The server re-validates every transition a handset pushes. CLAUDE.md hard rule
4 is about pricing, but the reasoning carries: a status that moved on one device
and would be refused here leaves the two disagreeing about whether a job is in
production, and the handset is the copy nobody else can see.

::

    confirmed -> measurement_booked -> measured -> material_selected
              -> in_production -> ready -> installed -> closed

with ``cancelled`` reachable from anywhere up to and including ``ready``, and
``closed`` and ``cancelled`` terminal.

No shortcuts and no backwards moves. ``order_events`` is append-only, and the
history it accumulates is what somebody reads a year later: a skipped step is a
lie in it, and a rewound one silently overwrites a visit that really happened. A
remeasure is new dimensions on the same order, not a return to
``measurement_booked``.

Two guards, both about money one stage later. ``measured`` needs every line that
wanted a site visit to have final dimensions -- five of six windows measured is
not a measured order, and marking it so hands final pricing a line with no tape
behind it. ``material_selected`` needs every deferred material chosen (§13 B7),
because at final pricing a missing material raises rather than guessing.

Cancelling needs a reason, four characters after trimming, the same bar a price
override takes (§6.5) and for the same reason: what happens to the deposit is
§13 B3, unanswered, and whoever answers it will be reading these rows. Nothing
here computes a forfeit, a refund or a credit.

Pure. No clock read, no I/O, no ORM.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .einvoice_threshold import NONE as NO_THRESHOLD
from .einvoice_threshold import ThresholdCheck


class UnknownOrderStatus(ValueError):
    """A status this build does not know.

    Raised rather than defaulted. Guessing which stage a job is at would put a
    real order in the wrong column of every report, quietly.
    """

    def __init__(self, wire: str) -> None:
        super().__init__(f'"{wire}" is not a status in SPEC.md §6.3')
        self.wire = wire


class OrderStatus(Enum):
    """Where an order is. The values are ``orders.status`` on both sides."""

    CONFIRMED = "confirmed"
    MEASUREMENT_BOOKED = "measurement_booked"
    MEASURED = "measured"
    MATERIAL_SELECTED = "material_selected"
    IN_PRODUCTION = "in_production"
    READY = "ready"
    INSTALLED = "installed"
    CLOSED = "closed"
    CANCELLED = "cancelled"

    @property
    def is_terminal(self) -> bool:
        """Nothing moves out of these.

        A cancelled order that comes back is a new order, not this one
        reopened.
        """
        return self in (OrderStatus.CLOSED, OrderStatus.CANCELLED)

    @classmethod
    def from_wire(cls, wire: str) -> OrderStatus:
        try:
            return cls(wire)
        except ValueError as exc:
            raise UnknownOrderStatus(wire) from exc


#: The happy path in order, for a progress indicator. ``cancelled`` is not on
#: it: it is a branch off the side, not a stage of the job.
PIPELINE: tuple[OrderStatus, ...] = (
    OrderStatus.CONFIRMED,
    OrderStatus.MEASUREMENT_BOOKED,
    OrderStatus.MEASURED,
    OrderStatus.MATERIAL_SELECTED,
    OrderStatus.IN_PRODUCTION,
    OrderStatus.READY,
    OrderStatus.INSTALLED,
    OrderStatus.CLOSED,
)


class StatusRefusal(Enum):
    """Why a status change was refused."""

    #: The order is already there. Two people tapping the same button, or one
    #: tapping twice on a slow handset -- it writes nothing, and it is not a
    #: failure worth showing anybody.
    ALREADY_THERE = "already_there"

    #: Closed or cancelled. Nothing moves.
    TERMINAL = "terminal"

    #: Not an edge of the pipeline: a skipped step, a backwards move, or
    #: cancelling something already installed.
    NOT_A_TRANSITION = "not_a_transition"

    #: A line that needs a site visit still has no final dimensions.
    LINES_NOT_MEASURED = "lines_not_measured"

    #: A line quoted at the dearest option in its group still has no material
    #: chosen. SPEC.md §13 B7.
    MATERIAL_NOT_CHOSEN = "material_not_chosen"

    #: Cancelling with no reason, or with one too short to mean anything.
    NO_REASON = "no_reason"

    #: The final crossed RM10,000 and nobody has the buyer's details.
    #: SPEC.md §10.4: *"Enforce in the state machine, not the UI."*
    BUYER_DETAILS_REQUIRED = "buyer_details_required"


#: The steps a §10.4 block bites on: everything after the final total exists.
#:
#: ``CANCELLED`` is deliberately absent. Cancelling has nothing to do with
#: invoicing, and refusing it would leave an over-threshold order trapped with
#: no way out.
_AFTER_MEASURED: frozenset[OrderStatus] = frozenset(
    {
        OrderStatus.MATERIAL_SELECTED,
        OrderStatus.IN_PRODUCTION,
        OrderStatus.READY,
        OrderStatus.INSTALLED,
        OrderStatus.CLOSED,
    }
)


@dataclass(frozen=True, slots=True)
class OrderLineState:
    """The four things about a line that the guards read.

    Deliberately not the line itself. The state machine has no business knowing
    about rates, and passing the whole row would let it start reading them.
    """

    needs_measuring: bool
    has_final_dimensions: bool
    material_deferred: bool
    material_chosen: bool


@dataclass(frozen=True, slots=True)
class StatusChange:
    """The outcome of asking an order to move."""

    to: OrderStatus | None = None
    refused_because: StatusRefusal | None = None

    @property
    def is_allowed(self) -> bool:
        return self.to is not None


#: The shortest cancellation reason that says anything. §6.5 sets the same bar
#: for a price override.
MIN_REASON_LENGTH = 4

#: What each status may become. Everything not listed is refused.
#:
#: The two terminal entries are empty and unreachable -- :func:`advance_order`
#: answers ``terminal`` before it consults this table, because "nothing moves
#: out of a closed order" is a different thing to tell somebody than "that is
#: not a step". They are kept because the table is the readable statement of
#: the machine, and a test holds the two in step.
_ALLOWED: dict[OrderStatus, frozenset[OrderStatus]] = {
    OrderStatus.CONFIRMED: frozenset(
        {OrderStatus.MEASUREMENT_BOOKED, OrderStatus.CANCELLED}
    ),
    OrderStatus.MEASUREMENT_BOOKED: frozenset(
        {OrderStatus.MEASURED, OrderStatus.CANCELLED}
    ),
    OrderStatus.MEASURED: frozenset(
        {OrderStatus.MATERIAL_SELECTED, OrderStatus.CANCELLED}
    ),
    OrderStatus.MATERIAL_SELECTED: frozenset(
        {OrderStatus.IN_PRODUCTION, OrderStatus.CANCELLED}
    ),
    OrderStatus.IN_PRODUCTION: frozenset({OrderStatus.READY, OrderStatus.CANCELLED}),
    OrderStatus.READY: frozenset({OrderStatus.INSTALLED, OrderStatus.CANCELLED}),
    # Not cancelled. The curtains are on the customer's wall; taking them down
    # is a return, which this system does not model, and calling it a
    # cancellation would put a fitted job in the cancelled column of every
    # report.
    OrderStatus.INSTALLED: frozenset({OrderStatus.CLOSED}),
    OrderStatus.CLOSED: frozenset(),
    OrderStatus.CANCELLED: frozenset(),
}


def allowed_from(status: OrderStatus) -> frozenset[OrderStatus]:
    """What ``status`` may become, for a screen deciding which buttons to show.

    Empty for a terminal status. Says nothing about the guards -- a move listed
    here can still be refused because a window is unmeasured.
    """
    return _ALLOWED.get(status, frozenset())


def next_in_pipeline(status: OrderStatus) -> OrderStatus | None:
    """The next step along the happy path, or ``None`` at the end of it.

    Says nothing about whether the move is currently *permitted* -- ask
    :func:`advance_order` for that.
    """
    try:
        i = PIPELINE.index(status)
    except ValueError:
        return None
    if i + 1 >= len(PIPELINE):
        return None
    return PIPELINE[i + 1]


def advance_order(
    *,
    frm: OrderStatus,
    to: OrderStatus,
    lines: list[OrderLineState],
    reason: str | None = None,
    threshold: ThresholdCheck = NO_THRESHOLD,
) -> StatusChange:
    """Decide whether an order may move from ``frm`` to ``to``.

    ``reason`` is required only when cancelling, and is trimmed before it is
    measured so whitespace cannot pass for an explanation.
    """
    # Checked before terminal, so that a double tap on an order that is already
    # closed reads as a no-op rather than as an error somebody has to interpret.
    if frm is to:
        return StatusChange(refused_because=StatusRefusal.ALREADY_THERE)

    if frm.is_terminal:
        return StatusChange(refused_because=StatusRefusal.TERMINAL)

    if to not in allowed_from(frm):
        return StatusChange(refused_because=StatusRefusal.NOT_A_TRANSITION)

    if to is OrderStatus.CANCELLED:
        # Cancellation reads no line state. An order that somehow has no lines
        # must still be closable rather than stuck in confirmed forever.
        if len((reason or "").strip()) < MIN_REASON_LENGTH:
            return StatusChange(refused_because=StatusRefusal.NO_REASON)
        return StatusChange(to=OrderStatus.CANCELLED)

    # §10.4: an order whose final crossed RM10,000 cannot advance until the
    # buyer's details exist. Checked *after* the cancel branch, so an
    # over-threshold order is never trapped: cancelling has nothing to do with
    # invoicing, and refusing it would leave a job nobody can close.
    #
    # The block bites from `material_selected` onwards -- the first step after
    # the final total exists. §10.2 says capture has to happen while the
    # customer is standing there, and the measurer has only just left; waiting
    # until the job is installed means asking somebody who has no reason left
    # to answer the phone. §13 C12 asks which step the client calls invoicing.
    if threshold.blocks_advance and to in _AFTER_MEASURED:
        return StatusChange(refused_because=StatusRefusal.BUYER_DETAILS_REQUIRED)

    if to is OrderStatus.MEASURED and any(
        line.needs_measuring and not line.has_final_dimensions for line in lines
    ):
        return StatusChange(refused_because=StatusRefusal.LINES_NOT_MEASURED)

    if to is OrderStatus.MATERIAL_SELECTED and any(
        line.material_deferred and not line.material_chosen for line in lines
    ):
        return StatusChange(refused_because=StatusRefusal.MATERIAL_NOT_CHOSEN)

    return StatusChange(to=to)
