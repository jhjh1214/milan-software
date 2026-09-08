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
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
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
  private readonly text_ = inject(Text);

  /** The words, as a signal: switching language re-renders the screen. */
  protected readonly t = this.text_.strings;

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
  protected readonly failure = signal<Failure | null>(null);

  /** Chosen at render time, so a failure on screen follows the language. */
  protected message(failure: Failure): string {
    const words = this.t().publish;
    if (failure.status === 403) return words.notAdmin;
    if (failure.status === 422) return words.notACard;
    // The server refuses a version that is not newer. Versions only go up: a
    // re-used number would leave two different cards answering to one.
    if (failure.status === 400) return words.versionMustGoUp;
    if (failure.status === null) return words.wentWrong;
    return commonMessage(this.t(), failure);
  }
  protected readonly diff = signal<CardDiffOut | null>(null);
  protected readonly publishedVersion = signal<number | null>(null);

  /**
   * Bumped by every action that invalidates whatever preview is in flight.
   *
   * A preview request takes a round trip, and `stage` stays `'editing'`
   * for its whole duration — so an edit or a list switch that lands while
   * one is outstanding saw nothing to invalidate and did nothing, and the
   * response then arrived and stamped `'previewed'` over text it never
   * described. The one thing this screen exists to prevent, reachable
   * because the earlier guard only checked state at the moment of the
   * edit, never at the moment the response used it.
   */
  private previewSeq = 0;

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
    this.previewSeq++;
    // Any edit invalidates the preview. Publishing against a diff that
    // describes different text is the one thing this screen exists to prevent.
    if (this.stage() !== 'editing') {
      this.stage.set('editing');
      this.diff.set(null);
    }
  }

  protected chooseList(id: ListId): void {
    this.listId.set(id);
    this.previewSeq++;
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

    // Tags this specific request. If an edit or a list switch lands before
    // the response does, `previewSeq` moves on and the response below is
    // recognised as describing text nobody is looking at anymore.
    const requestSeq = this.previewSeq;

    // The card's labels are {zh, en, ms} maps, and the server picks one. Sent
    // the reader's language rather than a literal 'en', or the diff would name
    // every product in English on a screen saying everything else in Malay.
    this.api.previewCard(this.listId(), card, this.text_.language()).subscribe({
      next: (diff) => {
        this.busy.set(false);
        if (requestSeq !== this.previewSeq) return;
        this.diff.set(diff);
        this.stage.set('previewed');
      },
      error: (err: unknown) => {
        this.busy.set(false);
        if (requestSeq !== this.previewSeq) return;
        this.diff.set(null);
        this.failure.set(failureOf(err));
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
        this.failure.set(failureOf(err));
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
