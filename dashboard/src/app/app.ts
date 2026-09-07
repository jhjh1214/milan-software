import { Component, effect, inject } from '@angular/core';
import { Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';

import { Session } from './auth/session';
import { LanguagePicker } from './i18n/language-picker';
import { Text } from './i18n/text';

/**
 * The shell: a thin bar with the way between screens, and nothing else.
 *
 * It appears only once somebody is signed in, so the sign-in screen has no
 * chrome around it — there is exactly one thing to do there and a nav bar
 * would suggest otherwise.
 *
 * Every screen still owns its own layout. A chrome that each page has to fit
 * inside is the thing that makes the third screen awkward.
 */
@Component({
  selector: 'app-root',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, LanguagePicker],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  protected readonly session = inject(Session);
  private readonly router = inject(Router);
  private readonly text = inject(Text);

  /** The words, as a signal: switching language re-renders the bar. */
  protected readonly t = this.text.strings;

  constructor() {
    // `index.html` carries no `lang`, because which language this page speaks
    // is decided at runtime from the signed-in person's account (§13 C9). A
    // fixed one in the markup would tell a screen reader the wrong thing two
    // thirds of the time; this keeps it true as somebody switches.
    effect(() => {
      document.documentElement.lang = this.text.language();
    });
  }

  protected signOut(): void {
    this.session.signOut();
    void this.router.navigate(['/sign-in']);
  }
}
