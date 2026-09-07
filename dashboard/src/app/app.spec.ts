/**
 * The shell.
 *
 * Two things are worth pinning. The nav only appears once somebody is signed
 * in, so the sign-in screen has no chrome suggesting there is anything else to
 * do. And the admin-only link is hidden rather than shown and refused —
 * offering somebody a screen that answers 403 wastes their time and teaches
 * them the app is unreliable.
 *
 * Hiding it is not a permission check and is not relied on as one. The server
 * refuses §6.5's log to a non-admin either way.
 */

import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import { App } from './app';
import { Api } from './api/api';
import { Session, type Identity } from './auth/session';

describe('App', () => {
  let fixture: ComponentFixture<App>;
  let session: Session;
  let api: Api;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        // Signing out navigates, so the target has to exist. An empty route
        // table makes that navigation reject, which surfaces as an unhandled
        // error rather than as a failing assertion — green tests beside a red
        // run, which is the worst of both.
        provideRouter([
          { path: 'sign-in', children: [] },
          { path: 'orders', children: [] },
          { path: 'overrides', children: [] },
        ]),
      ],
    });
    fixture = TestBed.createComponent(App);
    session = TestBed.inject(Session);
    api = TestBed.inject(Api);
  });

  const signedInAs = (role: Identity['role']): void => {
    session.user.set({ id: 'u1', name: 'Boss', role, language: 'en' });
    api.token.set('a-token');
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  it('shows no chrome before anybody signs in', () => {
    // There is exactly one thing to do on the sign-in screen, and a nav bar
    // would suggest otherwise.
    fixture.detectChanges();
    expect(text()).not.toContain('Orders');
    expect(text()).not.toContain('Sign out');
  });

  it('shows the way between screens once signed in', () => {
    signedInAs('staff');
    fixture.detectChanges();
    expect(text()).toContain('Orders');
    expect(text()).toContain('Boss');
    expect(text()).toContain('Sign out');
  });

  it('offers the price log to an admin', () => {
    signedInAs('admin');
    fixture.detectChanges();
    expect(text()).toContain('Price changes');
  });

  it('does not offer it to staff or a part-timer', () => {
    // Hidden rather than shown and refused. The server refuses it either way;
    // this is so nobody is invited to try.
    for (const role of ['staff', 'parttime'] as const) {
      signedInAs(role);
      fixture.detectChanges();
      expect(text()).not.toContain('Price changes');
    }
  });

  it('signing out clears the session and the token', () => {
    signedInAs('admin');
    fixture.detectChanges();

    const button: HTMLButtonElement =
      fixture.nativeElement.querySelector('.who button.sign-out');
    button.click();
    fixture.detectChanges();

    expect(session.signedIn()).toBe(false);
    expect(api.token()).toBeNull();
    expect(text()).not.toContain('Sign out');
  });

  describe('the language the bar speaks', () => {
    // SPEC.md §13 C9. The handset has been trilingual since Phase 2; the
    // office was English on an assumption that turned out to be wrong.
    const languages = (): HTMLButtonElement[] =>
      Array.from(
        fixture.nativeElement.querySelectorAll('.languages button'),
      ) as HTMLButtonElement[];

    it('follows the signed-in person, not the browser', () => {
      // CLAUDE.md: switchable per user, not per device. Two people share this
      // machine and the server already knows which language each of them
      // reads.
      session.user.set({ id: 'u1', name: 'Boss', role: 'admin', language: 'ms' });
      fixture.detectChanges();
      expect(text()).toContain('Pesanan');
      expect(text()).not.toContain('Orders');

      session.user.set({ id: 'u2', name: 'Ah Lian', role: 'admin', language: 'zh' });
      fixture.detectChanges();
      expect(text()).toContain('订单');
    });

    it('falls back to Chinese for an account naming a language we do not speak', () => {
      // A language column is free text on the wire. Rendering a blank nav
      // would be the alternative.
      session.user.set({ id: 'u1', name: 'Boss', role: 'admin', language: 'ta' });
      fixture.detectChanges();
      expect(text()).toContain('订单');
    });

    it('the picker switches every word at once', () => {
      signedInAs('admin');
      fixture.detectChanges();
      expect(text()).toContain('Orders');

      // 中文, English, Bahasa Melayu — the order LANGUAGES declares.
      languages()[2].click();
      fixture.detectChanges();

      expect(text()).toContain('Pesanan');
      expect(text()).toContain('Log keluar');
      expect(text()).not.toContain('Sign out');
    });

    it('each language names itself, in itself', () => {
      // Never translated: somebody who cannot read the current language has
      // to be able to find the way out of it.
      signedInAs('admin');
      fixture.detectChanges();
      expect(languages().map((b) => b.textContent?.trim())).toEqual([
        '中文',
        'English',
        'Bahasa Melayu',
      ]);
    });
  });
});
