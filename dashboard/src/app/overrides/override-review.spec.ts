/**
 * The weekly override review. SPEC.md §6.5.
 *
 * > without it the log is never read and the control does not exist
 *
 * So what is tested is the things that would quietly stop it being a control: a
 * week boundary that drops a row, a net total that hides a bad week, a reason
 * shortened into something less than what was typed, and a 403 that looks like
 * a quiet week rather than like a refusal.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import type { PriceOverrideOut } from '../api/types';
import { OverrideReview, weekStart } from './override-review';

const row = (over: Partial<PriceOverrideOut> = {}): PriceOverrideOut => ({
  id: 'ov1',
  order_line_id: 'l1',
  order_id: 'o1',
  before_sen: 55200,
  after_sen: 50000,
  reason: 'matched a competitor quote',
  admin_user_id: 'u-boss',
  at: '2026-08-27T11:00:00Z',
  ...over,
});

describe('weekStart', () => {
  it('is the Monday on or before the day', () => {
    // Monday because that is how the shop talks about a week. Getting this
    // wrong puts a row in two weeks or in neither.
    const monday = '2026-08-24T00:00:00.000Z';
    expect(weekStart(new Date('2026-08-24T09:00:00Z')).toISOString()).toBe(monday);
    expect(weekStart(new Date('2026-08-27T11:00:00Z')).toISOString()).toBe(monday);
    // Sunday belongs to the week that started six days earlier, not the one
    // about to start.
    expect(weekStart(new Date('2026-08-30T23:59:00Z')).toISOString()).toBe(monday);
    expect(weekStart(new Date('2026-08-31T00:00:00Z')).toISOString()).toBe(
      '2026-08-31T00:00:00.000Z',
    );
  });
});

describe('OverrideReview', () => {
  let fixture: ComponentFixture<OverrideReview>;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([]),
      ],
    });
    fixture = TestBed.createComponent(OverrideReview);
    http = TestBed.inject(HttpTestingController);
  });

  const load = (rows: PriceOverrideOut[]): void => {
    fixture.detectChanges();
    const req = http.expectOne((r) => r.url === '/api/overrides');
    req.flush({ overrides: rows });
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  it('asks for a half-open week', () => {
    // Inclusive at the start, exclusive at the end, so one row lands in
    // exactly one week rather than in two or in neither.
    fixture.detectChanges();
    const req = http.expectOne((r) => r.url === '/api/overrides');

    const start = new Date(req.request.params.get('start')!);
    const end = new Date(req.request.params.get('end')!);
    expect(end.getTime() - start.getTime()).toBe(7 * 86_400_000);
    expect(start.getUTCDay()).toBe(1);

    req.flush({ overrides: [] });
  });

  it('shows who, how much, and why', () => {
    // The three questions the log exists to answer. Anything missing makes a
    // row unusable for the conversation it is meant to start.
    load([row()]);
    expect(text()).toContain('u-boss');
    expect(text()).toContain('RM 552.00');
    expect(text()).toContain('RM 500.00');
    expect(text()).toContain('matched a competitor quote');
  });

  it('shows the reason as typed, not shortened', () => {
    const long =
      'customer had a written quote from the shop across the road and would ' +
      'have walked, boss approved matching it';
    load([row({ reason: long })]);
    expect(text()).toContain(long);
  });

  it('totals the week before any single row is read', () => {
    // A week full of individually reasonable-looking changes can still add up
    // to something nobody decided.
    load([
      row({ id: 'a', before_sen: 55200, after_sen: 50000 }),
      row({ id: 'b', before_sen: 100000, after_sen: 90000 }),
      row({ id: 'c', before_sen: 20000, after_sen: 22000 }),
    ]);

    expect(text()).toContain('3 changes');
    // -5200 - 10000 + 2000
    expect(text()).toContain('RM -132.00');
  });

  it('a quiet week says so in words', () => {
    // An empty table reads as "failed to load", and this screen has to be
    // trustworthy about a week in which nobody changed anything.
    load([]);
    expect(text()).toContain('Nobody changed a price this week');
  });

  it('a refusal is not shown as a quiet week', () => {
    // §6.5 makes this admin-only on the server. Rendering a 403 as an empty
    // table would tell a non-admin that nothing happened, which is worse than
    // telling them nothing.
    fixture.detectChanges();
    http
      .expectOne((r) => r.url === '/api/overrides')
      .flush({ detail: 'no' }, { status: 403, statusText: 'Forbidden' });
    fixture.detectChanges();

    expect(text()).toContain('Only an admin can see the override log');
    expect(text()).not.toContain('Nobody changed a price');
  });

  it('a failed load offers a way back', () => {
    fixture.detectChanges();
    http
      .expectOne((r) => r.url === '/api/overrides')
      .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });
    fixture.detectChanges();

    expect(text()).toContain('The server answered 500');
    expect(text()).toContain('Try again');
  });
});
