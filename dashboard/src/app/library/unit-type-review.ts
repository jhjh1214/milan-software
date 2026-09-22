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
import { Component, computed, DestroyRef, inject, signal } from '@angular/core';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { ThinkingDots } from '../shared/thinking-dots';
import type {
  FloorPlanOut,
  OpeningOut,
  RecognitionJobOut,
  RoomOut,
  UnitTypeWithVersionsOut,
} from '../api/types';

/** How often to check on a background recognition job. Not urgent -- an
 * admin who started one is not staring at the screen the way a fair's own
 * quoting would be, so a few seconds either way costs nothing. */
const RECOGNITION_POLL_MS = 3000;

/** A point clicked on the floor plan image, in the image's own natural pixels. */
interface CalibrationPoint {
  readonly x: number;
  readonly y: number;
}

/** What just happened, before it becomes a sentence in the reader's language. */
type Note =
  | { readonly kind: 'approved'; readonly name: string }
  | { readonly kind: 'rejected'; readonly name: string }
  | { readonly kind: 'bulkApproved'; readonly approved: number; readonly failed: number };

@Component({
  selector: 'app-unit-type-review',
  imports: [CommonModule, ThinkingDots],
  templateUrl: './unit-type-review.html',
  styleUrl: './unit-type-review.css',
})
export class UnitTypeReview {
  private readonly api = inject(Api);

  private readonly clearPollTimers = inject(DestroyRef).onDestroy(() => {
    for (const timer of this.pollTimers.values()) clearTimeout(timer);
  });

  protected readonly items = signal<readonly UnitTypeWithVersionsOut[]>([]);
  protected readonly loading = signal(false);
  protected readonly failure = signal<Failure | null>(null);
  protected readonly note = signal<Note | null>(null);

  /**
   * The shell a unit type lives under. `POST /api/projects` already
   * existed and was tested; nothing anywhere -- neither client -- could
   * reach it. A part-timer's own device can only ever pick from a project
   * it has already seen with a connection in hand, never create one, so
   * without this control the very first project in a new area has nowhere
   * to come from.
   */
  protected readonly addingProject = signal(false);
  protected readonly projectName = signal('');
  protected readonly projectDeveloper = signal('');
  protected readonly projectArea = signal('');
  protected readonly savingProject = signal(false);
  protected readonly projectFailure = signal<Failure | null>(null);
  protected readonly projectNote = signal<string | null>(null);

  protected readonly canAddProject = computed(
    () => !this.savingProject() && this.projectName().trim().length > 0,
  );

  /** Ids currently mid-request -- a set rather than one id, so a bulk
   * approve and a single row's own action never fight over one flag. */
  protected readonly acting = signal<ReadonlySet<string>>(new Set());
  /** The id whose reject form is open, and what has been typed into it. */
  protected readonly rejectingId = signal<string | null>(null);
  protected readonly reason = signal('');

  protected readonly canSendBack = computed(
    () => this.reason().trim().length > 0 && this.acting().size === 0,
  );

  /** Rows an admin has ticked for a bulk approve. Orthogonal to `acting`:
   * selecting is a separate step from a request being in flight. */
  protected readonly selected = signal<ReadonlySet<string>>(new Set());

  protected readonly canBulkApprove = computed(
    () => this.selected().size > 0 && this.acting().size === 0,
  );

  protected readonly allSelected = computed(
    () => this.items().length > 0 && this.selected().size === this.items().length,
  );

  protected isSelected(item: UnitTypeWithVersionsOut): boolean {
    return this.selected().has(item.id);
  }

  protected toggleSelect(item: UnitTypeWithVersionsOut): void {
    this.selected.update((s) => {
      const next = new Set(s);
      if (next.has(item.id)) next.delete(item.id);
      else next.add(item.id);
      return next;
    });
  }

  protected toggleSelectAll(): void {
    this.selected.set(this.allSelected() ? new Set() : new Set(this.items().map((i) => i.id)));
  }

  /** The unit type id currently mid-upload. */
  protected readonly uploading = signal<string | null>(null);
  /** Floor plan id -> an object URL for its image, fetched once and kept. */
  protected readonly imageUrls = signal<Readonly<Record<string, string>>>({});
  /** The floor plan id currently being calibrated, if any. */
  protected readonly calibrating = signal<string | null>(null);
  protected readonly calibPoints = signal<readonly CalibrationPoint[]>([]);
  protected readonly realDistance = signal('');
  protected readonly calibError = signal<string | null>(null);

  /** Floor plan id -> the background recognition job last known for it, or
   * the failure that stopped one starting. SPEC.md Phase 8, "Future:
   * assisted digitisation" -- a proposal is display-only: there is no form
   * on this screen it can prefill, only the reviewer's own reading of the
   * submission. Runs in the background rather than blocking this screen
   * (unlike the handset's own "try recognition", which needs an answer
   * while someone is standing at a fair table) because nobody reviewing an
   * upload here is waiting on it the same way -- a locally hosted model on
   * modest hardware can take several minutes, and this screen should stay
   * usable for everything else while one runs. */
  protected readonly recognitionJobs = signal<Readonly<Record<string, RecognitionJobOut>>>(
    {},
  );
  protected readonly recognizeFailed = signal<string | null>(null);
  /** Floor plan id -> the timer for its next poll, so a component destroyed
   * mid-poll (navigating away) does not keep calling the server. */
  private readonly pollTimers = new Map<string, ReturnType<typeof setTimeout>>();

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
    if (this.acting().size > 0) return;
    this.acting.set(new Set([item.id]));
    this.failure.set(null);

