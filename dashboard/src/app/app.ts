import { Component, effect, inject } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';

import { AccountMenu } from './account/account-menu';
import { LanguagePrompt } from './account/language-prompt';
import { Session } from './auth/session';
import { Text } from './i18n/text';
import { NavIcon } from './shared/nav-icon';

/**
 * The shell: a sidebar with the way between screens, and nothing else.
 *
 * It appears only once somebody is signed in, so the sign-in screen has no
 * chrome around it — there is exactly one thing to do there and a nav bar
 * would suggest otherwise.
 *
 * A sidebar rather than the original single-row top bar: ten links in one
 * horizontal line either wraps onto a second row or shrinks until nothing
 * is readable, and neither reads as a finished product. Grouped into
 * sections instead, the way the office already thinks about the two roles
 * — everyone's own work, then what only an admin sees.
 *
 * Every screen still owns its own layout. A chrome that each page has to fit
 * inside is the thing that makes the third screen awkward.
 */
@Component({
  selector: 'app-root',
  imports: [
    RouterOutlet,
    RouterLink,
    RouterLinkActive,
    AccountMenu,
    LanguagePrompt,
    NavIcon,
  ],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  protected readonly session = inject(Session);
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
}
