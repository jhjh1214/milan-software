import {
  ApplicationConfig,
  provideBrowserGlobalErrorListeners,
} from '@angular/core';
import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';
import { provideRouter, withComponentInputBinding } from '@angular/router';

import { authInterceptor } from './auth/auth.interceptor';
import { routes } from './app.routes';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideRouter(routes, withComponentInputBinding()),
    // fetch rather than XHR: this runs on a desk with a wire in it, and the
    // retry and offline machinery belongs on the handset where it earns its
    // keep.
    provideHttpClient(withFetch(), withInterceptors([authInterceptor])),
  ],
};
