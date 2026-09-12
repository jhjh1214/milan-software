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
import type {
  FloorPlanOut,
  OpeningOut,
  RoomOut,
  UnitTypeWithVersionsOut,
} from '../api/types';

/** A point clicked on the floor plan image, in the image's own natural pixels. */
interface CalibrationPoint {
  readonly x: number;
  readonly y: number;
}

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

  /** The unit type id currently mid-upload. */
  protected readonly uploading = signal<string | null>(null);
  /** Floor plan id -> an object URL for its image, fetched once and kept. */
  protected readonly imageUrls = signal<Readonly<Record<string, string>>>({});
  /** The floor plan id currently being calibrated, if any. */
  protected readonly calibrating = signal<string | null>(null);
  protected readonly calibPoints = signal<readonly CalibrationPoint[]>([]);
  protected readonly realDistance = signal('');
  protected readonly calibError = signal<string | null>(null);

  /** Straight-line pixel distance between the two clicked points, rounded --
   * the one place this screen uses `sqrt`. The server never does: it takes
   * this as a plain integer and keeps its own arithmetic exactly rational. */
  protected readonly pixelDistance = computed<number | null>(() => {
    const pts = this.calibPoints();
    if (pts.length !== 2) return null;
    const dx = pts[1].x - pts[0].x;
    const dy = pts[1].y - pts[0].y;
    return Math.round(Math.sqrt(dx * dx + dy * dy));
  });

  protected readonly canConfirmCalibration = computed(() => {
    const px = this.pixelDistance();
    const mm = Number(this.realDistance());
    return px !== null && px > 0 && Number.isFinite(mm) && mm > 0;
  });

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
        for (const item of out.unit_types) {
          const plan = this.latestVersion(item)?.floor_plan;
          if (plan) this.loadImage(plan.id);
        }
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

  protected floorPlan(item: UnitTypeWithVersionsOut): FloorPlanOut | null {
    return this.latestVersion(item)?.floor_plan ?? null;
  }

  protected imageUrl(floorPlanId: string): string | null {
    return this.imageUrls()[floorPlanId] ?? null;
  }

  private loadImage(floorPlanId: string): void {
    if (this.imageUrls()[floorPlanId]) return;
    this.api.floorPlanImage(floorPlanId).subscribe({
      next: (blob) => {
        const url = URL.createObjectURL(blob);
        this.imageUrls.update((m) => ({ ...m, [floorPlanId]: url }));
      },
      error: () => {
        // The queue's own failure banner is for the list itself; a single
        // image failing to load is shown as no image, not a page error.
      },
    });
  }

  private replaceFloorPlan(item: UnitTypeWithVersionsOut, plan: FloorPlanOut): void {
    this.items.set(
      this.items().map((i) => {
        if (i.id !== item.id) return i;
        const versions = i.versions.map((v, idx) =>
          idx === i.versions.length - 1 ? { ...v, floor_plan: plan } : v,
        );
        return { ...i, versions };
      }),
    );
    this.loadImage(plan.id);
  }

  protected onFileSelected(item: UnitTypeWithVersionsOut, event: Event): void {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0] ?? null;
    input.value = '';
    if (file === null) return;

    this.uploading.set(item.id);
    this.failure.set(null);
    this.api.uploadFloorPlan(item.id, file).subscribe({
      next: (plan) => {
        this.uploading.set(null);
        this.replaceFloorPlan(item, plan);
      },
      error: (err: unknown) => {
        this.uploading.set(null);
        this.failure.set(failureOf(err));
      },
    });
  }

  protected startCalibrating(floorPlanId: string): void {
    this.calibrating.set(floorPlanId);
    this.calibPoints.set([]);
    this.realDistance.set('');
    this.calibError.set(null);
  }

  protected cancelCalibrating(): void {
    this.calibrating.set(null);
    this.calibPoints.set([]);
    this.realDistance.set('');
    this.calibError.set(null);
  }

  /** A click on the floor plan image while calibrating it. Coordinates are
   * converted to the image's own natural pixels, so the scale this produces
   * means the same thing regardless of how large the browser rendered it. */
  protected onImageClick(event: MouseEvent, floorPlanId: string): void {
    if (this.calibrating() !== floorPlanId) return;
    if (this.calibPoints().length >= 2) return;

    const img = event.currentTarget as HTMLImageElement;
    const rect = img.getBoundingClientRect();
    const scaleX = img.naturalWidth / rect.width;
    const scaleY = img.naturalHeight / rect.height;
    const point: CalibrationPoint = {
      x: (event.clientX - rect.left) * scaleX,
      y: (event.clientY - rect.top) * scaleY,
    };
    this.calibPoints.set([...this.calibPoints(), point]);
  }

  protected confirmCalibration(item: UnitTypeWithVersionsOut): void {
    const floorPlanId = this.calibrating();
    const pixelDistance = this.pixelDistance();
    const mm = Number(this.realDistance());
    if (floorPlanId === null || pixelDistance === null) return;
    if (!Number.isFinite(mm) || mm <= 0) return;

    this.calibError.set(null);
    // The one place a millimetre value is converted to tenths: the boundary
    // between what an admin types and what the server ever stores.
    const realDistanceTmm = Math.round(mm * 10);
    this.api.calibrateFloorPlan(floorPlanId, pixelDistance, realDistanceTmm).subscribe({
      next: (plan) => {
        this.replaceFloorPlan(item, plan);
        this.cancelCalibrating();
      },
      error: (err: unknown) => {
        this.calibError.set(this.message(failureOf(err)));
      },
    });
  }
}
