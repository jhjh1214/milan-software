/**
 * A session the server no longer honours looks the same everywhere: the
 * next request answers 401. Without this, that only ever became a worded
 * "you were signed out" message on whichever one screen happened to be
 * making the request at the time (`Api.token`'s own doc comment already
 * promised "a 401 can clear it from anywhere," a promise nothing here ever
 * actually kept) — the sidebar kept rendering the full signed-in shell, and
 * every other open screen stayed exactly as stale until it, too, happened
 * to make a request.
 *
 * That gap matters more now that `Session` persists across a refresh
 * (`session.ts`): a token revoked elsewhere (deactivated, or a future
 * expiry) could sit valid-looking in `sessionStorage` and get silently
 * restored on the next page load, with nothing to notice until whatever
 * screen loaded first happened to call the server.
 *
 * Scoped to "there was a session to lose": a wrong PIN on the sign-in
 * screen is also a 401, and `Session.signIn` already classifies that one
 * directly into a `SignInFailure`. Reacting here too would just be a second,
 * redundant redirect to the screen already showing. Checking
 * `session.signedIn()` at the moment the 401 arrives is what tells the two
 * apart -- true only once a real session existed to be revoked.
 */

import { HttpErrorResponse, type HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { Router } from '@angular/router';
import { catchError, throwError } from 'rxjs';

import { Session } from './session';

export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const session = inject(Session);
  const router = inject(Router);

  return next(req).pipe(
    catchError((err: unknown) => {
      if (err instanceof HttpErrorResponse && err.status === 401 && session.signedIn()) {
        session.signOut();
        // Same convenience the sign-in guard already gives a signed-out
        // visitor: landing back where they were, not the default screen.
        void router.navigate(['/sign-in'], { queryParams: { next: router.url } });
      }
      return throwError(() => err);
    }),
  );
};
