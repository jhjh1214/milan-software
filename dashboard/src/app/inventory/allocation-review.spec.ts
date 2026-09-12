/**
 * Stock waiting on an admin's decision. SPEC.md Phase 9.
 *
 * Mirrors `unit-type-review.spec.ts`'s own checks: the actual queue is
 * shown, approving or rejecting removes it, and a reject cannot be sent
 * with an empty reason. What is unique here is the "no single lot covers
 * it" case, which must not let approval through without a lot chosen.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import type { AllocationOut, MaterialOut, StockLotOut } from '../api/types';
import { Text } from '../i18n/text';
import { AllocationReview } from './allocation-review';

const allocation = (over: Partial<AllocationOut> = {}): AllocationOut => ({
  id: 'a1',
  order_line_id: 'ol1',
  order_id: 'o1',
  material_id: 'm1',
  lot_id: 'lot1',
  qty: '6',
  status: 'proposed',
  proposed_at: '2026-09-13T09:00:00Z',
  decided_by_user_id: null,
  decided_at: null,
  decision_note: null,
  allocated_at: null,
  released_at: null,
  ...over,
});

const material = (over: Partial<MaterialOut> = {}): MaterialOut => ({
  id: 'm1',
  family: 'flooring',
  variant_compat: ['spc_4mm_1mm'],
  code: 'SPC-OAK-4MM',
  names: { zh: 'SPC地板', en: 'SPC flooring', ms: 'Lantai SPC' },
  uom: 'box',
  coverage_per_unit: '18',
  reorder_level: null,
  is_active: true,
  created_at: '2026-09-13T09:00:00Z',
  updated_at: '2026-09-13T09:00:00Z',
  ...over,
});

const lot = (over: Partial<StockLotOut> = {}): StockLotOut => ({
  id: 'lot1',
  material_id: 'm1',
  lot_ref: 'DYE-001',
  qty_on_hand: '20',
  location: null,
  received_at: '2026-09-13T09:00:00Z',
  cost_sen: null,
  ...over,
});

describe('AllocationReview', () => {
  let fixture: ComponentFixture<AllocationReview>;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    fixture = TestBed.createComponent(AllocationReview);
    http = TestBed.inject(HttpTestingController);
    TestBed.inject(Text).pick('en');
  });

  /** Loads the queue. Extra `expectOne`s for any per-item lot fetch (only
   * fired for a `lot_id === null` allocation) are flushed by the caller. */
  const load = (allocations: AllocationOut[]): void => {
    fixture.detectChanges();
    http
      .expectOne((r) => r.url === '/api/allocations')
      .flush({ allocations });
    http
      .expectOne((r) => r.url === '/api/materials')
      .flush({ materials: [material()] });
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  const button = (label: string): HTMLButtonElement => {
    const found = Array.from(
      fixture.nativeElement.querySelectorAll('button'),
    ).find((b) => (b as HTMLButtonElement).textContent?.trim().includes(label));
    if (!found) throw new Error(`no button labelled "${label}"`);
    return found as HTMLButtonElement;
  };

  it('says so rather than showing a blank screen when nothing is waiting', () => {
    load([]);
    expect(text()).toContain('Nothing waiting for review.');
  });

  it('shows the material name and quantity, not just an id', () => {
    load([allocation()]);
    expect(text()).toContain('SPC flooring');
    expect(text()).toContain('6');
    expect(text()).toContain('ol1');
  });

  it('approving with a lot already picked needs no extra input', () => {
    load([allocation()]);
    button('Approve').click();

    const req = http.expectOne('/api/allocations/a1/approve');
    expect(req.request.body).toEqual({ lot_id: null });
    req.flush(allocation({ status: 'approved' }));
    fixture.detectChanges();

    expect(text()).toContain('Approved -- stock has been allocated.');
  });

  it('a proposal with no lot chosen fetches lots and blocks approval until one is picked', () => {
    load([allocation({ lot_id: null, decision_note: 'no single lot covers it' })]);

    http.expectOne('/api/stock/lots?material_id=m1').flush({ lots: [lot()] });
    fixture.detectChanges();

    expect(text()).toContain('no single lot covers it');
    expect(button('Approve').disabled).toBe(true);

    const select = fixture.nativeElement.querySelector('select') as HTMLSelectElement;
    select.value = 'lot1';
    select.dispatchEvent(new Event('change'));
    fixture.detectChanges();

    expect(button('Approve').disabled).toBe(false);
    button('Approve').click();

    const req = http.expectOne('/api/allocations/a1/approve');
    expect(req.request.body).toEqual({ lot_id: 'lot1' });
  });

  it('rejecting requires a reason', () => {
    load([allocation()]);
    button('Reject').click();
    fixture.detectChanges();

    expect(button('Send back').disabled).toBe(true);

    const textarea = fixture.nativeElement.querySelector('textarea') as HTMLTextAreaElement;
    textarea.value = 'wrong material';
    textarea.dispatchEvent(new Event('input'));
    fixture.detectChanges();

    expect(button('Send back').disabled).toBe(false);
    button('Send back').click();

    const req = http.expectOne('/api/allocations/a1/reject');
    expect(req.request.body).toEqual({ reason: 'wrong material' });
    req.flush(allocation({ status: 'rejected' }));
    fixture.detectChanges();

    expect(text()).toContain('Sent back.');
  });

  it('cancelling a reject closes the form without sending anything', () => {
    load([allocation()]);
    button('Reject').click();
    fixture.detectChanges();
    button('Cancel').click();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('textarea')).toBeFalsy();
    http.expectNone('/api/allocations/a1/reject');
  });

  it('a failure is said in words, with a way back', () => {
    fixture.detectChanges();
    http.expectOne((r) => r.url === '/api/allocations').flush(
      { detail: 'nope' },
      { status: 500, statusText: 'Server Error' },
    );
    http.expectOne((r) => r.url === '/api/materials').flush({ materials: [] });
    fixture.detectChanges();

    expect(text()).toContain('The server answered 500');
    button('Reload').click();
    http.expectOne((r) => r.url === '/api/allocations').flush({ allocations: [] });
    http.expectOne((r) => r.url === '/api/materials').flush({ materials: [] });
  });
});
