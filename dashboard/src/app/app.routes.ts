import { Routes } from '@angular/router';

import { signedIn } from './auth/signed-in.guard';

/**
 * Every screen is reachable by URL, and every filter state with it. SPEC.md
 * §11 Phase 5 makes that an acceptance criterion: somebody has to be able to
 * send a colleague a link to exactly what they are looking at.
 *
 * Lazily loaded, so opening the board does not download the screens nobody on
 * this desk uses today.
 */
export const routes: Routes = [
  { path: '', pathMatch: 'full', redirectTo: 'orders' },
  {
    path: 'sign-in',
    loadComponent: () => import('./auth/sign-in').then((m) => m.SignIn),
    title: 'Sign in',
  },
  {
    path: 'orders',
    canActivate: [signedIn],
    loadComponent: () =>
      import('./orders/order-board').then((m) => m.OrderBoard),
    title: 'Orders',
  },
];
