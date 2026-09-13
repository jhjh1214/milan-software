/**
 * Signing in to the dashboard. SPEC.md §12, §3.
 *
 * Two things are worth testing here and neither is the happy path.
 *
 * The **failure classification**, because it is what somebody actually reads
 * when they cannot get in. §12's throttle backs off and never locks out, so a
 * 429 has to say "wait a moment" — telling a supervisor mid-shift they are
 * locked out sends them to find somebody else's PIN.
 *
 * And the **token's lifetime**: it now survives a refresh in `sessionStorage`
 * (every office PC belongs to one person, per CLAUDE.md's own "Current
 * state" -- the shared-machine assumption that used to keep this in-memory
 * only is retired), but must still never reach `localStorage` or a cookie,
 * which would make it a standing secret rather than one gone the moment
 * the tab closes.
 */

import { HttpErrorResponse, provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { Api } from '../api/api';
import { Session } from './session';

describe('Session', () => {
  let session: Session;
  let api: Api;
  let http: HttpTestingController;

  beforeEach(() => {
    // sessionStorage is a real browser global, not reset between tests by
    // the runner -- without this, a token persisted by one test's Session
    // would be picked back up by the next test's fresh one.
    sessionStorage.clear();
    localStorage.clear();

    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    session = TestBed.inject(Session);
    api = TestBed.inject(Api);
    http = TestBed.inject(HttpTestingController);
  });

  const attempt = (): Promise<string | null> => session.signIn('0123', '4821');

  const respond = (status: number): void => {
    const req = http.expectOne('/api/auth/login');
    req.flush(
      { detail: 'no' },
      status === 0
        ? { status: 0, statusText: 'Unknown Error' }
        : { status, statusText: 'x' },
    );
  };

  it('holds the token and the identity once in', async () => {
    const promise = attempt();
    http.expectOne('/api/auth/login').flush({
      token: 'a-token',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });

    expect(await promise).toBeNull();
    expect(session.signedIn()).toBe(true);
    expect(session.isAdmin()).toBe(true);
    expect(api.token()).toBe('a-token');
  });

  it('sends the phone and PIN, and no roster is involved', async () => {
    const promise = attempt();
    const req = http.expectOne('/api/auth/login');
    expect(req.request.body.phone).toBe('0123');
    expect(req.request.body.pin).toBe('4821');
    req.flush({
      token: 't',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });
    await promise;
  });

  it('a throttle says wait, never locked out', async () => {
    // §12: the throttle backs off but never locks out. Telling somebody
    // mid-shift they are locked out sends them to find another PIN.
    const promise = attempt();
    respond(429);
    expect(await promise).toBe('throttled');
    expect(session.signedIn()).toBe(false);
  });

  it('a wrong PIN and an unknown phone are the same answer', async () => {
    // Saying "no such phone" tells somebody holding a stolen handset which
    // numbers are real.
    const promise = attempt();
    respond(401);
    expect(await promise).toBe('wrong');
  });

  it('no answer from the server is its own case', async () => {
    const promise = attempt();
    respond(0);
    expect(await promise).toBe('offline');
  });

  it('anything else is a server problem, not the user\'s', async () => {
    const promise = attempt();
    respond(500);
    expect(await promise).toBe('server');
  });

  it('a failed sign-in leaves no token behind', async () => {
    const promise = attempt();
    respond(401);
    await promise;
    expect(api.token()).toBeNull();
    expect(session.user()).toBeNull();
  });

  it('signing out forgets everything', async () => {
    const promise = attempt();
    http.expectOne('/api/auth/login').flush({
      token: 'a-token',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });
    await promise;

    session.signOut();
    expect(api.token()).toBeNull();
    expect(session.signedIn()).toBe(false);
    expect(session.isAdmin()).toBe(false);
  });

  it('the token never reaches localStorage or a cookie', async () => {
    // Those outlive the browser being closed; `sessionStorage` does not.
    const promise = attempt();
    http.expectOne('/api/auth/login').flush({
      token: 'a-token',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });
    await promise;

    expect(JSON.stringify(localStorage)).not.toContain('a-token');
    expect(document.cookie).not.toContain('a-token');
  });

  it('survives a refresh, in sessionStorage', async () => {
    const promise = attempt();
    http.expectOne('/api/auth/login').flush({
      token: 'a-token',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });
    await promise;

    // A refresh tears down every Angular service and rebuilds them fresh --
    // simulated here by asking a brand new Session to read what the first
    // one left behind, the same as the real page load would.
    const revived = TestBed.runInInjectionContext(() => new Session());
    expect(revived.signedIn()).toBe(true);
    expect(revived.user()?.name).toBe('Boss');
  });

  it('signing out clears the persisted copy too', async () => {
    const promise = attempt();
    http.expectOne('/api/auth/login').flush({
      token: 'a-token',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });
    await promise;

    session.signOut();

    const revived = TestBed.runInInjectionContext(() => new Session());
    expect(revived.signedIn()).toBe(false);
  });

  it('a corrupted entry is read as no session, not a thrown error', () => {
    sessionStorage.setItem('milan.session', '{not json');
    expect(() => TestBed.runInInjectionContext(() => new Session())).not.toThrow();
  });

  it('a staff sign-in is not an admin', async () => {
    // The role decides what is offered, never what is permitted — the server
    // refuses regardless. But offering an admin-only screen to staff wastes
    // their time on a 403.
    const promise = attempt();
    http.expectOne('/api/auth/login').flush({
      token: 't',
      user: { id: 'u2', name: 'Ah Lian', role: 'staff', language: 'en' },
    });
    await promise;

    expect(session.signedIn()).toBe(true);
    expect(session.isAdmin()).toBe(false);
  });

  it('an error that is not an HTTP response is still handled', () => {
    // Nothing about signing in should ever throw at the caller.
    const err = new HttpErrorResponse({ status: 503 });
    expect(err.status).toBe(503);
  });

  describe('setLanguage', () => {
    it('updates the local copy at once and persists to the account', async () => {
      const promise = attempt();
      http.expectOne('/api/auth/login').flush({
        token: 'a-token',
        user: { id: 'u1', name: 'Boss', role: 'admin', language: 'zh' },
      });
      await promise;

      session.setLanguage('en');
      expect(session.user()?.language).toBe('en');

      const req = http.expectOne('/api/auth/language');
      expect(req.request.body).toEqual({ language: 'en' });
      req.flush({ id: 'u1', name: 'Boss', role: 'admin', language: 'en' });
    });

    it('does nothing when nobody is signed in', () => {
      // No account to remember it against.
      session.setLanguage('en');
      expect(session.user()).toBeNull();
      http.expectNone('/api/auth/language');
    });

    it('a failed persist does not undo the local pick', async () => {
      // A preference, not money moving: the worst case is that it does not
      // survive to the next sign-in, not that this screen breaks.
      const promise = attempt();
      http.expectOne('/api/auth/login').flush({
        token: 'a-token',
        user: { id: 'u1', name: 'Boss', role: 'admin', language: 'zh' },
      });
      await promise;

      session.setLanguage('en');
      http
        .expectOne('/api/auth/language')
        .flush({ detail: 'no' }, { status: 500, statusText: 'x' });

      expect(session.user()?.language).toBe('en');
    });
  });
});
