/**
 * Materials, lots and the ledger. SPEC.md Phase 9.
 *
 * What matters here: a material can be added and deactivated, receiving
 * stock shows up against the right material, and the reorder-alert badge
 * reads "available" (already fetched from the server) rather than
 * something this screen invents.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import type { MaterialOut, ReorderAlertOut, StockLotOut } from '../api/types';
import { Text } from '../i18n/text';
import { Materials } from './materials';

const material = (over: Partial<MaterialOut> = {}): MaterialOut => ({
  id: 'm1',
  family: 'flooring',
  variant_compat: ['spc_4mm_1mm'],
  code: 'SPC-OAK-4MM',
  names: { zh: 'SPC地板', en: 'SPC flooring', ms: 'Lantai SPC' },
  uom: 'box',
  coverage_per_unit: '18',
  reorder_level: '10',
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
  cost_sen: 1200,
  ...over,
});

describe('Materials', () => {
  let fixture: ComponentFixture<Materials>;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    fixture = TestBed.createComponent(Materials);
    http = TestBed.inject(HttpTestingController);
    TestBed.inject(Text).pick('en');
  });

  const load = (
    materials: MaterialOut[],
    alerts: ReorderAlertOut[] = [],
  ): void => {
    fixture.detectChanges();
    http
      .expectOne((r) => r.url === '/api/materials')
      .flush({ materials });
    http.expectOne('/api/inventory/alerts').flush({ alerts });
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

  it('says so rather than showing a blank screen when there are none yet', () => {
    load([]);
    expect(text()).toContain('No materials yet.');
  });

  it('shows the material list', () => {
    load([material()]);
    expect(text()).toContain('SPC-OAK-4MM');
    expect(text()).toContain('flooring');
  });

  it('flags a material below its reorder level, using the server figure', () => {
    load(
      [material()],
      [
        {
          material: material(),
          on_hand: '12',
          committed: '5',
          available: '7',
          reorder_level: '10',
        },
      ],
    );
    expect(text()).toContain('7');
    expect(text()).toContain('Below reorder level');
  });

  it('adding a material posts the form and reloads the list', () => {
    load([]);
    button('Add a material').click();
    fixture.detectChanges();

    el<HTMLInputElement>('#family').value = 'flooring';
    el<HTMLInputElement>('#family').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#code').value = 'SPC-NEW';
    el<HTMLInputElement>('#code').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#name-zh').value = '新地板';
    el<HTMLInputElement>('#name-zh').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#name-en').value = 'New flooring';
    el<HTMLInputElement>('#name-en').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#name-ms').value = 'Lantai baharu';
    el<HTMLInputElement>('#name-ms').dispatchEvent(new Event('input'));
    fixture.detectChanges();

    el('form.add').dispatchEvent(new Event('submit'));

    const req = http.expectOne('/api/materials');
    expect(req.request.body.code).toBe('SPC-NEW');
    req.flush(material({ id: 'm2', code: 'SPC-NEW' }));

    http.expectOne((r) => r.url === '/api/materials').flush({ materials: [] });
    http.expectOne('/api/inventory/alerts').flush({ alerts: [] });
    fixture.detectChanges();
  });

  it('a duplicate code is said in words, not a raw 409', () => {
    load([]);
    button('Add a material').click();
    fixture.detectChanges();
    el<HTMLInputElement>('#family').value = 'flooring';
    el<HTMLInputElement>('#family').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#code').value = 'SPC-OAK-4MM';
    el<HTMLInputElement>('#code').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#name-zh').value = 'a';
    el<HTMLInputElement>('#name-zh').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#name-en').value = 'b';
    el<HTMLInputElement>('#name-en').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#name-ms').value = 'c';
    el<HTMLInputElement>('#name-ms').dispatchEvent(new Event('input'));
    fixture.detectChanges();

    el('form.add').dispatchEvent(new Event('submit'));
    http
      .expectOne('/api/materials')
      .flush({ detail: 'nope' }, { status: 409, statusText: 'Conflict' });
    fixture.detectChanges();

    expect(text()).toContain('That material code is already in use.');
  });

  it('deactivating removes it from the list on reload', () => {
    load([material()]);
    button('Deactivate').click();

    http
      .expectOne('/api/materials/m1/deactivate')
      .flush(material({ is_active: false }));
    http.expectOne((r) => r.url === '/api/materials').flush({ materials: [] });
    http.expectOne('/api/inventory/alerts').flush({ alerts: [] });
    fixture.detectChanges();

    expect(text()).toContain('No materials yet.');
  });

  it('expanding a material fetches and shows its lots', () => {
    load([material()]);
    button('Receive stock').click();

    http.expectOne('/api/stock/lots?material_id=m1').flush({ lots: [lot()] });
    fixture.detectChanges();

    expect(text()).toContain('DYE-001');
    expect(text()).toContain('20');
  });

  it('receiving stock posts against the right material and refreshes', () => {
    load([material()]);
    button('Receive stock').click();
    http.expectOne('/api/stock/lots?material_id=m1').flush({ lots: [] });
    fixture.detectChanges();

    el<HTMLInputElement>('#lot-ref-m1').value = 'DYE-002';
    el<HTMLInputElement>('#lot-ref-m1').dispatchEvent(new Event('input'));
    el<HTMLInputElement>('#qty-m1').value = '15';
    el<HTMLInputElement>('#qty-m1').dispatchEvent(new Event('input'));
    fixture.detectChanges();

    el('form.receive').dispatchEvent(new Event('submit'));

    const req = http.expectOne('/api/stock/receive');
    expect(req.request.body).toEqual(
      expect.objectContaining({ material_id: 'm1', lot_ref: 'DYE-002', qty: '15' }),
    );
    req.flush(lot({ lot_ref: 'DYE-002', qty_on_hand: '15' }));

    http.expectOne('/api/stock/lots?material_id=m1').flush({ lots: [] });
    http.expectOne((r) => r.url === '/api/materials').flush({ materials: [material()] });
    http.expectOne('/api/inventory/alerts').flush({ alerts: [] });
  });
});
