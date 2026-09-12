/// Local persistence. Drift over SQLite, per CLAUDE.md — relational, not
/// key-value.
///
/// SPEC.md §8.1: "The app will be backgrounded mid-quote by a phone call. Every
/// keystroke persists locally. Reopening returns to the exact window." A dropped
/// phone at a fair must cost nothing.
///
/// ## Conventions this schema obeys
///
/// - **Ids are client-generated UUID v4.** Two part-timers offline at one fair
///   must never collide, so nothing waits on a server for an id.
/// - **Lengths are `_tmm`** — integer tenths of a millimetre. A column named
///   `_mm` is a bug.
/// - **Money is `_sen`** — integer. No `REAL` column ever holds currency.
/// - **Syncing tables carry `synced_at`**, null until the server has it.
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// A quotation in progress, or one already converted to an order.
///
/// Phase 1 kept this in memory and lost it on force-quit. Phase 2 does not.
@DataClassName('QuoteRow')
class Quotes extends Table {
  /// Client-generated UUID v4.
  TextColumn get id => text()();

  /// Which rate card priced this quote. Pinned at creation so a later
  /// publish cannot silently reprice work already shown to a customer.
  IntColumn get rateCardVersion => integer()();

  /// `standard` or `mvp`.
  TextColumn get tier => text().withDefault(const Constant('standard'))();

  /// The user's language when the quote was made, for reprinting it the same
  /// way later.
  TextColumn get language => text().withDefault(const Constant('zh'))();

  /// Free-text customer name. A full customer record arrives with Phase 4.
  TextColumn get customerName => text().nullable()();
  TextColumn get customerPhone => text().nullable()();

  /// Where this quote was taken: `fair`, `showroom`, `home_visit`, `phone` or
  /// `referral`.
  ///
  /// Recorded on the quote rather than worked out from the date, because it
  /// decides two things the date cannot. §3: "Promo and the 12-month lock are
  /// fair-only. Showroom pays standard." And client, Sep 2026: *"only depo at
  /// fair can lock price."* A showroom walk-in during the four days of a fair
  /// is a real customer, and reading the calendar would hand them both the
  /// promo rate and a hold they never bought.
  ///
  /// Every report segments by it too (§3) — the company currently cannot answer
  /// whether a fair beats three months of showroom traffic.
  TextColumn get channel => text().withDefault(const Constant('showroom'))();

