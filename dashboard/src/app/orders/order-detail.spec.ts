/**
 * One order on the dashboard. SPEC.md §6.3, §6.5.
 *
 * The two derived lines are what is worth testing. `size()` turns tenths of a
 * millimetre into feet for the screen — a display accessor, the same rule
 * `Length.mm` has on the handset — and a wrong divisor there is a dimension
 * that looks plausible and is not. `basis()` is the sentence somebody reads out
 * on the phone when a customer asks why a line cost what it did, so every part
 * of the snapshot has to be in it.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import type { BuyerOut, OrderDetailOut, OrderLineOut } from '../api/types';
import { OrderDetail } from './order-detail';

const line = (over: Partial<OrderLineOut> = {}): OrderLineOut => ({
  id: 'l1',
  sort_order: 0,
  room: 'Living room',
  variant: 'night_curtain_sfold',
  material_key: null,
  layer: 'night',
  est_width_tmm: 36576, // exactly 12ft
  est_height_tmm: 27432, // exactly 9ft
  final_width_tmm: null,
  final_height_tmm: null,
  is_site_measured: false,
  quantity: 1,
  applied_rule_id: 'night-curtain-lo',
  applied_band_label: 'up to 10ft',
  applied_rate_card_version: 1,
  applied_discount_pct: '0',
  standard_rate_sen: 4600,
  rate_sen: 4600,
  billed_qty: '12',
  billed_unit: 'ft',
  line_total_sen: 55200,
  material_deferred: false,
  is_overridden: false,
  ...over,
});

const detail = (over: Partial<OrderDetailOut> = {}): OrderDetailOut => ({
  order: {
    id: 'o1',
    order_no: 'MLK-2608-0001',
    status: 'confirmed',
    channel: 'fair',
    customer_name: 'Ah Lian',
    customer_phone: '0123456789',
    estimate_total_sen: 55200,
    deposit_paid_sen: 30000,
    has_unmeasured_lines: true,
    confirmed_at: '2026-08-29T14:00:00Z',
    line_count: 1,
    held_until: null,
  },
  lines: [line()],
  events: [],
  overrides: [],
  buyer: null,
  ...over,
});

describe('OrderDetail', () => {
  let fixture: ComponentFixture<OrderDetail>;
  let component: OrderDetail;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([]),
      ],
    });
    fixture = TestBed.createComponent(OrderDetail);
    fixture.componentRef.setInput('id', 'o1');
    component = fixture.componentInstance;
    http = TestBed.inject(HttpTestingController);
  });

  const load = async (d: OrderDetailOut = detail()): Promise<void> => {
    fixture.detectChanges();
    await Promise.resolve();
    http.expectOne('/api/orders/o1').flush(d);
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  it('shows the order, its lines and its history', async () => {
    await load(
      detail({
        events: [
          {
            id: 'e1',
            event: 'confirmed',
            note: 'Deposit RM 300.00',
            by_user_id: 'u1',
            at: '2026-08-29T14:00:00Z',
          },
        ],
      }),
    );

    expect(text()).toContain('MLK-2608-0001');
    expect(text()).toContain('Ah Lian');
    expect(text()).toContain('RM 552.00');
    expect(text()).toContain('RM 300.00');
    expect(text()).toContain('Living room');
    expect(text()).toContain('confirmed');
  });

  it('says the estimate can only fall, never rise', async () => {
    // §8.5 is binding, and it is the promise the whole quote-then-measure
    // asymmetry exists to keep.
    await load();
    expect(text()).toContain('same or lower, never higher');
  });

  it('shows no balance owing', async () => {
    // Client, Sep 2026: the deposit buys a held rate, not a part-paid bill. A
    // balance worked out from an estimate is a number the customer remembers
    // and the tape contradicts.
    await load();
    expect(text().toLowerCase()).not.toContain('balance');
    expect(text().toLowerCase()).not.toContain('owing');
  });

  it('says "pending sync" rather than showing a blank number', async () => {
    const d = detail();
    await load({ ...d, order: { ...d.order, order_no: null } });
    expect(text()).toContain('pending sync');
  });

  describe('the size line', () => {
    it('turns tenths of a millimetre into feet', async () => {
      // 36576 tmm is exactly 12ft, 27432 exactly 9ft. A wrong divisor here is
      // a dimension that looks plausible and is not.
      await load();
      expect(component['size'](line())).toBe('12.0 × 9.0ft (estimate)');
    });

    it('shows a width-only line without a phantom height', async () => {
      await load();
      expect(component['size'](line({ est_height_tmm: null }))).toBe(
        '12.0ft (estimate)',
      );
    });

    it('shows the estimate beside what was measured', async () => {
      // §6.3 keeps both for good, so the variance report can say who is
      // guessing badly. The screen shows both for the same reason.
      await load();
      const measured = line({
        is_site_measured: true,
        final_width_tmm: 35052, // 11.5ft
        final_height_tmm: 27432,
      });
      expect(component['size'](measured)).toBe(
        '12.0 × 9.0ft → 11.5 × 9.0ft measured',
      );
    });
  });

  describe('the pricing basis', () => {
    it('carries everything needed to answer "why did this cost that"', async () => {
      await load();
      const basis = component['basis'](line());
      expect(basis).toContain('12 ft');
      expect(basis).toContain('RM 46.00');
      expect(basis).toContain('up to 10ft');
      expect(basis).toContain('list v1');
    });

    it('names a held discount, and stays quiet when there is none', async () => {
      await load();
      expect(component['basis'](line())).not.toContain('held');
      expect(
        component['basis'](line({ applied_discount_pct: '1/10' })),
      ).toContain('held 1/10 off');
    });

    it('never turns the discount into a float', async () => {
      // An exact rational as a string, the same on all three sides. Parsing it
      // would put a float into the one number that is a percentage of money.
      await load();
      expect(component['basis'](line({ applied_discount_pct: '1/3' }))).toContain(
        '1/3',
      );
    });
  });

  it('flags a line whose price was moved by hand', async () => {
    // §6.5: the marker is visible on screen and on the printed quote, and is
    // never cleared.
    await load(detail({ lines: [line({ is_overridden: true })] }));
    expect(text()).toContain('Price changed by hand');
  });

  it('flags a material still to be chosen, and says it was quoted dear', async () => {
    // §13 B7. The line says so on its face, and the drop when the customer
    // picks the cheaper option is the promise being kept, not a discount.
    await load(detail({ lines: [line({ material_deferred: true })] }));
    expect(text()).toContain('Material still to choose');
    expect(text()).toContain('dearest');
  });

  it('shows an override audit row with who, how much, and why', async () => {
    await load(
      detail({
        overrides: [
          {
            id: 'ov1',
            order_line_id: 'l1',
            order_id: 'o1',
            before_sen: 55200,
            after_sen: 50000,
            reason: 'matched a competitor quote',
            admin_user_id: 'u-boss',
            at: '2026-08-29T15:00:00Z',
          },
        ],
      }),
    );

    expect(text()).toContain('RM 552.00 to RM 500.00');
    expect(text()).toContain('u-boss');
    expect(text()).toContain('matched a competitor quote');
  });

  describe('the customer details for the invoice', () => {
    // SPEC.md §10.3. The office runs the SQL Account export, so it has to see
    // whether an order can be exported without opening somebody's handset.
    const buyer = (over: Partial<BuyerOut> = {}): BuyerOut => ({
      name: 'Ah Lian',
      tin: 'C1234567890',
      id_type: null,
      id_number: null,
      address_line1: '12 Jalan Melaka',
      address_line2: null,
      city: 'Melaka',
      state: 'Melaka',
      postcode: '75000',
      msic_code: null,
      einvoice_requested: false,
      captured_at: '2026-09-12T02:00:00Z',
      complete: true,
      missing: [],
      ...over,
    });

    it('shows what is on file', async () => {
      await load(detail({ buyer: buyer() }));

      expect(text()).toContain('C1234567890');
      expect(text()).toContain('12 Jalan Melaka');
      expect(text()).toContain('Everything the invoice needs is here');
    });

    it('an address with no second line has no hole in it', async () => {
      // Joined in the component rather than the template, so an absent line 2
      // does not leave ", ," in the middle of an address somebody is reading
      // onto a form.
      await load(detail({ buyer: buyer() }));
      expect(text()).toContain('12 Jalan Melaka, 75000 Melaka, Melaka');
      expect(text()).not.toContain(', ,');
    });

    it('states everything outstanding at once', async () => {
      // Not one field at a time. Whoever telephones this customer gets one
      // conversation, and a screen that revealed the next gap after each call
      // is a customer rung three times.
      await load(
        detail({
          buyer: buyer({
            tin: null,
            address_line1: null,
            city: null,
            state: null,
            postcode: null,
            complete: false,
            missing: ['identifier', 'address'],
          }),
        }),
      );

      expect(text()).toContain('Still needed');
      expect(text()).toContain('a TIN, or an ID number with its type');
      expect(text()).toContain('a full address');
    });

    it('never having been asked reads differently from having nothing', async () => {
      // One means somebody still has to go and ask. The other means they did
      // and came away empty, and the next step is different.
      await load(
        detail({
          buyer: buyer({
            tin: null,
            address_line1: null,
            city: null,
            state: null,
            postcode: null,
            captured_at: null,
            complete: false,
            missing: ['identifier', 'address'],
          }),
        }),
      );

      expect(text()).toContain('Nobody has taken these yet');
    });

    it('says why they are needed when the order is over the threshold', async () => {
      await load(
        detail({
          order: { ...detail().order, estimate_total_sen: 1_200_000 },
          buyer: buyer(),
        }),
      );

      expect(text()).toContain('over RM10,000');
    });

    it('says nothing about the threshold on a small order', async () => {
      await load(detail({ buyer: buyer() }));
      expect(text()).not.toContain('over RM10,000');
    });

    it('a customer request is a reason on its own, at any amount', async () => {
      // §10.3: asked for at any value.
      await load(detail({ buyer: buyer({ einvoice_requested: true }) }));
      expect(text()).toContain('asked for an e-invoice');
    });

    it('the identifier is not masked', async () => {
      // This screen exists so the person doing the export can check the number
      // against whatever the accounts system rejected. Masking it sends them
      // to the handset, which is the trip the read side exists to remove.
      await load(
        detail({ buyer: buyer({ id_type: 'nric', id_number: '900101015555' }) }),
      );
      expect(text()).toContain('900101015555');
    });

    it('the dashboard does not claim to issue invoices', async () => {
      // CLAUDE.md hard rule 7 and §10.1. SQL Account is the sole issuer.
      await load(detail({ buyer: buyer() }));
      expect(text()).toContain('does not issue invoices');
      expect(text().toLowerCase()).not.toContain('tax invoice');
    });

    it('an order with no buyer block at all renders without it', async () => {
      // A server that has not been migrated yet, or an older response.
      await load(detail({ buyer: null }));
      expect(text()).not.toContain('Customer details for the invoice');
      expect(text()).toContain('MLK-2608-0001');
    });
  });

  it('an unknown order says so rather than showing an empty shell', async () => {
    // An empty detail renders as an order that lost its contents, which reads
    // as data loss rather than as a bad link.
    fixture.detectChanges();
    await Promise.resolve();
    http
      .expectOne('/api/orders/o1')
      .flush({ detail: 'no' }, { status: 404, statusText: 'Not Found' });
    fixture.detectChanges();

    expect(text()).toContain('No such order');
  });
});
