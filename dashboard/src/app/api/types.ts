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

export interface OrderDetailOut {
  readonly order: OrderSummary;
  readonly lines: readonly OrderLineOut[];
  readonly events: readonly OrderEventOut[];
  readonly overrides: readonly PriceOverrideOut[];
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
