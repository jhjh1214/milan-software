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
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { formatDate, formatSen, urgencyOf, type Urgency } from '../api/money';
import type {
  AllocationOut,
  BuyerDetailsIn,
  BuyerOut,
  MaterialOut,
  OrderDetailOut,
  OrderLineOut,
  StockLotOut,
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
  { key: 'name', options: [] },
  { key: 'tin', options: [] },
  { key: 'id_type', options: ID_TYPES },
  { key: 'id_number', options: [] },
  { key: 'address_line1', options: [] },
  { key: 'address_line2', options: [] },
  { key: 'city', options: [] },
  { key: 'state', options: [] },
  { key: 'postcode', options: [] },
  { key: 'msic_code', options: [] },
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

/**
 * An exact rational as the wire holds it (`"700/3"`, `"250"`) shown to one
 * decimal place. Display only, the same rule `Length.mm` follows on the
 * handset — never parsed back into anything that prices or stores a
 * quantity, which stays the exact string throughout the rest of this app.
 */
function exactRationalToFixed(exact: string | null): string {
  if (exact === null) return '';
  const slash = exact.indexOf('/');
  const value =
    slash === -1
      ? Number(exact)
      : Number(exact.slice(0, slash)) / Number(exact.slice(slash + 1));
  return Number.isFinite(value) ? value.toFixed(1) : exact;
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
  protected readonly failure = signal<Failure | null>(null);

  /** The words, as a signal: switching language re-renders the order. */
  private readonly text = inject(Text);
  protected readonly t = this.text.strings;

  /** Chosen at render time, so a failure on screen follows the language. */
  protected message(failure: Failure): string {
    if (failure.status === 404) return this.t().order.noSuchOrder;
    if (failure.status === 401) return this.t().order.signedOut;
    if (failure.status === null) return this.t().order.wentWrong;
    return commonMessage(this.t(), failure);
  }

  /** What to call each buyer box. Keyed on the column, never on a label. */
  protected fieldLabel(key: BuyerField): string {
    const words = this.t().buyer;
    switch (key) {
      case 'name':
        return words.fieldName;
      case 'tin':
        return words.fieldTin;
      case 'id_type':
        return words.fieldIdType;
      case 'id_number':
        return words.fieldIdNumber;
      case 'address_line1':
        return words.fieldAddress1;
      case 'address_line2':
        return words.fieldAddress2;
      case 'city':
        return words.fieldCity;
      case 'state':
        return words.fieldState;
      case 'postcode':
        return words.fieldPostcode;
      default:
        return words.fieldMsic;
    }
  }

  /**
   * A history row's event name.
   *
   * Most are lifecycle steps and say what the handset says about the same job.
   * Anything else -- a step added later, an event the server invented -- falls
   * back to the wire value with its underscores opened out rather than to a
   * blank line where a fact should be.
   */
  protected eventLabel(event: string): string {
    const known = this.t().status as unknown as Record<string, string>;
    return known[event] ?? event.replaceAll('_', ' ');
  }

  protected readonly buyerFields = BUYER_FIELDS;

  /** The buyer form: open or not, what is typed, and what was loaded. */
  protected readonly editingBuyer = signal(false);
  protected readonly draft = signal<Draft>(EMPTY_DRAFT);
  protected readonly draftRequested = signal(false);
  protected readonly savingBuyer = signal(false);

  /**
   * What the save did, not the sentence about it.
   *
   * The same reasoning as a failure: composed at the moment of the click it
   * would freeze in whichever language was on screen then -- and this one is
   * telling somebody whether a legal requirement is now met.
   */
  protected readonly buyerNote = signal<'complete' | 'incomplete' | null>(null);

  /** The server's refusal reason, turned into words at read time. */
  protected readonly buyerFailure = signal<string | null>(null);

  protected buyerNoteText(note: 'complete' | 'incomplete'): string {
    const words = this.t().buyer;
    return note === 'complete' ? words.savedComplete : words.savedIncomplete;
  }

  /**
   * A refusal, in words. Every one of these means **nothing was stored**.
   *
   * `stale` is the one that happens: a handset captured for this order after
   * this screen was loaded, and the merge would have put an older answer over
   * a newer one.
   */
  protected buyerFailureText(reason: string): string {
    const words = this.t().buyer;
    if (reason === 'stale') return words.refusedStale;
    if (reason === 'unknown_order') return words.refusedUnknown;
    if (reason === 'error') return this.t().order.wentWrong;
    return words.refusedOther(reason);
  }

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
        this.failure.set(failureOf(err));
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

    // A room-sourced flooring line (SPEC.md's property library): a saved
    // room's area does not reduce to one rectangle, so there is no width
    // and no height to show at the estimate, only the area itself. Once
    // it has been through a real site visit, the tape's own width and
    // height show exactly as any other measured line's do.
    const estimate =
      line.est_width_tmm === null
        ? this.t().order.sizeAreaSqft(exactRationalToFixed(line.direct_area_sqft))
        : (() => {
            const width = feet(line.est_width_tmm);
            const height = feet(line.est_height_tmm);
            return height === null ? `${width}ft` : `${width} × ${height}ft`;
          })();

    if (!line.is_site_measured) return this.t().order.sizeEstimate(estimate);

    const fw = feet(line.final_width_tmm);
    const fh = feet(line.final_height_tmm);
    const measured = fh === null ? `${fw}ft` : `${fw} × ${fh}ft`;
    return this.t().order.sizeMeasured(estimate, measured);
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
    const words = this.t().buyer;
    switch (missing) {
      case 'name':
        return words.missingName;
      case 'identifier':
        return words.missingIdentifier;
      default:
        return words.missingAddress;
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
    if (d.buyer?.einvoice_requested) return this.t().buyer.whyRequested;
    const total = d.order.estimate_total_sen;
    if (total >= 1_000_000) return this.t().buyer.whyOverThreshold;
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
          this.buyerFailure.set(result.refused_because);
          return;
        }
        this.editingBuyer.set(false);
        this.buyerNote.set(result.complete ? 'complete' : 'incomplete');
        // Reload rather than patch what is on screen: the server merged this
        // into whatever else has landed, and only it knows the result.
        this.load();
      },
      error: () => {
        this.savingBuyer.set(false);
        this.buyerFailure.set('error');
      },
    });
  }

  /**
   * Manual allocation, from the order line it belongs to. SPEC.md §11 Phase
   * 9's own named gap: `POST /api/allocations` already exists and is tested
   * -- for a material with no exact auto-proposal conversion (§13 F3), or a
   * manual split across a second lot -- and this is its natural home,
   * where an admin is already looking at the line and its material.
   *
   * Materials are fetched lazily, on the first line where the form is
   * opened: most orders (curtains, blinds) are never inventory-tracked, and
   * a screen opened on every order should not fetch a list it will almost
   * never use.
   */
  protected readonly allocatingLineId = signal<string | null>(null);
  protected readonly materials = signal<readonly MaterialOut[]>([]);
  protected readonly materialsLoaded = signal(false);
  protected readonly lotsByMaterial = signal<
    Readonly<Record<string, readonly StockLotOut[]>>
  >({});
  protected readonly allocateMaterialId = signal('');
  protected readonly allocateLotId = signal('');
  protected readonly allocateQty = signal('');
  protected readonly savingAllocation = signal(false);
  protected readonly allocationFailure = signal<Failure | null>(null);
  protected readonly allocationNote = signal<string | null>(null);

  protected allocationMessage(failure: Failure): string {
    return commonMessage(this.t(), failure);
  }

  protected materialName(material: MaterialOut): string {
    return material.names[this.text.language()] ?? material.code;
  }

  protected openAllocate(line: OrderLineOut): void {
    this.allocatingLineId.set(line.id);
    this.allocateMaterialId.set('');
    this.allocateLotId.set('');
    this.allocateQty.set('');
    this.allocationFailure.set(null);
    this.allocationNote.set(null);
    if (!this.materialsLoaded()) {
      this.api.materials(true).subscribe({
        next: (out) => {
          this.materials.set(out.materials);
          this.materialsLoaded.set(true);
        },
        error: (err: unknown) => this.allocationFailure.set(failureOf(err)),
      });
    }
  }

  protected cancelAllocate(): void {
    this.allocatingLineId.set(null);
    this.allocationFailure.set(null);
  }

  protected setAllocateMaterial(materialId: string): void {
    this.allocateMaterialId.set(materialId);
    this.allocateLotId.set('');
    if (materialId) this.loadLotsFor(materialId, false);
  }

  /** `force` bypasses the cache -- used after an allocation decrements a
   * lot, so opening the control again for the same material doesn't keep
   * showing the now-stale quantity. */
  private loadLotsFor(materialId: string, force: boolean): void {
    if (!force && this.lotsByMaterial()[materialId]) return;
    this.api.stockLots(materialId).subscribe({
      next: (out) =>
        this.lotsByMaterial.update((m) => ({ ...m, [materialId]: out.lots })),
      error: (err: unknown) => this.allocationFailure.set(failureOf(err)),
    });
  }

  protected setAllocateLot(lotId: string): void {
    this.allocateLotId.set(lotId);
  }

  protected setAllocateQty(value: string): void {
    this.allocateQty.set(value);
  }

  protected lotsForSelectedMaterial(): readonly StockLotOut[] {
    return this.lotsByMaterial()[this.allocateMaterialId()] ?? [];
  }

  protected readonly canSubmitAllocate = computed(
    () =>
      !this.savingAllocation() &&
      this.allocateMaterialId().length > 0 &&
      this.allocateLotId().length > 0 &&
      this.allocateQty().trim().length > 0,
  );

  protected submitAllocate(line: OrderLineOut, event: Event): void {
    event.preventDefault();
    if (!this.canSubmitAllocate()) return;
    const order = this.detail()?.order;
    if (order === undefined) return;

    this.savingAllocation.set(true);
    this.allocationFailure.set(null);
    this.allocationNote.set(null);

    const materialId = this.allocateMaterialId();

    this.api
      .createManualAllocation({
        order_line_id: line.id,
        order_id: order.id,
        material_id: materialId,
        lot_id: this.allocateLotId(),
        qty: this.allocateQty().trim(),
      })
      .subscribe({
        next: () => {
          this.savingAllocation.set(false);
          this.allocatingLineId.set(null);
          this.allocationNote.set(line.id);
          // This just decremented the lot's qty_on_hand. Opening the
          // control again for the same material -- this line or another
          // -- must not keep showing the figure from before it moved.
          this.loadLotsFor(materialId, true);
          // Reload rather than patch what is on screen: the new allocation
          // itself now shows against the line, the same "let the server
          // say what happened" rule the buyer form already follows.
          this.load();
        },
        error: (err: unknown) => {
          this.savingAllocation.set(false);
          this.allocationFailure.set(failureOf(err));
        },
      });
  }

  /**
   * What is already claimed against this line -- SPEC.md §11 Phase 9's own
   * named gap. Rejected allocations are left off: they are the allocation
   * review queue's own history, not a fact about the line today.
   */
  protected allocationsFor(line: OrderLineOut): readonly AllocationOut[] {
    return (this.detail()?.allocations ?? []).filter(
      (a) => a.order_line_id === line.id && a.status !== 'rejected',
    );
  }

  protected readonly releasingId = signal<string | null>(null);
  protected readonly releaseFailure = signal<Failure | null>(null);

  protected releaseMessage(failure: Failure): string {
    return commonMessage(this.t(), failure);
  }

  protected allocationStatusLabel(allocation: AllocationOut): string {
    const words = this.t().inventory;
    switch (allocation.status) {
      case 'proposed':
        return words.allocationStatusProposed;
      case 'approved':
        return words.allocationStatusApproved;
      case 'released':
        return words.allocationStatusReleased;
      default:
        return allocation.status;
    }
  }

  /**
   * An order cancelled after stock was set aside for it. `POST /api/
   * allocations/{id}/release` already existed, tested, with no way to
   * reach it -- this is that control's home, next to the allocation it
   * undoes.
   */
  protected release(allocation: AllocationOut): void {
    if (this.releasingId() !== null) return;

    this.releasingId.set(allocation.id);
    this.releaseFailure.set(null);

    this.api.releaseAllocation(allocation.id).subscribe({
      next: () => {
        this.releasingId.set(null);
        this.load();
      },
      error: (err: unknown) => {
        this.releasingId.set(null);
        this.releaseFailure.set(failureOf(err));
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
    return this.t().order.basis(
      line.billed_qty,
      line.billed_unit,
      this.money(line.rate_sen),
      band,
      line.applied_rate_card_version,
      discount,
    );
  }
}


