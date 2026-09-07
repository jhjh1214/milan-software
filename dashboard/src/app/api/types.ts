/**
 * What the server sends. Mirrors `backend/app/api/schemas.py` field for field.
 *
 * Hand-written rather than generated, for now. SPEC.md §11 Phase 5 asks for a
 * typed client generated from OpenAPI, and that is the right end state — but a
 * generator wired up before there is a screen to use it is a build step nobody
 * has yet had a reason to trust. These are small, and the names are the same on
 * both sides, so a drift shows up as a compile error the moment a screen reads
 * a field the server stopped sending.
 *
 * Two conventions carry over from the rest of the system and must not be
 * softened here:
 *
 * - **Money is integer sen.** `estimateTotalSen` is 55200 for RM552.00. No
 *   number in this file is a currency amount in ringgit, and none is a float.
 * - **Lengths are tenths of a millimetre.** A field ending `Tmm` is never
 *   millimetres.
 */

/** One card on the order board. */
export interface OrderSummary {
  readonly id: string;

  /**
   * Issued by the server. Null until the handset that took the deposit has
   * synced — the board shows that as "pending sync" rather than as a blank,
   * because a blank reads as a bug.
   */
  readonly order_no: string | null;

  readonly status: OrderStatus;
  readonly channel: Channel;
  readonly customer_name: string | null;
  readonly customer_phone: string | null;

  /** Integer sen. */
  readonly estimate_total_sen: number;
  /** Integer sen. */
  readonly deposit_paid_sen: number;

  readonly has_unmeasured_lines: boolean;
  readonly confirmed_at: string;
  readonly line_count: number;

  /**
   * When this customer's soonest rate hold runs out, or null when they have
   * none. The board sorts by it and colours by how close it is: a hold that
   * expires unused is a customer who paid RM300 and got nothing.
   */
  readonly held_until: string | null;
}

export interface OrdersOut {
  readonly orders: readonly OrderSummary[];
  /** How many match the filter, not how many are on this page. */
  readonly total: number;
}

export interface OrderLineOut {
  readonly id: string;
  readonly sort_order: number;
  readonly room: string;
  readonly variant: string;
  readonly material_key: string | null;
  readonly layer: string;

  /** Tenths of a millimetre. */
  readonly est_width_tmm: number;
  readonly est_height_tmm: number | null;
  readonly final_width_tmm: number | null;
  readonly final_height_tmm: number | null;

  readonly is_site_measured: boolean;
  readonly quantity: number;

  /** The snapshot that keeps the number explainable a year later. */
  readonly applied_rule_id: string;
  readonly applied_band_label: string | null;
  readonly applied_rate_card_version: number;
  /** An exact rational as a string — `0`, `1/10`. Never parse this as a float. */
  readonly applied_discount_pct: string;

  readonly standard_rate_sen: number;
  readonly rate_sen: number;
  readonly billed_qty: string;
  readonly billed_unit: string;
  readonly line_total_sen: number;

  readonly material_deferred: boolean;
  /** Somebody moved this total by hand. Never cleared. */
  readonly is_overridden: boolean;
}

export interface OrderEventOut {
  readonly id: string;
  readonly event: string;
  readonly note: string | null;
  readonly by_user_id: string | null;
  readonly at: string;
}

export interface PriceOverrideOut {
  readonly id: string;
  readonly order_line_id: string;
  readonly order_id: string;
  readonly before_sen: number;
  readonly after_sen: number;
  readonly reason: string;
  readonly admin_user_id: string;
  readonly at: string;
}

/**
 * What is on file about the buyer, for the invoice. SPEC.md §10.3.
 *
 * What the server reports. The office writes through `BuyerDetailsIn`, which
 * is a different shape on purpose: this carries every field, that one carries
 * only what somebody changed.
 */
export interface BuyerOut {
  readonly name: string | null;
  readonly tin: string | null;
  readonly id_type: string | null;
  readonly id_number: string | null;
  readonly address_line1: string | null;
  readonly address_line2: string | null;
  readonly city: string | null;
  readonly state: string | null;
  readonly postcode: string | null;
  readonly msic_code: string | null;
  readonly einvoice_requested: boolean;
  /** Null when nobody has ever captured — which reads differently from
   *  "captured and came away with nothing", and has to. */
  readonly captured_at: string | null;
  /** From the same rule the handset shows, never computed here. Two answers
   *  would disagree about who still has to be telephoned. */
  readonly complete: boolean;
  readonly missing: readonly string[];
}

/**
 * A correction to what is on file about the buyer. SPEC.md §10.3, §13 C14.
 *
 * The same endpoint a handset pushes to, and it **merges**: a field this
 * payload does not carry keeps whatever the server holds. That is why every
 * field is optional and why the office sends only what somebody actually
 * changed — a measurer capturing a TIN at the house while the office types an
 * address at a desk must not lose either half.
 *
 * The three states are distinct and all three are used:
 *
 * | On the wire | Means |
 * |---|---|
 * | absent | leave whatever is stored |
 * | `""` | clear it — the server trims, so a space is not a value |
 * | a value | store it |
 *
 * The empty string is the answer to C14's complaint that a field cleared on a
 * handset stays on the server: the device has no way to send one, the office
 * does.
 */
