/**
 * One button, sun or moon. Labelled in words too — an icon alone fails
 * `aria-labels`/`icon-only-buttons` for anybody on a screen reader.
 */

import { Component, inject } from '@angular/core';

import { Text } from '../i18n/text';
import { Theme } from './theme';

@Component({
  selector: 'app-theme-toggle',
  template: `
    <button
      type="button"
      class="theme-toggle"
      [attr.aria-label]="label()"
      [attr.title]="label()"
      (click)="theme.toggle()"
    >
      @if (theme.effective() === 'dark') {
        <!-- Sun: shown in dark mode, as the action that switches away from it. -->
        <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
          <circle cx="12" cy="12" r="4.5" fill="none" stroke="currentColor" stroke-width="1.8" />
          <g stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
            <line x1="12" y1="2.5" x2="12" y2="5" />
            <line x1="12" y1="19" x2="12" y2="21.5" />
            <line x1="2.5" y1="12" x2="5" y2="12" />
            <line x1="19" y1="12" x2="21.5" y2="12" />
            <line x1="4.9" y1="4.9" x2="6.6" y2="6.6" />
            <line x1="17.4" y1="17.4" x2="19.1" y2="19.1" />
            <line x1="4.9" y1="19.1" x2="6.6" y2="17.4" />
            <line x1="17.4" y1="6.6" x2="19.1" y2="4.9" />
          </g>
        </svg>
      } @else {
        <!-- Moon: shown in light mode, as the action that switches to dark. -->
        <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
          <path
            d="M20 14.5A8.5 8.5 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5Z"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linejoin="round"
          />
        </svg>
      }
    </button>
  `,
  styles: `
    .theme-toggle {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 36px;
      height: 36px;
      padding: 0;
      border: 1px solid var(--color-border);
      border-radius: var(--radius-sm);
      background: var(--color-surface);
      color: var(--color-fg-muted);
      cursor: pointer;
      transition: border-color 120ms, color 120ms;
    }

    .theme-toggle:hover {
      border-color: var(--color-fg-faint);
      color: var(--color-fg);
    }
  `,
})
export class ThemeToggle {
  protected readonly theme = inject(Theme);
  private readonly text = inject(Text);

  protected label(): string {
    return this.theme.effective() === 'dark'
      ? this.text.strings().nav.switchToLight
      : this.text.strings().nav.switchToDark;
  }
}
