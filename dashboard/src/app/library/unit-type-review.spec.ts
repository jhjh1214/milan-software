/**
 * The admin review queue. SPEC.md Phase 8.
 *
 * > A part-timer's submission is never searchable or quotable until an
 * > admin has approved it.
 *
 * What is tested is the gate itself: a submission's actual content is shown
 * (not just its name), approving or rejecting removes it from the queue, a
 * rejection cannot be sent with an empty reason, and a failure is said in
 * words rather than leaving the queue looking quiet.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import type { UnitTypeWithVersionsOut } from '../api/types';
import { Text } from '../i18n/text';
import { UnitTypeReview } from './unit-type-review';

const item = (
  over: Partial<UnitTypeWithVersionsOut> = {},
): UnitTypeWithVersionsOut => ({
  id: 'ut1',
  project_id: 'p1',
  project_name: 'ABC Development',
  name: 'Type B',
  floor_count: null,
  variant_of: null,
  status: 'pending_review',
  created_by_user_id: 'parttimer-1',
  created_at: '2026-09-08T09:00:00Z',
  updated_at: '2026-09-08T09:00:00Z',
  versions: [
    {
      id: 'v1',
      version: 1,
      approved_by_user_id: null,
      approved_at: null,
      rejected_by_user_id: null,
      rejected_at: null,
      rejection_reason: null,
      note: null,
      openings: [
        {
          id: 'o1',
          label: 'W1',
          room: 'Living',
          floor: null,
          nominal_w_tmm: 18000,
          nominal_h_tmm: 24000,
          sort_order: 0,
        },
      ],
      rooms: [
        {
          id: 'r1',
          name: 'Living',
          floor: null,
          nominal_area_mm2: 18_000_000,
          skirting_run_tmm: null,
        },
      ],
      floor_plan: null,
    },
  ],
  ...over,
});

describe('UnitTypeReview', () => {
  let fixture: ComponentFixture<UnitTypeReview>;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting(), provideRouter([])],
    });
    fixture = TestBed.createComponent(UnitTypeReview);
    http = TestBed.inject(HttpTestingController);
    // Pinned rather than assumed: the dashboard defaults to Chinese (§13 C9).
    TestBed.inject(Text).pick('en');
  });

  const load = (items: UnitTypeWithVersionsOut[]): void => {
    fixture.detectChanges();
    const req = http.expectOne(
      (r) => r.url === '/api/unit-types' && r.params.get('status') === 'pending_review',
    );
    req.flush({ unit_types: items });
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  const el = <T extends Element>(selector: string): T => {
    const found = fixture.nativeElement.querySelector(selector) as T | null;
    if (found === null) throw new Error(`no ${selector} on the screen`);
    return found;
  };

  const button = (label: string): HTMLButtonElement => {
    const found = Array.from(
      fixture.nativeElement.querySelectorAll('button'),
    ).find((b) => (b as HTMLButtonElement).textContent?.trim().includes(label));
    if (!found) throw new Error(`no button labelled "${label}"`);
    return found as HTMLButtonElement;
  };

  it('asks only for what is waiting on a decision', () => {
    fixture.detectChanges();
    const req = http.expectOne((r) => r.url === '/api/unit-types');
    expect(req.request.params.get('status')).toBe('pending_review');
    req.flush({ unit_types: [] });
  });

  it('says so rather than showing a blank queue when nothing is waiting', () => {
    load([]);
    expect(text()).toContain('Nothing waiting for review');
  });

  it('shows the actual submission, not just its name', () => {
    // The whole point of the screen: an admin has to see what was submitted
    // to review it, not rubber-stamp a name.
    load([item()]);
    expect(text()).toContain('ABC Development, Type B');
    expect(text()).toContain('1 opening');
    expect(text()).toContain('1 room');
    expect(text()).toContain('W1');
    expect(text()).toContain('Living');
    // 18000 tenths-of-mm = 5.9ft, 24000 tenths-of-mm = 7.9ft.
    expect(text()).toContain('5.9');
    expect(text()).toContain('7.9');
  });

  it('approving removes it from the queue and says so', () => {
    load([item()]);
    button('Approve').click();

    const req = http.expectOne('/api/unit-types/ut1/approve');
    expect(req.request.method).toBe('POST');
    req.flush({
      id: 'ut1',
      project_id: 'p1',
      project_name: 'ABC Development',
      name: 'Type B',
      floor_count: null,
      variant_of: null,
      status: 'approved',
      created_by_user_id: 'parttimer-1',
      created_at: '2026-09-08T09:00:00Z',
      updated_at: '2026-09-08T09:05:00Z',
    });
    fixture.detectChanges();

    // The note names the type, so the card itself gone — not the raw text
    // absent, which the note's own sentence would fail on purpose.
    expect(fixture.nativeElement.querySelectorAll('.card').length).toBe(0);
    expect(text()).toContain('now live in the library');
  });

  it('a reject cannot be sent with an empty reason', () => {
    load([item()]);
    button('Reject').click();
    fixture.detectChanges();

    expect(el<HTMLButtonElement>('.reject-form .btn-danger').disabled).toBe(true);

    el<HTMLTextAreaElement>('textarea').value = 'Window looks too wide';
    el<HTMLTextAreaElement>('textarea').dispatchEvent(new Event('input'));
    fixture.detectChanges();

    expect(el<HTMLButtonElement>('.reject-form .btn-danger').disabled).toBe(false);
  });

  it('rejecting sends the reason and removes it from the queue', () => {
    load([item()]);
    button('Reject').click();
    fixture.detectChanges();

    el<HTMLTextAreaElement>('textarea').value = 'Window looks too wide';
    el<HTMLTextAreaElement>('textarea').dispatchEvent(new Event('input'));
    fixture.detectChanges();

    button('Send back').click();
    const req = http.expectOne('/api/unit-types/ut1/reject');
    expect(req.request.body).toEqual({ reason: 'Window looks too wide' });
    req.flush({
      id: 'ut1',
      project_id: 'p1',
      project_name: 'ABC Development',
      name: 'Type B',
      floor_count: null,
      variant_of: null,
      status: 'draft',
      created_by_user_id: 'parttimer-1',
      created_at: '2026-09-08T09:00:00Z',
      updated_at: '2026-09-08T09:05:00Z',
    });
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelectorAll('.card').length).toBe(0);
    expect(text()).toContain('sent back for correction');
  });

  it('cancelling a reject closes the form without sending anything', () => {
    load([item()]);
    button('Reject').click();
    fixture.detectChanges();

    button('Cancel').click();
    fixture.detectChanges();

    expect(() => el('textarea')).toThrow();
    http.expectNone('/api/unit-types/ut1/reject');
  });

  it('a failure is said in words, with a way back', () => {
    fixture.detectChanges();
    http
      .expectOne((r) => r.url === '/api/unit-types')
      .flush({ detail: 'no' }, { status: 500, statusText: 'x' });
    fixture.detectChanges();

    expect(el('[role="alert"]')).toBeTruthy();

    button('Try again').click();
    http.expectOne((r) => r.url === '/api/unit-types').flush({ unit_types: [] });
  });
});
