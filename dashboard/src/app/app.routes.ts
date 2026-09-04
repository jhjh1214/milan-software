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
  {
    // Everybody signed in, like the order board: booking a visit is the job of
    // whoever is at the desk, not a privilege. Who may *move* an order along
    // is SPEC.md §13 C8, unanswered.
    path: 'measurement',
    canActivate: [signedIn],
    loadComponent: () =>
      import('./measurement/measurement-queue').then((m) => m.MeasurementQueue),
    title: 'Measurement queue',
  },
  {
    // Admin only, and the server enforces that. The guard here only keeps
    // somebody signed out from landing on an unexplained empty screen; a
    // non-admin who reaches it is told plainly rather than shown a blank week,
    // which would read as "nobody changed anything".
    path: 'overrides',
    canActivate: [signedIn],
    loadComponent: () =>
      import('./overrides/override-review').then((m) => m.OverrideReview),
    title: 'Prices changed by hand',
  },
  {
    // Admin only, server-enforced. Publishing changes what every handset
    // quotes tomorrow.
    path: 'rates',
    canActivate: [signedIn],
    loadComponent: () =>
      import('./rates/publish-card').then((m) => m.PublishCard),
    title: 'Publish a price list',
  },
  {
    // Admin only, server-enforced. Deactivating stops the handset in somebody's
    // pocket, which is why the screen asks for their name first.
    path: 'people',
    canActivate: [signedIn],
    loadComponent: () => import('./people/people').then((m) => m.People),
    title: 'People',
  },
];
