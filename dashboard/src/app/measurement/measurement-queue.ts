/**
 * What is waiting for a site visit. SPEC.md §11 Phase 5.
 *
 * > Measurement queue — grouped by project so one trip covers several units
 *
 * §13 C10, answered: the server groups by delivery zone first (already
 * captured on every order at quote time), then by customer within it — keyed
 * on the normalised phone, exactly as a rate lock is. Zones are ordered by
 * the longest-waiting order inside them, so route clustering never buries an
 * overdue customer behind a zone that merely sorts earlier. This screen
 * renders a heading wherever the zone changes, on top of the flat, already-
 * ordered list the server sends.
 *
 * Each trip can also carry a free-text address note, typed in by staff --
 * not a real address record, just enough to open a free Google Maps search
 * link before the visit (no paid routing API; SPEC.md §13 C10's write-up).
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
import { forkJoin, map } from 'rxjs';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { formatDate, formatSen } from '../api/money';
import { SegmentedControl } from '../shared/segmented-control';
import type { MeasurementGroup } from '../api/types';

/** One row this screen renders: either a zone heading or a trip beneath it. */
type QueueRow =
  | { readonly kind: 'zone-header'; readonly zoneOf: string; readonly label: string }
  | { readonly kind: 'group'; readonly group: MeasurementGroup };

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
  protected readonly failure = signal<Failure | null>(null);

  private readonly text = inject(Text);

  /** The words, as a signal: switching language re-renders the queue. */
  protected readonly t = this.text.strings;

  /** Chosen at render time, so a failure on screen follows the language. */
  protected message(failure: Failure): string {
    if (failure.status === 401) return this.t().queue.signedOut;
    if (failure.status === null) return this.t().queue.wentWrong;
    return commonMessage(this.t(), failure);
  }

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
        this.failure.set(failureOf(err));
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
    return group.customer_name ?? this.t().queue.noName;
  }

  /**
   * A zone's label in the reader's own language, falling back to English,
   * then to the raw id, then to "no zone" -- the same fallback chain
   * `products.ts` already uses for a rate-card row's labels. A group missing
   * a label is not a reason to hide the trip that needs a route the most.
   */
  protected zoneLabel(group: MeasurementGroup): string {
    if (group.delivery_zone_id === null) return this.t().queue.unzonedHeading;
    const lang = this.text.language();
    return (
      group.delivery_zone_labels?.[lang] ??
      group.delivery_zone_labels?.['en'] ??
      group.delivery_zone_id
    );
  }

  /**
   * The visible trips with a zone-heading row inserted wherever the zone
   * changes. The server already clusters and orders zones (worst-waiting
   * first); this only walks that list once to mark the boundaries -- it
   * never re-sorts, matching the rest of this screen's own rule.
   */
  protected readonly rows = computed<readonly QueueRow[]>(() => {
    const rows: QueueRow[] = [];
    let lastZone: string | null | undefined = undefined;
    for (const group of this.visible()) {
      if (group.delivery_zone_id !== lastZone) {
        rows.push({
          kind: 'zone-header',
          zoneOf: group.delivery_zone_id ?? 'unzoned',
          label: this.zoneLabel(group),
        });
        lastZone = group.delivery_zone_id;
      }
      rows.push({ kind: 'group', group });
    }
    return rows;
  });

  protected rowKey(row: QueueRow): string {
    return row.kind === 'group' ? row.group.key : `zone-header:${row.zoneOf}`;
  }

  /** The address on a trip, from whichever job carries one -- every job in a
   * group is the same house, so the first note found speaks for all of them. */
  protected addressOf(group: MeasurementGroup): string | null {
    return group.jobs.find((j) => j.site_address_note !== null)?.site_address_note ?? null;
  }

  /** A free Google Maps search link -- no API key, no billing, just the
   * documented `maps/search` URL scheme opening on that address. */
  protected navigateHref(address: string): string {
    return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`;
  }

  protected readonly editingAddress = signal<string | null>(null);
  protected readonly addressDraft = signal('');
  protected readonly savingAddress = signal<ReadonlySet<string>>(new Set());

  protected editAddress(group: MeasurementGroup): void {
    this.editingAddress.set(group.key);
    this.addressDraft.set(this.addressOf(group) ?? '');
  }

  protected cancelAddress(): void {
    this.editingAddress.set(null);
  }

  /**
   * Saves the same note onto every job in the trip -- they are one house, so
   * the address should read the same however the queue happens to have split
   * that customer's orders into jobs.
   */
  protected saveAddress(group: MeasurementGroup): void {
    const note = this.addressDraft().trim() || null;
    this.savingAddress.update((s) => new Set(s).add(group.key));

    forkJoin(group.jobs.map((job) => this.api.setSiteAddress(job.order_id, note))).subscribe({
      next: () => {
        this.groups.update((all) =>
          all.map((g) =>
            g.key !== group.key
              ? g
              : { ...g, jobs: g.jobs.map((j) => ({ ...j, site_address_note: note })) },
          ),
        );
        this.savingAddress.update((s) => {
          const next = new Set(s);
          next.delete(group.key);
          return next;
        });
        this.editingAddress.set(null);
      },
      error: () => {
        this.savingAddress.update((s) => {
          const next = new Set(s);
          next.delete(group.key);
          return next;
        });
      },
    });
  }
}
