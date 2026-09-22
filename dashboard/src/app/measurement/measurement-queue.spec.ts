/**
 * The measurement queue. SPEC.md §11 Phase 5.
 *
 * > Measurement queue — grouped by project so one trip covers several units
 * > Every filter state is reachable by URL
 *
 * Both are acceptance criteria, and both are tested here — the second through
 * a real router rather than a stubbed one, because a filter that lives in a
 * component field would pass every assertion about behaviour and still fail
 * the criterion the moment somebody pasted the link into a message.
 *
 * The rest is about what would quietly make the screen wrong: re-sorting what
 * the server ordered, counting trips where somebody meant jobs, and pooling
 * customers who have no phone into one imaginary visit.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import type { MeasurementGroup, MeasurementJob } from '../api/types';
import { Text } from '../i18n/text';
import { MeasurementQueue, filterFrom, waitOf } from './measurement-queue';

const job = (over: Partial<MeasurementJob> = {}): MeasurementJob => ({
  order_id: 'o1',
  order_no: 'MLK-2608-0001',
  status: 'confirmed',
  channel: 'fair',
  line_count: 3,
  unmeasured_line_count: 3,
  material_pending_count: 0,
  estimate_total_sen: 55200,
  confirmed_at: '2026-08-10T14:00:00Z',
  booked_at: null,
  waiting_days: 5,
  site_address_note: null,
  ...over,
});

const trip = (over: Partial<MeasurementGroup> = {}): MeasurementGroup => ({
  key: 'phone:0123456789',
  customer_name: 'Ah Lian',
  customer_phone: '0123456789',
  grouped_by_phone: true,
  delivery_zone_id: null,
  delivery_zone_labels: null,
  jobs: [job()],
  oldest_confirmed_at: '2026-08-10T14:00:00Z',
  waiting_days: 5,
  booked_count: 0,
  ...over,
});

describe('filterFrom', () => {
  it('reads the three states out of a URL', () => {
    expect(filterFrom('unbooked')).toBe('unbooked');
    expect(filterFrom('booked')).toBe('booked');
    expect(filterFrom('all')).toBe('all');
  });

  it('falls back to the whole queue rather than to a subset it cannot name', () => {
    // A hand-edited or stale link should show everything. Showing a silent
    // subset is how somebody concludes there is no work waiting.
    expect(filterFrom(null)).toBe('all');
    expect(filterFrom('')).toBe('all');
    expect(filterFrom('nonsense')).toBe('all');
  });
});

describe('waitOf', () => {
  it('turns days waited into something a screen can colour', () => {
    // Not the board's 60/30: those count down to a rate hold expiring, this
    // counts up from money already taken.
    expect(waitOf(0)).toBe('fresh');
    expect(waitOf(13)).toBe('fresh');
    expect(waitOf(14)).toBe('slow');
    expect(waitOf(29)).toBe('slow');
    expect(waitOf(30)).toBe('overdue');
  });
});

describe('MeasurementQueue', () => {
  let http: HttpTestingController;
  let harness: RouterTestingHarness;
  let router: Router;
  let i18n: Text;

  beforeEach(async () => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([
          { path: 'measurement', component: MeasurementQueue },
        ]),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    router = TestBed.inject(Router);
    i18n = TestBed.inject(Text);
    // Pinned rather than assumed: the dashboard defaults to Chinese (§13 C9)
    // and nobody is signed in here. What these tests are about is the queue.
    i18n.pick('en');
    harness = await RouterTestingHarness.create();
  });

  const open = async (
    url: string,
    groups: MeasurementGroup[],
    total?: number,
  ): Promise<void> => {
    await harness.navigateByUrl(url);
    http
      .expectOne('/api/measurement-queue')
      .flush({ groups, total_orders: total ?? groups.length });
    harness.detectChanges();
  };

  const text = (): string => harness.routeNativeElement!.textContent as string;

  describe('one trip covers several units', () => {
    it('shows a customer with two orders as one trip, and says so', () => {
      // The saving §11 Phase 5 is after. It is only real if somebody can see
      // it before they plan the day.
      return open('/measurement', [
        trip({ jobs: [job({ order_id: 'a' }), job({ order_id: 'b' })] }),
      ]).then(() => {
        expect(text()).toContain('Ah Lian');
        expect(text()).toContain('one visit covers them all');
        expect(text()).toContain('2 jobs across 1 trip');
      });
    });

    it('does not claim a saving for a trip of one', async () => {
      await open('/measurement', [trip()]);
      expect(text()).not.toContain('one visit covers them all');
      expect(text()).toContain('1 job across 1 trip');
    });

    it('says plainly when an order could not be grouped', async () => {
      // Honest about the limit rather than silent. Pooling the phone-less
      // orders would invent a visit that does not exist.
      await open('/measurement', [
        trip({
          key: 'order:o1',
          customer_phone: null,
          grouped_by_phone: false,
        }),
      ]);

      expect(text()).toContain('No phone recorded');
    });

    it('names a trip that has no name on it', async () => {
      await open('/measurement', [trip({ customer_name: null })]);
      expect(text()).toContain('No name recorded');
    });
  });

  describe('every filter state is reachable by URL', () => {
    it('opens straight into the unbooked trips from a pasted link', async () => {
      // The acceptance criterion, tested the way it is used: somebody sends a
      // colleague a link and the colleague sees the same eleven trips.
      await open('/measurement?show=unbooked', [
        trip({ key: 'a', booked_count: 0 }),
        trip({ key: 'b', booked_count: 1 }),
      ]);

      expect(text()).toContain('1 job across 1 trip');
    });

    it('opens into the booked ones the same way', async () => {
      await open('/measurement?show=booked', [
        trip({ key: 'a', booked_count: 0 }),
        trip({ key: 'b', booked_count: 1, jobs: [job({ order_id: 'b1' })] }),
      ]);

      expect(text()).toContain('Visit booked');
      expect(text()).toContain('1 job across 1 trip');
    });

    it('puts the filter in the URL when a button is pressed', async () => {
      await open('/measurement', [trip()]);

      const button = harness
        .routeNativeElement!.querySelectorAll('button')[1] as HTMLButtonElement;
      button.click();
      harness.detectChanges();
      await harness.fixture.whenStable();

      expect(router.url).toBe('/measurement?show=unbooked');
    });

    it('drops the parameter for "all", so the plain URL is the default', async () => {
      await open('/measurement?show=booked', [trip()]);

      const all = harness
        .routeNativeElement!.querySelectorAll('button')[0] as HTMLButtonElement;
      all.click();
      harness.detectChanges();
      await harness.fixture.whenStable();

      expect(router.url).toBe('/measurement');
    });

    it('a trip with some jobs booked is not "nobody called yet"', async () => {
      // The point of the filter is finding people nobody has spoken to. A
      // customer with two units, one booked, has been called.
      await open('/measurement?show=unbooked', [
        trip({ jobs: [job({ order_id: 'a' }), job({ order_id: 'b' })], booked_count: 1 }),
      ]);

      expect(text()).toContain('No trips match this filter');
    });
  });

  describe('what the office reads off it', () => {
    it('keeps the order the server sent', async () => {
      // Sorted by who has waited longest, decided once on the server. A list
      // that reorders itself between two desks is one nobody trusts.
      await open('/measurement', [
        trip({ key: 'first', customer_name: 'Waited longest', waiting_days: 40 }),
        trip({ key: 'second', customer_name: 'Waited less', waiting_days: 2 }),
      ]);

      expect(text().indexOf('Waited longest')).toBeLessThan(
        text().indexOf('Waited less'),
      );
    });

    it('says the days waited in words, not only in colour', async () => {
      await open('/measurement', [trip({ waiting_days: 41 })]);

      expect(text()).toContain('Waiting 41 days');
      const card = harness.routeNativeElement!.querySelector('.trip')!;
      expect(card.getAttribute('data-wait')).toBe('overdue');
    });

    it('counts jobs and windows, not trips', async () => {
      await open(
        '/measurement',
        [
          trip({
            key: 'a',
            jobs: [
              job({ order_id: 'a1', unmeasured_line_count: 3 }),
              job({ order_id: 'a2', unmeasured_line_count: 2 }),
            ],
          }),
          trip({ key: 'b', jobs: [job({ order_id: 'b1', unmeasured_line_count: 1 })] }),
        ],
        3,
      );

      expect(text()).toContain('3 jobs across 2 trips');
      expect(text()).toContain('6 still to measure');
    });

    it('totals a trip in integer sen', async () => {
      // Never through a fractional ringgit. This is the third place in the
      // system that invariant could be broken.
      await open('/measurement', [
        trip({
          jobs: [
            job({ order_id: 'a', estimate_total_sen: 55200 }),
            job({ order_id: 'b', estimate_total_sen: 4499 }),
          ],
        }),
      ]);

      expect(text()).toContain('Trip total RM 596.99');
    });

    it('shows an order with no number as pending sync, never invented', async () => {
      // Server-issued, because it goes on a document the customer keeps.
      await open('/measurement', [trip({ jobs: [job({ order_no: null })] })]);

      expect(text()).toContain('pending sync');
    });

    it('says how many materials are still to choose', async () => {
      // §13 B7: those lines are quoted at the dearest option in their group,
      // so each choice can only bring the final price down.
      await open('/measurement', [
        trip({ jobs: [job({ material_pending_count: 2 })] }),
      ]);

      expect(text()).toContain('2 materials to choose');
    });

    it('does not offer a rate or a way to reprice', async () => {
      // Phase 6 reprices, at the held version. Nothing here should invite it.
      await open('/measurement', [trip()]);

      expect(text()).not.toContain('rate');
      expect(harness.routeNativeElement!.querySelector('input')).toBeNull();
    });
  });

  describe('when it cannot load', () => {
    it('says so with a way back, rather than showing an empty queue', async () => {
      // An empty queue and a failed request look identical, and somebody would
      // act on the first by going home.
      await harness.navigateByUrl('/measurement');
      http
        .expectOne('/api/measurement-queue')
        .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });
      harness.detectChanges();

      expect(text()).toContain('The server answered 500');
      expect(text()).not.toContain('Nothing is waiting for a visit');
    });

    it('distinguishes an empty queue from an empty filter', async () => {
      // Two different sentences for two different facts. "No trips match this
      // filter" on a genuinely empty queue would send somebody hunting for a
      // filter they never set.
      await open('/measurement', []);
      expect(text()).toContain('Nothing is waiting for a visit');
    });

    it('says a filter emptied the queue when trips exist behind it', async () => {
      await open('/measurement?show=booked', [trip({ booked_count: 0 })]);

      expect(text()).toContain('No trips match this filter');
      expect(text()).not.toContain('Nothing is waiting for a visit');
    });

    it('the Try again button asks again', async () => {
      // Pressed by no test until now. A retry that does nothing is worse than
      // none: somebody presses it twice and concludes the server is down.
      await harness.navigateByUrl('/measurement');
      http
        .expectOne('/api/measurement-queue')
        .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });
      harness.detectChanges();

      const retry = harness.routeNativeElement!.querySelector(
        '.failure button',
      ) as HTMLButtonElement;
      retry.click();
      harness.detectChanges();

      http
        .expectOne('/api/measurement-queue')
        .flush({ groups: [trip()], total_orders: 1 });
      harness.detectChanges();
      expect(text()).not.toContain('The server answered 500');
    });
  });

  describe('in the other two languages', () => {
    // SPEC.md §13 C9. Every count on this screen is a function rather than a
    // number beside a noun: English needs the plural `s`, Chinese needs a
    // measure word and no plural, and Malay needs neither. A shared template
    // would make two of the three read like a translation.

    it('counts jobs and trips the way Chinese counts them', async () => {
      i18n.pick('zh');
      await open('/measurement', [
        trip({ jobs: [job({ order_id: 'a' }), job({ order_id: 'b' })] }),
      ]);

      expect(text()).toContain('量尺排程');
      expect(text()).toContain('1 趟，共 2 张单');
      expect(text()).toContain('去一趟就够');
      expect(text()).not.toContain('jobs across');
    });

    it('says the same things in Malay', async () => {
      i18n.pick('ms');
      await open('/measurement', [
        trip({ jobs: [job({ order_id: 'a' }), job({ order_id: 'b' })] }),
      ]);

      expect(text()).toContain('Senarai ukuran');
      expect(text()).toContain('2 pesanan dalam 1 perjalanan');
      expect(text()).toContain('satu lawatan mencukupi');
    });

    it('a trip of one is not pluralised into a trip of many', async () => {
      // The English `s` is the whole reason these are functions. Getting it
      // from a template would print "1 jobs across 1 trips".
      await open('/measurement', [trip()]);
      expect(text()).toContain('1 job across 1 trip');
      expect(text()).not.toContain('1 jobs');
      expect(text()).not.toContain('1 trips');
    });

    it('what could not be grouped is said in the reader’s language', async () => {
      // §13 C10. The honest sentence, not the silent one — and it is the
      // sentence somebody acts on by going to find a phone number.
      i18n.pick('ms');
      await open('/measurement', [
        trip({ key: 'order:o1', customer_phone: null, grouped_by_phone: false }),
      ]);

      expect(text()).toContain('Tiada nombor telefon');
      expect(text()).not.toContain('No phone recorded');
    });
  });

  describe('grouped by zone, §13 C10', () => {
    it('shows a heading with the zone label in the reader’s language', async () => {
      await open('/measurement', [
        trip({
          delivery_zone_id: 'zone-kl',
          delivery_zone_labels: { zh: '吉隆坡', en: 'KL', ms: 'KL' },
        }),
      ]);

      const headers = harness.routeNativeElement!.querySelectorAll('.zone-header');
      expect(headers.length).toBe(1);
      expect(headers[0].textContent).toBe('KL');
    });

    it('clusters trips sharing a zone under one heading, in the server’s order', async () => {
      await open('/measurement', [
        trip({
          key: 'a',
          delivery_zone_id: 'zone-kl',
          delivery_zone_labels: { en: 'KL' },
        }),
        trip({
          key: 'b',
          delivery_zone_id: 'zone-kl',
          delivery_zone_labels: { en: 'KL' },
        }),
        trip({
          key: 'c',
          delivery_zone_id: 'zone-muar',
          delivery_zone_labels: { en: 'Muar' },
        }),
      ]);

      expect(harness.routeNativeElement!.querySelectorAll('.zone-header').length).toBe(2);
      expect(harness.routeNativeElement!.querySelectorAll('.trip').length).toBe(3);
    });

    it('says plainly when a trip has no zone recorded', async () => {
      await open('/measurement', [trip({ delivery_zone_id: null })]);

      expect(text()).toContain('No delivery zone recorded');
    });

    it('falls back to English, then the raw id, when a label is missing', async () => {
      await open('/measurement', [
        trip({ delivery_zone_id: 'zone-x', delivery_zone_labels: null }),
      ]);

      const header = harness.routeNativeElement!.querySelector('.zone-header')!;
      expect(header.textContent).toBe('zone-x');
    });
  });

  describe('the site address note, §13 C10’s write-up', () => {
    it('offers to add an address when none is set', async () => {
      await open('/measurement', [trip()]);
      expect(text()).toContain('Add address');
      expect(harness.routeNativeElement!.querySelector('a.btn[href*="google.com/maps"]')).toBeNull();
    });

    it('shows the address and a free Google Maps link once one is set', async () => {
      await open('/measurement', [
        trip({ jobs: [job({ site_address_note: '12 Jalan Melati, Taman Melati' })] }),
      ]);

      expect(text()).toContain('12 Jalan Melati, Taman Melati');
      const link = harness.routeNativeElement!.querySelector(
        'a.btn[href*="google.com/maps"]',
      ) as HTMLAnchorElement;
      expect(link).not.toBeNull();
      expect(link.getAttribute('href')).toBe(
        'https://www.google.com/maps/search/?api=1&query=12%20Jalan%20Melati%2C%20Taman%20Melati',
      );
    });

    it('saves a typed address and shows it without a further reload', async () => {
      await open('/measurement', [trip()]);

      const addButton = Array.from(
        harness.routeNativeElement!.querySelectorAll('button'),
      ).find((b) => b.textContent?.includes('Add address')) as HTMLButtonElement;
      addButton.click();
      harness.detectChanges();

      const input = harness.routeNativeElement!.querySelector(
        '.address-input',
      ) as HTMLInputElement;
      input.value = '12 Jalan Melati';
      input.dispatchEvent(new Event('input'));
      harness.detectChanges();

      const saveButton = Array.from(
        harness.routeNativeElement!.querySelectorAll('button'),
      ).find((b) => b.textContent?.trim() === 'Save') as HTMLButtonElement;
      saveButton.click();

      const req = http.expectOne('/api/orders/o1/site-address');
      expect(req.request.method).toBe('PATCH');
      expect(req.request.body).toEqual({ site_address_note: '12 Jalan Melati' });
      req.flush({ order_id: 'o1', site_address_note: '12 Jalan Melati' });
      harness.detectChanges();

      expect(text()).toContain('12 Jalan Melati');
      expect(text()).not.toContain('Add address');
    });
  });
});