export interface BuyerDetailsIn {
  readonly order_id: string;
  /**
   * When this was captured, ISO 8601.
   *
   * The server refuses a push older than the one it already stored, so this
   * is what decides a race between an office desk and a handset. It is this
   * browser's clock — the office is online and the skew is seconds, and the
   * failure it produces is a visible refusal rather than a silent overwrite.
   */
  readonly captured_at: string;
  readonly name?: string;
  readonly tin?: string;
  readonly id_type?: string;
  readonly id_number?: string;
  readonly address_line1?: string;
  readonly address_line2?: string;
  readonly city?: string;
  readonly state?: string;
  readonly postcode?: string;
  readonly msic_code?: string;
  readonly einvoice_requested?: boolean;
}

/** What the server did with a buyer push. */
export interface BuyerDetailsResult {
  readonly order_id: string;
  readonly complete: boolean;
  readonly missing: readonly string[];
  /**
   * Set when **nothing was written**, and it arrives with a 200.
   *
   * `stale` if a newer capture is already stored, `unknown_order` if the order
   * itself never reached the server. Both have to read as failures: a screen
   * that said "saved" here would be telling somebody a legal requirement was
   * met when it was not.
   */
  readonly refused_because: string | null;
}

export interface OrderDetailOut {
  readonly order: OrderSummary;
  readonly lines: readonly OrderLineOut[];
  readonly events: readonly OrderEventOut[];
  readonly overrides: readonly PriceOverrideOut[];
  readonly buyer: BuyerOut | null;
}

export interface OverridesOut {
  readonly overrides: readonly PriceOverrideOut[];
}

/** Where an order is. SPEC.md §6.3, and the same wire values the device uses. */
export type OrderStatus =
  | 'confirmed'
  | 'measurement_booked'
  | 'measured'
  | 'material_selected'
  | 'in_production'
  | 'ready'
  | 'installed'
  | 'closed'
  | 'cancelled';

/** Where an order came from. Every report segments by it. */
export type Channel =
  | 'showroom'
  | 'home_visit'
  | 'fair'
  | 'referral'
  | 'phone';

/**
 * The pipeline in order. `cancelled` is not on it: it is a branch off the side,
 * not a stage of the job.
 */
export const PIPELINE: readonly OrderStatus[] = [
  'confirmed',
  'measurement_booked',
  'measured',
  'material_selected',
  'in_production',
  'ready',
  'installed',
  'closed',
];

/** One rule whose price a publish would move. */
export interface RateChangeOut {
  readonly rule_id: string;
  readonly label: string;
  /** Integer sen. Null when the rule is being added or removed. */
  readonly old_rate_sen: number | null;
  readonly new_rate_sen: number | null;
  readonly old_mvp_rate_sen: number | null;
  readonly new_mvp_rate_sen: number | null;
  /**
   * What the standard rate moves by. Null for an added or removed rule —
   * "moved by RM46" is a sentence about a rule that existed before.
   */
  readonly delta_sen: number | null;
}

/** Everything a publish would do, before it does any of it. */
export interface CardDiffOut {
  readonly changed: readonly RateChangeOut[];
  readonly added: readonly RateChangeOut[];
  /**
   * A product that stops being quotable is at least as big a change as one
   * that gets dearer, and it is the one nobody notices.
   */
  readonly removed: readonly RateChangeOut[];
  /** Counted, not listed. A preview is only readable if it shows what moves. */
  readonly unchanged: number;
  /** True when publishing would create a version nobody can tell apart. */
  readonly is_empty: boolean;
  readonly total_delta_sen: number;
}

export interface PublishOut {
  readonly version: number;
  readonly list_id: string;
  readonly published_by: string | null;
}

export type ListId = 'fair' | 'standard';

/** What somebody may do. SPEC.md 3, least privileged first. */
export type Role = 'parttime' | 'staff' | 'admin';

/**
 * Somebody who uses the system.
 *
 * No PIN and no hash: nothing replayable leaves the server, and a hash is
 * still something to attack offline at leisure.
 */
export interface PersonOut {
  readonly id: string;
  readonly name: string;
  readonly phone: string | null;
  readonly email: string | null;
  readonly role: Role;
  readonly language: string;
  readonly is_active: boolean;
  readonly deactivated_at: string | null;
}

export interface PeopleOut {
  /** Leavers included. Hiding them loses the answer to "who used to have access". */
  readonly people: readonly PersonOut[];
}

export interface DeactivateOut {
  readonly person: PersonOut;
  /** How many live handsets that just signed out. */
  readonly sessions_revoked: number;
}

export interface AddPersonIn {
  readonly name: string;
  readonly phone: string;
  /** Sent once, never stored and never read back. */
  readonly pin: string;
  readonly role: Role;
}

