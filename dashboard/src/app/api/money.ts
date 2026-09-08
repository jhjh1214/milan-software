/**
 * Money on the dashboard. SPEC.md §8.3, and CLAUDE.md's invariant.
 *
 * **Money is integer sen and `number` never holds ringgit.** RM46.00 is 4600.
 * The mobile app and the server both hold this line; the dashboard is the third
 * place it could be broken, and the way it would break is somebody dividing by
 * 100 to make a number look right on screen and then adding two of them.
 *
 * So there is exactly one function here that turns sen into text, and nothing
 * that turns sen into a fractional number. If a total is needed, add the sen.
 */

/**
 * `RM 1,234.50`. Always two decimals, always the prefix, thousands grouped.
 *
 * Negative amounts keep the sign after the prefix — `RM -52.00` — matching what
 * the handset prints, so a refund reads the same on both.
 */
export function formatSen(sen: number, options?: { symbol?: boolean }): string {
  const withSymbol = options?.symbol ?? true;
  const negative = sen < 0;
  const abs = Math.abs(sen);

  // Integer arithmetic throughout. `abs / 100` would introduce a float into the
  // one part of this file that exists to keep floats out.
  const ringgit = Math.trunc(abs / 100);
  const cents = abs % 100;

  const grouped = ringgit.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const body = `${grouped}.${cents.toString().padStart(2, '0')}`;
  const signed = negative ? `-${body}` : body;

  return withSymbol ? `RM ${signed}` : signed;
}

/** `12 Mar 2027`, the format SPEC.md §8.3 fixes for dates. */
export function formatDate(iso: string | null): string {
  if (iso === null) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';

  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return `${date.getDate()} ${months[date.getMonth()]} ${date.getFullYear()}`;
}

/**
 * Whole days from now until [iso], or null when there is no date.
 *
 * Negative when it has already passed. Counted on whole days rather than on
 * hours, so a hold does not change colour halfway through an afternoon.
 */
export function daysUntil(iso: string | null, now: Date = new Date()): number | null {
  if (iso === null) return null;
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return null;

  // Local calendar days, matching `formatDate` above — this office reads
  // "today" in Asia/Kuala_Lumpur, not UTC. Bucketing on the UTC calendar
  // instead moved every card's day count (and so its amber/red colour) by
  // one for the eight hours between midnight and 8am local, since KL is
  // UTC+8 and has already turned its page while UTC has not.
  const a = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
  const b = Date.UTC(then.getFullYear(), then.getMonth(), then.getDate());
  return Math.round((b - a) / 86_400_000);
}

/** How urgently a hold needs attention. SPEC.md §11 Phase 5: amber at 60, red at 30. */
export type Urgency = 'none' | 'soon' | 'urgent' | 'gone';

/**
 * Amber inside 60 days, red inside 30, and its own state once it has passed.
 *
 * "Gone" is separate from "urgent" on purpose. An expired hold is not a thing
 * to hurry — it is a customer who paid RM300 and got nothing, which is a
 * different conversation and should not sit in the same colour as one that can
 * still be saved.
 */
export function urgencyOf(heldUntil: string | null, now: Date = new Date()): Urgency {
  const days = daysUntil(heldUntil, now);
  if (days === null) return 'none';
  if (days < 0) return 'gone';
  if (days <= 30) return 'urgent';
  if (days <= 60) return 'soon';
  return 'none';
}
