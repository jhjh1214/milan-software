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
 */

import { CommonModule } from '@angular/common';
import { Component, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';

import { Api } from '../api/api';
import { formatDate, formatSen, urgencyOf, type Urgency } from '../api/money';
import type { BuyerOut, OrderDetailOut, OrderLineOut } from '../api/types';

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
