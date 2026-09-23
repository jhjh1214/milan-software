/**
 * What needs attention right now, composed from what the dashboard already
 * fetches elsewhere -- no new backend read beyond what each linked screen
 * already calls. Signing in used to drop straight into Orders; this is the
 * landing page that answers "what should I look at first" before that.
 *
 * Each stat is its own independent fetch with its own loading state, so a
 * slow one (the measurement queue, open to everyone) never holds up a fast
 * one (an admin-only count) behind it.
 *
 * Admin-only stats (pending library reviews, pending allocations) are
 * fetched only for an admin -- hidden rather than shown and refused, the
 * same rule the sidebar itself already follows.
 */

import { CommonModule } from '@angular/common';
import { Component, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';

import { Api } from '../api/api';
import { Session } from '../auth/session';
import { Text } from '../i18n/text';

@Component({
  selector: 'app-home',
  imports: [CommonModule, RouterLink],
  templateUrl: './home.html',
  styleUrl: './home.css',
})
export class Home {
  private readonly api = inject(Api);
  protected readonly session = inject(Session);
  protected readonly t = inject(Text).strings;

  /** `null` while loading or on failure -- a stat that could not be fetched
   * shows as "-", never a fabricated 0 that reads as genuinely zero. */
  protected readonly measurementCount = signal<number | null>(null);
  protected readonly measurementLoading = signal(true);

  protected readonly pendingReviewCount = signal<number | null>(null);
  protected readonly pendingReviewLoading = signal(this.session.isAdmin());

  protected readonly pendingAllocationCount = signal<number | null>(null);
  protected readonly pendingAllocationLoading = signal(this.session.isAdmin());

  constructor() {
    this.api.measurementQueue().subscribe({
      next: (out) => {
        this.measurementCount.set(out.total_orders);
        this.measurementLoading.set(false);
      },
      error: () => this.measurementLoading.set(false),
    });

    if (this.session.isAdmin()) {
      this.api.unitTypes('pending_review').subscribe({
        next: (out) => {
          this.pendingReviewCount.set(out.unit_types.length);
          this.pendingReviewLoading.set(false);
        },
        error: () => this.pendingReviewLoading.set(false),
      });

      this.api.allocations().subscribe({
        next: (out) => {
          this.pendingAllocationCount.set(out.allocations.length);
          this.pendingAllocationLoading.set(false);
        },
        error: () => this.pendingAllocationLoading.set(false),
      });
    }
  }
}
