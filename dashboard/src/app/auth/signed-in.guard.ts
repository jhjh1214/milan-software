/**
 * Sends somebody who is not signed in to the sign-in screen.
 *
 * **Not a permission check.** The server refuses an unauthenticated request and
 * would refuse it identically if this file said otherwise; every screen behind
 * this guard is also protected on the server side, which is where protection
 * belongs. What this does is stop a board rendering empty and unexplained when
 * the real answer is "sign in first".
 *
 * The redirect carries where they were going, so signing in lands them there
 * rather than on the default screen — somebody who followed a colleague's link
 * to a filtered board should arrive at that board.
 */

import { inject } from '@angular/core';
import { Router, type CanActivateFn } from '@angular/router';

import { Session } from './session';

export const signedIn: CanActivateFn = (_route, state) => {
  const session = inject(Session);
  const router = inject(Router);

  if (session.signedIn()) return true;

  return router.createUrlTree(['/sign-in'], {
    queryParams: { next: state.url },
  });
};
