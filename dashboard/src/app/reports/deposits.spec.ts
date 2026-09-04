/**
 * The declined-deposit summary. SPEC.md §6.2.
 *
 * > Log which button was pressed. The declined-deposit report tells the boss
 * > what fairs are leaving on the table.
 *
 * The two things that would quietly make it useless: folding a dismissal into
 * a refusal, which blames the customer for a conversation that never finished;
 * and a take rate of "0" where nobody answered at all, which libels a quiet
 * afternoon.
 */

import { describe, expect, it } from 'vitest';

import type { DepositPromptOut } from '../api/types';
import { CATEGORIES, summariseDeposits, takeRate } from './deposits';

const prompt = (over: Partial<DepositPromptOut> = {}): DepositPromptOut => ({
  id: 'p1',
  quote_id: 'q1',
  category: 'curtain',
  choice: 'declined',
  category_subtotal_sen: 55200,
  at: '2026-08-29T11:00:00Z',
  ...over,
});

describe('summariseDeposits', () => {
  it('counts each button separately', () => {
    const rows = summariseDeposits([
      prompt({ id: '1', choice: 'collected' }),
      prompt({ id: '2', choice: 'declined' }),
      prompt({ id: '3', choice: 'lines_removed' }),
      prompt({ id: '4', choice: 'dismissed' }),
    ]);

    const curtain = rows.find((r) => r.category === 'curtain')!;
    expect(curtain.asked).toBe(4);
    expect(curtain.collected).toBe(1);
    expect(curtain.declined).toBe(1);
    expect(curtain.linesRemoved).toBe(1);
    expect(curtain.dismissed).toBe(1);
  });

  it('never folds a dismissal into a refusal', () => {
    // "They said no" and "nobody asked properly" are different problems, and
    // only one of them is the customer's.
    const rows = summariseDeposits([
      prompt({ id: '1', choice: 'dismissed' }),
      prompt({ id: '2', choice: 'dismissed' }),
    ]);

    const curtain = rows.find((r) => r.category === 'curtain')!;
    expect(curtain.dismissed).toBe(2);
    expect(curtain.declined).toBe(0);
  });

  it('leaves on the table everything that was not deposited on', () => {
    // The point of the report. Not how often somebody said no — what the fair
    // quoted in that category and did not secure.
    const rows = summariseDeposits([
      prompt({ id: '1', choice: 'collected', category_subtotal_sen: 100000 }),
      prompt({ id: '2', choice: 'declined', category_subtotal_sen: 55200 }),
      prompt({ id: '3', choice: 'dismissed', category_subtotal_sen: 4499 }),
      prompt({ id: '4', choice: 'lines_removed', category_subtotal_sen: 301 }),
    ]);

    const curtain = rows.find((r) => r.category === 'curtain')!;
    expect(curtain.leftOnTheTableSen).toBe(60000);
  });

  it('keeps the categories apart', () => {
    const rows = summariseDeposits([
      prompt({ id: '1', category: 'curtain', choice: 'collected' }),
      prompt({ id: '2', category: 'flooring', choice: 'declined' }),
    ]);

    expect(rows.find((r) => r.category === 'curtain')!.collected).toBe(1);
    expect(rows.find((r) => r.category === 'flooring')!.collected).toBe(0);
    expect(rows.find((r) => r.category === 'flooring')!.declined).toBe(1);
  });

  it('shows every category even when nothing happened in it', () => {
    // A quiet month must not silently drop a row and make the report a
    // different shape from last month's.
    const rows = summariseDeposits([]);

    expect(rows.map((r) => r.category)).toEqual([...CATEGORIES]);
    expect(rows.every((r) => r.asked === 0)).toBe(true);
  });
});

describe('takeRate', () => {
  it('excludes dismissals from the denominator', () => {
    // Counting them would make a busy stall look like a bad one.
    const [row] = summariseDeposits([
      prompt({ id: '1', choice: 'collected' }),
      prompt({ id: '2', choice: 'declined' }),
      prompt({ id: '3', choice: 'dismissed' }),
    ]);

    expect(takeRate(row)).toEqual([1, 2]);
  });

  it('counts a removed line as an answer', () => {
    // The customer engaged and the lines came off. That is a real outcome, not
    // a conversation that never happened.
    const [row] = summariseDeposits([
      prompt({ id: '1', choice: 'collected' }),
      prompt({ id: '2', choice: 'lines_removed' }),
    ]);

    expect(takeRate(row)).toEqual([1, 2]);
  });

  it('is null when nobody answered, never zero', () => {
    // Nobody answering is not a take rate of zero, and showing it as one would
    // libel a quiet afternoon.
    const [row] = summariseDeposits([prompt({ id: '1', choice: 'dismissed' })]);

    expect(takeRate(row)).toBeNull();
  });
});
