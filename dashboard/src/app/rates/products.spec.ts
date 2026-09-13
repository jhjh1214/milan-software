/**
 * Live per-product price editing. No whole-card upload, no preview step --
 * what matters here is that a price actually moves against the right
 * product, a mandatory reason travels with it, an unchecked MVP toggle
 * clears that rate explicitly (never by omission), and Save stays disabled
 * until the edit as typed would actually be accepted.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import type { ProductOut } from '../api/types';
import { Text } from '../i18n/text';
import { Products } from './products';

const product = (over: Partial<ProductOut> = {}): ProductOut => ({
  id: 'night-curtain-lo',
  family: 'curtain',
  variant: 'night_curtain',
  material_key: null,
  labels: { zh: '遮光窗帘', en: 'Night curtain', ms: 'Langsir malam' },
  basis: 'per_ft_width',
  rate_sen: 4600,
  mvp_rate_sen: 4000,
  provisional: false,
  ...over,
});

describe('Products', () => {
  let fixture: ComponentFixture<Products>;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    fixture = TestBed.createComponent(Products);
    http = TestBed.inject(HttpTestingController);
    TestBed.inject(Text).pick('en');
  });

  const load = (products: ProductOut[], version = 1): void => {
    fixture.detectChanges();
    http
      .expectOne('/api/rate-cards/fair/products')
      .flush({ list_id: 'fair', version, products });
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

  const type = (selector: string, value: string): void => {
    const input = el<HTMLInputElement>(selector);
    input.value = value;
    input.dispatchEvent(new Event('input'));
  };

  it('says so rather than showing a blank screen when there are none yet', () => {
    load([]);
    expect(text()).toContain('No products on this list yet.');
  });

  it('shows the product list in the reader’s language', () => {
    load([product()]);
    expect(text()).toContain('Night curtain');
    expect(text()).toContain('RM 46.00');
    expect(text()).toContain('RM 40.00');
  });

  it('flags a provisional row that has no real price yet', () => {
    load([product({ id: 'stair-step', provisional: true, mvp_rate_sen: null })]);
    expect(text()).toContain('No price yet');
  });

  it('switching list reloads the other one', () => {
    load([product()]);
    button('standard').click();
    http
      .expectOne('/api/rate-cards/standard/products')
      .flush({ list_id: 'standard', version: 101, products: [] });
    fixture.detectChanges();
    expect(text()).toContain('No products on this list yet.');
  });

  it('disables Save until something actually changes', () => {
    load([product()]);
    button('Edit price').click();
    fixture.detectChanges();

    type('#reason-night-curtain-lo', 'testing');
    fixture.detectChanges();

    expect(button('Save').disabled).toBe(true);
    expect(text()).toContain('That is already the price.');
  });

  it('disables Save until the reason is long enough', () => {
    load([product()]);
    button('Edit price').click();
    fixture.detectChanges();

    type('#rate-night-curtain-lo', '50.00');
    type('#reason-night-curtain-lo', 'ab');
    fixture.detectChanges();

    expect(button('Save').disabled).toBe(true);
    expect(text()).toContain('Say why');
  });

  it('editing a price posts the new rate and mandatory reason, and reloads live', () => {
    load([product()]);
    button('Edit price').click();
    fixture.detectChanges();

    type('#rate-night-curtain-lo', '50.00');
    type('#reason-night-curtain-lo', 'match a competitor at the fair');
    fixture.detectChanges();

    expect(button('Save').disabled).toBe(false);
    el('form.edit').dispatchEvent(new Event('submit'));

    const req = http.expectOne(
      '/api/rate-cards/fair/products/night-curtain-lo/price',
    );
    expect(req.request.body).toEqual({
      rate_sen: 5000,
      mvp_rate_sen: 4000,
      reason: 'match a competitor at the fair',
    });
    req.flush({
      rule_id: 'night-curtain-lo',
      list_id: 'fair',
      version: 102,
      rate_sen: 5000,
      mvp_rate_sen: 4000,
      edited_by: 'u1',
      at: '2026-09-14T00:00:00Z',
    });

    http
      .expectOne('/api/rate-cards/fair/products')
      .flush({ list_id: 'fair', version: 102, products: [product({ rate_sen: 5000 })] });
    fixture.detectChanges();

    expect(text()).toContain('Saved as version 102');
  });

  it('unchecking the MVP toggle clears it explicitly, never by omission', () => {
    load([product()]);
    button('Edit price').click();
    fixture.detectChanges();

    const hasMvp = el<HTMLInputElement>('#has-mvp-night-curtain-lo');
    hasMvp.checked = false;
    hasMvp.dispatchEvent(new Event('change'));
    type('#reason-night-curtain-lo', 'dropping the MVP tier on this line');
    fixture.detectChanges();

    el('form.edit').dispatchEvent(new Event('submit'));

    const req = http.expectOne(
      '/api/rate-cards/fair/products/night-curtain-lo/price',
    );
    expect(req.request.body).toEqual({
      rate_sen: 4600,
      mvp_rate_sen: null,
      reason: 'dropping the MVP tier on this line',
    });
    req.flush({
      rule_id: 'night-curtain-lo',
      list_id: 'fair',
      version: 102,
      rate_sen: 4600,
      mvp_rate_sen: null,
      edited_by: 'u1',
      at: '2026-09-14T00:00:00Z',
    });
    http
      .expectOne('/api/rate-cards/fair/products')
      .flush({ list_id: 'fair', version: 102, products: [product({ mvp_rate_sen: null })] });
  });

  it('a product moved under a concurrent publish is said in words, not a raw 404', () => {
    load([product()]);
    button('Edit price').click();
    fixture.detectChanges();
    type('#rate-night-curtain-lo', '50.00');
    type('#reason-night-curtain-lo', 'testing a stale row');
    fixture.detectChanges();

    el('form.edit').dispatchEvent(new Event('submit'));
    http
      .expectOne('/api/rate-cards/fair/products/night-curtain-lo/price')
      .flush({ detail: 'no such product' }, { status: 404, statusText: 'Not Found' });
    fixture.detectChanges();

    expect(text()).toContain('That product is no longer on this list.');
  });

  it('a role the server refuses is said in words, not a raw 403', () => {
    load([product()]);
    button('Edit price').click();
    fixture.detectChanges();
    type('#rate-night-curtain-lo', '50.00');
    type('#reason-night-curtain-lo', 'testing a refused role');
    fixture.detectChanges();

    el('form.edit').dispatchEvent(new Event('submit'));
    http
      .expectOne('/api/rate-cards/fair/products/night-curtain-lo/price')
      .flush({ detail: 'staff or admin only' }, { status: 403, statusText: 'Forbidden' });
    fixture.detectChanges();

    expect(text()).toContain('Only staff or an admin can change a price.');
  });

  it('a failed load can be retried', () => {
    fixture.detectChanges();
    http
      .expectOne('/api/rate-cards/fair/products')
      .flush({ detail: 'err' }, { status: 500, statusText: 'Server Error' });
    fixture.detectChanges();
    expect(text()).toContain('The server answered 500.');

    button('Reload').click();
    http
      .expectOne('/api/rate-cards/fair/products')
      .flush({ list_id: 'fair', version: 1, products: [] });
    fixture.detectChanges();

    expect(text()).toContain('No products on this list yet.');
  });
});
