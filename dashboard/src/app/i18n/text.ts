/**
 * Which language this browser is speaking, and the words for it.
 *
 * SPEC.md §13 C9. CLAUDE.md: *"switchable per user, not per device."*
 *
 * ## Precedence, and why
 *
 * 1. What somebody picked from the switcher, **this browser, right now**
 * 2. The signed-in person's own `Identity.language`, from the server
 * 3. `zh`, the default
 *
 * ## The choice persists to the account, not the browser
 *
 * Every office PC now belongs to one person (confirmed 2026-09, superseding
 * the earlier "shared machine" assumption that kept this session-only). A
 * pick made from the switcher is sent to the account via `Session.
 * setLanguage`, so it is genuinely the **person's** language: it follows
 * them to any machine, the same as SPEC.md always said it should.
 *
 * `picked` still exists as an immediate, this-tab value — the switcher has
 * to feel instant and must not wait on a round trip — but it is a cache of
 * what was just persisted, not the source of truth. A fresh tab or a fresh
 * sign-in has no `picked` yet and reads straight off the account.
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

  /**
   * Picks a language. Renders instantly, and — when somebody is signed in —
   * persists to their account in the background via `Session.setLanguage`.
   */
  pick(language: Language): void {
    this.picked.set(language);
    this.session.setLanguage(language);
  }

  /**
   * Hands the account's language back the authority.
   *
   * Called when somebody signs in: a pick made on this browser by whoever
   * used it last — before this account, or on the sign-in screen before
   * anybody was known — must not leak onto the account that just arrived.
   * Their own account already knows what they read.
   */
  followTheAccount(): void {
    this.picked.set(null);
  }
}
