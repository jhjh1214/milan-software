/**
 * Signing in to the dashboard. SPEC.md §12.
 *
 * Phone plus PIN, the same credentials the handsets use — there is no separate
 * office account, so a leaver is deactivated once and is out of everything.
 *
 * No roster to pick a name from. A staff list on a sign-in screen hands the
 * staff list to anyone who opens it, and the same reasoning that keeps it off
 * the handset keeps it off a browser on a desk people walk past.
 */

import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';

import { Session, type SignInFailure } from './session';

const MESSAGES: Record<SignInFailure, string> = {
  // Never says which of the two was wrong. Saying "no such phone" tells
  // somebody holding a stolen handset which numbers are real.
  wrong: 'That phone and PIN do not match.',
  // §12: the throttle backs off but never locks out, so this is "wait", never
  // "you are locked out" — somebody mid-shift has to be able to get back in.
  throttled: 'Too many tries. Wait a moment and try again.',
  offline: 'No answer from the server.',
  server: 'Something went wrong signing in.',
};

@Component({
  selector: 'app-sign-in',
  imports: [FormsModule],
  templateUrl: './sign-in.html',
  styleUrl: './sign-in.css',
})
export class SignIn {
  private readonly session = inject(Session);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected phone = '';
  protected pin = '';

  protected readonly busy = signal(false);
  protected readonly failure = signal<string | null>(null);

  protected async submit(): Promise<void> {
    if (this.busy()) return;

    this.busy.set(true);
    this.failure.set(null);

    const failed = await this.session.signIn(this.phone.trim(), this.pin);
    this.busy.set(false);

    if (failed === null) {
      // The PIN does not stay in a field behind a route change.
      this.pin = '';
      // Back to where they were headed, so a colleague's link to a filtered
      // board survives being asked to sign in on the way.
      const next = this.route.snapshot.queryParamMap.get('next');
      void this.router.navigateByUrl(next ?? '/orders');
      return;
    }
    this.failure.set(MESSAGES[failed]);
  }

  protected get ready(): boolean {
    return this.phone.trim().length > 0 && this.pin.length > 0;
  }
}
