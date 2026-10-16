/**
 * Asks which language to read, once.
 *
 * Shown the first time an account signs in on a browser, so a part-timer who
 * reads only Malay is not left to find a switcher in a language they cannot
 * read. After that it never reappears: the choice lives on the account, and
 * changing it later is a menu item (`AccountMenu`), not a fixture on screen.
 *
 * The title is in all three languages at once, because nobody has chosen yet
 * and any single one would be a guess about who is looking.
 */

import { Component, ElementRef, computed, effect, inject, signal } from '@angular/core';

import { Session } from '../auth/session';
import { Text } from '../i18n/text';
import { LANGUAGES, LANGUAGE_NAMES, type Language } from '../i18n/strings';

const KEY_PREFIX = 'milan.language-confirmed.';

/** Storage can be blocked or full. Failing to remember only means asking
 * once more, which is harmless. */
function wasConfirmed(userId: string): boolean {
  try {
    return localStorage.getItem(KEY_PREFIX + userId) === '1';
  } catch {
    return false;
  }
}

function remember(userId: string): void {
  try {
    localStorage.setItem(KEY_PREFIX + userId, '1');
  } catch {
    // Asked again next time; nothing to recover.
  }
}

@Component({
  selector: 'app-language-prompt',
  template: `
    @if (visible()) {
      <div class="scrim"></div>
      <div class="dialog" role="dialog" aria-modal="true" aria-labelledby="language-prompt-title">
        <h2 id="language-prompt-title">选择语言 · Choose your language · Pilih bahasa</h2>
        <div class="options">
          @for (l of languages; track l) {
            <button type="button" class="btn btn-lg" [attr.lang]="l" (click)="choose(l)">
              {{ names[l] }}
            </button>
          }
        </div>
      </div>
    }
  `,
  styles: `
    .scrim {
      position: fixed;
      inset: 0;
      z-index: 40;
      background: var(--scrim);
    }

    .dialog {
      position: fixed;
      z-index: 41;
      top: 50%;
      left: 50%;
      width: min(420px, calc(100vw - var(--space-5) * 2));
      padding: var(--space-5);
      transform: translate(-50%, -50%);
      border-radius: var(--radius-lg);
      background: var(--color-surface);
      box-shadow: var(--shadow-md);
      text-align: center;
    }

    h2 {
      margin: 0 0 var(--space-5);
      font-size: var(--text-lg);
      line-height: 1.4;
    }

    .options {
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
    }
  `,
})
export class LanguagePrompt {
  private readonly session = inject(Session);
  private readonly text = inject(Text);
  private readonly host = inject<ElementRef<HTMLElement>>(ElementRef);

  protected readonly languages = LANGUAGES;
  protected readonly names = LANGUAGE_NAMES;

  /** Accounts answered since this component was created. `localStorage`
   * alone is not a signal, so the screen would not notice it changing. */
  private readonly answered = signal<ReadonlySet<string>>(new Set());

  protected readonly visible = computed(() => {
    const user = this.session.user();
    if (!this.session.signedIn() || !user) return false;
    return !this.answered().has(user.id) && !wasConfirmed(user.id);
  });

  constructor() {
    // Put the keyboard on the first choice so Enter works straight away.
    effect(() => {
      if (!this.visible()) return;
      queueMicrotask(() => this.host.nativeElement.querySelector('button')?.focus());
    });
  }

  protected choose(language: Language): void {
    const user = this.session.user();
    this.text.pick(language);
    if (!user) return;
    remember(user.id);
    this.answered.update((ids) => new Set(ids).add(user.id));
  }
}
