/**
 * The same answers `lock_grant_cases` in shared/pricing-fixtures.json gives,
 * so the date an admin is shown is the date a handset will actually grant.
 */

import { describe, expect, it } from 'vitest';

import { holdEndsOn } from './hold-ends';

describe('holdEndsOn', () => {
  it('counts from the day after the fair ends, the anniversary inclusive', () => {
    expect(holdEndsOn('2026-08-31')).toBe('2027-09-01');
  });

  it('rolls into the next year from New Year’s Eve', () => {
    expect(holdEndsOn('2026-12-31')).toBe('2028-01-01');
  });

  it('clamps a 29 February start to the 28th', () => {
    expect(holdEndsOn('2028-02-28')).toBe('2029-02-28');
  });

  it('leaves a 28 February start alone', () => {
    expect(holdEndsOn('2028-02-27')).toBe('2029-02-28');
    expect(holdEndsOn('2027-02-27')).toBe('2028-02-28');
  });

  it('keeps a month end that exists next year', () => {
    expect(holdEndsOn('2026-08-30')).toBe('2027-08-31');
  });

  it('refuses anything that is not a real date', () => {
    expect(holdEndsOn('')).toBeNull();
    expect(holdEndsOn('2026-02-30')).toBeNull();
    expect(holdEndsOn('31/08/2026')).toBeNull();
  });
});
