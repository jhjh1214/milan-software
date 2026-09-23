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
import { Session } from '../auth/session';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { SegmentedControl } from '../shared/segmented-control';
import { formatDate, formatSen, urgencyOf, type Urgency } from '../api/money';
import {
  PIPELINE,
  type Channel,
  type OrderStatus,
  type OrderSummary,
  type PersonOut,
} from '../api/types';

const CHANNELS: readonly Channel[] = [
  'fair',
  'showroom',
  'home_visit',
  'referral',
  'phone',
];

@Component({
  selector: 'app-order-board',
  imports: [CommonModule, RouterLink, SegmentedControl],
  templateUrl: './order-board.html',
  styleUrl: './order-board.css',
})
export class OrderBoard {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  /** Public to the template: the salesperson filter is admin-only, matching
   * `GET /api/people`'s own gate -- offering it to somebody who cannot
   * fetch the names to fill it would just be a filter that never works. */
  protected readonly session = inject(Session);

  protected readonly statuses = PIPELINE;
  protected readonly channels = CHANNELS;

  /** Fetched once, only for an admin -- SPEC.md §11 Phase 5's own wishlist
   * names a salesperson filter alongside channel, and every name it needs
   * already lives behind the admin-only people list. */
  protected readonly people = signal<readonly PersonOut[]>([]);

  /** How many placeholder cards to draw while nothing has arrived yet. */
  protected readonly skeletonRows = [0, 1, 2, 3, 4, 5];

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
  protected readonly failure = signal<Failure | null>(null);

  /** The words, as a signal: switching language re-renders the board. */
  protected readonly t = inject(Text).strings;

  /** Chosen at render time, so a failure on screen follows the language. */
  protected message(failure: Failure): string {
    if (failure.status === 401) return this.t().board.signedOut;
    if (failure.status === null) return this.t().board.wentWrong;
    return commonMessage(this.t(), failure);
  }

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
  protected readonly salesperson = computed(
    () => this.params()?.get('salesperson') ?? null,
  );

  constructor() {
    if (this.session.isAdmin()) {
      this.api.people().subscribe({
        next: (out) => this.people.set(out.people),
        // The board itself is the main content; a failed people fetch just
        // means the filter stays empty rather than blocking the board.
        error: () => undefined,
      });
    }

    effect(() => {
      // Re-reads whenever the URL changes, which is the only way a filter
      // changes. A separate "apply" path would be a second source of truth.
      const status = this.status();
      const channel = this.channel();
      const salesperson = this.salesperson();
      this.load(status, channel, salesperson);
    });
  }

  private load(
    status: OrderStatus | null,
    channel: Channel | null,
    salesperson: string | null,
  ): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api
      .orders({
        ...(status ? { status } : {}),
        ...(channel ? { channel } : {}),
        ...(salesperson ? { confirmedByUserId: salesperson } : {}),
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
          this.failure.set(failureOf(err));
          this.loading.set(false);
        },
      });
  }

  /** Sets or clears one filter, by putting it in the URL. */
  protected filterBy(
    key: 'status' | 'channel' | 'salesperson',
    value: string | null,
  ): void {
    void this.router.navigate([], {
      relativeTo: this.route,
      queryParams: { [key]: value },
      queryParamsHandling: 'merge',
    });
  }

  protected retry(): void {
    this.load(this.status(), this.channel(), this.salesperson());
  }

  protected readonly money = formatSen;
  protected readonly date = formatDate;

  protected urgency(order: OrderSummary): Urgency {
    return urgencyOf(order.held_until);
  }

  /** The lifecycle word, not the wire value with its underscores swapped
   * for spaces. §6.6 names these and the handset says the same thing. */
  protected readonly statusLabel = (s: OrderStatus): string => this.t().status[s];
  protected readonly channelLabel = (c: Channel): string => this.t().channel[c];
}