    this.api.approveUnitType(item.id).subscribe({
      next: () => {
        this.acting.set(new Set());
        this.items.set(this.items().filter((i) => i.id !== item.id));
        this.note.set({ kind: 'approved', name: this.label(item) });
      },
      error: (err: unknown) => {
        this.acting.set(new Set());
        this.failure.set(failureOf(err));
      },
    });
  }

  /**
   * Approves every selected row in one request. One bad id in the batch
   * never sinks the rest -- the server reports each id's own outcome, so a
   * row that failed stays visible and selected for the admin to handle
   * individually, and everything that succeeded leaves the queue.
   */
  protected bulkApprove(): void {
    if (!this.canBulkApprove()) return;
    const ids = [...this.selected()];
    this.acting.set(new Set(ids));
    this.failure.set(null);

    this.api.bulkApproveUnitTypes(ids).subscribe({
      next: (out) => {
        this.acting.set(new Set());
        const okIds = new Set(out.results.filter((r) => r.ok).map((r) => r.unit_type_id));
        const failedIds = new Set(
          out.results.filter((r) => !r.ok).map((r) => r.unit_type_id),
        );
        this.items.set(this.items().filter((i) => !okIds.has(i.id)));
        this.selected.set(failedIds);
        this.note.set({
          kind: 'bulkApproved',
          approved: okIds.size,
          failed: failedIds.size,
        });
      },
      error: (err: unknown) => {
        this.acting.set(new Set());
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
    this.acting.set(new Set([item.id]));
    this.failure.set(null);

    this.api.rejectUnitType(item.id, this.reason().trim()).subscribe({
      next: () => {
        this.acting.set(new Set());
        this.rejectingId.set(null);
        this.reason.set('');
        this.items.set(this.items().filter((i) => i.id !== item.id));
        this.note.set({ kind: 'rejected', name: this.label(item) });
      },
      error: (err: unknown) => {
        this.acting.set(new Set());
        this.failure.set(failureOf(err));
      },
    });
  }

  protected noteText(note: Note): string {
    const words = this.t().library;
    if (note.kind === 'approved') return words.approvedNote(note.name);
    if (note.kind === 'rejected') return words.rejectedNote(note.name);
    return words.bulkApprovedNote(note.approved, note.failed);
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

  protected openAddProject(): void {
    this.addingProject.set(true);
    this.projectName.set('');
    this.projectDeveloper.set('');
    this.projectArea.set('');
    this.projectFailure.set(null);
    this.projectNote.set(null);
  }

  protected cancelAddProject(): void {
    this.addingProject.set(false);
  }

  protected submitAddProject(event: Event): void {
    event.preventDefault();
    this.addProject();
  }

  protected addProject(): void {
    if (!this.canAddProject()) return;
    this.savingProject.set(true);
    this.projectFailure.set(null);

    this.api
      .createProject({
        name: this.projectName().trim(),
        developer: this.projectDeveloper().trim() || null,
        area: this.projectArea().trim() || null,
      })
      .subscribe({
        next: (project) => {
          this.savingProject.set(false);
          this.addingProject.set(false);
          this.projectNote.set(project.name);
        },
        error: (err: unknown) => {
          this.savingProject.set(false);
          this.projectFailure.set(failureOf(err));
        },
      });
  }

  protected recognitionJobFor(floorPlanId: string): RecognitionJobOut | null {
    return this.recognitionJobs()[floorPlanId] ?? null;
  }

  /** Starts recognition in the background and returns immediately -- never
   * writes anything, and the result (once ready) is shown beside the
   * submission for the reviewer to read, not applied to any field
   * automatically, the same as `/api/recognize`'s own synchronous contract.
   */
  protected startRecognition(floorPlan: FloorPlanOut): void {
    this.recognizeFailed.set(null);
    this.api.startRecognitionJob(floorPlan.id).subscribe({
      next: (job) => {
        this.recognitionJobs.update((m) => ({ ...m, [floorPlan.id]: job }));
        this.pollRecognition(floorPlan.id);
      },
      error: () => this.recognizeFailed.set(floorPlan.id),
    });
  }

  private pollRecognition(floorPlanId: string): void {
    this.api.recognitionJob(floorPlanId).subscribe({
      next: (job) => {
        this.recognitionJobs.update((m) => ({ ...m, [floorPlanId]: job }));
        if (job.status === 'pending') {
          this.pollTimers.set(
            floorPlanId,
            setTimeout(() => this.pollRecognition(floorPlanId), RECOGNITION_POLL_MS),
          );
        } else {
          this.pollTimers.delete(floorPlanId);
        }
      },
      error: () => {
        this.recognizeFailed.set(floorPlanId);
        this.pollTimers.delete(floorPlanId);
      },
    });
  }
}
