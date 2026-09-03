/**
 * The order board. SPEC.md §11 Phase 5.
 *
 * > kanban by status, filter by channel/project/salesperson/fair, sorted by
 * > `held_until` ascending, amber at 60 days, red at 30
 *
 * The sort is the point. A rate hold that expires unused is a customer who paid
 * RM300 and got nothing, so the cards nearest that are the ones at the top and
 * the ones with colour on them. Everything else on this screen is arrangement.
 *
 * ## Filters live in the URL
 *
 * §11 Phase 5: *"Every filter state is reachable by URL."* Which means somebody
 * can send a colleague a link to exactly what they are looking at, and the back
 * button does what a back button does. The component reads its filters from the
 * query string and writes them back; it never holds them anywhere else, so the
 * two cannot disagree.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, effect, inject, signal } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { toSignal } from '@angular/core/rxjs-interop';

import { Api } from '../api/api';
import { formatDate, formatSen, urgencyOf, type Urgency } from '../api/money';
import { PIPELINE, type Channel, type OrderStatus, type OrderSummary } from '../api/types';

const CHANNELS: readonly Channel[] = [
  'fair',
  'showroom',
  'home_visit',
  'referral',
  'phone',
];

@Component({
  selector: 'app-order-board',
  imports: [CommonModule, RouterLink],
  templateUrl: './order-board.html',
  styleUrl: './order-board.css',
})
export class OrderBoard {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly statuses = PIPELINE;
  protected readonly channels = CHANNELS;

  protected readonly orders = signal<readonly OrderSummary[]>([]);
  protected readonly total = signal(0);
  protected readonly loading = signal(false);

  /**
   * Null when a request has not failed. A string when it has.
   *
   * Shown as a sentence with a retry, never swallowed: a board that silently
   * shows nothing is indistinguishable from a quiet week, and the office would
   * make decisions on it.
   */
  protected readonly failure = signal<string | null>(null);

  /** The filters, read from the URL so the URL is the only place they live. */
  private readonly params = toSignal(this.route.queryParamMap, {
    initialValue: null,
  });

  protected readonly status = computed(
    () => (this.params()?.get('status') as OrderStatus | null) ?? null,
  );
  protected readonly channel = computed(
    () => (this.params()?.get('channel') as Channel | null) ?? null,
  );

  constructor() {
    effect(() => {
      // Re-reads whenever the URL changes, which is the only way a filter
      // changes. A separate "apply" path would be a second source of truth.
      const status = this.status();
      const channel = this.channel();
      this.load(status, channel);
    });
  }

  private load(status: OrderStatus | null, channel: Channel | null): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api
      .orders({
        ...(status ? { status } : {}),
        ...(channel ? { channel } : {}),
      })
      .subscribe({
        next: (page) => {
          this.orders.set(page.orders);
          this.total.set(page.total);
          this.loading.set(false);
        },
        error: (err: unknown) => {
          this.orders.set([]);
          this.total.set(0);
          this.failure.set(describe(err));
          this.loading.set(false);
        },
      });
  }

  /** Sets or clears one filter, by putting it in the URL. */
  protected filterBy(key: 'status' | 'channel', value: string | null): void {
    void this.router.navigate([], {
      relativeTo: this.route,
      queryParams: { [key]: value },
      queryParamsHandling: 'merge',
    });
  }

  protected retry(): void {
    this.load(this.status(), this.channel());
  }

  protected readonly money = formatSen;
  protected readonly date = formatDate;

  protected urgency(order: OrderSummary): Urgency {
    return urgencyOf(order.held_until);
  }

  /** What the board says about an order with no number yet. */
  protected reference(order: OrderSummary): string {
    return order.order_no ?? 'Pending sync';
  }
}

function describe(err: unknown): string {
  if (typeof err === 'object' && err !== null && 'status' in err) {
    const status = (err as { status: number }).status;
    if (status === 401) return 'Signed out. Sign in again to see the board.';
    if (status === 0) return 'No answer from the server.';
    return `The server answered ${status}.`;
  }
  return 'Something went wrong loading the board.';
}
