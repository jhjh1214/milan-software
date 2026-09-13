/**
 * Live per-product price editing. No whole-card upload, no preview step.
 *
 * The whole-card publish screen (`publish-card.ts`) stays for what it is
 * good at: bringing in a whole new printed list. This screen is for the
 * other case the client asked for -- one product's price, moved on the
 * spot, because even at a fair table it should be possible to answer a
 * competitor on a single item without reaching for a whole new card.
 *
 * Staff or admin, never a part-timer (hard rule 8: nothing selectable means
 * nothing to get wrong about a rate). Every change still asks a mandatory
 * reason, the same discipline §6.5 already requires of an order-line
 * override -- the gate is a speed bump, the reason read back later is the
 * actual control.
 *
 * ## Still a new version underneath, never a row edited in place
 *
 * `Api.editProductPrice` calls the same `POST .../price` route that
 * publishes a whole new `RateCardVersion` with just this one rule changed.
 * Nothing here mutates a row in place; this screen only removes the
 * upload/preview ceremony around it.
 *
 * ## Why validation happens twice
 *
 * `decide_rate_edit` (backend/app/pricing/rate_edit.py) is the actual
 * authority -- refusing a non-positive rate, an unchanged price, or a too-
 * short reason. `blockReason` below re-derives the same three checks
 * client-side, so a fair-table conversation gets an answer instantly
 * instead of a round trip that comes back refused; if the two ever
 * disagree the server's decision still wins.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { formatSen } from '../api/money';
import type { ListId, ProductOut } from '../api/types';

/** Mirrors `MIN_REASON_LENGTH` in backend/app/pricing/rate_edit.py: short
 * enough to type at a fair table, long enough to mean something later. */
const MIN_REASON_LENGTH = 4;

/** Sen to an editable `46.00`-shaped string. Exact integer arithmetic --
 * `(sen / 100).toFixed(2)` would be the one float this screen could
 * introduce into a money value, which is exactly what CLAUDE.md's
 * invariant forbids. Deliberately not added to `money.ts`, which is one
 * function turning sen into *display* text; this is a text-box prefill. */
function senToRmText(sen: number): string {
  const whole = Math.trunc(sen / 100);
  const cents = sen % 100;
  return `${whole}.${cents.toString().padStart(2, '0')}`;
}

/** The inverse, parsed as a string rather than through `Number(x) * 100` --
 * the same reasoning, the other direction. Null for anything that is not
 * plainly a non-negative amount with at most two decimal places. */
function rmTextToSen(raw: string): number | null {
  const text = raw.trim();
  if (!/^\d+(\.\d{1,2})?$/.test(text)) return null;
  const [whole, frac = ''] = text.split('.');
  const cents = (frac + '00').slice(0, 2);
  return Number(whole) * 100 + Number(cents);
}

@Component({
  selector: 'app-products',
  imports: [CommonModule],
  templateUrl: './products.html',
  styleUrl: './products.css',
})
export class Products {
  private readonly api = inject(Api);
  private readonly text_ = inject(Text);

  /** The words, as a signal: switching language re-renders the screen. */
  protected readonly t = this.text_.strings;

  protected readonly lists: readonly ListId[] = ['fair', 'standard'];
  protected readonly listId = signal<ListId>('fair');

  protected readonly products = signal<readonly ProductOut[]>([]);
  protected readonly version = signal<number | null>(null);
  protected readonly loading = signal(false);
  protected readonly failure = signal<Failure | null>(null);
  protected readonly saved = signal<number | null>(null);

  // --- the one open edit row ---
  protected readonly editingId = signal<string | null>(null);
  protected readonly rate = signal('');
  protected readonly hasMvp = signal(false);
  protected readonly mvpRate = signal('');
  protected readonly reason = signal('');
  protected readonly saving = signal(false);
  protected readonly editFailure = signal<Failure | null>(null);

  protected readonly editingProduct = computed<ProductOut | null>(() => {
    const id = this.editingId();
    if (id === null) return null;
    return this.products().find((p) => p.id === id) ?? null;
  });

