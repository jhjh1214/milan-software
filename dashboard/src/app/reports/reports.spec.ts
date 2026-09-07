/**
 * The reports screen. SPEC.md §11 Phase 5, §6.3, §8.5, §13 C11.
 *
 * What is tested is the things that would make a report actively misleading
 * rather than merely wrong:
 *
 * * a variance table shown without the sentence saying the column is biased by
 *   design — read cold, it accuses honest people of padding quotes;
 * * an order whose final came out above its estimate blending into the row
 *   beside it, when §8.5 says that cannot happen at all;
 * * a balance built from a quotation presented as a debt;
 * * a report nobody can link to, which fails §11's URL criterion.
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

import type {
  BalancesReport,
  OutstandingBalance,
  SalespersonVariance,
} from '../api/types';
import { Text } from '../i18n/text';
import { PERIODS, Reports, panelFrom, weeksFrom } from './reports';

const salesperson = (
  over: Partial<SalespersonVariance> = {},
): SalespersonVariance => ({
  user_id: 'u1',
  name: 'Ah Meng',
  orders_priced: 2,
  orders_awaiting_final: 1,
  estimate_total_sen: 120000,
  final_total_sen: 110000,
  variance_sen: -10000,
  orders_over_estimate: 0,
  ...over,
});

const balance = (over: Partial<OutstandingBalance> = {}): OutstandingBalance => ({
  order_id: 'o1',
  order_no: 'MLK-2608-0001',
  customer_name: 'Ah Lian',
  customer_phone: '0123456789',
  status: 'in_production',
  confirmed_at: '2026-08-10T14:00:00Z',
  days_since_deposit: 25,
  total_sen: 55200,
  deposit_paid_sen: 30000,
  balance_sen: 25200,
  is_estimate: true,
  ...over,
});

const balances = (over: Partial<BalancesReport> = {}): BalancesReport => ({
  balances: [balance()],
  buckets: [
    { days_from: 0, days_to: 31, orders: 1, balance_sen: 25200 },
    { days_from: 31, days_to: 61, orders: 0, balance_sen: 0 },
    { days_from: 61, days_to: 91, orders: 0, balance_sen: 0 },
    { days_from: 91, days_to: null, orders: 0, balance_sen: 0 },
  ],
  total_balance_sen: 25200,
  estimated_balance_sen: 25200,
  ...over,
});

describe('panelFrom', () => {
  it('reads the four reports out of a URL', () => {
    expect(panelFrom('fairs')).toBe('fairs');
    expect(panelFrom('balances')).toBe('balances');
    expect(panelFrom('deposits')).toBe('deposits');
    expect(panelFrom('variance')).toBe('variance');
  });

  it('falls back to the first report rather than to nothing', () => {
    expect(panelFrom(null)).toBe('variance');
    expect(panelFrom('nonsense')).toBe('variance');
  });
});

describe('weeksFrom', () => {
  it('accepts only the periods on offer', () => {
    expect(weeksFrom('4')).toBe(4);
    expect(weeksFrom('52')).toBe(52);
  });

  it('refuses a hand-typed window nobody offered', () => {
    // `?weeks=9999` would ask the server for every prompt ever recorded. The
    // honest answer to a number nobody offered is the default.
    expect(weeksFrom('9999')).toBe(12);
    expect(weeksFrom('-1')).toBe(12);
    expect(weeksFrom('abc')).toBe(12);
    expect(weeksFrom(null)).toBe(12);
  });
});

describe('Reports', () => {
  let http: HttpTestingController;
  let harness: RouterTestingHarness;
  let router: Router;
  let i18n: Text;

  beforeEach(async () => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([{ path: 'reports', component: Reports }]),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    router = TestBed.inject(Router);
    i18n = TestBed.inject(Text);
    // Pinned rather than assumed: the dashboard defaults to Chinese (§13 C9)
    // and nobody is signed in here.
    i18n.pick('en');
    harness = await RouterTestingHarness.create();
  });

  const text = (): string => harness.routeNativeElement!.textContent as string;

  const open = async (url: string, route: string, body: object): Promise<void> => {
    await harness.navigateByUrl(url);
    http.expectOne((r) => r.url === route).flush(body);
    harness.detectChanges();
  };

  describe('estimate against final', () => {
    it('is the report a plain /reports link opens', async () => {
      await open('/reports', '/api/reports/variance', {
        rows: [salesperson()],
        nothing_priced_yet: false,
      });

      expect(text()).toContain('Ah Meng');
    });

    it('says the column is biased before showing it', async () => {
      // Read without this, an honest over-estimate looks like padding. The
      // quote rounds every quantity up and the bill uses the exact tape.
      await open('/reports', '/api/reports/variance', {
        rows: [salesperson()],
        nothing_priced_yet: false,
      });

      expect(text()).toContain('rounds every quantity up');
      expect(text()).toContain('much further out than everybody else');
    });

    it('explains an empty table rather than showing a bare one', async () => {
      // Final prices arrive with Phase 6. An empty table with no sentence is
      // indistinguishable from a query that failed.
      await open('/reports', '/api/reports/variance', {
        rows: [salesperson({ orders_priced: 0 })],
        nothing_priced_yet: true,
      });

      expect(text()).toContain('Nothing has been finally priced yet');
    });

    it('flags an order priced above its estimate rather than blending it in', async () => {
      // §8.5: the final will be the same or lower, never higher. That is a
      // broken promise, not a statistic.
      await open('/reports', '/api/reports/variance', {
        rows: [salesperson({ orders_over_estimate: 2 })],
        nothing_priced_yet: false,
      });

      const flagged = harness.routeNativeElement!.querySelector('.breach');
      expect(flagged?.textContent?.trim()).toBe('2');
    });

    it('does not flag a salesperson with none', async () => {
      await open('/reports', '/api/reports/variance', {
        rows: [salesperson({ orders_over_estimate: 0 })],
        nothing_priced_yet: false,
      });

      expect(harness.routeNativeElement!.querySelector('.breach')).toBeNull();
    });

    it('names a salesperson the order never recorded', async () => {
      await open('/reports', '/api/reports/variance', {
        rows: [salesperson({ user_id: null, name: null })],
        nothing_priced_yet: false,
      });

      expect(text()).toContain('Nobody recorded');
    });
  });

  describe('fair performance', () => {
    it('shows what a fair quoted and what it secured', async () => {
      // §6.1: the RM300 is what a fair is for. Orders without holds are a fair
      // that quoted and secured nothing.
      await open('/reports?report=fairs', '/api/reports/fairs', {
        fairs: [
          {
            promo_code: 'MITC-2026-08',
            valid_from: '2026-08-28',
            valid_to: '2026-08-31',
            orders: 12,
            estimate_total_sen: 1_200_000,
            deposits_taken_sen: 360_000,
            locks_opened: 9,
          },
        ],
      });

      expect(text()).toContain('MITC-2026-08');
      expect(text()).toContain('RM 12,000.00');
      expect(text()).toContain('RM 3,600.00');
      expect(text()).toContain('9');
    });

    it('says plainly when no fair orders exist', async () => {
      await open('/reports?report=fairs', '/api/reports/fairs', { fairs: [] });
      expect(text()).toContain('No orders have come from a fair yet');
    });
  });

  describe('outstanding balances', () => {
    it('never calls anything overdue', async () => {
      // §13 C11: there is no invoice date and no payment terms in this system,
      // so it cannot know when a balance falls due.
      await open('/reports?report=balances', '/api/reports/balances', balances());

      expect(text()).toContain('Nothing here is overdue');
      expect(text()).toContain('Aged from the deposit');
      expect(text().toLowerCase()).not.toContain('overdue by');
    });

    it('marks a balance built from a quotation as an estimate', async () => {
      // §8.5 makes it an upper bound — the most that could be owed, not a debt.
      await open('/reports?report=balances', '/api/reports/balances', balances());

      expect(text()).toContain('Every total below is still a quotation');
      expect(harness.routeNativeElement!.querySelector('.estimated')).not.toBeNull();
    });

    it('says "some" when only part of the book is estimated', async () => {
      // A different sentence from "every total", because the reader has to
      // know whether to look for the marks on the rows.
      await open(
        '/reports?report=balances',
        '/api/reports/balances',
        balances({
          balances: [balance(), balance({ order_id: 'o2', is_estimate: false })],
          total_balance_sen: 50400,
          estimated_balance_sen: 25200,
        }),
      );

      expect(text()).toContain('Some totals are still quotations');
      expect(text()).not.toContain('Every total below is still a quotation');
    });

    it('does not call a final price an estimate', async () => {
      await open(
        '/reports?report=balances',
        '/api/reports/balances',
        balances({
          balances: [balance({ is_estimate: false })],
          estimated_balance_sen: 0,
        }),
      );

      expect(harness.routeNativeElement!.querySelector('.estimated')).toBeNull();
      expect(text()).not.toContain('the most that could be owed');
    });

    it('shows every bucket, including the empty ones', async () => {
      await open('/reports?report=balances', '/api/reports/balances', balances());

      const cards = harness.routeNativeElement!.querySelectorAll('.buckets li');
      expect(cards.length).toBe(4);
      expect(text()).toContain('Over 90 days');
    });

    it('says how much of the book is still estimated', async () => {
      await open(
        '/reports?report=balances',
        '/api/reports/balances',
        balances({ total_balance_sen: 50000, estimated_balance_sen: 20000 }),
      );

      expect(text()).toContain('Outstanding RM 500.00');
      expect(text()).toContain('RM 200.00 is still estimated');
    });
  });

  describe('declined deposits', () => {
    it('asks for the window the URL names', async () => {
      await harness.navigateByUrl('/reports?report=deposits&weeks=4');
      const req = http.expectOne((r) => r.url === '/api/deposit-prompts');

      const start = new Date(req.request.params.get('start')!);
      const end = new Date(req.request.params.get('end')!);
      expect(Math.round((end.getTime() - start.getTime()) / 86_400_000)).toBe(28);

      req.flush({ prompts: [] });
    });

    it('summarises what the fair left behind', async () => {
      await open('/reports?report=deposits', '/api/deposit-prompts', {
        prompts: [
          {
            id: '1',
            quote_id: 'q1',
            category: 'flooring',
            choice: 'declined',
            category_subtotal_sen: 96000,
            at: '2026-08-29T11:00:00Z',
          },
        ],
      });

      expect(text()).toContain('RM 960.00');
      // The category in words, not the wire value it is keyed on.
      expect(text()).toContain('Flooring');
    });

    it('shows no take rate at all where nobody answered', async () => {
      // Not "0 of 1". Nobody answering is not a refusal, and showing it as one
      // would libel a quiet afternoon.
      await open('/reports?report=deposits', '/api/deposit-prompts', {
        prompts: [
          {
            id: '1',
            quote_id: 'q1',
            category: 'curtain',
            choice: 'dismissed',
            category_subtotal_sen: 55200,
            at: '2026-08-29T11:00:00Z',
          },
        ],
      });

      const cells = harness.routeNativeElement!.querySelectorAll('tbody tr td');
      // Take rate is the seventh column.
      expect(cells[6].textContent!.trim()).toBe('—');
      expect(text()).not.toContain('0 of 1');
    });

    it('keeps a dismissal apart from a refusal on screen', async () => {
      await open('/reports?report=deposits', '/api/deposit-prompts', {
        prompts: [],
      });

      expect(text()).toContain('“they said no” and “nobody asked properly”');
    });
  });

  describe('every filter state is reachable by URL', () => {
    it('opens the panel a pasted link names', async () => {
      await open('/reports?report=balances', '/api/reports/balances', balances());
      expect(text()).toContain('Aged from the deposit');
    });

    it('puts the panel in the URL when a tab is pressed', async () => {
      await open('/reports', '/api/reports/variance', {
        rows: [],
        nothing_priced_yet: true,
      });

      const tabs = harness.routeNativeElement!.querySelectorAll('.tabs button');
      (tabs[1] as HTMLButtonElement).click();
      harness.detectChanges();
      await harness.fixture.whenStable();

      expect(router.url).toBe('/reports?report=fairs');
      http.expectOne((r) => r.url === '/api/reports/fairs').flush({ fairs: [] });
    });

    it('drops the parameter for the first report', async () => {
      await open('/reports?report=fairs', '/api/reports/fairs', { fairs: [] });

      const tabs = harness.routeNativeElement!.querySelectorAll('.tabs button');
      (tabs[0] as HTMLButtonElement).click();
      harness.detectChanges();
      await harness.fixture.whenStable();

      expect(router.url).toBe('/reports');
      http
        .expectOne((r) => r.url === '/api/reports/variance')
        .flush({ rows: [], nothing_priced_yet: true });
    });

    it('fetches only the panel on screen', async () => {
      // Four requests to show one table is three wasted, and the balances
      // query walks every open order.
      await open('/reports?report=fairs', '/api/reports/fairs', { fairs: [] });

      http.expectNone('/api/reports/variance');
      http.expectNone('/api/reports/balances');
      http.expectNone('/api/deposit-prompts');
    });
  });

  describe('when it cannot load', () => {
    it('says a refusal plainly rather than showing an empty report', async () => {
      // A blank variance table reads as "nobody is guessing badly", which is
      // the opposite of what a 403 means.
      await harness.navigateByUrl('/reports');
      http
        .expectOne((r) => r.url === '/api/reports/variance')
        .flush({ detail: 'admin only' }, { status: 403, statusText: 'Forbidden' });
      harness.detectChanges();

      expect(text()).toContain('Only an admin can read the reports');
      expect(text()).not.toContain('Nothing has been finally priced yet');
    });

    it('the Try again button asks again', async () => {
      // Every screen here offers one and none of them was ever pressed in a
      // test. A retry that does nothing is worse than no retry: somebody
      // presses it twice and concludes the server is down.
      await harness.navigateByUrl('/reports');
      http
        .expectOne((r) => r.url === '/api/reports/variance')
        .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });
      harness.detectChanges();

      const retry = harness.routeNativeElement!.querySelector(
        '.failure button',
      ) as HTMLButtonElement;
      retry.click();
      harness.detectChanges();

      http
        .expectOne((r) => r.url === '/api/reports/variance')
        .flush({ rows: [salesperson()], nothing_priced_yet: false });
      harness.detectChanges();
      expect(text()).toContain('Ah Meng');
    });
  });

  describe('in the other two languages', () => {
    // SPEC.md §13 C9. Two sentences here are the whole point of the reports
    // they sit on, and both are the kind somebody acts on: §8.5's warning that
    // the variance column is biased by design, and §13 C11's insistence that
    // nothing on the balances report is overdue.

    it('warns that the variance column is biased, in Chinese', async () => {
      // Read cold, and in any language, the table accuses honest people of
      // padding their quotes. The warning is worth nothing to a reader who
      // cannot read it.
      i18n.pick('zh');
      await open('/reports', '/api/reports/variance', {
        rows: [salesperson()],
        nothing_priced_yet: false,
      });

      expect(text()).toContain('估价对实价');
      expect(text()).toContain('每个数量都往上进位');
      expect(text()).not.toContain('rounds every quantity up');
    });

    it('says nothing is overdue, in Malay', async () => {
      // §13 C11. There is no invoice date and no payment terms in this
      // system, so it reports days since the deposit and lets the reader
      // conclude. A Malay reader given an English caveat has been given a
      // number and no caveat.
      i18n.pick('ms');
      await open('/reports?report=balances', '/api/reports/balances', balances());

      expect(text()).toContain('Tiada apa-apa di sini yang tertunggak');
      expect(text()).not.toContain('Nothing here is overdue');
    });

    it('the ageing bands are worded here, not on the wire', async () => {
      // The server sends the range and the screen says the words. An English
      // label on the wire would have been the one English string on the page.
      i18n.pick('ms');
      await open('/reports?report=balances', '/api/reports/balances', balances());

      expect(text()).toContain('0-30 hari');
      expect(text()).toContain('Melebihi 90 hari');
      expect(text()).not.toContain('0-30 days');
    });

    it('a quotation is still marked as one in Chinese', async () => {
      // §8.5 makes a quoted total an upper bound rather than a debt. The mark
      // is what stops a book overstating what is collectable.
      i18n.pick('zh');
      await open('/reports?report=balances', '/api/reports/balances', balances());

      expect(text()).toContain('还是估价');
      expect(harness.routeNativeElement!.querySelector('.estimated')).not.toBeNull();
    });

    it('a refusal is not shown as an empty report, in any language', async () => {
      i18n.pick('ms');
      await harness.navigateByUrl('/reports');
      http
        .expectOne((r) => r.url === '/api/reports/variance')
        .flush({ detail: 'no' }, { status: 403, statusText: 'Forbidden' });
      harness.detectChanges();

      expect(text()).toContain('Hanya admin boleh membaca laporan');
    });
  });

  describe('the window buttons on the declined-deposit report', () => {
    // The one control on this screen that nothing has ever clicked. It is also
    // the one whose effect is invisible if it fails: the table still renders,
    // with the default window, and reads as though four weeks is what was
    // asked for.

    const buttons = (): HTMLButtonElement[] =>
      Array.from(
        harness.routeNativeElement!.querySelectorAll('.periods button'),
      ) as HTMLButtonElement[];

    const press = async (index: number): Promise<void> => {
      buttons()[index].click();
      await harness.fixture.whenStable();
      harness.detectChanges();
    };

    /** The window the next request actually asked for, in whole days. */
    const askedForDays = (): number => {
      const req = http.expectOne((r) => r.url === '/api/deposit-prompts');
      const start = new Date(req.request.params.get('start') as string);
      const end = new Date(req.request.params.get('end') as string);
      req.flush({ prompts: [] });
      harness.detectChanges();
      return Math.round((end.getTime() - start.getTime()) / 86_400_000);
    };

    it('offers exactly the periods the component knows how to honour', async () => {
      // A hand-typed ?weeks=9999 falls back to the default rather than asking
      // the server for every prompt ever recorded, so the buttons and that
      // list have to be the same list.
      await open('/reports?report=deposits', '/api/deposit-prompts', {
        prompts: [],
      });
      expect(buttons().length).toBe(PERIODS.length);
    });

    it('pressing one asks the server for that window', async () => {
      await open('/reports?report=deposits', '/api/deposit-prompts', {
        prompts: [],
      });

      await press(0); // 4 weeks
      expect(askedForDays()).toBe(28);
      expect(router.url).toContain('weeks=4');
    });

    it('the default window is the plain URL, not ?weeks=12', async () => {
      // The default is twelve weeks, which is PERIODS[1] rather than the first
      // button — so the one that clears the parameter is the middle one.
      // Otherwise the link somebody sends says what the default already said,
      // and the two drift the first time the default moves.
      await open('/reports?report=deposits&weeks=52', '/api/deposit-prompts', {
        prompts: [],
      });

      await press(1); // back to the default
      expect(askedForDays()).toBe(84);
      expect(router.url).not.toContain('weeks=');
      expect(router.url).toContain('report=deposits');
    });

    it('changing the window keeps the report you are looking at', async () => {
      // `queryParamsHandling: 'merge'` is doing that, and dropping it would
      // bounce the reader back to the variance table on every press.
      await open('/reports?report=deposits', '/api/deposit-prompts', {
        prompts: [],
      });

      await press(2);
      askedForDays();
      expect(router.url).toContain('report=deposits');
    });
  });
});
