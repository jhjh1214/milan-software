/**
 * When the fair runs -- the fair card's promo window, set by an admin.
 *
 * The window decides two things about money: which days handsets quote fair
 * prices at all (fair mode closes with it), and when every deposit taken at
 * the fair stops holding its price -- twelve months from the day after it
 * ends (SPEC.md §6.1). So the dates are data an admin edits here, never a
 * date in code, and the consequence is shown beside them before saving.
 *
 * Staff see the dates (they quote against them) but not the control; the
 * server refuses them either way, and hiding it here is a courtesy, not the
 * check. Like a price edit, saving publishes a new fair card version with a
 * mandatory reason recorded against whoever saved it.
 *
 * `decide_fair_dates` (backend/app/pricing/fair_dates.py) is the authority;
 * `blockReason` re-derives the refusals a browser can know in advance so
 * the answer is instant, and the server still wins if the two disagree.
 */

import { Component, computed, inject, output, signal } from '@angular/core';

import { Api } from '../api/api';
import { formatDate } from '../api/money';
import type { FairDatesOut } from '../api/types';
import { Session } from '../auth/session';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { holdEndsOn } from './hold-ends';

/** Mirrors `MIN_REASON_LENGTH` in backend/app/pricing/rate_edit.py. */
const MIN_REASON_LENGTH = 4;

/** Mirrors `MAX_CODE_LENGTH` in backend/app/pricing/fair_dates.py. */
const MAX_CODE_LENGTH = 64;

/** A `YYYY-MM-DD` as §8.3's `12 Mar 2027`, read as a local calendar day. */
function showDate(iso: string): string {
  return formatDate(`${iso}T00:00:00`);
}

@Component({
  selector: 'app-fair-dates',
  templateUrl: './fair-dates.html',
  styleUrl: './fair-dates.css',
})
export class FairDates {
  private readonly api = inject(Api);
  private readonly session = inject(Session);

  protected readonly t = inject(Text).strings;
  protected readonly isAdmin = this.session.isAdmin;

  /** A new fair card was published; the price list beside this is stale. */
  readonly changed = output<number>();

  protected readonly dates = signal<FairDatesOut | null>(null);
  protected readonly failure = signal<Failure | null>(null);
  protected readonly saved = signal<number | null>(null);

  // --- the edit form ---
  protected readonly editing = signal(false);
  protected readonly code = signal('');
  protected readonly from = signal('');
  protected readonly to = signal('');
  protected readonly reason = signal('');
  protected readonly saving = signal(false);
  protected readonly saveFailure = signal<Failure | null>(null);

  protected readonly show = showDate;

  /** When deposits at the fair as it stands stop holding their price. */
  protected readonly holdsUntil = computed<string | null>(() => {
    const to = this.dates()?.valid_to ?? null;
    const held = to === null ? null : holdEndsOn(to);
    return held === null ? null : showDate(held);
  });

  /** The same, for the dates as typed -- the consequence before saving. */
  protected readonly typedHoldsUntil = computed<string | null>(() => {
    const held = holdEndsOn(this.to());
    return held === null ? null : showDate(held);
  });

  protected readonly blockReason = computed<string | null>(() => {
    const words = this.t().fairDates;
    const code = this.code().trim();
    if (code.length === 0 || code.length > MAX_CODE_LENGTH) return words.noCode;

    const from = this.from();
    const to = this.to();
    if (holdEndsOn(from) === null || holdEndsOn(to) === null) {
      return words.noDates;
    }
    // `YYYY-MM-DD` compares correctly as text.
    if (to < from) return words.endsBeforeStart;

    const now = this.dates();
    if (
      now !== null &&
      now.code === code &&
      now.valid_from === from &&
      now.valid_to === to
    ) {
      return words.noChange;
    }

    if (this.reason().trim().length < MIN_REASON_LENGTH) return words.noReason;
    return null;
  });

  protected readonly canSave = computed(
    () => !this.saving() && this.blockReason() === null,
  );

  constructor() {
    this.load();
  }

  private load(): void {
    this.failure.set(null);
    this.api.fairDates().subscribe({
      next: (out) => this.dates.set(out),
      error: (err: unknown) => this.failure.set(failureOf(err)),
    });
  }

  protected message(failure: Failure): string {
    return commonMessage(this.t(), failure);
  }

  protected saveMessage(failure: Failure): string {
    if (failure.status === 403) return this.t().fairDates.notAllowed;
    return commonMessage(this.t(), failure);
  }

  protected openEdit(): void {
    const now = this.dates();
    this.code.set(now?.code ?? '');
    this.from.set(now?.valid_from ?? '');
    this.to.set(now?.valid_to ?? '');
    this.reason.set('');
    this.saveFailure.set(null);
    this.saved.set(null);
    this.editing.set(true);
  }

  protected closeEdit(): void {
    this.editing.set(false);
    this.saveFailure.set(null);
  }

  protected submit(event: Event): void {
    event.preventDefault();
    if (!this.canSave()) return;

    this.saving.set(true);
    this.saveFailure.set(null);
    this.api
      .setFairDates({
        code: this.code().trim(),
        valid_from: this.from(),
        valid_to: this.to(),
        reason: this.reason().trim(),
      })
      .subscribe({
        next: (out) => {
          this.saving.set(false);
          this.dates.set(out);
          this.saved.set(out.version);
          this.editing.set(false);
          this.changed.emit(out.version);
        },
        error: (err: unknown) => {
          this.saving.set(false);
          this.saveFailure.set(failureOf(err));
        },
      });
  }
}
