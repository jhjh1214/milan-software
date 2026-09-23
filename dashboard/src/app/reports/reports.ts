/**
 * The four reports. SPEC.md §11 Phase 5.
 *
 * > Reports — estimate vs final variance by salesperson, fair performance,
 * > outstanding balances aged, declined category deposits
 *
 * One screen, four panels, and **which panel is in the URL** — §11 Phase 5
 * makes every filter state reachable by URL an acceptance criterion, and a
 * report somebody cannot link to is one they have to describe over the phone.
 * The declined-deposit period is in the URL for the same reason.
 *
 * Only the visible panel is fetched. Four requests to show one table is three
 * wasted, and the balances query walks every open order.
 *
 * **Every number that came off the server is shown as the server sent it.**
 * Nothing here re-derives a total or re-sorts a table: the server is the
 * authority on money (CLAUDE.md hard rule 4), and a second arithmetic here is
 * a second answer waiting to disagree. The one thing this file computes is the
 * declined-deposit summary, which the server deliberately does not aggregate.
 *
 * Every field is a signal. A plain field read inside a `computed` never
 * recomputes, which has already left a button permanently disabled twice.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, effect, inject, signal } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { formatDate, formatSen } from '../api/money';
import { SegmentedControl } from '../shared/segmented-control';
import { summariseDeposits, takeRate } from './deposits';
import type { CategoryDeclines } from './deposits';
import type {
  AgeingBucket,
  BalancesReport,
  DepositPromptsOut,
  FairReport,
  VarianceReport,
} from '../api/types';

/** Which report is on screen. Lives in the URL and nowhere else. */
export type Panel = 'variance' | 'fairs' | 'balances' | 'deposits';

const PANELS: readonly Panel[] = ['variance', 'fairs', 'balances', 'deposits'];

/** How far back the declined-deposit report looks. Also in the URL. */
export const PERIODS: readonly number[] = [4, 12, 52];
const DEFAULT_WEEKS = 12;

/** Reads the panel out of a URL, defaulting rather than failing. */
export function panelFrom(raw: string | null): Panel {
  return PANELS.includes(raw as Panel) ? (raw as Panel) : 'variance';
}

/**
 * Reads the period out of a URL.
 *
 * Only the offered periods are accepted. A hand-typed `?weeks=9999` would ask
 * the server for every prompt ever recorded, and the honest answer to a number
 * nobody offered is the default, not an attempt to honour it.
 */
export function weeksFrom(raw: string | null): number {
  const parsed = Number(raw);
  return PERIODS.includes(parsed) ? parsed : DEFAULT_WEEKS;
}

