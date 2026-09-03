/**
 * Publishing a rate card, with the diff first. SPEC.md §11 Phase 5.
 *
 * > Publishing shows exactly which products move and by how much before commit
 *
 * Two steps, and the second is not available until the first has happened.
 * Nobody publishes 77 rows and hopes: a price change is live on every handset
 * within a pull, and the rows it moves are what a customer is quoted tomorrow.
 *
 * ## The diff comes from the server
 *
 * Not computed here. The server is the authority on pricing (CLAUDE.md hard
 * rule 4), so the thing that shows what will change is the same thing that
 * decides what lands. A preview worked out in the browser could disagree with
 * the publish it precedes, and once it has done that once nobody trusts it
 * again.
 *
 * ## Publishing creates a version, never an edit
 *
 * Rate card rows are never updated in place and never deleted. A quote taken at
 * the August fair has to stay explainable in March, which it can only be if the
 * card it was priced against still exists.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';

import { Api } from '../api/api';
import { formatSen } from '../api/money';
import type { CardDiffOut, ListId, RateChangeOut } from '../api/types';

/** What state the two-step publish is in. */
type Stage = 'editing' | 'previewed' | 'published';

@Component({
  selector: 'app-publish-card',
  imports: [CommonModule],
  templateUrl: './publish-card.html',
  styleUrl: './publish-card.css',
})
export class PublishCard {
  private readonly api = inject(Api);

  protected readonly lists: readonly ListId[] = ['fair', 'standard'];
  protected readonly listId = signal<ListId>('fair');

  /**
   * The card, as JSON text. Pasted or dropped in.
   *
   * A signal, not a field beside one. Holding it in both places was two
   * sources of truth for one string, and change detection noticed before
   * anybody else would have.
   */
  protected readonly text = signal('');

  protected readonly stage = signal<Stage>('editing');
  protected readonly busy = signal(false);
  protected readonly failure = signal<string | null>(null);
  protected readonly diff = signal<CardDiffOut | null>(null);
  protected readonly publishedVersion = signal<number | null>(null);

  /**
   * The parsed card, or null when the text is not a card yet.
   *
   * Parsed here only to catch a paste that is not JSON at all — the server
   * decides everything else. Two validators would eventually disagree about
   * what a card is.
   */
  protected readonly parsed = computed<unknown | null>(() => {
    const raw = this.text();
    if (raw.trim() === '') return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  });

  protected onText(value: string): void {
    this.text.set(value);
    // Any edit invalidates the preview. Publishing against a diff that
    // describes different text is the one thing this screen exists to prevent.
    if (this.stage() !== 'editing') {
      this.stage.set('editing');
      this.diff.set(null);
    }
  }

  protected chooseList(id: ListId): void {
    this.listId.set(id);
    // The same reasoning: a diff of the fair card says nothing about the
    // standard one.
    this.stage.set('editing');
    this.diff.set(null);
  }

  protected async onFile(event: Event): Promise<void> {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    this.onText(await file.text());
  }

  protected preview(): void {
    const card = this.parsed();
    if (card === null || this.busy()) return;

    this.busy.set(true);
    this.failure.set(null);

    this.api.previewCard(this.listId(), card, 'en').subscribe({
      next: (diff) => {
        this.diff.set(diff);
        this.stage.set('previewed');
        this.busy.set(false);
      },
      error: (err: unknown) => {
        this.diff.set(null);
        this.failure.set(describe(err));
        this.busy.set(false);
      },
    });
  }

  protected publish(): void {
    // Never reachable without a preview. The button is absent until then, and
    // this is the second lock on the same door.
    if (this.stage() !== 'previewed' || this.busy()) return;

    const card = this.parsed();
    if (card === null) return;

    this.busy.set(true);
    this.failure.set(null);

    this.api.publishCard(this.listId(), card).subscribe({
      next: (out) => {
        this.publishedVersion.set(out.version);
        this.stage.set('published');
        this.busy.set(false);
      },
      error: (err: unknown) => {
        this.failure.set(describe(err));
        this.busy.set(false);
      },
    });
  }

  protected startAgain(): void {
    this.text.set('');
    this.diff.set(null);
    this.publishedVersion.set(null);
    this.failure.set(null);
    this.stage.set('editing');
  }

  protected readonly money = formatSen;

  /** Signed, so a rise and a cut read differently at a glance. */
  protected delta(change: RateChangeOut): string {
    return change.delta_sen === null ? '' : formatSen(change.delta_sen);
  }

  protected readonly canPreview = computed(
    () => this.parsed() !== null && !this.busy(),
  );

  /**
   * Whether publishing is offered at all.
   *
   * Not offered for a card that changes nothing: it would create a version
   * nobody can tell apart from the live one, and every handset would pull it
   * for no reason.
   */
  protected readonly canPublish = computed(() => {
    const diff = this.diff();
    return (
      this.stage() === 'previewed' &&
      !this.busy() &&
      diff !== null &&
      !diff.is_empty
    );
  });
}

function describe(err: unknown): string {
  if (typeof err === 'object' && err !== null && 'status' in err) {
    const status = (err as { status: number }).status;
    if (status === 403) return 'Only an admin can publish a price list.';
    if (status === 401) return 'Signed out. Sign in again.';
    if (status === 422) return 'That is not a rate card the server accepts.';
    if (status === 400) {
      // The server refuses a version that is not newer. Versions only go up:
      // a re-used number would leave two different cards answering to one.
      return 'The server refused it — check the version number goes up.';
    }
    if (status === 0) return 'No answer from the server.';
    return `The server answered ${status}.`;
  }
  return 'Something went wrong.';
}
