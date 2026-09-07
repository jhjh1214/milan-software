/**
 * Signing in to the dashboard. SPEC.md §12.
 *
 * Phone plus PIN, the same credentials the handsets use — there is no separate
 * office account, so a leaver is deactivated once and is out of everything.
 *
 * No roster to pick a name from. A staff list on a sign-in screen hands the
 * staff list to anyone who opens it, and the same reasoning that keeps it off
 * the handset keeps it off a browser on a desk people walk past.
 *
 * The language picker is on this screen because it has to be: the default is
 * Chinese, and the account that would say otherwise is on the far side of the
 * button somebody cannot read (§13 C9).
 */

import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';

import { LanguagePicker } from '../i18n/language-picker';
import { Text } from '../i18n/text';
import { Session, type SignInFailure } from './session';

@Component({
  selector: 'app-sign-in',
  imports: [FormsModule, LanguagePicker],
  templateUrl: './sign-in.html',
  styleUrl: './sign-in.css',
})
export class SignIn {
  private readonly session = inject(Session);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly text = inject(Text);

  protected readonly t = this.text.strings;

  protected phone = '';
  protected pin = '';

  protected readonly busy = signal(false);

  /**
   * Which failure, not its sentence.
   *
   * Holding the rendered string would freeze it in whichever language was on
   * screen when it happened — so switching language with a failure showing
   * would leave one line of the old one behind, on the screen whose whole job
   * is being readable to somebody who cannot read the default.
   */
  protected readonly failure = signal<SignInFailure | null>(null);

  protected message(failed: SignInFailure): string {
    const words = this.t().signIn;
    switch (failed) {
      // Never says which of the two was wrong. Saying "no such phone" tells
      // somebody holding a stolen handset which numbers are real.
      case 'wrong':
        return words.wrong;
      // §12: the throttle backs off but never locks out, so this is "wait",
      // never "you are locked out" — somebody mid-shift has to get back in.
      case 'throttled':
        return words.throttled;
      case 'offline':
        return words.offline;
      default:
        return words.server;
    }
  }

  protected async submit(): Promise<void> {
    if (this.busy()) return;

    this.busy.set(true);
    this.failure.set(null);

    const failed = await this.session.signIn(this.phone.trim(), this.pin);
    this.busy.set(false);

    if (failed === null) {
      // The PIN does not stay in a field behind a route change.
      this.pin = '';
      // Whoever picked a language here was choosing for this screen. The
      // person who just signed in has a language on their own account, and
      // that is the one that should follow them to every machine in the shop.
      this.text.followTheAccount();
      // Back to where they were headed, so a colleague's link to a filtered
      // board survives being asked to sign in on the way.
      const next = this.route.snapshot.queryParamMap.get('next');
      void this.router.navigateByUrl(next ?? '/orders');
      return;
    }
    this.failure.set(failed);
  }

  protected get ready(): boolean {
    return this.phone.trim().length > 0 && this.pin.length > 0;
  }
}
