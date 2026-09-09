/**
 * The admin review queue. SPEC.md Phase 8.
 *
 * > A part-timer's submission is never searchable or quotable until an
 * > admin has approved it.
 *
 * This screen **is** that gate, in the dashboard: everything sitting at
 * `pending_review`, with the actual submission attached so an admin can
 * check it rather than rubber-stamp a name. Mirrors `override-review.ts`'s
 * own ethos — the whole control is on this being read.
 *
 * Every field is a signal. A plain class field read inside a `computed`
 * never recomputes, which has bitten this codebase twice already.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import type { OpeningOut, RoomOut, UnitTypeWithVersionsOut } from '../api/types';

/** What just happened, before it becomes a sentence in the reader's language. */
type Note =
  | { readonly kind: 'approved'; readonly name: string }
  | { readonly kind: 'rejected'; readonly name: string };

@Component({
  selector: 'app-unit-type-review',
  imports: [CommonModule],
  templateUrl: './unit-type-review.html',
  styleUrl: './unit-type-review.css',
})
export class UnitTypeReview {
  private readonly api = inject(Api);

  protected readonly items = signal<readonly UnitTypeWithVersionsOut[]>([]);
  protected readonly loading = signal(false);
  protected readonly failure = signal<Failure | null>(null);
  protected readonly note = signal<Note | null>(null);

  /** The id currently mid-request, so a double click cannot fire twice. */
  protected readonly acting = signal<string | null>(null);
  /** The id whose reject form is open, and what has been typed into it. */
  protected readonly rejectingId = signal<string | null>(null);
  protected readonly reason = signal('');

  protected readonly canSendBack = computed(
    () => this.reason().trim().length > 0 && this.acting() === null,
  );

  /** The words, as a signal: switching language re-renders the queue. */
  protected readonly t = inject(Text).strings;

  constructor() {
    this.load();
  }

  private load(): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.unitTypes('pending_review').subscribe({
      next: (out) => {
        this.items.set(out.unit_types);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.items.set([]);
        this.failure.set(failureOf(err));
        this.loading.set(false);
      },
    });
  }

  protected retry(): void {
    this.load();
  }

  protected message(failure: Failure): string {
    return commonMessage(this.t(), failure);
  }

  /** The latest version's own content -- what the admin is actually judging. */
  protected latestVersion(item: UnitTypeWithVersionsOut) {
    return item.versions[item.versions.length - 1];
  }

  protected openings(item: UnitTypeWithVersionsOut): readonly OpeningOut[] {
    return this.latestVersion(item)?.openings ?? [];
  }

  protected rooms(item: UnitTypeWithVersionsOut): readonly RoomOut[] {
    return this.latestVersion(item)?.rooms ?? [];
  }

  /** Tenths-of-a-millimetre to feet, one decimal -- the same conversion
   * `order-detail.ts` uses for a line's own dimensions. */
  protected feet(tmm: number): string {
    return (tmm / 3048).toFixed(1);
  }

  /** Plain mm² to square feet, whole numbers -- a floor area is read as a
   * round number, never to a fraction of a square foot. */
  protected sqft(areaMm2: number): string {
    return (areaMm2 / 92_903.04).toFixed(0);
  }

  protected approve(item: UnitTypeWithVersionsOut): void {
    if (this.acting() !== null) return;
    this.acting.set(item.id);
    this.failure.set(null);

    this.api.approveUnitType(item.id).subscribe({
      next: () => {
        this.acting.set(null);
        this.items.set(this.items().filter((i) => i.id !== item.id));
        this.note.set({ kind: 'approved', name: this.label(item) });
      },
      error: (err: unknown) => {
        this.acting.set(null);
        this.failure.set(failureOf(err));
      },
    });
  }

  protected startRejecting(item: UnitTypeWithVersionsOut): void {
    this.rejectingId.set(item.id);
    this.reason.set('');
    this.note.set(null);
  }

  protected cancelRejecting(): void {
    this.rejectingId.set(null);
    this.reason.set('');
  }

  protected confirmReject(item: UnitTypeWithVersionsOut): void {
    if (!this.canSendBack()) return;
    this.acting.set(item.id);
    this.failure.set(null);

    this.api.rejectUnitType(item.id, this.reason().trim()).subscribe({
      next: () => {
        this.acting.set(null);
        this.rejectingId.set(null);
        this.reason.set('');
        this.items.set(this.items().filter((i) => i.id !== item.id));
        this.note.set({ kind: 'rejected', name: this.label(item) });
      },
      error: (err: unknown) => {
        this.acting.set(null);
        this.failure.set(failureOf(err));
      },
    });
  }

  protected noteText(note: Note): string {
    const words = this.t().library;
    return note.kind === 'approved' ? words.approvedNote(note.name) : words.rejectedNote(note.name);
  }

  protected label(item: UnitTypeWithVersionsOut): string {
    return `${item.project_name}, ${item.name}`;
  }
}
