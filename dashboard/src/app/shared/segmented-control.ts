/**
 * A row of toggle buttons picking one value out of several -- a filter, a
 * tab strip, a "which rate card" chooser. Five screens each hand-rolled the
 * same `[class.on]`/`[attr.aria-pressed]`/click-to-select shape; this is
 * that shape, extracted once.
 *
 * Deliberately owns no wrapper element of its own. The five call sites use
 * three different wrappers (`<nav aria-label>`, `<div role="group"
 * aria-labelledby>`, `<fieldset><legend>`) and none of them should have to
 * change to adopt this -- `host: { style: 'display: contents' }` keeps this
 * component out of layout and the accessibility tree entirely, so its
 * `<button>`s render as if they were direct children of whatever the caller
 * already wraps them in.
 */

import { Component, input, output } from '@angular/core';

@Component({
  selector: 'app-segmented-control',
  host: { style: 'display: contents', '[class.capitalize]': 'capitalize()' },
  styleUrl: './segmented-control.css',
  template: `
    @if (allLabel(); as all) {
      <!-- No [attr.aria-pressed] here, matching the markup this replaces --
           only a real option reports pressed state; "no filter" never did. -->
      <button
        type="button"
        [class.on]="selected() === null"
        (click)="select.emit(null)"
      >
        {{ all }}
      </button>
    }
    @for (opt of options(); track opt) {
      <button
        type="button"
        [class.on]="selected() === opt"
        [attr.aria-pressed]="selected() === opt"
        (click)="select.emit(opt)"
      >
        {{ optionLabel()(opt) }}
      </button>
    }
  `,
})
export class SegmentedControl<T> {
  readonly options = input.required<readonly T[]>();
  readonly optionLabel = input.required<(opt: T) => string>();
  readonly selected = input.required<T | null>();
  /** A synthetic "everything" option, emitted as `null` on click. Omitted
   * entirely for a control with no such option. */
  readonly allLabel = input<string | null>(null);
  readonly select = output<T | null>();

  /** Two of the five original sites stored their option labels lowercase
   * and relied on CSS to title-case them for display (`products`/`publish`
   * list-id labels: `'fair'`/`'standard'`). Rather than silently drop that
   * -- which would un-capitalize live text in a refactor that is supposed
   * to change nothing visible -- it is an explicit opt-in here. */
  readonly capitalize = input(false);
}
