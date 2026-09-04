/**
 * What is waiting for a site visit. SPEC.md §11 Phase 5.
 *
 * > Measurement queue — grouped by project so one trip covers several units
 *
 * There is no project library until Phase 8 and no address is captured
 * anywhere, so the server groups by customer — keyed on the normalised phone,
 * exactly as a rate lock is. §13 C10 asks what should really group a day's
 * route; if the answer turns out to be "by area", that is an address field and
 * a different key, and nothing on this screen changes.
 *
 * **The order is who has waited longest**, decided by the server. This screen
 * does not re-sort: a list that reorders itself between two desks looking at
 * the same queue is a list nobody trusts.
 *
 * **The filter is in the URL**, which §11 Phase 5 makes an acceptance
 * criterion. Somebody has to be able to send a colleague a link to the eleven
 * trips nobody has called yet.
 *
 * **No money is editable here and no rate is shown.** Phase 6 reprices, at the
 * held version. The estimate is displayed because it tells a measurer how big
 * a job they are driving to, and that is all it is for.
 *
 * Every field is a signal. A plain field read inside a `computed` never
 * recomputes, which has already left a button permanently disabled twice.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs';

import { Api } from '../api/api';
import { formatDate, formatSen } from '../api/money';
import type { MeasurementGroup } from '../api/types';

/** Which trips to show. Lives in the URL and nowhere else. */
export type QueueFilter = 'all' | 'unbooked' | 'booked';

const FILTERS: readonly QueueFilter[] = ['all', 'unbooked', 'booked'];

/**
 * Reads the filter out of a URL, defaulting rather than failing.
 *
 * A hand-edited or stale link should show the whole queue, not an error. The
 * one thing it must not do is silently show a *subset* it cannot name.
 */
export function filterFrom(raw: string | null): QueueFilter {
  return FILTERS.includes(raw as QueueFilter) ? (raw as QueueFilter) : 'all';
}

/**
 * How long a trip has been waiting, as a state a screen can colour.
 *
 * Thresholds are deliberately not the order board's 60/30 days. Those count
 * down to a rate hold expiring; this counts up from a deposit somebody took,
 * and two weeks without a phone call is already a complaint waiting to happen.
 */
export type Wait = 'fresh' | 'slow' | 'overdue';

export function waitOf(days: number): Wait {
  if (days >= 30) return 'overdue';
  if (days >= 14) return 'slow';
  return 'fresh';
}

@Component({
  selector: 'app-measurement-queue',
  imports: [CommonModule, RouterLink],
  templateUrl: './measurement-queue.html',
  styleUrl: './measurement-queue.css',
})
export class MeasurementQueue {
  private readonly api = inject(Api);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);

  protected readonly groups = signal<readonly MeasurementGroup[]>([]);
  protected readonly totalOrders = signal(0);
  protected readonly loading = signal(false);
  protected readonly failure = signal<string | null>(null);

  /** The filter, read from the URL. The URL is the state, not a copy of it. */
  protected readonly filter = toSignal(
    this.route.queryParamMap.pipe(map((p) => filterFrom(p.get('show')))),
    { initialValue: 'all' as QueueFilter },
  );

  protected readonly filters = FILTERS;

  constructor() {
    this.load();
  }

  private load(): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.measurementQueue().subscribe({
      next: (out) => {
        this.groups.set(out.groups);
        this.totalOrders.set(out.total_orders);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.groups.set([]);
        this.totalOrders.set(0);
        this.failure.set(describe(err));
        this.loading.set(false);
      },
    });
  }

  protected retry(): void {
    this.load();
  }

  /**
   * Sets the filter by navigating, so the back button works and the URL can be
   * copied to somebody else.
   *
   * `all` drops the parameter rather than writing `?show=all`, so the plain URL
   * and the default state are the same link.
   */
  protected show(next: QueueFilter): void {
    void this.router.navigate([], {
      relativeTo: this.route,
      queryParams: { show: next === 'all' ? null : next },
      queryParamsHandling: 'merge',
    });
  }

  /**
   * The trips on screen. Filtered here, never re-sorted.
   *
   * A trip is "unbooked" when *no* job in it has a visit booked. A customer
   * with two units, one booked, is somebody who has been called — the point of
   * this filter is finding the people nobody has spoken to.
   */
  protected readonly visible = computed(() => {
    const show = this.filter();
    const all = this.groups();
    if (show === 'unbooked') return all.filter((g) => g.booked_count === 0);
    if (show === 'booked') return all.filter((g) => g.booked_count > 0);
    return all;
  });

  /** Orders across the visible trips, not trips. */
  protected readonly visibleOrders = computed(() =>
    this.visible().reduce((sum, group) => sum + group.jobs.length, 0),
  );

  /** Windows still to measure across the visible trips. */
  protected readonly visibleUnmeasured = computed(() =>
    this.visible().reduce(
      (sum, group) =>
        sum +
        group.jobs.reduce((n, job) => n + job.unmeasured_line_count, 0),
      0,
    ),
  );

  /**
   * What a trip is worth, in sen.
   *
   * Summed in integer sen, never through a fractional ringgit. This is the
   * third place in the system that invariant could be broken and the way it
   * breaks is somebody dividing by 100 to make one number look right and then
   * adding two of them.
   */
  protected total(group: MeasurementGroup): number {
    return group.jobs.reduce((sum, job) => sum + job.estimate_total_sen, 0);
  }

  protected wait = waitOf;
  protected readonly money = formatSen;
  protected readonly date = formatDate;

  /** What to call a trip with no name and no phone on it. */
  protected nameOf(group: MeasurementGroup): string {
    return group.customer_name ?? 'No name recorded';
  }
}

function describe(err: unknown): string {
  if (typeof err === 'object' && err !== null && 'status' in err) {
    const status = (err as { status: number }).status;
    if (status === 401) return 'Signed out. Sign in again.';
    if (status === 403) return 'You do not have access to this.';
    if (status === 0) return 'No answer from the server.';
    return `The server answered ${status}.`;
  }
  return 'Something went wrong.';
}
