/**
 * Every price moved by hand this week. SPEC.md §6.5.
 *
 * > An offline PIN is bypassable, and one shared admin password reaches every
 * > part-timer within a month. The real control is the audit log plus a weekly
 * > review screen, not the gate. Individual PINs so the log names a person, and
 * > build the "overrides this week" screen — **without it the log is never read
 * > and the control does not exist.**
 *
 * The handset has this screen already, for the one person holding it. This is
 * the office copy: every handset's overrides in one place, which is the only
 * version that can actually be reviewed on a Monday morning.
 *
 * Deliberately plain. Three things per row — who, how much, why — and a total
 * at the top so a bad week is visible before anybody reads a single row. A
 * screen with more on it gets skimmed, and a skimmed audit log is the same as
 * no audit log.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, effect, inject, signal } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { toSignal } from '@angular/core/rxjs-interop';

import { Api } from '../api/api';
import { formatDate, formatSen } from '../api/money';
import type { PriceOverrideOut } from '../api/types';

/** The Monday on or before [day], at midnight UTC. */
export function weekStart(day: Date): Date {
  const midnight = new Date(
    Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate()),
  );
  // getUTCDay() is 0 for Sunday, so Sunday belongs to the week that started
  // six days earlier rather than to the one about to start.
  const back = (midnight.getUTCDay() + 6) % 7;
  midnight.setUTCDate(midnight.getUTCDate() - back);
  return midnight;
}

@Component({
  selector: 'app-override-review',
  imports: [CommonModule],
  templateUrl: './override-review.html',
  styleUrl: './override-review.css',
})
export class OverrideReview {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly rows = signal<readonly PriceOverrideOut[]>([]);
  protected readonly loading = signal(false);
  protected readonly failure = signal<string | null>(null);

  private readonly params = toSignal(this.route.queryParamMap, {
    initialValue: null,
  });

  /** Which week, from the URL. Absent means the one we are in. */
  protected readonly start = computed(() => {
    const given = this.params()?.get('week');
    if (given) {
      const parsed = new Date(given);
      if (!Number.isNaN(parsed.getTime())) return weekStart(parsed);
    }
    return weekStart(new Date());
  });

  protected readonly end = computed(() => {
    const next = new Date(this.start());
    next.setUTCDate(next.getUTCDate() + 7);
    return next;
  });

  /**
   * What the week moved, in total.
   *
   * Summed in integer sen. A week that took RM4,000 off the top of quotes is
   * the thing to notice before reading any single row, and it is the number a
   * screen full of individually reasonable-looking rows hides.
   */
  protected readonly net = computed(() =>
    this.rows().reduce((sum, row) => sum + (row.after_sen - row.before_sen), 0),
  );

  constructor() {
    effect(() => {
      const start = this.start();
      const end = this.end();
      this.load(start, end);
    });
  }

  private load(start: Date, end: Date): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.overrides(start.toISOString(), end.toISOString()).subscribe({
      next: (out) => {
        this.rows.set(out.overrides);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.rows.set([]);
        this.failure.set(describe(err));
        this.loading.set(false);
      },
    });
  }

  protected step(weeks: number): void {
    const to = new Date(this.start());
    to.setUTCDate(to.getUTCDate() + weeks * 7);
    void this.router.navigate([], {
      relativeTo: this.route,
      queryParams: { week: to.toISOString().slice(0, 10) },
      queryParamsHandling: 'merge',
    });
  }

  protected retry(): void {
    this.load(this.start(), this.end());
  }

  protected readonly money = formatSen;
  protected readonly date = formatDate;

  /** The last day of the week, for the heading. */
  protected readonly lastDay = computed(() => {
    const last = new Date(this.end());
    last.setUTCDate(last.getUTCDate() - 1);
    return last.toISOString();
  });
}

function describe(err: unknown): string {
  if (typeof err === 'object' && err !== null && 'status' in err) {
    const status = (err as { status: number }).status;
    // §6.5 makes this admin-only on the server. Said plainly rather than shown
    // as an empty week, which would read as "nobody changed anything".
    if (status === 403) return 'Only an admin can see the override log.';
    if (status === 401) return 'Signed out. Sign in again.';
    if (status === 0) return 'No answer from the server.';
    return `The server answered ${status}.`;
  }
  return 'Something went wrong loading the log.';
}
