import {
  ApplicationConfig,
  provideBrowserGlobalErrorListeners,
} from '@angular/core';
import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';
import {
  provideRouter,
  withComponentInputBinding,
  withViewTransitions,
} from '@angular/router';

import { authInterceptor } from './auth/auth.interceptor';
import { routes } from './app.routes';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    // A native browser feature (the View Transitions API), not a package --
    // no-ops in browsers that do not support it. `prefers-reduced-motion` is
    // not automatic for this the way it is for a CSS `animation`; the
    // matching override sits in `styles.css` beside every other one.
    provideRouter(routes, withComponentInputBinding(), withViewTransitions()),
    // fetch rather than XHR: this runs on a desk with a wire in it, and the
    // retry and offline machinery belongs on the handset where it earns its
    // keep.
    provideHttpClient(withFetch(), withInterceptors([authInterceptor])),
  ],
};