  /// The delivery zone charged on this quote, if any.
  ///
  /// SPEC.md §4.1: the charge is driven by the delivery address, not by any
  /// line, and must be surfaced **before** the total — never after the customer
  /// has already agreed a number.
  TextColumn get deliveryZoneId => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Null until the server has this row. Phase 3.
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One window on a quote.
///
/// Stores what was *entered*, not what was computed. Prices are derived by the
/// engine on read, so a rate-card correction reprices old drafts rather than
/// leaving them frozen at a number nobody can reproduce.
@DataClassName('QuoteLineRow')
class QuoteLines extends Table {
  TextColumn get id => text()();
  TextColumn get quoteId => text().references(Quotes, #id)();

  /// Display order within the quote.
  IntColumn get sortOrder => integer()();

  TextColumn get room => text()();
  TextColumn get variant => text()();

  /// Null means the customer has not chosen a material yet — the fair case.
  TextColumn get materialKey => text().nullable()();

  TextColumn get layer => text()();

  /// The line this one is an upgrade to, if any.
  ///
  /// A special track, a motor or a box is an extra charge **on top of** the
  /// curtain or blind it belongs to (A16), so it is a child line rather than a
  /// separate window. It carries a copy of its parent's dimensions — instantiate
  /// rather than reference, so editing the parent later cannot silently
  /// reprice a line the customer already agreed.
  TextColumn get parentLineId => text().nullable()();

  /// Tenths of a millimetre. Never millimetres.
  IntColumn get widthTmm => integer()();
  IntColumn get heightTmm => integer().nullable()();

  /// Exactly what the user typed, so §5.5 can show entered beside billed
  /// without inventing precision that was never entered.
  TextColumn get rawWidth => text()();
  TextColumn get rawHeight => text()();

  IntColumn get quantity => integer().withDefault(const Constant(1))();

  /// On-device path to the photo of this window.
  ///
  /// The path only, not the bytes: a 3MB JPEG in a SQLite row bloats every
  /// query that touches the line. §7 keeps `local_path` until upload and
  /// `remote_key` after, and the upload half arrives with sync in Phase 3.
  TextColumn get photoPath => text().nullable()();

  /// Where this line's dimensions came from. SPEC.md Phase 8's Property /
  /// Project / Unit Library.
  ///
  /// Null means typed by hand, true of every line before this library
  /// existed. No separate "source" flag beside these: a non-null
  /// [sourceUnitTypeId] already says "the library", and a flag that could
  /// disagree with the id it sits beside is a second place to be wrong.
  TextColumn get sourceProjectId => text().nullable()();
  TextColumn get sourceUnitTypeId => text().nullable()();
  IntColumn get sourceVersion => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Handset preferences. Small, flat, and deliberately not domain data.
///
/// Drift over a key-value store is CLAUDE.md's rule about *orders* — a quote is
/// an order with lines and Hive would turn every read into a hand-rolled join.
/// "Is this handset at a fair" is one boolean, and giving it a table with one
/// column would be the same mistake in the other direction.
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// One RM300, holding one category's prices for twelve months. SPEC.md §6.1.
///
/// **Rows are never edited into existence.** `openCategoryLock` in
/// `pricing/rate_lock.dart` is the only thing that builds one, and it refuses
/// outside a fair and below the minimum, so a screen cannot open a lock the
/// business does not sell.
///
/// Held on the device as well as the server because the resolver has to work
/// with no signal: a customer who deposited at the August fair and walks into
/// the showroom in March must be priced correctly on a handset that has not
/// synced today.
@DataClassName('CategoryLockRow')
class CategoryLocks extends Table {
  TextColumn get id => text()();

  /// Whose lock it is. The lock follows the **customer**, not the order — a
  /// hold bought at last August's fair prices a line added months later.
  TextColumn get customerId => text()();

  /// `curtain`, `flooring` or `wallpaper`. Three, not seven: blinds and tracks
  /// ride the curtain deposit.
  TextColumn get category => text()();

  /// The payment that bought it, so a refund can find the lock it cancels.
  TextColumn get depositPaymentId => text().nullable()();

  /// Pinned **both**, at deposit time. Pinning only the version silently
  /// reprices this customer when the promo percentage moves.
  IntColumn get heldRateCardVersion => integer()();

  /// Exact rational, stored in this type's own `toString` notation — `0`,
  /// `1/10`. Never a float: a percentage of a price is money.
  TextColumn get heldDiscountPct => text().withDefault(const Constant('0'))();

  /// The **last day** the hold is good for, inclusive.
  DateTimeColumn get heldUntil => dateTime()();

  /// `active`, `expired`, `cancelled` or `refunded`.
  TextColumn get status => text().withDefault(const Constant('active'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A confirmed sale. SPEC.md §6.3.
///
/// §3: a deposit confirms an order — *"Not a quote, not a lead. A confirmed
/// sale."* So a row here means money has been taken.
///
/// **The quote is referenced, never consumed.** Client, Sep 2026: *"the quote
/// should be recorded as reference to the order, so have rough estimate of what
/// to do."* The quote stays exactly as it was; this points back at it. That is
/// what the measurement team reads before going out, and what §6.3's variance
/// report compares the final against.
@DataClassName('OrderRow')
class Orders extends Table {
  /// Client-generated UUID v4, like every other id here.
  TextColumn get id => text()();

  /// The quote this was confirmed from. The rough estimate of what to do.
  TextColumn get quoteId => text().references(Quotes, #id)();

  /// `{branch}-{yymm}-{seq}`. **Server-issued**, null until sync, shown as
  /// "pending sync" — the same rule as a receipt number, and for the same
  /// reason: it goes on a document the customer takes away, and two part-timers
  /// offline at one fair would invent the same one.
  TextColumn get orderNo => text().nullable()();

  /// Where the sale happened. Decides whether the deposit locked anything.
  TextColumn get channel => text()();

  /// The card that priced it. A later publish must not reprice a confirmed
  /// order.
  IntColumn get pinnedRateCardVersion => integer()();

  TextColumn get customerName => text().nullable()();
  TextColumn get customerPhone => text().nullable()();
  TextColumn get deliveryZoneId => text().nullable()();
  IntColumn get deliveryChargeSen => integer().withDefault(const Constant(0))();

  /// `confirmed`, `measurement_booked`, `measured`, `material_selected`,
  /// `in_production`, `ready`, `installed`, `closed`, `cancelled`.
  TextColumn get status => text().withDefault(const Constant('confirmed'))();

  /// **Both kept, for good.** §6.3: the variance report by salesperson tells
  /// the boss who is guessing badly, and it has nothing to compare if the
  /// estimate is overwritten by the final.
  IntColumn get estimateTotalSen => integer()();
  IntColumn get finalTotalSen => integer().nullable()();

  IntColumn get depositPaidSen => integer().withDefault(const Constant(0))();

  /// Against the **estimate** until the tape comes out, so it can only fall.
  IntColumn get balanceDueSen => integer().withDefault(const Constant(0))();

  // Buyer details, for an e-invoice. §10.3.
  //
  // Optional by default and null for most orders: most walk-ins are General
  // Public and never need any of this. They become required when the total
  // crosses RM10,000 (§10.2) or when the customer asks (§10.3), and the rule
  // for what counts as complete lives in `pricing/einvoice_threshold.dart`
  // rather than in a flag anybody can tick.
  //
  // Held on the order rather than on a customer record because there is no
  // customer table yet -- §13 B9's open half. When one arrives these move, and
  // the order keeps a snapshot: what was true when the invoice was issued is
  // not what is true when somebody moves house.
  TextColumn get buyerTin => text().nullable()();

  /// `nric`, `brn`, `passport` or `army`. Stored with its number or not at
  /// all -- a number with no type cannot be filed.
  TextColumn get buyerIdType => text().nullable()();
  TextColumn get buyerIdNumber => text().nullable()();

  TextColumn get buyerAddressLine1 => text().nullable()();
  TextColumn get buyerAddressLine2 => text().nullable()();
  TextColumn get buyerCity => text().nullable()();
  TextColumn get buyerState => text().nullable()();
  TextColumn get buyerPostcode => text().nullable()();

  /// Business buyers only.
  TextColumn get buyerMsicCode => text().nullable()();

  /// The customer asked for an e-invoice. §10.3: required at any value, so
  /// this is a reason to capture details on its own, not only a preference.
  BoolColumn get einvoiceRequested =>
      boolean().withDefault(const Constant(false))();

  /// True while any line is still on the sizes entered at the fair.
  BoolColumn get hasUnmeasuredLines =>
      boolean().withDefault(const Constant(true))();

  TextColumn get confirmedByUserId => text().nullable()();
  DateTimeColumn get confirmedAt => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One line on a confirmed order. SPEC.md §6.3.
///
/// A **copy** of the quote line, not a pointer to it. The quote is a record of
/// what was estimated and must not change when the order is measured; the order
/// is a record of what is being made and must not change when somebody edits an
/// old quote.
///
/// Each line snapshots how it was priced — rule, band, rate, card version,
/// discount — so a price is still explainable a year later, when the card that
/// produced it has been superseded twice.
@DataClassName('OrderLineRow')
class OrderLines extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text().references(Orders, #id)();

  /// The quote line it was copied from. The trail back to the estimate.
  TextColumn get quoteLineId => text()();

  IntColumn get sortOrder => integer()();
  TextColumn get room => text()();
  TextColumn get variant => text()();
  TextColumn get materialKey => text().nullable()();
  TextColumn get layer => text()();
  TextColumn get parentLineId => text().nullable()();

  /// What was entered at the fair. Tenths of a millimetre, never millimetres.
  IntColumn get estWidthTmm => integer()();
  IntColumn get estHeightTmm => integer().nullable()();

  /// What the tape said. Null until somebody has been out with one, and stored
  /// **beside** the estimate rather than over it.
  IntColumn get finalWidthTmm => integer().nullable()();
  IntColumn get finalHeightTmm => integer().nullable()();
  BoolColumn get isSiteMeasured =>
      boolean().withDefault(const Constant(false))();
  TextColumn get measuredByUserId => text().nullable()();
  DateTimeColumn get measuredAt => dateTime().nullable()();

  IntColumn get quantity => integer().withDefault(const Constant(1))();

  /// The lock that priced it, or null when nothing did. §6.1's hard rule, one
  /// step downstream: a line must not claim a lock priced it when none did.
  TextColumn get categoryLockId => text().nullable()();

  TextColumn get appliedRuleId => text()();
  TextColumn get appliedBandLabel => text().nullable()();
  IntColumn get appliedRateCardVersion => integer()();

  /// Exact rational in `Rational.toString` notation. Never a float.
  TextColumn get appliedDiscountPct =>
      text().withDefault(const Constant('0'))();

  /// Before tier substitution, and after. The quote prints both.
  IntColumn get standardRateSen => integer()();
  IntColumn get rateSen => integer()();

  TextColumn get billedQty => text()();
  TextColumn get billedUnit => text()();
  IntColumn get lineTotalSen => integer()();

  /// True when the material is still to be chosen and the line was quoted at
  /// the **dearest** option in its group (B7).
  BoolColumn get materialDeferred =>
      boolean().withDefault(const Constant(false))();

  /// True when an admin overrode the price. §6.5 keeps the reason in its own
  /// append-only table; this is the marker the quote and the screen show.
  BoolColumn get isOverridden => boolean().withDefault(const Constant(false))();

  // What the tape priced. Written **beside** the quoted figures above, never
  // over them: §6.3 keeps both so the variance report has something to
  // compare, and so a customer asking why the bill differs from the quote can
  // be shown the two side by side.
  //
  // All null until somebody has measured. They are written together or not at
  // all -- a final total with no billed quantity behind it is a number nobody
  // can explain a year later.

  /// The exact measured quantity, in `Rational.toString` notation. Never a
  /// float, and never rounded: the quote rounded up and the bill does not.
  TextColumn get finalBilledQty => text().nullable()();
  TextColumn get finalBilledUnit => text().nullable()();

  /// The rule and band the tape selected, which need not be the ones the
  /// estimate used -- a measured drop over 10ft moves a curtain into the upper
  /// band. Recorded so the change is visible rather than inferred from a rate.
  TextColumn get finalRuleId => text().nullable()();
  TextColumn get finalBandLabel => text().nullable()();
  IntColumn get finalRateSen => integer().nullable()();

  /// What the line actually bills. Integer sen.
  IntColumn get finalLineTotalSen => integer().nullable()();

  /// Where the estimate dimensions actually came from. SPEC.md Phase 8.
  ///
  /// `manual` (the default, and every line before this library existed) or
  /// `project_library`. Never `site_measurement` here -- that is earned
  /// through [isSiteMeasured] and a real visit, not claimed at confirmation.
  TextColumn get measurementSource =>
      text().withDefault(const Constant('manual'))();
  TextColumn get sourceProjectId => text().nullable()();
  TextColumn get sourceUnitTypeId => text().nullable()();
  IntColumn get sourceVersion => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Everything that ever happened to an order. §6.3. **APPEND ONLY.**
///
/// Corrections are new rows with a reason, never edits. An order that went to
/// production and came back is two events, and the second one does not erase
/// the first.
@DataClassName('OrderEventRow')
class OrderEvents extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text()();

  /// `confirmed`, `status_changed`, `measured`, `cancelled`, and so on.
  TextColumn get event => text()();
  TextColumn get note => text().nullable()();
  TextColumn get byUserId => text().nullable()();
  DateTimeColumn get at => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Every price an admin moved by hand. SPEC.md §6.5.
///
/// **APPEND ONLY, and never deletable from the app.** This table *is* the
/// control:
///
/// > An offline PIN is bypassable, and one shared admin password reaches every
/// > part-timer within a month. The real control is the audit log plus a weekly
/// > review screen, not the gate.
///
/// Which is why `reason` and `adminUserId` are both NOT NULL. A row that cannot
/// say who or why is not an audit trail; it is a record that a number changed.
///
/// `orderId` is denormalised off the line on purpose. The whole point of the
/// table is the "overrides this week" screen, and that screen groups by order —
/// making it join through `order_lines` for every row would be the small
/// friction that stops it being written.
@DataClassName('PriceOverrideRow')
class PriceOverrides extends Table {
  TextColumn get id => text()();
  TextColumn get orderLineId => text().references(OrderLines, #id)();

  /// Denormalised for the weekly review. See the class comment.
  TextColumn get orderId => text()();

  IntColumn get beforeSen => integer()();
  IntColumn get afterSen => integer()();

  /// Mandatory, minimum four characters, stored trimmed. §6.5.
  TextColumn get reason => text()();

  /// Mandatory. *"Individual PINs so the log names a person."*
  TextColumn get adminUserId => text()();

  /// Which handset. Two admins sharing a PIN still show up as two devices.
  TextColumn get deviceId => text().nullable()();

  DateTimeColumn get at => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Money taken. SPEC.md §6.4.
///
/// **The system records payments. It does not process them.** The existing card
/// terminal stays; there is no PCI scope, no merchant onboarding and no
/// chargeback exposure here. A row is a note that money changed hands.
///
/// **APPEND ONLY.** A refund is a new row with `kind: refund`, never an edit to
/// the row it reverses — the cash-up screen has to reconcile what happened, not
/// what the drawer looks like now.
///
/// Works fully offline; nothing here needs authorising.
@DataClassName('PaymentRow')
class Payments extends Table {
  TextColumn get id => text()();

  /// The quote this was taken against.
  ///
  /// A quote and the confirmed order it becomes share one client-generated id
  /// — §3: an RM300 deposit *is* the confirmation, "not a quote, not a lead, a
  /// confirmed sale" — so this keeps pointing at the right thing once §6.3's
  /// orders arrive.
  TextColumn get quoteId => text()();

  /// The hold this deposit bought, when it bought one. Null for a progress
  /// payment, a balance, or a deposit taken away from a fair.
  TextColumn get categoryLockId => text().nullable()();

  /// `deposit`, `progress`, `balance` or `refund`.
  TextColumn get kind => text()();

  /// Integer sen. A refund is stored positive and subtracted by its kind, so
  /// nobody has to remember which rows are negative.
  IntColumn get amountSen => integer()();

  /// `cash`, `card_terminal`, `duitnow`, `bank_transfer` or `cheque`.
  ///
  /// Required. The daily cash-up is expected-versus-held **per method**, and a
  /// payment with no method cannot be reconciled against anything.
  TextColumn get method => text()();

  /// Terminal slip number, transfer reference — typed in, whatever the person
  /// holding the receipt has.
  TextColumn get externalRef => text().nullable()();

  /// **SERVER issued.** Null until sync, shown as "pending sync", and never
  /// fabricated on the device (CLAUDE.md): it goes on a legal document, and two
  /// handsets offline at one fair would invent the same number.
  TextColumn get receiptNo => text().nullable()();

  TextColumn get takenByUserId => text().nullable()();
  DateTimeColumn get takenAt => dateTime()();
  TextColumn get deviceId => text().nullable()();

  /// `pending`, `settled` or `refunded`.
  TextColumn get status => text().withDefault(const Constant('pending'))();

  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Every time the category prompt was shown, and what was pressed. §6.2.
///
/// **APPEND ONLY.** The declined-deposit report is the point: it tells the boss
/// what fairs are leaving on the table, and it only exists if a decline is
/// recorded as deliberately as a sale. A row is never updated — pressing a
/// different button later is a second row.
@DataClassName('DepositPromptRow')
class DepositPrompts extends Table {
  TextColumn get id => text()();
  TextColumn get quoteId => text()();
  TextColumn get category => text()();

  /// `collected`, `declined`, `lines_removed` or `dismissed`. Dismissed is kept
  /// distinct from declined: "they said no" and "nobody asked properly" are
  /// different problems, and only one of them is the customer's.
  TextColumn get choice => text()();

  /// What the quote was worth in this category when the question was asked, so
  /// the report can say what was left on the table rather than only how often.
  IntColumn get categorySubtotalSen =>
      integer().withDefault(const Constant(0))();

  TextColumn get byUserId => text().nullable()();
  DateTimeColumn get at => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Work waiting to reach the server. §9.2.
///
/// The whole of the push side is this table plus a drainer. Nothing is sent
/// synchronously and nothing blocks the UI on a network call: a quote is
/// finished, a row lands here, and it goes up whenever there is signal — which
/// at a fair might be that evening, in the car.
///
/// **Drained FIFO.** Order matters because a later row can depend on an earlier
/// one, and because a queue that reorders is a queue nobody can reason about
/// when it goes wrong.
///
/// The row's [entityId] is the quote's own client-generated UUID, which is what
/// makes the push idempotent: the server has seen that id or it has not. A
/// retry after a connection dropped mid-request is therefore free, and the
/// device never has to know whether the first attempt landed.
@DataClassName('OutboxRow')
class Outbox extends Table {
  TextColumn get id => text()();

  /// `quote` for now. Payments and photos join it in Phase 4.
  TextColumn get entityType => text()();

  /// The entity's client-generated id. The server is idempotent on it.
  TextColumn get entityId => text()();

  /// The whole request body, serialised at enqueue time.
  ///
  /// Frozen rather than rebuilt at send time on purpose: what goes up is what
  /// the customer was shown, not what the quote has since been edited into.
  TextColumn get payload => text()();

  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();

  /// Why the last attempt failed. For the diagnostics screen; never shown raw
  /// to a part-timer.
  TextColumn get lastError => text().nullable()();

  /// Set when a row has failed so many times that it is clearly not going to
  /// work. It stops being retried but is **never deleted** — it is somebody's
  /// order, and it needs looking at rather than losing.
  DateTimeColumn get parkedAt => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A part-timer's own floor-plan submission, waiting to be finished or
/// already queued. SPEC.md Phase 8 -- the offline sibling of the admin's
/// dashboard upload, so a floor plan a customer WhatsApped to a part-timer's
/// phone at a fair can become a submission with no signal in the room.
///
/// **Reference measurements are not site measurements.** Nothing built on
/// this table ever reaches a quote or an order directly; it is pushed
/// through the outbox to `POST /api/unit-type-submissions` (mirroring an
/// order push), lands at `pending_review` on the server, and stays invisible
/// to quoting until an admin approves it -- the same two-step gate every
/// other route into the library already enforces.
@DataClassName('LibrarySubmissionRow')
class LibrarySubmissions extends Table {
  /// Client-generated UUID v4. This becomes the unit type's own id on the
  /// server, the same way an order's client id becomes its own row there --
  /// the device must know its id before a connection exists to ask a server
  /// for one.
  TextColumn get id => text()();

  /// Chosen from the cached project list (`kLibraryProjectsCacheKey` in
  /// `Settings`) -- `Project.id` stays server-generated (see the server's
  /// own docstring for why), so a submission can only ever point at a
  /// project this handset has already seen with a connection in hand.
  TextColumn get projectId => text()();

  /// Denormalised for display once the cache has moved on or gone stale.
  TextColumn get projectName => text()();

  TextColumn get unitTypeName => text()();
  IntColumn get floorCount => integer().nullable()();

  /// Openings and rooms, as JSON. A list of small records with no query need
  /// of their own -- the same reasoning that keeps `QuoteLines.photoPath` a
  /// single field rather than a table only ever read as a whole.
  TextColumn get openingsJson => text().withDefault(const Constant('[]'))();
  TextColumn get roomsJson => text().withDefault(const Constant('[]'))();

  /// The local file path to the floor-plan photo, mirroring
  /// `QuoteLines.photoPath`. Null until one is attached.
  TextColumn get photoPath => text().nullable()();
  TextColumn get photoContentType => text().nullable()();

  /// Both null until calibrated, both present once they are -- the same
  /// pairing the server's `FloorPlanImageIn` enforces on the way in.
  IntColumn get pixelDistance => integer().nullable()();
  IntColumn get realDistanceTmm => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Set once this row has been handed to the outbox. A submission can be
  /// edited freely before this; after, a correction is a fresh submission --
  /// the same "never edit what is already queued" rule the outbox's own
  /// payload-freezing enforces everywhere else.
  DateTimeColumn get queuedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Quotes,
    QuoteLines,
    Orders,
    OrderLines,
    OrderEvents,
    Outbox,
    CategoryLocks,
    DepositPrompts,
    Payments,
    PriceOverrides,
    Settings,
    LibrarySubmissions,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'milan_quote'));

  /// Store timestamps as ISO-8601 text in UTC, not as unix seconds.
  ///
  /// Two reasons. SPEC.md §7 requires timestamps stored UTC and displayed
  /// Asia/Kuala_Lumpur, and unix-seconds columns carry no zone at all. And
  /// second precision is too coarse for `updated_at` — two lines added in the
  /// same second tie, and after a crash `latestQuote` could reopen the wrong
  /// draft.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  int get schemaVersion => 14;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      // Written as real migrations rather than a wipe, because by the time
      // these ship a part-timer may already have an unsynced quote on their
      // phone.
      //
      // v2: upgrade lines — a special track or motor charged on top of the
      //     curtain it belongs to (A16).
      // v3: the order-level delivery zone charge (§4.1).
      if (from < 2) {
        await m.addColumn(quoteLines, quoteLines.parentLineId);
      }
      if (from < 3) {
        await m.addColumn(quotes, quotes.deliveryZoneId);
      }
      // v4: a photo per window (§8.1).
      if (from < 4) {
        await m.addColumn(quoteLines, quoteLines.photoPath);
      }
      // v5: the outbox (§9.2). Created rather than backfilled — a quote taken
      // before sync existed was never destined for a server.
      if (from < 5) {
        await m.createTable(outbox);
      }
      // v6: rate locks and the category prompt log (§6.1, §6.2).
      if (from < 6) {
        await m.createTable(categoryLocks);
        await m.createTable(depositPrompts);
      }
      // v7: where a quote was taken, and handset preferences.
      //
      // Existing rows default to `showroom`, which is the conservative
      // direction: a quote taken before this column existed cannot be shown to
      // have opened a lock, and claiming it was a fair would grant one
      // retrospectively.
      if (from < 7) {
        await m.addColumn(quotes, quotes.channel);
        await m.createTable(settings);
      }
      // v8: money taken (§6.4).
      if (from < 8) {
        await m.createTable(payments);
      }
      // v9: confirmed orders, their lines and their event log (§6.3).
      if (from < 9) {
        await m.createTable(orders);
        await m.createTable(orderLines);
        await m.createTable(orderEvents);
      }
      // v10: the price override audit log (§6.5). Created rather than
      // backfilled: there is nothing to backfill, and an empty audit table is
      // the honest state of a handset that has never overridden anything.
      if (from < 10) {
        await m.createTable(priceOverrides);
      }
      // v11: what the tape priced (§11 Phase 6). Added beside the estimate
      // rather than over it -- §6.3 keeps both, so the variance report has
      // something to compare and a customer can be shown the two side by side.
      //
      // `addColumn`, not `createTable`: these land on a table that already has
      // rows on somebody's handset, and every existing line is correctly null
      // here because nothing has been measured yet.
      if (from < 11) {
        await m.addColumn(orderLines, orderLines.finalBilledQty);
        await m.addColumn(orderLines, orderLines.finalBilledUnit);
        await m.addColumn(orderLines, orderLines.finalRuleId);
        await m.addColumn(orderLines, orderLines.finalBandLabel);
        await m.addColumn(orderLines, orderLines.finalRateSen);
        await m.addColumn(orderLines, orderLines.finalLineTotalSen);
      }
      // v12: buyer details for an e-invoice (§10.3). Nullable and empty on
      // every existing row, which is the honest state: nobody was asked,
      // because until now there was nowhere to put the answer.
      if (from < 12) {
        await m.addColumn(orders, orders.buyerTin);
        await m.addColumn(orders, orders.buyerIdType);
        await m.addColumn(orders, orders.buyerIdNumber);
        await m.addColumn(orders, orders.buyerAddressLine1);
        await m.addColumn(orders, orders.buyerAddressLine2);
        await m.addColumn(orders, orders.buyerCity);
        await m.addColumn(orders, orders.buyerState);
        await m.addColumn(orders, orders.buyerPostcode);
        await m.addColumn(orders, orders.buyerMsicCode);
        await m.addColumn(orders, orders.einvoiceRequested);
      }
      // v13: where a line's dimensions actually came from (SPEC.md Phase 8's
      // Property/Project/Unit Library). Nullable/defaulted on every existing
      // row, which reads as `manual` -- the truth for every line ever typed
      // before this library existed.
      if (from < 13) {
        await m.addColumn(quoteLines, quoteLines.sourceProjectId);
        await m.addColumn(quoteLines, quoteLines.sourceUnitTypeId);
        await m.addColumn(quoteLines, quoteLines.sourceVersion);
        await m.addColumn(orderLines, orderLines.measurementSource);
        await m.addColumn(orderLines, orderLines.sourceProjectId);
        await m.addColumn(orderLines, orderLines.sourceUnitTypeId);
        await m.addColumn(orderLines, orderLines.sourceVersion);
      }
      // v14: a part-timer's own floor-plan submission (SPEC.md Phase 8's
      // last open item) -- created rather than backfilled, the same as the
      // outbox itself: a submission made before this table existed was never
      // destined for a server.
      if (from < 14) {
        await m.createTable(librarySubmissions);
      }
    },
    beforeOpen: (details) async {
      // Drift does not enable foreign keys by default, and without this a line
      // can outlive the quote it belongs to.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// The quote currently being worked on, if there is one.
  ///
  /// Phase 1 has no order concept yet, so a session has at most one draft.
  Future<QuoteRow?> latestQuote() =>
      (select(quotes)
            ..orderBy([(q) => OrderingTerm.desc(q.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<List<QuoteLineRow>> linesFor(String quoteId) =>
      (select(quoteLines)
            ..where((l) => l.quoteId.equals(quoteId))
            ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
          .get();

  /// Watches a quote's lines so the UI updates without polling.
  Stream<List<QuoteLineRow>> watchLines(String quoteId) =>
      (select(quoteLines)
            ..where((l) => l.quoteId.equals(quoteId))
            ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
          .watch();

  /// Adds a line and touches the quote's `updated_at` in **one** transaction.
  ///
  /// Both or neither. A line that lands while its quote's timestamp does not
  /// would make `latestQuote` pick the wrong draft after a crash.
  Future<void> addLine(QuoteLinesCompanion line, String quoteId) =>
      transaction(() async {
        await into(quoteLines).insert(line);
        await (update(quotes)..where((q) => q.id.equals(quoteId))).write(
          QuotesCompanion(updatedAt: Value(DateTime.now())),
        );
      });

  Future<QuoteLineRow?> lineById(String lineId) =>
      (select(quoteLines)..where((l) => l.id.equals(lineId))).getSingleOrNull();

  Future<void> deleteLine(String lineId) =>
      (delete(quoteLines)..where((l) => l.id.equals(lineId))).go();

  Future<void> clearAll() => transaction(() async {
    await delete(quoteLines).go();
    await delete(quotes).go();
    await delete(outbox).go();
  });

  /// The next rows to send, oldest first. §9.2 drains FIFO.
  ///
  /// Parked rows are skipped: one bad row must not stop every quote behind it
  /// from reaching the office.
  Future<List<OutboxRow>> pendingOutbox({int limit = 50}) =>
      (select(outbox)
            ..where((o) => o.parkedAt.isNull())
            ..orderBy([(o) => OrderingTerm.asc(o.createdAt)])
            ..limit(limit))
          .get();

  /// How many quotes are waiting to send, for the badge in the app bar.
  ///
  /// A one-shot count rather than a live stream. The depth only moves when
  /// this app enqueues or drains, and both are our own code paths, so watching
  /// buys nothing — while a live query holds a subscription for the life of the
  /// screen and leaves drift's teardown timer pending when the tree is
  /// unmounted, which every widget test then trips over.
  Future<int> outboxDepth() async {
    final count = outbox.id.count();
    final row =
        await (selectOnly(outbox)
              ..addColumns([count])
              ..where(outbox.parkedAt.isNull()))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> enqueueOutbox(OutboxCompanion row) =>
      into(outbox).insert(row, mode: InsertMode.insertOrReplace);

  /// Removes a row the server has confirmed, and stamps the quote as synced,
  /// in **one** transaction.
  ///
  /// Both or neither: a row deleted while the quote's `synced_at` stayed null
  /// would leave a quote that looks unsent and will never be sent again.
  /// Writes the receipt number the server issued onto a payment, and clears
  /// its outbox row, in **one** transaction.
  ///
  /// Both or neither. A payment marked settled with no number would show a
  /// blank where a customer expects one; a number written with the row left
  /// queued would be pushed again and, worse, is the state where a second
  /// number could be issued.
  Future<void> settlePayment({
    required String paymentId,
    required String receiptNo,
    required DateTime at,
  }) => transaction(() async {
    await (update(payments)..where((p) => p.id.equals(paymentId))).write(
      PaymentsCompanion(
        receiptNo: Value(receiptNo),
        status: const Value('settled'),
        syncedAt: Value(at),
      ),
    );
  });

  /// Writes back the order number the server issued.
  ///
  /// The same rule as a receipt number and for the same reason: two
  /// part-timers offline at one fair would invent the same
  /// `{branch}-{yymm}-{seq}`, and it goes on a document the customer takes
  /// away. Until this lands the screen shows "pending sync".
  Future<void> settleOrder({
    required String orderId,
    required String orderNo,
    required DateTime at,
  }) => (update(orders)..where((o) => o.id.equals(orderId))).write(
    OrdersCompanion(orderNo: Value(orderNo), syncedAt: Value(at)),
  );

  /// Stamps one order event as accepted by the server.
  ///
  /// Per event, not per order: an order walks the pipeline many times and each
  /// step syncs on its own, so a stamp on the order would say nothing about
  /// which moves the server has actually seen.
  Future<void> settleOrderEvent({
    required String eventId,
    required DateTime at,
  }) => (update(orderEvents)..where((e) => e.id.equals(eventId))).write(
    OrderEventsCompanion(syncedAt: Value(at)),
  );

  /// Marks a hold as reaching the server.
  ///
  /// Only a stamp: the hold itself does not change. What the server decides
  /// about a clash is reported on the response and handled by the drainer, not
  /// written over the row that recorded the money.
  Future<void> settleLock({required String lockId, required DateTime at}) =>
      (update(categoryLocks)..where((l) => l.id.equals(lockId))).write(
        CategoryLocksCompanion(syncedAt: Value(at)),
      );

  /// Marks one prompt answer as reaching the server.
  Future<void> settleDepositPrompt({
    required String promptId,
    required DateTime at,
  }) => (update(depositPrompts)..where((p) => p.id.equals(promptId))).write(
    DepositPromptsCompanion(syncedAt: Value(at)),
  );

  /// Removes an outbox row whose work is done and has no `synced_at` of its
  /// own to stamp.
  Future<void> dropOutbox(String outboxId) =>
      (delete(outbox)..where((o) => o.id.equals(outboxId))).go();

  Future<void> completeOutbox(String outboxId, String quoteId, DateTime at) =>
      transaction(() async {
        await (delete(outbox)..where((o) => o.id.equals(outboxId))).go();
        await (update(quotes)..where((q) => q.id.equals(quoteId))).write(
          QuotesCompanion(syncedAt: Value(at)),
        );
      });
}
