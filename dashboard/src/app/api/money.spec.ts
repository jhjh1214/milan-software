/**
 * Money and dates on the dashboard. SPEC.md §8.3, and CLAUDE.md's invariant.
 *
 * This is the third place in the system that formats currency, and the way it
 * would break is somebody dividing by 100 to make a number look right. So what
 * is checked here is that integer sen go in and text comes out, with nothing
 * fractional in between.
 *
 * The urgency thresholds get the same attention as the money. §11 Phase 5 fixes
 * amber at 60 days and red at 30, and an off-by-one there is a hold that shows
 * as comfortable on the day it stops being comfortable.
 */

import { describe, expect, it } from 'vitest';

import { daysUntil, formatDate, formatSen, urgencyOf } from './money';

describe('formatSen', () => {
  it('always shows two decimals and the prefix', () => {
    expect(formatSen(0)).toBe('RM 0.00');
    expect(formatSen(5)).toBe('RM 0.05');
    expect(formatSen(900)).toBe('RM 9.00');
    expect(formatSen(4600)).toBe('RM 46.00');
    expect(formatSen(55200)).toBe('RM 552.00');
  });

  it('groups thousands', () => {
    expect(formatSen(123450)).toBe('RM 1,234.50');
    expect(formatSen(100000000)).toBe('RM 1,000,000.00');
  });

  it('keeps a negative sign after the prefix, the way the handset prints it', () => {
    // A refund has to read the same on the dashboard as on the receipt.
    expect(formatSen(-5200)).toBe('RM -52.00');
    expect(formatSen(-5)).toBe('RM -0.05');
  });

  it('can drop the symbol for a table column', () => {
    expect(formatSen(55200, { symbol: false })).toBe('552.00');
  });

  it('never loses a sen to floating point', () => {
    // 0.1 + 0.2 is why money is integer sen everywhere in this system. If this
    // function ever divides, one of these stops being exact.
    for (const sen of [1, 7, 99, 101, 1999, 123456789]) {
      const text = formatSen(sen, { symbol: false });
      const backToSen = Math.round(Number(text.replace(/,/g, '')) * 100);
      expect(backToSen).toBe(sen);
    }
  });
});

describe('formatDate', () => {
  it('is 12 Mar 2027, per §8.3', () => {
    expect(formatDate('2027-03-12T00:00:00Z')).toBe('12 Mar 2027');
    expect(formatDate('2026-08-29T14:00:00Z')).toBe('29 Aug 2026');
  });

  it('is empty rather than "Invalid Date" when there is nothing', () => {
    // A board full of "Invalid Date" is worse than a board with a gap.
    expect(formatDate(null)).toBe('');
    expect(formatDate('not a date')).toBe('');
  });
});

describe('daysUntil', () => {
  const now = new Date('2026-09-04T10:00:00Z');

  it('counts whole days, so a hold does not change colour at lunchtime', () => {
    expect(daysUntil('2026-09-04T23:59:00Z', now)).toBe(0);
    expect(daysUntil('2026-09-05T01:00:00Z', now)).toBe(1);
    expect(daysUntil('2026-10-04T00:00:00Z', now)).toBe(30);
  });

  it('goes negative once it has passed', () => {
    expect(daysUntil('2026-09-03T23:00:00Z', now)).toBe(-1);
  });

  it('is null when there is no date', () => {
    expect(daysUntil(null, now)).toBeNull();
  });
});

describe('urgencyOf', () => {
  const now = new Date('2026-09-04T10:00:00Z');

  const inDays = (n: number): string => {
    const d = new Date(now);
    d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString();
  };

  it('is amber inside 60 days and red inside 30, at the edges', () => {
    // §11 Phase 5 fixes these. An off-by-one shows a hold as comfortable on
    // the day it stops being comfortable.
    expect(urgencyOf(inDays(61), now)).toBe('none');
    expect(urgencyOf(inDays(60), now)).toBe('soon');
    expect(urgencyOf(inDays(31), now)).toBe('soon');
    expect(urgencyOf(inDays(30), now)).toBe('urgent');
    expect(urgencyOf(inDays(1), now)).toBe('urgent');
    expect(urgencyOf(inDays(0), now)).toBe('urgent');
  });

  it('has its own state once the hold has gone', () => {
    // Not the same as urgent. An expired hold is not a thing to hurry, it is a
    // customer who paid RM300 and got nothing — a different conversation, and
    // it should not sit in the same colour as one that can still be saved.
    expect(urgencyOf(inDays(-1), now)).toBe('gone');
    expect(urgencyOf(inDays(-400), now)).toBe('gone');
  });

  it('is nothing at all when there is no hold', () => {
    expect(urgencyOf(null, now)).toBe('none');
  });
});
