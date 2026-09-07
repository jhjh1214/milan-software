/**
 * Which language this browser is speaking, and the words for it.
 *
 * SPEC.md §13 C9. CLAUDE.md: *"switchable per user, not per device."*
 *
 * ## Precedence, and why
 *
 * 1. What somebody picked from the switcher, **this session only**
 * 2. The signed-in person's own `Identity.language`, from the server
 * 3. `zh`, the default
 *
 * ## The choice is not persisted, on purpose
 *
 * This is the shared office machine — the same reasoning that keeps the
 * session token out of `localStorage`. A language stored on the device is a
 * per-device setting, which is exactly what CLAUDE.md says this must not be:
 * the next person to sit down would get the last person's language, and the
 * `language` on their own account — the thing that exists so nobody has to
 * choose — would look broken.
 *
 * The cost is that somebody who reads only English sees a Chinese sign-in
 * screen and clicks once before signing in. After that their account decides,
 * every time, on any machine in the shop.
 */

import { Injectable, computed, inject, signal } from '@angular/core';

import { Session } from '../auth/session';
import { EN } from './en';
import { MS } from './ms';
import { ZH } from './zh';
import { asLanguage, type Language, type Strings } from './strings';

const DICTIONARIES: Readonly<Record<Language, Strings>> = {
  zh: ZH,
  en: EN,
  ms: MS,
};

@Injectable({ providedIn: 'root' })
export class Text {
  private readonly session = inject(Session);

  /** What the switcher last said, or null when nobody has touched it. */
  private readonly picked = signal<Language | null>(null);

  readonly language = computed<Language>(
    () =>
      this.picked() ?? asLanguage(this.session.user()?.language) ?? 'zh',
  );

  /**
   * The words. A signal, so switching re-renders every screen at once.
   *
   * Every component reads this rather than importing a dictionary: a component
   * that reached for `EN` directly would be right until somebody signed in.
   */
  readonly strings = computed<Strings>(() => DICTIONARIES[this.language()]);

  pick(language: Language): void {
    this.picked.set(language);
  }

  /**
   * Hands the account's language back the authority.
   *
   * Called when somebody signs in: whoever picked a language on the sign-in
   * screen was choosing for the sign-in screen, not for the person who then
   * signed in — and their account already knows what they read.
   */
  followTheAccount(): void {
    this.picked.set(null);
  }
}
