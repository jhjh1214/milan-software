/**
 * Three buttons, each labelled in its own language.
 *
 * Never translated: somebody who cannot read the current language has to be
 * able to find the way out of it, and "Bahasa Melayu" rendered as "马来文" is
 * no use to the person who needs it.
 *
 * Buttons rather than a `<select>` so all three are visible at once. A closed
 * dropdown showing 中文 tells a Malay reader nothing about what is inside it.
 */

import { Component, inject } from '@angular/core';

import { Text } from './text';
import { LANGUAGES, LANGUAGE_NAMES, type Language } from './strings';

@Component({
  selector: 'app-language-picker',
  template: `
    <div
      class="languages"
      role="group"
      [attr.aria-label]="text.strings().nav.language"
    >
      @for (l of languages; track l) {
        <button
          type="button"
          [class.on]="text.language() === l"
          [attr.aria-pressed]="text.language() === l"
          [attr.lang]="l"
          (click)="text.pick(l)"
        >
          {{ names[l] }}
        </button>
      }
    </div>
  `,
  styles: `
    .languages {
      display: flex;
      gap: 4px;
    }

    button {
      min-height: 32px;
      padding: 0 10px;
      border: 1px solid #c3cbd9;
      border-radius: 6px;
      background: #fff;
      color: #56637a;
      font: inherit;
      font-size: 13px;
      cursor: pointer;
    }

    button.on {
      border-color: #1d4ed8;
      background: #1d4ed8;
      color: #fff;
    }
  `,
})
export class LanguagePicker {
  protected readonly text = inject(Text);
  protected readonly languages: readonly Language[] = LANGUAGES;
  protected readonly names = LANGUAGE_NAMES;
}
