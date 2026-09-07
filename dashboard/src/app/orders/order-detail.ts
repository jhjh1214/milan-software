/**
 * One order, and why its numbers are what they are. SPEC.md §6.3, §6.5.
 *
 * Somebody opens this screen to answer a question, and it is nearly always the
 * same question: *why does this line cost that?* So the line rows carry the
 * snapshot the order was priced with — the rule, the band, the card version and
 * the discount — because a year later the card may have been superseded twice
 * and the answer has to be here rather than reconstructed.
 *
 * The other thing this screen exists for is the history. `order_events` is
 * append-only and it is the record of what happened to a job: who moved it, in
 * what order, and with what said about it. A screen that summarised that would
 * throw away the thing it is for.
 *
 * ## And it is where the office corrects the buyer's details
 *
 * SPEC.md §11 Phase 7 asks for the handset form *and* "the dashboard
 * equivalent for the office". The office is who runs the SQL Account export,
 * so it is who finds out that an IC number was mistyped or that an address
 * stops at the street — weeks after the measurer went home.
 *
 * The form **sends only what somebody changed**. Not the whole record: a
 * measurer can be capturing a TIN at a house while the office types an address
 * at a desk, and a payload carrying every field would silently undo whichever
 * landed first. Sending the diff means the two only collide when they edited
 * the *same* field, which is the only collision that is genuinely a conflict.
 *
 * Nothing here decides whether the record is complete. `complete` and
 * `missing` come back from the server's rule, the same one the handset shows,
 * and this screen only repeats it.
 *
 * Every piece of state is a signal. A plain field read inside a `computed`
 * never recomputes, which leaves a Save button permanently disabled — a bug
 * this codebase has now shipped twice and caught twice with a test.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';

import { Api } from '../api/api';
import { formatDate, formatSen, urgencyOf, type Urgency } from '../api/money';
import type {
  BuyerDetailsIn,
  BuyerOut,
  OrderDetailOut,
  OrderLineOut,
} from '../api/types';

/** The writable buyer columns. Wire names, matching the server's payload. */
type BuyerField =
  | 'name'
  | 'tin'
  | 'id_type'
  | 'id_number'
  | 'address_line1'
  | 'address_line2'
  | 'city'
  | 'state'
  | 'postcode'
  | 'msic_code';

interface BuyerFieldSpec {
  readonly key: BuyerField;
  readonly label: string;
  /** Empty for free text. Non-empty makes it a fixed list. */
  readonly options: readonly string[];
}

/**
 * The Malaysian identifier kinds, as the column stores them.
 *
 * A fixed list rather than free text: a number filed under a type nobody
 * recognises is a submission rejected weeks later, and an IC, a passport and a
 * business registration are different fields on the invoice. The wire values
 * match `mobile/lib/features/order/buyer_details_screen.dart` and the
 * `buyer_id_type` column; they must not drift. §13 **C13** asks the accountant
 * which of them MyInvois actually requires.
 */
const ID_TYPES = ['nric', 'brn', 'passport', 'army'] as const;

/** Every buyer field, in the order somebody asks for them on the telephone. */
const BUYER_FIELDS: readonly BuyerFieldSpec[] = [
  {
    key: 'name',
    label: 'Name, as on the IC or company registration',
    options: [],
  },
  { key: 'tin', label: 'TIN', options: [] },
  { key: 'id_type', label: 'ID type', options: ID_TYPES },
  { key: 'id_number', label: 'ID number', options: [] },
  { key: 'address_line1', label: 'Address line 1', options: [] },
  { key: 'address_line2', label: 'Address line 2 (optional)', options: [] },
  { key: 'city', label: 'City', options: [] },
  { key: 'state', label: 'State', options: [] },
  { key: 'postcode', label: 'Postcode', options: [] },
  { key: 'msic_code', label: 'MSIC code (business buyers only)', options: [] },
];

type Draft = Record<BuyerField, string>;

const EMPTY_DRAFT: Draft = {
  name: '',
  tin: '',
  id_type: '',
  id_number: '',
  address_line1: '',
  address_line2: '',
  city: '',
  state: '',
  postcode: '',
  msic_code: '',
};

/** The stored record as the form holds it: null and absent both become ''. */
function draftOf(buyer: BuyerOut | null): Draft {
  const draft = { ...EMPTY_DRAFT };
  if (buyer === null) return draft;
  for (const field of BUYER_FIELDS) {
    draft[field.key] = (buyer[field.key] ?? '').trim();
  }
  return draft;
}

