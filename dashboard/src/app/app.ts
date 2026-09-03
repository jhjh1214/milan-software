import { Component, inject } from '@angular/core';
import { Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';

import { Session } from './auth/session';

/**
 * The shell: a thin bar with the way between screens, and nothing else.
 *
 * It appears only once somebody is signed in, so the sign-in screen has no
 * chrome around it — there is exactly one thing to do there and a nav bar
 * would suggest otherwise.
 *
 * Every screen still owns its own layout. A chrome that each page has to fit
 * inside is the thing that makes the third screen awkward.
 */
@Component({
  selector: 'app-root',
  imports: [RouterOutlet, RouterLink, RouterLinkActive],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  protected readonly session = inject(Session);
  private readonly router = inject(Router);

  protected signOut(): void {
    this.session.signOut();
    void this.router.navigate(['/sign-in']);
  }
}
