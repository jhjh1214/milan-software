/**
 * One small line icon, picked by name.
 *
 * A shared component rather than inline `<svg>` at every call site: the
 * sidebar alone names ten of these, and writing the same `viewBox`/stroke
 * attributes out ten times is the kind of copy that drifts the eleventh
 * time somebody changes the stroke width. The actual path data still lives
 * in the template, literally, never through `[innerHTML]` -- Angular's
 * sanitizer treats injected markup as untrusted and a hand-written
 * `@switch` has no sanitizer to fight.
 *
 * Decorative only: every real label sits in the text beside it, never only
 * in an icon nobody can `alt`.
 */

import { Component, input } from '@angular/core';

export type NavIconName =
  | 'home'
  | 'orders'
  | 'measurement'
  | 'tag'
  | 'history'
  | 'document'
  | 'box'
  | 'check-box'
  | 'folder'
  | 'chart'
  | 'users'
  | 'sign-out'
  | 'chevron-down';

@Component({
  selector: 'app-nav-icon',
  template: `
    <svg
      viewBox="0 0 24 24"
      width="18"
      height="18"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      @switch (name()) {
        @case ('home') {
          <path d="M4 11.5 12 4l8 7.5" />
          <path d="M6 10v9a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-9" />
          <path d="M10 20v-6h4v6" />
        }
        @case ('orders') {
          <rect x="5" y="3.5" width="14" height="17" rx="2" />
          <path d="M9 3.5V3a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v.5" />
          <line x1="8" y1="10" x2="16" y2="10" />
          <line x1="8" y1="14" x2="16" y2="14" />
          <line x1="8" y1="18" x2="13" y2="18" />
        }
        @case ('measurement') {
          <rect x="3" y="9" width="18" height="6" rx="1.2" />
          <line x1="7" y1="9" x2="7" y2="12" />
          <line x1="11" y1="9" x2="11" y2="12" />
          <line x1="15" y1="9" x2="15" y2="12" />
          <line x1="19" y1="9" x2="19" y2="12" />
        }
        @case ('tag') {
          <path
            d="M12.5 3H5a2 2 0 0 0-2 2v7.5a2 2 0 0 0 .586 1.414l8.5 8.5a2 2 0 0 0 2.828 0l7.5-7.5a2 2 0 0 0 0-2.828l-8.5-8.5A2 2 0 0 0 12.5 3Z"
          />
          <circle cx="8" cy="8" r="1.4" fill="currentColor" stroke="none" />
        }
        @case ('history') {
          <circle cx="12" cy="13" r="8" />
          <polyline points="12 9 12 13 15 15" />
          <path d="M7 3.5 4 6" />
          <path d="M17 3.5 20 6" />
        }
        @case ('document') {
          <path d="M7 3h7l5 5v13a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Z" />
          <polyline points="14 3 14 8 19 8" />
          <line x1="9" y1="13" x2="15" y2="13" />
          <line x1="9" y1="17" x2="15" y2="17" />
        }
        @case ('box') {
          <path d="M3 8 12 3l9 5v9l-9 5-9-5Z" />
          <polyline points="3 8 12 13 21 8" />
          <line x1="12" y1="13" x2="12" y2="21.3" />
        }
        @case ('check-box') {
          <rect x="4" y="4" width="16" height="16" rx="3" />
          <polyline points="8 12.5 11 15.5 16 9.5" />
        }
        @case ('folder') {
          <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
        }
        @case ('chart') {
          <line x1="5" y1="20" x2="5" y2="11" />
          <line x1="12" y1="20" x2="12" y2="6" />
          <line x1="19" y1="20" x2="19" y2="14" />
          <line x1="3" y1="20" x2="21" y2="20" />
        }
        @case ('users') {
          <circle cx="9" cy="8" r="3.2" />
          <path d="M3.5 20a5.5 5.5 0 0 1 11 0" />
          <circle cx="17" cy="9.2" r="2.6" />
          <path d="M15 20a4.2 4.2 0 0 1 6.5-3.5" />
        }
        @case ('sign-out') {
          <path d="M9 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h3" />
          <polyline points="15 16 20 12 15 8" />
          <line x1="20" y1="12" x2="9" y2="12" />
        }
        @case ('chevron-down') {
          <polyline points="6 9 12 15 18 9" />
        }
      }
    </svg>
  `,
})
export class NavIcon {
  readonly name = input.required<NavIconName>();
}