@Component({
  selector: 'app-order-detail',
  imports: [CommonModule, RouterLink],
  templateUrl: './order-detail.html',
  styleUrl: './order-detail.css',
})
export class OrderDetail {
  private readonly api = inject(Api);

  /** Bound from the route, via `withComponentInputBinding`. */
  readonly id = input.required<string>();

  protected readonly detail = signal<OrderDetailOut | null>(null);
  protected readonly loading = signal(true);
  protected readonly failure = signal<string | null>(null);

  protected readonly buyerFields = BUYER_FIELDS;

  /** The buyer form: open or not, what is typed, and what was loaded. */
  protected readonly editingBuyer = signal(false);
  protected readonly draft = signal<Draft>(EMPTY_DRAFT);
  protected readonly draftRequested = signal(false);
  protected readonly savingBuyer = signal(false);
  protected readonly buyerNote = signal<string | null>(null);
  protected readonly buyerFailure = signal<string | null>(null);

  /**
   * What the form was opened with. A signal because `changedFields` reads it.
   *
   * Kept separately from `detail()` so the diff survives a reload landing
   * underneath somebody who is mid-edit: what they are correcting is what they
   * were shown, not whatever arrived since.
   */
  private readonly baseline = signal<Draft>(EMPTY_DRAFT);
  private readonly baselineRequested = signal(false);

  constructor() {
    // `input` is set before the first change detection, so reading it in the
    // constructor via an effect keeps the load in one place.
    queueMicrotask(() => this.load());
  }