/**
 * One order waiting for a site visit. SPEC.md §11 Phase 5.
 *
 * Counts, not rates. Repricing happens in Phase 6 at the held version, and
 * nothing on this screen should let somebody do it from here.
 */
export interface MeasurementJob {
  readonly order_id: string;
  readonly order_no: string | null;
  readonly status: OrderStatus;
  readonly channel: Channel;
  readonly line_count: number;
  /** Lines with no tape taken to them yet. The size of the visit. */
  readonly unmeasured_line_count: number;
  /** Decisions somebody has to make on site. SPEC.md §13 B7. */
  readonly material_pending_count: number;
  readonly estimate_total_sen: number;
  readonly confirmed_at: string;
  /** Null while the visit is still unbooked. Read from the order history. */
  readonly booked_at: string | null;
  readonly waiting_days: number;
}

/**
 * One trip. §11 Phase 5: *grouped by project so one trip covers several units*.
 *
 * There is no project library until Phase 8 and no address is captured
 * anywhere, so the grouping is the customer, keyed on the normalised phone
 * exactly as a rate lock is. §13 C10 asks what should really group a day.
 */
export interface MeasurementGroup {
  readonly key: string;
  readonly customer_name: string | null;
  readonly customer_phone: string | null;
  /** False when this is one order that had no phone to group on. */
  readonly grouped_by_phone: boolean;
  readonly jobs: readonly MeasurementJob[];
  readonly oldest_confirmed_at: string;
  readonly waiting_days: number;
  /** Zero is the trip nobody has called about yet. */
  readonly booked_count: number;
}

export interface MeasurementQueueOut {
  readonly groups: readonly MeasurementGroup[];
  /** Orders, not trips. "12 jobs across 9 trips" is the sentence people say. */
  readonly total_orders: number;
}

/** One salesperson's estimate against the tape. SPEC.md §6.3, §11 Phase 5. */
export interface SalespersonVariance {
  readonly user_id: string | null;
  readonly name: string | null;
  readonly orders_priced: number;
  readonly orders_awaiting_final: number;
  readonly estimate_total_sen: number;
  readonly final_total_sen: number;
  /** `final - estimate`. Negative is the expected direction. */
  readonly variance_sen: number;
  /**
   * Orders where the final came out **above** the estimate. §8.5 says that
   * cannot happen, so any number but zero is a broken promise, not a
   * statistic — never averaged into the variance beside it.
   */
  readonly orders_over_estimate: number;
}

export interface VarianceReport {
  readonly rows: readonly SalespersonVariance[];
  /** True while nothing anywhere has been finally priced. Phase 6 changes it. */
  readonly nothing_priced_yet: boolean;
}

/** What one fair did, keyed on the promo its orders pinned. */
export interface FairPerformance {
  readonly promo_code: string | null;
  readonly valid_from: string | null;
  readonly valid_to: string | null;
  readonly orders: number;
  readonly estimate_total_sen: number;
  readonly deposits_taken_sen: number;
  /** RM300s that opened a twelve-month hold. §6.1. */
  readonly locks_opened: number;
}

export interface FairReport {
  readonly fairs: readonly FairPerformance[];
}

/** One order with money still to come. Nothing here is overdue — §13 C11. */
export interface OutstandingBalance {
  readonly order_id: string;
  readonly order_no: string | null;
  readonly customer_name: string | null;
  readonly customer_phone: string | null;
  readonly status: OrderStatus;
  readonly confirmed_at: string;
  readonly days_since_deposit: number;
  readonly total_sen: number;
  readonly deposit_paid_sen: number;
  readonly balance_sen: number;
  /** True while the total is still the quotation — an upper bound, not a debt. */
  readonly is_estimate: boolean;
}

export interface AgeingBucket {
  readonly label: string;
  readonly orders: number;
  readonly balance_sen: number;
}

export interface BalancesReport {
  readonly balances: readonly OutstandingBalance[];
  readonly buckets: readonly AgeingBucket[];
  readonly total_balance_sen: number;
  /** How much of the total is still an estimate rather than a final price. */
  readonly estimated_balance_sen: number;
}

/** Which RM300 was asked for. SPEC.md §6.2. */
export type DepositCategory = 'curtain' | 'flooring' | 'wallpaper';

/**
 * Which button was pressed.
 *
 * `dismissed` is kept apart from `declined`: "they said no" and "nobody asked
 * properly" are different problems, and only one of them is the customer's.
 */
export type DepositChoice =
  | 'collected'
  | 'declined'
  | 'lines_removed'
  | 'dismissed';

export interface DepositPromptOut {
  readonly id: string;
  readonly quote_id: string;
  readonly category: DepositCategory;
  readonly choice: DepositChoice;
  /** What the quote was worth in this category when the question was asked. */
  readonly category_subtotal_sen: number;
  readonly at: string;
}

export interface DepositPromptsOut {
  readonly prompts: readonly DepositPromptOut[];
}
