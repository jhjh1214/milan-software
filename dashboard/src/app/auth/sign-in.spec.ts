/**
 * The sign-in screen. SPEC.md §12, §13 C9.
 *
 * It is the one screen everybody sees and the one place a PIN is typed. No
 * language picker on it any more — every office PC now belongs to one person,
 * so there is nobody here yet to ask, and the picker lives in the signed-in
 * nav bar instead (`app.ts`).
 *
 * Driven through the DOM. The form is bound with `(ngSubmit)` and this
 * component *does* import FormsModule — but that is exactly the pair the
 * people screen got wrong, and a test that called `submit()` could not tell
 * the two apart.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import { Api } from '../api/api';
import { Text } from '../i18n/text';
import { Session } from './session';
import { SignIn } from './sign-in';

describe('SignIn', () => {
  let fixture: ComponentFixture<SignIn>;
  let http: HttpTestingController;
  let session: Session;
  let api: Api;
  let text: Text;

  beforeEach(() => {
    // `Session` now persists a successful sign-in to `sessionStorage` so it
    // survives a refresh -- a real browser global, not reset between tests
    // by the runner. Without this, "submitting the form signs in" leaves a
    // token behind that a later test's own fresh `Session` silently
    // rehydrates, signing it in before its first assertion.
    sessionStorage.clear();
    localStorage.clear();

    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([
          { path: 'orders', children: [] },
          { path: 'reports', children: [] },
        ]),
      ],
    });
    fixture = TestBed.createComponent(SignIn);
    http = TestBed.inject(HttpTestingController);
    session = TestBed.inject(Session);
    api = TestBed.inject(Api);
    text = TestBed.inject(Text);
    fixture.detectChanges();
  });

  const words = (): string => fixture.nativeElement.textContent as string;

  const el = <T extends Element>(selector: string): T => {
    const found = fixture.nativeElement.querySelector(selector) as T | null;
    if (found === null) throw new Error(`no ${selector} on the screen`);
    return found;
  };

  const type = (id: string, value: string): void => {
    const box = el<HTMLInputElement>(`#${id}`);
    box.value = value;
    box.dispatchEvent(new Event('input'));
    fixture.detectChanges();
  };

  /**
   * Lets the sign-in promise finish and re-renders.
   *
   * A macrotask, not `whenStable()`. `signIn` is `async` over
   * `firstValueFrom`, so its continuation is queued after the flush and
   * zoneless change detection has nothing to wait for -- `whenStable()`
   * resolves on a screen that has not been told the answer yet.
   */
  const settle = async (): Promise<void> => {
    await new Promise((resolve) => setTimeout(resolve, 0));
    fixture.detectChanges();
  };

  const submit = async (): Promise<void> => {
    el<HTMLFormElement>('form').dispatchEvent(
      new Event('submit', { cancelable: true }),
    );
    await settle();
  };

  it('speaks Chinese before anybody has said who they are', () => {
    // The default, per CLAUDE.md's conventions. There is no account to ask
    // yet, and the shop is a Melaka Chinese-owned business.
    expect(words()).toContain('登入');
    expect(words()).toContain('手机号码');
  });

  it('has a place reserved for the client logo', () => {
    // No asset yet — just the space, so the screen does not have to be
    // relaid out the day one arrives.
    expect(() => el('.logo-placeholder')).not.toThrow();
  });

  it('offers the theme toggle before anybody has signed in', () => {
    // Dark mode is a browser preference, not an account fact, so there is no
    // reason to make somebody sign in first to get it.
    expect(() => el('.theme-toggle')).not.toThrow();
  });

  it('the button does nothing until both boxes have something in them', async () => {
    const button = el<HTMLButtonElement>('button[type="submit"]');
    expect(button.disabled).toBe(true);

    type('phone', '0123456789');
    expect(el<HTMLButtonElement>('button[type="submit"]').disabled).toBe(true);

    type('pin', '4821');
    expect(el<HTMLButtonElement>('button[type="submit"]').disabled).toBe(false);
  });

  it('submitting the form signs in and keeps the token', async () => {
    type('phone', ' 0123456789 ');
    type('pin', '4821');
    await submit();

    const req = http.expectOne('/api/auth/login');
    expect(req.request.body.phone).toBe('0123456789');
    expect(req.request.body.pin).toBe('4821');
    req.flush({
      token: 'a-token',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });
    await settle();

    expect(session.signedIn()).toBe(true);
    expect(api.token()).toBe('a-token');
  });

  it('the account language wins over whatever the last person on this browser picked', () => {
    // A previous colleague picked Malay from the nav-bar switcher on this
    // same browser and then signed out. Whoever signs in next reads their
    // own account's language, not the last person's leftover pick.
    text.pick('ms');
    expect(text.language()).toBe('ms');

    session.user.set({ id: 'u1', name: 'Boss', role: 'admin', language: 'en' });
    text.followTheAccount();
    expect(text.language()).toBe('en');
  });

  it('never says which of the two was wrong', async () => {
    // "No such phone" tells somebody holding a stolen handset which numbers
    // are real.
    type('phone', '0123456789');
    type('pin', '0000');
    await submit();

    http
      .expectOne('/api/auth/login')
      .flush({ detail: 'no' }, { status: 401, statusText: 'Unauthorized' });
    await settle();

    expect(words()).toContain('号码或密码不对');
    expect(words().toLowerCase()).not.toContain('phone');
  });

  it('a throttle says wait, never that somebody is locked out', async () => {
    // §12: the throttle backs off but never locks out. Somebody mid-shift has
    // to be able to get back in.
    type('phone', '0123456789');
    type('pin', '0000');
    await submit();

    http
      .expectOne('/api/auth/login')
      .flush({ detail: 'slow down' }, { status: 429, statusText: 'Too Many' });
    await settle();

    expect(words()).toContain('试太多次了');
  });

  it('switching language re-renders a failure that is already on screen', async () => {
    // The failure is held as a code rather than as a rendered sentence. The
    // alternative leaves one line of the old language behind, on the screen
    // whose whole job is being readable to somebody who cannot read it.
    type('phone', '0123456789');
    type('pin', '0000');
    await submit();
    http
      .expectOne('/api/auth/login')
      .flush({ detail: 'no' }, { status: 401, statusText: 'Unauthorized' });
    await settle();
    expect(words()).toContain('号码或密码不对');

    text.pick('ms');
    fixture.detectChanges();

    expect(words()).toContain('Nombor atau PIN salah');
    expect(words()).not.toContain('号码或密码不对');
  });
});