@Component({
  selector: 'app-reports',
  imports: [CommonModule, SegmentedControl],
  templateUrl: './reports.html',
  styleUrl: './reports.css',
})
export class Reports {
  private readonly api = inject(Api);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);

  protected readonly panels = PANELS;
  protected readonly periods = PERIODS;

  protected readonly panel = toSignal(
    this.route.queryParamMap.pipe(map((p) => panelFrom(p.get('report')))),
    { initialValue: 'variance' as Panel },
  );

  protected readonly weeks = toSignal(
    this.route.queryParamMap.pipe(map((p) => weeksFrom(p.get('weeks')))),
    { initialValue: DEFAULT_WEEKS },
  );

  protected readonly loading = signal(false);
  protected readonly failure = signal<Failure | null>(null);

  /** The words, as a signal: switching language re-renders every report. */
  protected readonly t = inject(Text).strings;

  /** Chosen at render time, so a failure on screen follows the language. */
  protected message(failure: Failure): string {
    // §6.5 and §11 make the reports admin-only on the server. Said plainly
    // rather than shown as an empty table, which reads as "nothing happened".
    if (failure.status === 403) return this.t().reports.notAdmin;
    if (failure.status === null) return this.t().reports.wentWrong;
    return commonMessage(this.t(), failure);
  }

  /**
   * One ageing band, in words. §13 C11: days since the deposit, never overdue.
   *
   * Built from the range the server sends rather than from a label it used to
   * send, so the wire carries a fact and the screen carries the wording.
   */
  protected bucketLabel(bucket: AgeingBucket): string {
    const words = this.t().reports;
    return bucket.days_to === null
      ? words.bucketOver(bucket.days_from - 1)
      : words.bucketRange(bucket.days_from, bucket.days_to - 1);
  }

  /** A deposit category, in words. §6.2. */
  protected categoryLabel(category: string): string {
    const words = this.t().reports;
    if (category === 'curtain') return words.categoryCurtain;
    if (category === 'flooring') return words.categoryFlooring;
    return words.categoryWallpaper;
  }

  protected readonly variance = signal<VarianceReport | null>(null);
  protected readonly fairs = signal<FairReport | null>(null);
  protected readonly balances = signal<BalancesReport | null>(null);
  protected readonly declines = signal<readonly CategoryDeclines[] | null>(null);

  constructor() {
    // Fetches whichever panel the URL asks for, and refetches when the URL
    // changes — including the back button, which is the case a click handler
    // alone would miss.
    effect(() => this.load(this.panel(), this.weeks()));
  }

  private load(panel: Panel, weeks: number): void {
    this.loading.set(true);
    this.failure.set(null);

    const done = <T>(set: (value: T) => void) => ({
      next: (value: T) => {
        set(value);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.failure.set(failureOf(err));
        this.loading.set(false);
      },
    });

    if (panel === 'variance') {
      this.api.variance().subscribe(done((v: VarianceReport) => this.variance.set(v)));
      return;
    }
    if (panel === 'fairs') {
      this.api.fairs().subscribe(done((f: FairReport) => this.fairs.set(f)));
      return;
    }
    if (panel === 'balances') {
      this.api
        .balances()
        .subscribe(done((b: BalancesReport) => this.balances.set(b)));
      return;
    }

    const end = new Date();
    const start = new Date(end.getTime() - weeks * 7 * 86_400_000);
    this.api
      .depositPrompts(start.toISOString(), end.toISOString())
      .subscribe(
        done((out: DepositPromptsOut) =>
          this.declines.set(summariseDeposits(out.prompts)),
        ),
      );
  }

  protected retry(): void {
    this.load(this.panel(), this.weeks());
  }

  /** Navigates rather than assigning, so the back button and a pasted link work. */
  protected showPanel(next: Panel): void {
    void this.router.navigate([], {
      relativeTo: this.route,
      // `variance` drops the parameter, so the plain URL and the default state
      // are the same link.
      queryParams: { report: next === 'variance' ? null : next },
      queryParamsHandling: 'merge',
    });
  }

  protected readonly panelLabel = (p: Panel): string => {
    const words = this.t().reports;
    if (p === 'variance') return words.variance;
    if (p === 'fairs') return words.fairs;
    if (p === 'balances') return words.balances;
    return words.deposits;
  };

  protected readonly weeksLabel = (w: number): string => this.t().reports.weeks(w);

  protected showWeeks(next: number): void {
    void this.router.navigate([], {
      relativeTo: this.route,
      queryParams: { weeks: next === DEFAULT_WEEKS ? null : next },
      queryParamsHandling: 'merge',
    });
  }

  /**
   * How much of the outstanding book is still a quotation rather than a bill.
   *
   * Kept visible because §8.5 makes a quotation an upper bound — the final
   * will be the same or lower — so an estimated balance is the most that could
   * be owed, and a total that hid the mix would overstate the book.
   */
  protected readonly estimatedShare = computed(() => {
    const report = this.balances();
    if (report === null || report.total_balance_sen === 0) return null;
    return report.estimated_balance_sen === report.total_balance_sen
      ? 'all'
      : report.estimated_balance_sen === 0
        ? 'none'
        : 'some';
  });

  protected readonly rate = takeRate;
  protected readonly money = formatSen;
  protected readonly date = formatDate;

  /** What to call a salesperson the order never named. */
  protected nameOf(name: string | null): string {
    return name ?? this.t().reports.nobodyRecorded;
  }
}

