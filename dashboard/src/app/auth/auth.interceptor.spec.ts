/**
 * A 401 from anywhere signs the browser out and sends it back to the
 * sign-in screen. Before this existed, `Api.token`'s own doc comment
 * promised exactly this ("a 401 can clear it from anywhere") and nothing
 * ever did it -- a revoked session just sat there showing a signed-in
 * shell until whichever screen happened to ask the server noticed on its
 * own, in words, with nothing else on the page any wiser.
 *
 * The one thing this must NOT do is react to a wrong PIN on the sign-in
 * screen itself, which is also a 401 -- `Session.signIn` already handles
 * that one directly into a `SignInFailure`, and this firing too would be a
 * second, redundant redirect to the screen already on screen.
 */

import {
  HttpClient,
  provideHttpClient,
  withInterceptors,
} from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { Component } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { Api } from '../api/api';
import { authInterceptor } from './auth.interceptor';
import { Session } from './session';

@Component({ selector: 'app-stub', template: '' })
class Stub {}

describe('authInterceptor', () => {
  let http: HttpClient;
  let httpMock: HttpTestingController;
  let session: Session;
  let router: Router;
  let harness: RouterTestingHarness;

  beforeEach(async () => {
    // `Session` now restores from `sessionStorage`, a real browser global
    // not reset between test files by the runner -- without this, a
    // session another spec file persisted could hydrate here and fire its
    // own `/api/auth/me` before this file's own `signIn()` helper runs.
    sessionStorage.clear();
    localStorage.clear();

    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([authInterceptor])),
        provideHttpClientTesting(),
        provideRouter([
          { path: 'sign-in', component: Stub },
          { path: 'orders', component: Stub },
        ]),
      ],
    });
    http = TestBed.inject(HttpClient);
    httpMock = TestBed.inject(HttpTestingController);
    session = TestBed.inject(Session);
    router = TestBed.inject(Router);
    harness = await RouterTestingHarness.create();
  });

  const signIn = (): void => {
    session.user.set({ id: 'u1', name: 'Boss', role: 'admin', language: 'en' });
    TestBed.inject(Api).token.set('a-token');
  };

  it('signs out and returns to sign-in when a signed-in session gets a 401', async () => {
    signIn();
    await harness.navigateByUrl('/orders');

    http.get('/api/orders').subscribe({ error: () => undefined });
    httpMock
      .expectOne('/api/orders')
      .flush({ detail: 'no' }, { status: 401, statusText: 'Unauthorized' });

    await harness.fixture.whenStable();

    expect(session.signedIn()).toBe(false);
    expect(TestBed.inject(Api).token()).toBeNull();
    expect(router.url).toContain('/sign-in');
    expect(router.url).toContain('next=%2Forders');
  });

  it('does not react to a 401 with nobody signed in yet -- a wrong PIN, not a revoked session', async () => {
    await harness.navigateByUrl('/sign-in');

    http.post('/api/auth/login', { phone: '0123', pin: '0000' }).subscribe({
      error: () => undefined,
    });
    httpMock
      .expectOne('/api/auth/login')
      .flush({ detail: 'no' }, { status: 401, statusText: 'Unauthorized' });

    await harness.fixture.whenStable();

    // Nothing to sign out of, and no redirect fired on top of the one
    // already on screen.
    expect(session.signedIn()).toBe(false);
  });

  it('still propagates the error to the caller', async () => {
    signIn();
    await harness.navigateByUrl('/orders');

    let caught: unknown = null;
    http.get('/api/orders').subscribe({ error: (err: unknown) => (caught = err) });
    httpMock
      .expectOne('/api/orders')
      .flush({ detail: 'no' }, { status: 401, statusText: 'Unauthorized' });

    await harness.fixture.whenStable();
    expect(caught).not.toBeNull();
  });

  it('leaves a signed-in session alone on any other status', async () => {
    signIn();
    await harness.navigateByUrl('/orders');

    http.get('/api/orders').subscribe({ error: () => undefined });
    httpMock
      .expectOne('/api/orders')
      .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });

    await harness.fixture.whenStable();

    expect(session.signedIn()).toBe(true);
    expect(router.url).toBe('/orders');
  });
});
