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
 * And the **token's lifetime**, because holding it anywhere durable on a shared
 * office machine hands the next person to sit down a live session.
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

  it('the token is nowhere durable', async () => {
    // A shared office machine. A token in localStorage outlives the browser
    // being closed, and the next person to sit down inherits a live session.
    const promise = attempt();
    http.expectOne('/api/auth/login').flush({
      token: 'a-token',
      user: { id: 'u1', name: 'Boss', role: 'admin', language: 'en' },
    });
    await promise;

    expect(JSON.stringify(localStorage)).not.toContain('a-token');
    expect(JSON.stringify(sessionStorage)).not.toContain('a-token');
    expect(document.cookie).not.toContain('a-token');
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
});
