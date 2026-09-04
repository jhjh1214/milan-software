/**
 * The declined-deposit summary. SPEC.md §6.2, §11 Phase 4 and 5.
 *
 * > Log which button was pressed. The declined-deposit report tells the boss
 * > what fairs are leaving on the table.
 *
 * The server returns the prompt rows raw and this counts them, mirroring
 * `summariseDeposits` in the handset's `pricing/deposit_prompt.dart`. That is a
 * second implementation on purpose: the two summarise different data — the
 * handset counts what happened on that phone, the office counts what every
 * phone sent up — and folding them into one server-side aggregate would fix the
 * slicing at whichever the first caller wanted.
 *
 * **The point is not the count.** It is `leftOnTheTableSen`: what a fair quoted
 * in a category and did not take a deposit on, which is the number that says
 * whether the prompt is worth having at all.
 *
 * Pure. No clock, no HTTP. The period is chosen by the caller.
 */

import type { DepositCategory, DepositChoice, DepositPromptOut } from '../api/types';

/**
 * Every category the prompt can be shown for, in a fixed order.
 *
 * Fixed so a quiet month does not silently drop a row and make the report a
 * different shape from last month's.
 */
export const CATEGORIES: readonly DepositCategory[] = [
  'curtain',
  'flooring',
  'wallpaper',
];

export interface CategoryDeclines {
  readonly category: DepositCategory;
  /** Every time the question was put. */
  readonly asked: number;
  readonly collected: number;
  /** They said no. */
  readonly declined: number;
  /**
   * Nobody got an answer. Kept apart from `declined` on purpose: "they said no"
   * and "nobody asked properly" are different problems, and only one of them is
   * the customer's.
   */
  readonly dismissed: number;
  /** The lines came back off the quote — a lost line more than a lost deposit. */
  readonly linesRemoved: number;
  /** What was quoted in this category and not deposited on. Integer sen. */
  readonly leftOnTheTableSen: number;
}

/**
 * Of the times the question was actually answered, how often with money.
 *
 * Returned as a numerator over a denominator rather than a percentage.
 * Dismissals are excluded from the denominator: counting them would blame the
 * customer for a conversation that never finished, and make a busy stall look
 * like a bad one.
 *
 * Null when nobody answered — which is not the same as a take rate of zero, and
 * showing it as zero would libel a quiet afternoon.
 */
export function takeRate(row: CategoryDeclines): [number, number] | null {
  const answered = row.collected + row.declined + row.linesRemoved;
  return answered === 0 ? null : [row.collected, answered];
}

/** Groups prompt rows by category. Every category present, even at zero. */
export function summariseDeposits(
  prompts: readonly DepositPromptOut[],
): readonly CategoryDeclines[] {
  return CATEGORIES.map((category) => {
    const rows = prompts.filter((p) => p.category === category);
    const count = (choice: DepositChoice): number =>
      rows.filter((r) => r.choice === choice).length;

    return {
      category,
      asked: rows.length,
      collected: count('collected'),
      declined: count('declined'),
      dismissed: count('dismissed'),
      linesRemoved: count('lines_removed'),
      // Summed in integer sen, never through a fractional ringgit.
      leftOnTheTableSen: rows
        .filter((r) => r.choice !== 'collected')
        .reduce((sum, r) => sum + r.category_subtotal_sen, 0),
    };
  });
}