  /**
   * Why Save is disabled, chosen at render time from the current words --
   * or null when the edit as typed would be accepted. Re-derives
   * `decide_rate_edit`'s three refusals that a client can actually know in
   * advance (NO_SUCH_PRODUCT cannot be predicted here: the row could have
   * moved under a concurrent publish, and that stays a server refusal).
   */
  protected readonly blockReason = computed<string | null>(() => {
    const product = this.editingProduct();
    if (product === null) return null;
    const words = this.t().products;

    const rateSen = rmTextToSen(this.rate());
    if (rateSen === null || rateSen <= 0) return words.notPositive;

    let mvpSen: number | null = null;
    if (this.hasMvp()) {
      mvpSen = rmTextToSen(this.mvpRate());
      if (mvpSen === null || mvpSen <= 0) return words.notPositive;
    }

    if (rateSen === product.rate_sen && mvpSen === product.mvp_rate_sen) {
      return words.noChange;
    }

    if (this.reason().trim().length < MIN_REASON_LENGTH) return words.noReason;

    return null;
  });

  protected readonly canSave = computed(
    () => !this.saving() && this.blockReason() === null,
  );

  protected readonly money = formatSen;

  constructor() {
    this.load();
  }

  private load(): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.products(this.listId()).subscribe({
      next: (out) => {
        this.products.set(out.products);
        this.version.set(out.version);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.products.set([]);
        this.version.set(null);
        this.failure.set(failureOf(err));
        this.loading.set(false);
      },
    });
  }

  protected retry(): void {
    this.load();
  }

  protected chooseList(id: ListId): void {
    if (id === this.listId()) return;
    this.listId.set(id);
    this.closeEdit();
    this.saved.set(null);
    this.load();
  }

  /** The label in whatever language is on screen, falling back to English
   * and then to the wire id -- a product missing a label is not a reason
   * to hide the row that needs a price change most. */
  protected labelFor(product: ProductOut): string {
    const lang = this.text_.language();
    return product.labels[lang] ?? product.labels['en'] ?? product.variant;
  }

  protected message(failure: Failure): string {
    return commonMessage(this.t(), failure);
  }

  protected editMessage(failure: Failure): string {
    const words = this.t().products;
    if (failure.status === 404) return words.noSuchProduct;
    if (failure.status === 403) return words.notAllowed;
    return commonMessage(this.t(), failure);
  }

  protected openEdit(product: ProductOut): void {
    this.editingId.set(product.id);
    this.rate.set(senToRmText(product.rate_sen));
    this.hasMvp.set(product.mvp_rate_sen !== null);
    this.mvpRate.set(
      product.mvp_rate_sen === null ? '' : senToRmText(product.mvp_rate_sen),
    );
    this.reason.set('');
    this.editFailure.set(null);
    this.saved.set(null);
  }

  protected closeEdit(): void {
    this.editingId.set(null);
    this.rate.set('');
    this.hasMvp.set(false);
    this.mvpRate.set('');
    this.reason.set('');
    this.editFailure.set(null);
  }

  protected submitEdit(event: Event): void {
    event.preventDefault();
    this.save();
  }

  protected save(): void {
    const product = this.editingProduct();
    if (product === null || !this.canSave()) return;

    const rateSen = rmTextToSen(this.rate());
    const mvpSen = this.hasMvp() ? rmTextToSen(this.mvpRate()) : null;
    if (rateSen === null || (this.hasMvp() && mvpSen === null)) return;

    this.saving.set(true);
    this.editFailure.set(null);

    this.api
      .editProductPrice(this.listId(), product.id, {
        rate_sen: rateSen,
        mvp_rate_sen: mvpSen,
        reason: this.reason().trim(),
      })
      .subscribe({
        next: (out) => {
          this.saving.set(false);
          this.saved.set(out.version);
          this.closeEdit();
          this.load();
        },
        error: (err: unknown) => {
          this.saving.set(false);
          this.editFailure.set(failureOf(err));
        },
      });
  }
}
