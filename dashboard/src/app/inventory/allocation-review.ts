/**
 * Stock waiting on an admin's decision. SPEC.md Phase 9.
 *
 * > Two routes to `approved`, the same one-gate shape the property library
 * > already uses: an auto-proposable material lands here `proposed` from
 * > `push_measurement`'s own hook and waits for an admin.
 *
 * Mirrors `unit-type-review.ts`'s own ethos -- the whole control is on this
 * screen being read. Approving or rejecting removes the row from the
 * queue; a reject cannot be sent with an empty reason, the same rule the
 * library's own reviewer already follows.
 *
 * Every field is a signal. A plain field read inside a `computed` never
 * recomputes, which has bitten this codebase twice before.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import type { AllocationOut, MaterialOut, StockLotOut } from '../api/types';

@Component({
  selector: 'app-allocation-review',
  imports: [CommonModule],
  templateUrl: './allocation-review.html',
  styleUrl: './allocation-review.css',
})
export class AllocationReview {
  private readonly api = inject(Api);

  protected readonly items = signal<readonly AllocationOut[]>([]);
  protected readonly materialsById = signal<Readonly<Record<string, MaterialOut>>>({});
  protected readonly loading = signal(false);
  protected readonly failure = signal<Failure | null>(null);
  protected readonly note = signal<'approved' | 'rejected' | null>(null);

  /** The id currently mid-request, so a double click cannot fire twice. */
  protected readonly acting = signal<string | null>(null);
  /** The id whose reject form is open, and what has been typed into it. */
  protected readonly rejectingId = signal<string | null>(null);
  protected readonly reason = signal('');

  /** Lots fetched on demand for an allocation the auto-proposal could not
   * pick a single lot for -- §13 F3's "no single lot covers it" case. */
  protected readonly lotsByMaterial = signal<Readonly<Record<string, readonly StockLotOut[]>>>(
    {},
  );
  protected readonly pickedLot = signal<Readonly<Record<string, string>>>({});

  private readonly text = inject(Text);
  protected readonly t = this.text.strings;

  protected readonly canSendBack = computed(
    () => this.reason().trim().length > 0 && this.acting() === null,
  );

  constructor() {
    this.load();
  }

  private load(): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.allocations('proposed').subscribe({
      next: (out) => {
        this.items.set(out.allocations);
        this.loading.set(false);
        for (const item of out.allocations) {
          if (item.lot_id === null) this.loadLots(item.material_id);
        }
      },
      error: (err: unknown) => {
        this.items.set([]);
        this.failure.set(failureOf(err));
        this.loading.set(false);
      },
    });
    this.api.materials(false).subscribe({
      next: (out) => {
        const map: Record<string, MaterialOut> = {};
        for (const m of out.materials) map[m.id] = m;
        this.materialsById.set(map);
      },
      error: () => {
        // The queue itself is the main content; a missing material name
        // degrades to showing its id rather than blocking the screen.
      },
    });
  }

  protected retry(): void {
    this.load();
  }

  protected message(failure: Failure): string {
    return commonMessage(this.t(), failure);
  }

  protected materialName(item: AllocationOut): string {
    const material = this.materialsById()[item.material_id];
    if (material === undefined) return item.material_id;
    return material.names[this.text.language()] ?? material.code;
  }

  private loadLots(materialId: string): void {
    if (this.lotsByMaterial()[materialId]) return;
    this.api.stockLots(materialId).subscribe({
      next: (out) =>
        this.lotsByMaterial.update((m) => ({ ...m, [materialId]: out.lots })),
      error: () => {
        // Shown as "no lot to pick from yet" rather than a page failure.
      },
    });
  }

  protected lotsFor(item: AllocationOut): readonly StockLotOut[] {
    return this.lotsByMaterial()[item.material_id] ?? [];
  }

  protected setPickedLot(item: AllocationOut, lotId: string): void {
    this.pickedLot.update((m) => ({ ...m, [item.id]: lotId }));
  }

  protected readonly canApprove = (item: AllocationOut): boolean =>
    this.acting() === null && (item.lot_id !== null || !!this.pickedLot()[item.id]);

  protected approve(item: AllocationOut): void {
    if (!this.canApprove(item)) return;
    this.acting.set(item.id);
    this.failure.set(null);

    this.api.approveAllocation(item.id, this.pickedLot()[item.id] ?? null).subscribe({
      next: () => {
        this.acting.set(null);
        this.items.set(this.items().filter((i) => i.id !== item.id));
        this.note.set('approved');
      },
      error: (err: unknown) => {
        this.acting.set(null);
        this.failure.set(failureOf(err));
      },
    });
  }

  protected startRejecting(item: AllocationOut): void {
    this.rejectingId.set(item.id);
    this.reason.set('');
    this.note.set(null);
  }

  protected cancelRejecting(): void {
    this.rejectingId.set(null);
    this.reason.set('');
  }

  protected confirmReject(item: AllocationOut): void {
    if (!this.canSendBack()) return;
    this.acting.set(item.id);
    this.failure.set(null);

    this.api.rejectAllocation(item.id, this.reason().trim()).subscribe({
      next: () => {
        this.acting.set(null);
        this.rejectingId.set(null);
        this.reason.set('');
        this.items.set(this.items().filter((i) => i.id !== item.id));
        this.note.set('rejected');
      },
      error: (err: unknown) => {
        this.acting.set(null);
        this.failure.set(failureOf(err));
      },
    });
  }
}
