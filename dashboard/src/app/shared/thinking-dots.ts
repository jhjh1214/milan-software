/**
 * A small breathing cluster of dots -- "AI is working on this," beside the
 * text that already says so. Never the only signal, the same rule `.spinner`
 * follows: this is a visual companion to a sentence, not a replacement for
 * one.
 *
 * A tiny wrapper around the global `.thinking-dots` CSS class (`styles.css`,
 * beside `.spinner`/`.skeleton`) rather than a component with its own styles
 * -- those two are plain classes too, and a screen reaching for this should
 * not need to learn a second pattern.
 */

import { Component, input } from '@angular/core';

@Component({
  selector: 'app-thinking-dots',
  template: `
    <span class="thinking-dots" role="status" [attr.aria-label]="label()">
      <span class="dot"></span>
      <span class="dot"></span>
      <span class="dot"></span>
    </span>
  `,
})
export class ThinkingDots {
  readonly label = input<string>('');
}
