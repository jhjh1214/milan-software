/**
 * The one place the dashboard talks to the server.
 *
 * Every call carries the session token and every response is typed. Nothing
 * else in the app builds a URL, so a route that changes is a compile error in
 * one file rather than a 404 discovered by somebody in the office.
 *
 * ## What this deliberately does not do
 *
 * **No retries and no caching.** The dashboard runs on a desk with a wire in
 * it, not at a fair. The offline machinery belongs on the handset, where it is
 * the difference between taking a deposit and not; here a failed request should
 * say so and let somebody press the button again.
 *
 * **No re-pricing.** The server owns prices (CLAUDE.md hard rule 4). The
 * dashboard shows what it is told, so there is no second engine here to drift.
 */

import { HttpClient, HttpParams } from '@angular/common/http';
import { Injectable, inject, signal } from '@angular/core';
import { Observable } from 'rxjs';

import type {
  CardDiffOut,
  Channel,
  ListId,
  OrderDetailOut,
  OrderStatus,
  OrdersOut,
  OverridesOut,
  PublishOut,
} from './types';

/** Where the server is. Set once, at build time. */
export const API_BASE = '/api';

export interface OrderFilters {
  readonly status?: OrderStatus;
  readonly channel?: Channel;
  /** Inclusive. */
  readonly confirmedFrom?: string;
  /** Exclusive, so one order lands in exactly one period. */
  readonly confirmedTo?: string;
  readonly limit?: number;
  readonly offset?: number;
}

@Injectable({ providedIn: 'root' })
export class Api {
  private readonly http = inject(HttpClient);

  /**
   * The signed-in session's token.
   *
   * A signal so a 401 can clear it from anywhere and every screen notices at
   * once. Held in memory only: a token in localStorage outlives the browser
   * being closed, and this is a shared office machine.
   */
  readonly token = signal<string | null>(null);

  orders(filters: OrderFilters = {}): Observable<OrdersOut> {
    let params = new HttpParams();
    if (filters.status) params = params.set('status', filters.status);
    if (filters.channel) params = params.set('channel', filters.channel);
    if (filters.confirmedFrom) {
      params = params.set('confirmed_from', filters.confirmedFrom);
    }
    if (filters.confirmedTo) {
      params = params.set('confirmed_to', filters.confirmedTo);
    }
    if (filters.limit !== undefined) {
      params = params.set('limit', String(filters.limit));
    }
    if (filters.offset !== undefined) {
      params = params.set('offset', String(filters.offset));
    }

    return this.http.get<OrdersOut>(`${API_BASE}/orders`, {
      params,
      headers: this.authorised(),
    });
  }

  order(id: string): Observable<OrderDetailOut> {
    return this.http.get<OrderDetailOut>(`${API_BASE}/orders/${id}`, {
      headers: this.authorised(),
    });
  }

  /** Every price moved by hand in a window. Admin only, server-enforced. */
  overrides(start: string, end: string): Observable<OverridesOut> {
    return this.http.get<OverridesOut>(`${API_BASE}/overrides`, {
      params: new HttpParams().set('start', start).set('end', end),
      headers: this.authorised(),
    });
  }

  /**
   * What publishing this card would change. Changes nothing itself.
   *
   * The diff is computed on the server, because the server is the authority on
   * pricing — a diff worked out here would be a different implementation from
   * the one that decides what actually lands.
   */
  previewCard(
    listId: ListId,
    payload: unknown,
    language: string,
  ): Observable<CardDiffOut> {
    return this.http.post<CardDiffOut>(
      `${API_BASE}/rate-cards/preview`,
      { list_id: listId, payload, language },
      { headers: this.authorised() },
    );
  }

  /**
   * Publishes a card. Admin only, server-enforced.
   *
   * A price change publishes a **new version**; old rows are never updated in
   * place and never deleted, so a quote taken at a fair can still be explained
   * months later.
   */
  publishCard(listId: ListId, payload: unknown): Observable<PublishOut> {
    return this.http.post<PublishOut>(
      `${API_BASE}/rate-cards`,
      { list_id: listId, payload },
      { headers: this.authorised() },
    );
  }

  private authorised(): Record<string, string> {
    const token = this.token();
    return token === null ? {} : { Authorization: `Bearer ${token}` };
  }
}
