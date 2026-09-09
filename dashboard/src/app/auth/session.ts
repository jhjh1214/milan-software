/**
 * Who is signed in on this browser. SPEC.md §12, §3 roles.
 *
 * ## The token is held in memory only
 *
 * Not `localStorage`. This is a shared office machine and a token that outlives
 * the browser being closed is one the next person to sit down inherits. On the
 * handset the opposite is true — a session that ends mid-fair costs a deposit,
 * which is why SPEC.md §12 makes those never expire — but nothing here is
 * holding a customer's money while somebody walks away from the desk.
 *
 * The cost is signing in again after a refresh. That is a few seconds once a
 * morning, paid by the person who benefits from it.
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
      return null;
    } catch (err: unknown) {
      return classify(err);
    }
  }

  /** Forgets everything. Does not tell the server; §12 revocation is separate. */
  signOut(): void {
    this.api.token.set(null);
    this.user.set(null);
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
