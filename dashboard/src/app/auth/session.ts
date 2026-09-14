/**
 * Who is signed in on this browser. SPEC.md §12, §3 roles.
 *
 * ## The token survives a refresh, in `sessionStorage`
 *
 * This was in-memory only, deliberately, under an assumption CLAUDE.md's
 * own "Current state" has since retired: *"a token in `localStorage` on a
 * shared office machine is one the next person inherits"* -- true when
 * that was written, false since every office PC turned out to belong to
 * one person, the same fact that already moved the language pick from a
 * per-tab choice to an account one. Losing the whole session to an
 * accidental F5 was never the point of that guard; it was collateral from
 * a machine-sharing assumption that no longer holds.
 *
 * `sessionStorage`, not `localStorage`: it survives exactly a refresh and a
 * duplicated tab, and is gone the moment the tab or browser closes -- long
 * enough to save the person at this desk a second sign-in, short enough
 * that it does not become a standing secret sitting in the browser
 * forever the way a `localStorage` token would. Nothing about §12's "never
 * expire" changes: the token itself is exactly as long-lived as before,
 * revocation is still the only control, and this only changes where the
 * browser is allowed to remember one it already has.
 *
 * On the handset the opposite has always been true — a session that ends
 * mid-fair costs a deposit, which is why SPEC.md §12 makes those never
 * expire — but nothing here is holding a customer's money while somebody
 * walks away from the desk, so a page refresh losing work is the only
 * thing this ever guarded against.
 *
 * ## Roles are the server's business
 *
 * The role is kept so screens can avoid *offering* what will be refused —
 * §6.5's override review is admin-only — but nothing here is a permission
 * check. The server refuses, and it would refuse the same if this file lied.
 */

import { HttpClient } from '@angular/common/http';
import { Injectable, computed, inject, signal } from '@angular/core';
import { firstValueFrom } from 'rxjs';

import { API_BASE, Api } from '../api/api';

/** Where the token and identity live across a refresh. Session-only: gone
 * the moment this tab or the browser closes, never a standing secret. */
const STORAGE_KEY = 'milan.session';

interface StoredSession {
  readonly token: string;
  readonly user: Identity;
}

export interface Identity {
  readonly id: string;
  readonly name: string;
  readonly role: 'admin' | 'staff' | 'parttime';
  readonly language: string;
}

interface SessionOut {
  readonly token: string;
  readonly user: Identity;
}

/** Why a sign-in did not work, in words somebody can act on. */
export type SignInFailure =
  | 'wrong'
  | 'throttled'
  | 'offline'
  | 'server';

@Injectable({ providedIn: 'root' })
export class Session {
  private readonly http = inject(HttpClient);
  private readonly api = inject(Api);

  readonly user = signal<Identity | null>(null);
  readonly signedIn = computed(() => this.user() !== null);
  readonly isAdmin = computed(() => this.user()?.role === 'admin');

  /** Staff or admin -- hard rule 8 keeps a part-timer off a rate entirely,
   * so the live per-product price screen is offered to neither of them
   * alone but to both roles above it. */
  readonly isStaffOrAdmin = computed(() => {
    const role = this.user()?.role;
    return role === 'admin' || role === 'staff';
  });

  constructor() {
    this.restore();
  }

  /**
   * Picks a session back up after a refresh. A missing or unreadable entry
   * is the same as none -- signing in again, never a thrown error.
   *
   * The cached copy is trusted immediately, so the shell paints without
   * waiting on a round trip -- that immediacy is the whole reason to
   * persist a session rather than just refetch one. It is then confirmed
   * in the background against `GET /api/auth/me`, whose own docstring says
   * exactly what this is for: noticing a session revoked while this
   * browser was closed, and picking up a role or language changed in the
   * office meanwhile. The mobile app already does this on reconnect; nothing
   * called this route from the dashboard before a session could survive a
   * refresh, because before that there was nothing stale left to confirm.
   * A 401 here is handled by `authInterceptor`, not locally -- one place
   * turns "the server no longer honours this token" into a clean sign-out.
   */
  private restore(): void {
    try {
      const raw = sessionStorage.getItem(STORAGE_KEY);
      if (raw === null) return;
      const stored = JSON.parse(raw) as StoredSession;
      this.api.token.set(stored.token);
      this.user.set(stored.user);
    } catch {
      // Private browsing, blocked storage, or a corrupted entry -- read as
      // "sign in again", not a reason to fail loudly on every page load.
      return;
    }

    this.api.me().subscribe({
      next: (account) => {
        this.user.set({ ...account, role: account.role as Identity['role'] });
        this.persist();
      },
      // Any failure here (offline, a 500) leaves the cached identity in
      // place rather than signing out on a bad connection -- a genuine 401
      // is `authInterceptor`'s job, not this subscription's.
      error: () => undefined,
    });
  }

  /** Called after every change to the token or the identity, so the two
   * never drift apart in storage the way they never do in memory. */
  private persist(): void {
    try {
      const token = this.api.token();
      const user = this.user();
      if (token === null || user === null) {
        sessionStorage.removeItem(STORAGE_KEY);
      } else {
        sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ token, user }));
      }
    } catch {
      // Persistence is a convenience on top of the in-memory signals, which
      // stay correct either way -- never worth failing sign-in over.
    }
  }

  async signIn(phone: string, pin: string): Promise<SignInFailure | null> {
    try {
      const session = await firstValueFrom(
        this.http.post<SessionOut>(`${API_BASE}/auth/login`, {
          phone,
          pin,
          // The browser is the device. A stable id per install would be better
          // and needs somewhere to live that is not localStorage, so for now
          // every sign-in is a new one — the server replaces a session per
          // device id, and a desk browser signing in twice is not a fair.
          device_id: crypto.randomUUID(),
          device_label: 'dashboard',
        }),
      );

      this.api.token.set(session.token);
      this.user.set(session.user);
      this.persist();
      return null;
    } catch (err: unknown) {
      return classify(err);
    }
  }

  /** Forgets everything. Does not tell the server; §12 revocation is separate. */
  signOut(): void {
    this.api.token.set(null);
    this.user.set(null);
    this.persist();
  }

  /**
   * Persists a language choice to the signed-in account. SPEC.md §13 C9.
   *
   * Updates the local copy first, so the switcher feels instant, and fires
   * the request in the background. A failure is swallowed deliberately —
   * this is a preference, not money moving, and the worst case is that the
   * pick does not survive to the next sign-in rather than the screen
   * blocking on it. Does nothing when nobody is signed in yet: there is no
   * account to remember it against.
   */
  setLanguage(language: string): void {
    const current = this.user();
    if (current === null) return;
    this.user.set({ ...current, language });
    this.persist();
    this.api.setMyLanguage(language).subscribe({ error: () => undefined });
  }
}

function classify(err: unknown): SignInFailure {
  if (typeof err !== 'object' || err === null || !('status' in err)) {
    return 'server';
  }
  const status = (err as { status: number }).status;

  // The server backs off after repeated failures rather than locking out
  // (§12), so this is "wait a moment", never "you are locked out".
  if (status === 429) return 'throttled';
  if (status === 401) return 'wrong';
  if (status === 0) return 'offline';
  return 'server';
}
