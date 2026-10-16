/**
 * The one place the person's own settings live: language, light or dark, and
 * signing out.
 *
 * They are behind a single quiet button at the foot of the sidebar rather than
 * on screen all day. Nobody changes language or theme more than a handful of
 * times, and a control that is always showing is a control that is always in
 * the way. The language is asked for once, at first sign-in
 * (`LanguagePrompt`); this is where it is changed afterwards.
 */

import { Component, ElementRef, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';

import { Session } from '../auth/session';
import { Text } from '../i18n/text';
import { LANGUAGES, LANGUAGE_NAMES } from '../i18n/strings';
import { Theme } from '../theme/theme';

@Component({
  selector: 'app-account-menu',
  host: {
    '(document:click)': 'closeOnOutsideClick($event)',
    '(document:keydown.escape)': 'close()',
  },
  template: `
    <button
      type="button"
      class="trigger"
      aria-haspopup="menu"
      [attr.aria-expanded]="open()"
      (click)="open.set(!open())"
    >
      <span class="avatar" aria-hidden="true">{{ initial() }}</span>
      <span class="who-info">
        <span class="who-name">{{ session.user()?.name }}</span>
        <span class="who-role">{{ roleLabel() }}</span>
      </span>
      <svg class="chevron" viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
        <path
          d="M2.5 7.5 6 4l3.5 3.5"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </button>

    @if (open()) {
      <div class="menu" role="menu">
        <p class="group-label" id="language-label">{{ t().nav.language }}</p>
        <div class="languages" role="group" aria-labelledby="language-label">
          @for (l of languages; track l) {
            <button
              type="button"
              role="menuitemradio"
              class="item"
              [class.on]="text.language() === l"
              [attr.aria-checked]="text.language() === l"
              [attr.lang]="l"
              (click)="text.pick(l)"
            >
              <span>{{ names[l] }}</span>
              @if (text.language() === l) {
                <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
                  <path
                    d="m3.5 8.5 3 3 6-7"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                </svg>
              }
            </button>
          }
        </div>

        <div class="rule" role="separator"></div>

        <button type="button" role="menuitem" class="item theme-toggle" (click)="theme.toggle()">
          {{ themeLabel() }}
        </button>
        <button type="button" role="menuitem" class="item sign-out" (click)="signOut()">
          {{ t().nav.signOut }}
        </button>
      </div>
    }
  `,
  styles: `
    :host {
      position: relative;
      display: block;
    }

    .trigger {
      display: flex;
      align-items: center;
      gap: var(--space-2);
      width: 100%;
      padding: var(--space-2);
      border: none;
      border-radius: var(--radius-sm);
      background: transparent;
      color: var(--color-fg);
      text-align: left;
      cursor: pointer;
      transition: background var(--duration-fast) var(--ease);
    }

    .trigger:hover,
    .trigger[aria-expanded='true'] {
      background: var(--color-surface-muted);
    }

    .avatar {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 32px;
      height: 32px;
      flex-shrink: 0;
      border-radius: 50%;
      background: var(--color-accent-bg);
      color: var(--color-accent);
      font-size: var(--text-sm);
      font-weight: 600;
    }

    .who-info {
      display: flex;
      flex-direction: column;
      min-width: 0;
      flex: 1;
      line-height: 1.25;
    }

    .who-name {
      overflow: hidden;
      font-size: var(--text-sm);
      font-weight: 500;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .who-role {
      font-size: var(--text-xs);
      color: var(--color-fg-muted);
    }

    .chevron {
      flex-shrink: 0;
      color: var(--color-fg-faint);
    }

    .menu {
      position: absolute;
      bottom: calc(100% + var(--space-2));
      left: 0;
      right: 0;
      z-index: 20;
      min-width: 220px;
      padding: var(--space-2);
      border: 1px solid var(--color-border-subtle);
      border-radius: var(--radius-md);
      background: var(--color-surface);
      box-shadow: var(--shadow-md);
    }

    .group-label {
      margin: var(--space-1) var(--space-2) var(--space-1);
      font-size: var(--text-xs);
      font-weight: 500;
      color: var(--color-fg-muted);
    }

    .item {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: var(--space-2);
      width: 100%;
      min-height: 34px;
      padding: 0 var(--space-2);
      border: none;
      border-radius: 6px;
      background: transparent;
      color: var(--color-fg);
      font-size: var(--text-base);
      text-align: left;
      white-space: nowrap;
      cursor: pointer;
    }

    .item:hover {
      background: var(--color-surface-muted);
    }

    .item.on {
      color: var(--color-accent);
    }

    .rule {
      height: 1px;
      margin: var(--space-2) calc(var(--space-2) * -1);
      background: var(--color-border-subtle);
    }

    .sign-out {
      color: var(--color-danger);
    }

    /* The shell is a header on a narrow window, so the menu opens downward
       from the top-right instead. */
    @media (max-width: 720px) {
      .who-info,
      .chevron {
        display: none;
      }

      .trigger {
        width: auto;
      }

      .menu {
        top: calc(100% + var(--space-2));
        bottom: auto;
        left: auto;
        right: 0;
        width: 220px;
      }
    }
  `,
})
export class AccountMenu {
  protected readonly session = inject(Session);
  protected readonly text = inject(Text);
  protected readonly theme = inject(Theme);
  private readonly router = inject(Router);
  private readonly host = inject<ElementRef<HTMLElement>>(ElementRef);

  protected readonly t = this.text.strings;
  protected readonly languages = LANGUAGES;
  protected readonly names = LANGUAGE_NAMES;
  protected readonly open = signal(false);

  protected readonly initial = computed(() => {
    const name = this.session.user()?.name ?? '';
    return name.trim().charAt(0).toUpperCase() || '?';
  });

  protected readonly roleLabel = computed(() => {
    const role = this.session.user()?.role;
    return role === null || role === undefined ? '' : this.t().role[role];
  });

  protected readonly themeLabel = computed(() =>
    this.theme.effective() === 'dark'
      ? this.t().nav.switchToLight
      : this.t().nav.switchToDark,
  );

  protected close(): void {
    this.open.set(false);
  }

  protected closeOnOutsideClick(event: Event): void {
    if (!this.host.nativeElement.contains(event.target as Node)) this.close();
  }

  protected signOut(): void {
    this.close();
    this.session.signOut();
    void this.router.navigate(['/sign-in']);
  }
}
