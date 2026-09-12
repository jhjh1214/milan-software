/**
 * Materials, lots and the ledger. SPEC.md Phase 9.
 *
 * Admin-only, server-enforced -- §13 F2's own answer names the office's
 * purchasing/supplier-ordering person as the one accountable for every
 * movement, and every write here lands on the same role that already owns
 * rate cards, overrides and exports.
 *
 * A material row expands to its lots, a receive-stock form, and a reorder
 * alert if it has one -- one screen, because a material with no stock and a
 * material about to run out are the same conversation with whoever is
 * standing at this desk.
 *
 * Every field is a signal. A plain field read inside a `computed` never
 * recomputes, which has bitten this codebase twice before.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import type { MaterialOut, ReorderAlertOut, StockLotOut } from '../api/types';

const UOMS = ['metre', 'sqft', 'box', 'piece', 'roll'] as const;

@Component({
  selector: 'app-materials',
  imports: [CommonModule],
  templateUrl: './materials.html',
  styleUrl: './materials.css',
})
export class Materials {
  private readonly api = inject(Api);

  protected readonly uoms = UOMS;

  protected readonly materials = signal<readonly MaterialOut[]>([]);
  protected readonly alerts = signal<readonly ReorderAlertOut[]>([]);
  protected readonly loading = signal(false);
  protected readonly failure = signal<Failure | null>(null);
  protected readonly note = signal<string | null>(null);
  protected readonly saving = signal(false);

  /** The words, as a signal: switching language re-renders the screen. */
  protected readonly t = inject(Text).strings;

  protected readonly alertByMaterial = computed(() => {
    const map: Record<string, ReorderAlertOut | undefined> = {};
    for (const alert of this.alerts()) map[alert.material.id] = alert;
    return map;
  });

  // --- the add-material form ---
  protected readonly adding = signal(false);
  protected readonly family = signal('');
  protected readonly code = signal('');
  protected readonly nameZh = signal('');
  protected readonly nameEn = signal('');
  protected readonly nameMs = signal('');
  protected readonly uom = signal<(typeof UOMS)[number]>('box');
  protected readonly coveragePerUnit = signal('');
  protected readonly reorderLevel = signal('');

  protected readonly canAdd = computed(
    () =>
      !this.saving() &&
      this.family().trim().length > 0 &&
      this.code().trim().length > 0 &&
      this.nameZh().trim().length > 0 &&
      this.nameEn().trim().length > 0 &&
      this.nameMs().trim().length > 0,
  );

  // --- per-material: expanded lots + receive-stock form ---
  protected readonly expanded = signal<string | null>(null);
  protected readonly lotsByMaterial = signal<Readonly<Record<string, readonly StockLotOut[]>>>(
    {},
  );
  protected readonly lotRef = signal('');
  protected readonly receiveQty = signal('');
  protected readonly costRm = signal('');
  protected readonly location = signal('');

  protected readonly canReceive = computed(
    () => !this.saving() && this.lotRef().trim().length > 0 && this.receiveQty().trim().length > 0,
  );

  constructor() {
    this.load();
  }

  private load(): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.materials().subscribe({
      next: (out) => {
        this.materials.set(out.materials);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.materials.set([]);
        this.failure.set(failureOf(err));
        this.loading.set(false);
      },
    });
    this.api.reorderAlerts().subscribe({
      next: (out) => this.alerts.set(out.alerts),
      error: () => {
        // The materials list is the main content; a failed alerts fetch is
        // shown as no alerts rather than blocking the whole screen.
      },
    });
  }

  protected retry(): void {
    this.load();
  }

  protected uomLabel(uom: string): string {
    const words = this.t().inventory;
    switch (uom) {
      case 'metre':
        return words.uomMetre;
      case 'sqft':
        return words.uomSqft;
      case 'box':
        return words.uomBox;
      case 'piece':
        return words.uomPiece;
      case 'roll':
        return words.uomRoll;
      default:
        return uom;
    }
  }

  protected message(failure: Failure): string {
    if (failure.status === 409) return this.t().inventory.duplicateCode;
    return commonMessage(this.t(), failure);
  }

  protected openAdd(): void {
    this.adding.set(true);
    this.note.set(null);
    this.failure.set(null);
  }

  protected cancelAdd(): void {
    this.adding.set(false);
    this.family.set('');
    this.code.set('');
    this.nameZh.set('');
    this.nameEn.set('');
    this.nameMs.set('');
    this.coveragePerUnit.set('');
    this.reorderLevel.set('');
  }

  protected submitAdd(event: Event): void {
    event.preventDefault();
    this.add();
  }

  protected add(): void {
    if (!this.canAdd()) return;
    this.failure.set(null);
    this.saving.set(true);

    this.api
      .createMaterial({
        family: this.family().trim(),
        variant_compat: [],
        code: this.code().trim(),
        names: {
          zh: this.nameZh().trim(),
          en: this.nameEn().trim(),
          ms: this.nameMs().trim(),
        },
        uom: this.uom(),
        coverage_per_unit: this.coveragePerUnit().trim() || null,
        reorder_level: this.reorderLevel().trim() || null,
      })
      .subscribe({
        next: () => {
          this.saving.set(false);
          this.cancelAdd();
          this.load();
        },
        error: (err: unknown) => {
          this.saving.set(false);
          this.failure.set(failureOf(err));
        },
      });
  }

  protected deactivate(material: MaterialOut): void {
    if (this.saving()) return;
    this.saving.set(true);
    this.api.deactivateMaterial(material.id).subscribe({
      next: () => {
        this.saving.set(false);
        this.note.set(material.code);
        this.load();
      },
      error: (err: unknown) => {
        this.saving.set(false);
        this.failure.set(failureOf(err));
      },
    });
  }

  protected lotsFor(material: MaterialOut): readonly StockLotOut[] {
    return this.lotsByMaterial()[material.id] ?? [];
  }

  protected toggleExpand(material: MaterialOut): void {
    if (this.expanded() === material.id) {
      this.expanded.set(null);
      return;
    }
    this.expanded.set(material.id);
    this.lotRef.set('');
    this.receiveQty.set('');
    this.costRm.set('');
    this.location.set('');
    this.loadLots(material.id);
  }

  private loadLots(materialId: string): void {
    this.api.stockLots(materialId).subscribe({
      next: (out) =>
        this.lotsByMaterial.update((m) => ({ ...m, [materialId]: out.lots })),
      error: (err: unknown) => this.failure.set(failureOf(err)),
    });
  }

  protected submitReceive(materialId: string, event: Event): void {
    event.preventDefault();
    this.receive(materialId);
  }

  protected receive(materialId: string): void {
    if (!this.canReceive()) return;
    this.failure.set(null);
    this.saving.set(true);

    const rm = Number(this.costRm());
    this.api
      .receiveStock({
        material_id: materialId,
        lot_ref: this.lotRef().trim(),
        qty: this.receiveQty().trim(),
        cost_sen: Number.isFinite(rm) && this.costRm().trim() ? Math.round(rm * 100) : null,
        location: this.location().trim() || null,
      })
      .subscribe({
        next: () => {
          this.saving.set(false);
          this.lotRef.set('');
          this.receiveQty.set('');
          this.costRm.set('');
          this.location.set('');
          this.loadLots(materialId);
          this.load();
        },
        error: (err: unknown) => {
          this.saving.set(false);
          this.failure.set(failureOf(err));
        },
      });
  }
}
