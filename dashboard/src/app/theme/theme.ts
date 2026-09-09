/**
 * Light or dark, and which one wins when nobody has said.
 *
 * Three states, the same shape as the language pick in `i18n/text.ts`:
 *
 * 1. What somebody explicitly chose from the toggle, this browser
 * 2. The OS's own `prefers-color-scheme`
 * 3. Light, if neither of those is available (a test environment with no
 *    `matchMedia`, or a browser too old to have one)
 *
 * Unlike the language, this is not tied to the signed-in account. A visual
 * preference is a browser convenience, not a fact about the person — the
 * boss and whoever borrows their PC for five minutes can each have the office
 * look how they like without touching anything either of them would notice
 * missing on a different machine. `localStorage` is the right tool for
 * exactly that, which is why it is used here and nowhere else in this app.
 */

import { Injectable, computed, effect, signal } from '@angular/core';

export type ThemePreference = 'light' | 'dark';
const STORAGE_KEY = 'milan.theme';

function storedPreference(): ThemePreference | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw === 'light' || raw === 'dark' ? raw : null;
  } catch {
    return null;
  }
}

function systemPrefersDark(): boolean {
  try {
    return (
      typeof window.matchMedia === 'function' &&
      window.matchMedia('(prefers-color-scheme: dark)').matches
    );
  } catch {
    return false;
  }
}

@Injectable({ providedIn: 'root' })
export class Theme {
  /** `null` until somebody picks — then the OS setting no longer matters. */
  private readonly picked = signal<ThemePreference | null>(storedPreference());
  private readonly systemDark = signal(systemPrefersDark());

  readonly effective = computed<ThemePreference>(
    () => this.picked() ?? (this.systemDark() ? 'dark' : 'light'),
  );

  constructor() {
    try {
      if (typeof window.matchMedia === 'function') {
        window
          .matchMedia('(prefers-color-scheme: dark)')
          .addEventListener('change', (e) => this.systemDark.set(e.matches));
      }
    } catch {
      // No matchMedia (older browser, or a test environment). Light it is.
    }

    effect(() => {
      document.documentElement.setAttribute('data-theme', this.effective());
    });
  }

  toggle(): void {
    const next: ThemePreference = this.effective() === 'dark' ? 'light' : 'dark';
    this.picked.set(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // Best-effort. Worst case the choice does not survive a refresh.
    }
  }
}