  private load(): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.order(this.id()).subscribe({
      next: (detail) => {
        this.detail.set(detail);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.detail.set(null);
        this.failure.set(describe(err));
        this.loading.set(false);
      },
    });
  }

  protected retry(): void {
    this.load();
  }

  protected readonly money = formatSen;
  protected readonly date = formatDate;

  protected urgency(): Urgency {
    return urgencyOf(this.detail()?.order.held_until ?? null);
  }

  /**
   * The dimensions as entered, and as measured if they have been.
   *
   * Tenths of a millimetre on the wire; feet on the screen, because that is
   * what the shop measures in. Shown to one decimal and never fed back into
   * anything — this is a display accessor, the same rule `Length.mm` has on
   * the handset.
   */
  protected size(line: OrderLineOut): string {
    const feet = (tmm: number | null): string | null =>
      tmm === null ? null : (tmm / 3048).toFixed(1);

    const width = feet(line.est_width_tmm);
    const height = feet(line.est_height_tmm);
    const estimate = height === null ? `${width}ft` : `${width} × ${height}ft`;

    if (!line.is_site_measured) return `${estimate} (estimate)`;

    const fw = feet(line.final_width_tmm);
    const fh = feet(line.final_height_tmm);
    const measured = fh === null ? `${fw}ft` : `${fw} × ${fh}ft`;
    return `${estimate} → ${measured} measured`;
  }

  /**
   * The buyer's address as one readable block, blank lines dropped.
   *
   * Joined here rather than in the template so an absent line 2 does not leave
   * a hole in the middle of an address somebody is reading onto a form.
   */
  protected address(buyer: BuyerOut): string {
    return [
      buyer.address_line1,
      buyer.address_line2,
      [buyer.postcode, buyer.city].filter(Boolean).join(' '),
      buyer.state,
    ]
      .map((part) => part?.trim())
      .filter((part) => !!part)
      .join(', ');
  }

  /** What is still outstanding, in words rather than as a wire value. */
  protected missingLabel(missing: string): string {
    switch (missing) {
      case 'name':
        return 'the full name, as on the IC or company registration';
      case 'identifier':
        return 'a TIN, or an ID number with its type';
      default:
        return 'a full address — street, city, state and postcode';
    }
  }

  /**
   * Why these details matter for this particular order.
   *
   * Not a rule — the RM10,000 gate is the state machine's, on the handset and
   * on the server. This is a note beside a figure the office is already
   * looking at, so somebody chasing a customer knows whether it is the law or
   * a request.
   */
  protected whyCaptured(d: OrderDetailOut): string | null {
    if (d.buyer?.einvoice_requested) {
      return 'The customer asked for an e-invoice, so these are needed whatever the amount.';
    }
    const total = d.order.estimate_total_sen;
    if (total >= 1_000_000) {
      return 'This order is over RM10,000, so by law the invoice needs the customer’s own details.';
    }
    return null;
  }

  protected openBuyerEdit(): void {
    const buyer = this.detail()?.buyer ?? null;
    this.draft.set(draftOf(buyer));
    this.baseline.set(draftOf(buyer));
    this.draftRequested.set(buyer?.einvoice_requested ?? false);
    this.baselineRequested.set(buyer?.einvoice_requested ?? false);
    this.buyerNote.set(null);
    this.buyerFailure.set(null);
    this.editingBuyer.set(true);
  }

  protected cancelBuyerEdit(): void {
    this.editingBuyer.set(false);
    this.buyerFailure.set(null);
  }

  protected setDraft(key: BuyerField, value: string): void {
    this.draft.update((d) => ({ ...d, [key]: value }));
  }

  /**
   * Which fields somebody actually altered. Compared trimmed, both sides.
   *
   * Trimmed because the server trims too: typing a space into an empty box is
   * not a correction, and sending it as one would stamp `buyer_captured_at`
   * and win a race it had no business entering.
   */
  protected readonly changedFields = computed<readonly BuyerField[]>(() => {
    const draft = this.draft();
    const was = this.baseline();
    return BUYER_FIELDS.map((f) => f.key).filter(
      (key) => draft[key].trim() !== was[key].trim(),
    );
  });

  protected readonly canSaveBuyer = computed(
    () =>
      !this.savingBuyer() &&
      (this.changedFields().length > 0 ||
        this.draftRequested() !== this.baselineRequested()),
  );

  /** The form's own submit, so Enter in a box saves rather than reloading. */
  protected submitBuyer(event: Event): void {
    event.preventDefault();
    this.saveBuyer();
  }

  /**
   * Sends the diff, and says plainly what came back.
   *
   * A field emptied goes up as `""`, which is the server's explicit clear —
   * the thing a handset cannot express (§13 C14), and the reason a wrong IC
   * number can be removed from here and nowhere else.
   */
  protected saveBuyer(): void {
    if (!this.canSaveBuyer()) return;

    const draft = this.draft();
    const payload: Record<string, unknown> = {
      order_id: this.id(),
      captured_at: new Date().toISOString(),
    };
    for (const key of this.changedFields()) {
      payload[key] = draft[key].trim();
    }
    if (this.draftRequested() !== this.baselineRequested()) {
      payload['einvoice_requested'] = this.draftRequested();
    }

    this.savingBuyer.set(true);
    this.buyerFailure.set(null);
    this.buyerNote.set(null);

    this.api.saveBuyer(payload as unknown as BuyerDetailsIn).subscribe({
      next: (result) => {
        this.savingBuyer.set(false);
        if (result.refused_because !== null) {
          // Nothing was written. It arrived as a 200, and saying "saved" here
          // would tell somebody a legal requirement was met when it was not.
          this.buyerFailure.set(refusal(result.refused_because));
          return;
        }
        this.editingBuyer.set(false);
        this.buyerNote.set(
          result.complete
            ? 'Saved. Everything the invoice needs is here.'
            : 'Saved. Some of it is still outstanding.',
        );
        // Reload rather than patch what is on screen: the server merged this
        // into whatever else has landed, and only it knows the result.
        this.load();
      },
      error: (err: unknown) => {
        this.savingBuyer.set(false);
        this.buyerFailure.set(describe(err));
      },
    });
  }

  /** What a line was priced on, in one line somebody can read out. */
  protected basis(line: OrderLineOut): string {
    const band = line.applied_band_label ? ` · ${line.applied_band_label}` : '';
    const discount =
      line.applied_discount_pct === '0'
        ? ''
        : ` · held ${line.applied_discount_pct} off`;
    return `${line.billed_qty} ${line.billed_unit} at ${this.money(
      line.rate_sen,
    )}${band} · list v${line.applied_rate_card_version}${discount}`;
  }
}

/**
 * A refusal the server reports rather than raises.
 *
 * Both of these mean **nothing was stored**. `stale` is the one that happens:
 * a handset captured for this order after this screen was loaded, and the
 * merge would have put an older answer over a newer one.
 */
function refusal(reason: string): string {
  if (reason === 'stale') {
    return (
      'Not saved — somebody captured these on a handset more recently. ' +
      'Reload to see what they took, then correct it again.'
    );
  }
  if (reason === 'unknown_order') {
    return 'Not saved — the server has no record of this order yet.';
  }
  return `Not saved — the server refused it (${reason}).`;
}

function describe(err: unknown): string {
  if (typeof err === 'object' && err !== null && 'status' in err) {
    const status = (err as { status: number }).status;
    if (status === 404) return 'No such order.';
    if (status === 401) return 'Signed out. Sign in again to see this order.';
    if (status === 0) return 'No answer from the server.';
    return `The server answered ${status}.`;
  }
  return 'Something went wrong loading this order.';
}
