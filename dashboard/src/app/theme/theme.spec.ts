/**
 * Light or dark. Three states worth pinning: an explicit pick wins over the
 * OS, the OS wins over nothing, and a pick survives to the next construction
 * of the service (the only thing `localStorage` is used for anywhere in this
 * app — a visual preference, not the account or the session token).
 */

import { TestBed } from '@angular/core/testing';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { Theme } from './theme';

describe('Theme', () => {
  beforeEach(() => {
    localStorage.clear();
    document.documentElement.removeAttribute('data-theme');
  });

  afterEach(() => {
    localStorage.clear();
    document.documentElement.removeAttribute('data-theme');
  });

  it('defaults to light when nothing has been picked', () => {
    TestBed.configureTestingModule({});
    const theme = TestBed.inject(Theme);
    expect(theme.effective()).toBe('light');
  });

  it('toggling flips the effective mode and writes the attribute', async () => {
    TestBed.configureTestingModule({});
    const theme = TestBed.inject(Theme);

    theme.toggle();
    expect(theme.effective()).toBe('dark');
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark');

    theme.toggle();
    expect(theme.effective()).toBe('light');
  });

  it('a pick survives a fresh instance, via localStorage', () => {
    TestBed.configureTestingModule({});
    TestBed.inject(Theme).toggle();

    TestBed.resetTestingModule();
    TestBed.configureTestingModule({});
    const reloaded = TestBed.inject(Theme);

    expect(reloaded.effective()).toBe('dark');
  });
});
