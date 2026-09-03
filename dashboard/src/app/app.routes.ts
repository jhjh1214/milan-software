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
  {
    // `:id` binds straight to the component's `id` input, through
    // withComponentInputBinding. One less thing to wire, and one less place
    // for the route and the component to disagree about a parameter name.
    path: 'orders/:id',
    canActivate: [signedIn],
    loadComponent: () =>
      import('./orders/order-detail').then((m) => m.OrderDetail),
    title: 'Order',
  },
];
