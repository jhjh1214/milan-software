/**
 * The order board. SPEC.md §11 Phase 5.
 *
 * > Every filter state is reachable by URL
 *
 * That is an acceptance criterion, and until now it was the one the board
 * claimed and nothing checked. It is tested here through a real router, because
 * a filter held in a component field passes every assertion about behaviour and
 * still fails the criterion the moment somebody pastes the link into a message.
 *
 * The other thing worth pinning is the sort and its colours. §11 wants amber at
 * 60 days and red at 30, and a hold that has already run out is a fourth state:
 * not a thing to hurry, but a customer who paid RM300 and got nothing.
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

import type { OrderSummary } from '../api/types';
import { OrderBoard } from './order-board';

const card = (over: Partial<OrderSummary> = {}): OrderSummary => ({
  id: 'o1',
  order_no: 'MLK-2608-0001',
  status: 'confirmed',
  channel: 'fair',
  customer_name: 'Ah Lian',
  customer_phone: '0123456789',
  estimate_total_sen: 55200,
  deposit_paid_sen: 30000,
  has_unmeasured_lines: true,
  confirmed_at: '2026-08-10T14:00:00Z',
  line_count: 3,
  held_until: null,
  ...over,
});

describe('OrderBoard', () => {
  let http: HttpTestingController;
  let harness: RouterTestingHarness;
  let router: Router;

  beforeEach(async () => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([{ path: 'orders', component: OrderBoard }]),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    router = TestBed.inject(Router);
    harness = await RouterTestingHarness.create();
  });

  const text = (): string => harness.routeNativeElement!.textContent as string;

  const open = async (
    url: string,
    orders: OrderSummary[],
    total?: number,
  ): Promise<void> => {
    await harness.navigateByUrl(url);
    http
      .expectOne((r) => r.url === '/api/orders')
      .flush({ orders, total: total ?? orders.length });
    harness.detectChanges();
  };

  describe('every filter state is reachable by URL', () => {
    it('asks the server for exactly what the link names', async () => {
      // The criterion, tested the way it is used: somebody pastes a link and
      // the board they see is the board that was described to them.
      await harness.navigateByUrl('/orders?status=in_production&channel=fair');
      const req = http.expectOne((r) => r.url === '/api/orders');

      expect(req.request.params.get('status')).toBe('in_production');
      expect(req.request.params.get('channel')).toBe('fair');
      req.flush({ orders: [], total: 0 });
    });

    it('sends no filter when the URL names none', async () => {
      await harness.navigateByUrl('/orders');
      const req = http.expectOne((r) => r.url === '/api/orders');

      expect(req.request.params.has('status')).toBe(false);
      expect(req.request.params.has('channel')).toBe(false);
      req.flush({ orders: [], total: 0 });
    });

    it('puts a pressed filter in the URL', async () => {
      await open('/orders', [card()]);

      const buttons = harness.routeNativeElement!.querySelectorAll('button');
      // The first group is Stage: [All, confirmed, …].
      (buttons[1] as HTMLButtonElement).click();
      harness.detectChanges();
      await harness.fixture.whenStable();

      expect(router.url).toBe('/orders?status=confirmed');
      http.expectOne((r) => r.url === '/api/orders').flush({ orders: [], total: 0 });
    });

    it('keeps one filter while another changes', async () => {
      // `queryParamsHandling: 'merge'`. Losing the stage when somebody picks a
      // channel would make the two filters unusable together.
      await open('/orders?status=confirmed', [card()]);

      const groups = harness.routeNativeElement!.querySelectorAll('.filter-group');
      const channel = groups[1].querySelectorAll('button')[1] as HTMLButtonElement;
      channel.click();
      harness.detectChanges();
      await harness.fixture.whenStable();

      expect(router.url).toContain('status=confirmed');
      expect(router.url).toContain('channel=fair');
      http.expectOne((r) => r.url === '/api/orders').flush({ orders: [], total: 0 });
    });

    it('clearing a filter takes it out of the URL', async () => {
      await open('/orders?status=confirmed', [card()]);

      const all = harness.routeNativeElement!.querySelectorAll('button')[0];
      (all as HTMLButtonElement).click();
      harness.detectChanges();
      await harness.fixture.whenStable();

      expect(router.url).toBe('/orders');
      http.expectOne((r) => r.url === '/api/orders').flush({ orders: [], total: 0 });
    });

    it('reloads when the back button changes the URL', async () => {
      // The case a click handler alone would miss: the filter changed and
      // nobody pressed anything.
      await open('/orders?status=confirmed', [card()]);

      await harness.navigateByUrl('/orders?status=ready');
      const req = http.expectOne((r) => r.url === '/api/orders');

      expect(req.request.params.get('status')).toBe('ready');
      req.flush({ orders: [], total: 0 });
    });

    it('shows the filter it is actually applying as pressed', async () => {
      // A link that filters silently -- the URL says one thing, the buttons
      // another -- is worse than one that does not filter at all.
      await open('/orders?status=ready', []);

      const pressed = harness.routeNativeElement!.querySelectorAll(
        'button[aria-pressed="true"]',
      );
      expect(pressed.length).toBe(1);
      expect(pressed[0].textContent!.trim()).toBe('ready');
    });
  });

  describe('what the board says', () => {
    it('says how many of how many, not just how many', async () => {
      // A board that cannot say "1 of 512" leaves somebody guessing whether
      // their filter did anything.
      await open('/orders?status=confirmed', [card()], 512);

      expect(text()).toContain('Showing 1 of 512');
    });

    it('colours a hold by how close it is to running out', async () => {
      // §11 Phase 5: amber at 60 days, red at 30.
      const now = new Date();
      const inDays = (n: number): string =>
        new Date(now.getTime() + n * 86_400_000).toISOString();

      await open('/orders', [
        card({ id: 'a', held_until: inDays(200) }),
        card({ id: 'b', held_until: inDays(45) }),
        card({ id: 'c', held_until: inDays(10) }),
        card({ id: 'd', held_until: inDays(-5) }),
      ]);

      const urgencies = Array.from(
        harness.routeNativeElement!.querySelectorAll('.card'),
      ).map((el) => el.getAttribute('data-urgency'));

      expect(urgencies).toEqual(['none', 'soon', 'urgent', 'gone']);
    });

    it('keeps a hold that has already gone in its own state', async () => {
      // Not "urgent". An expired hold is not a thing to hurry -- it is a
      // customer who paid RM300 and got nothing, which is a different
      // conversation.
      await open('/orders', [
        card({ held_until: new Date(Date.now() - 86_400_000).toISOString() }),
      ]);

      const el = harness.routeNativeElement!.querySelector('.card');
      expect(el!.getAttribute('data-urgency')).toBe('gone');
    });

    it('never invents an order number', async () => {
      // Server-issued, because it goes on a document the customer keeps.
      await open('/orders', [card({ order_no: null })]);

      expect(text()).toContain('Pending sync');
      expect(text()).not.toContain('o1');
    });

    it('shows money in sen formatted once, never as a fraction', async () => {
      await open('/orders', [
        card({ estimate_total_sen: 55200, deposit_paid_sen: 30000 }),
      ]);

      expect(text()).toContain('RM 552.00');
      expect(text()).toContain('RM 300.00 taken');
    });
  });

  describe('when it cannot load', () => {
    it('says so with a way back rather than showing a quiet week', async () => {
      // The office would make decisions on an empty board.
      await harness.navigateByUrl('/orders');
      http
        .expectOne((r) => r.url === '/api/orders')
        .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });
      harness.detectChanges();

      expect(text()).toContain('The server answered 500');
      expect(text()).not.toContain('Nothing matches these filters');
    });

    it('distinguishes an empty filter from an empty board', async () => {
      await open('/orders?status=closed', [], 0);
      expect(text()).toContain('Nothing matches these filters');
    });

    it('the Try again button asks again, with the filters still on', async () => {
      // The retry has to repeat the request that failed, not a bare one. A
      // reload that quietly dropped the filter would show the whole board to
      // somebody who asked for one status, and look like it worked.
      await harness.navigateByUrl('/orders?status=confirmed');
      http
        .expectOne((r) => r.url === '/api/orders')
        .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });
      harness.detectChanges();

      const retry = harness.routeNativeElement!.querySelector(
        '.failure button',
      ) as HTMLButtonElement;
      retry.click();
      harness.detectChanges();

      const again = http.expectOne((r) => r.url === '/api/orders');
      expect(again.request.params.get('status')).toBe('confirmed');
      again.flush({ orders: [card()], total: 1 });
      harness.detectChanges();
      expect(text()).toContain('MLK-2608-0001');
    });
  });
});
