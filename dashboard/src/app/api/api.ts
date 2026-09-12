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
import { Observable, from, switchMap } from 'rxjs';

import type {
  AddPersonIn,
  BalancesReport,
  BuyerDetailsIn,
  BuyerDetailsResult,
  CardDiffOut,
  Channel,
  DeactivateOut,
  DepositPromptsOut,
  ExtractionOut,
  FairReport,
  FloorPlanOut,
  ListId,
  MeasurementQueueOut,
  OrderDetailOut,
  OrderStatus,
  OrdersOut,
  OverridesOut,
  PeopleOut,
  PersonOut,
  ProjectsOut,
  PublishOut,
  UnitTypeDetailOut,
  UnitTypeStatus,
  UnitTypesOut,
  VarianceReport,
} from './types';

/** Where the server is. Set once, at build time. */
export const API_BASE = '/api';

/** A blob's bytes as bare base64 -- `FileReader`'s data URL, minus the
 * `data:<type>;base64,` prefix `/api/recognize` does not want repeated back
 * to it (it already has the content type as its own field). */
function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result as string;
      resolve(result.slice(result.indexOf(',') + 1));
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/** What `POST /api/auth/language` hands back: the account, freshly read. */
export interface MyAccountOut {
  readonly id: string;
  readonly name: string;
  readonly role: string;
  readonly language: string;
}

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

  /**
   * Corrects what is on file about the buyer. SPEC.md §10.3, §11 Phase 7.
   *
   * The same endpoint the handset pushes to, deliberately: one write path and
   * one merge rule, so the office and the measurer cannot end up with two
   * different ideas of what happens to a field neither of them touched.
   *
   * A refusal comes back **200 with `refused_because` set**, not as an error —
   * so the caller has to read the body rather than trust the status code.
   */
  saveBuyer(payload: BuyerDetailsIn): Observable<BuyerDetailsResult> {
    return this.http.post<BuyerDetailsResult>(
      `${API_BASE}/orders/buyer`,
      payload,
      { headers: this.authorised() },
    );
  }

  /**
   * Everything waiting for a site visit, grouped into trips.
   *
   * No parameters: the queue is what it is, and the clock is the server's --
   * two screens open on two desks should not disagree about what today is.
   */
  measurementQueue(): Observable<MeasurementQueueOut> {
    return this.http.get<MeasurementQueueOut>(`${API_BASE}/measurement-queue`, {
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
   * Estimate against the tape, per salesperson. Admin only, server-enforced.
   *
   * Read knowing the whole column is biased: a quotation rounds every quantity
   * up and the final bill uses the exact tape, so an honest estimate always
   * comes in high.
   */
  variance(): Observable<VarianceReport> {
    return this.http.get<VarianceReport>(`${API_BASE}/reports/variance`, {
      headers: this.authorised(),
    });
  }

  /** What each fair did, keyed on the promo its orders pinned. Admin only. */
  fairs(): Observable<FairReport> {
    return this.http.get<FairReport>(`${API_BASE}/reports/fairs`, {
      headers: this.authorised(),
    });
  }

  /**
   * Money still to come, aged by how long since the deposit. Admin only.
   *
   * Nothing in it is overdue: the system has no invoice date and no payment
   * terms, so it cannot know when a balance falls due (§13 C11).
   */
  balances(): Observable<BalancesReport> {
    return this.http.get<BalancesReport>(`${API_BASE}/reports/balances`, {
      headers: this.authorised(),
    });
  }

  /**
   * Every answer to the category prompt in a window. Admin only.
   *
   * Raw rows, deliberately. The counting happens where it is read, because the
   * office slices it differently from the handset and two summaries that have
   * to agree eventually will not.
   */
  depositPrompts(start: string, end: string): Observable<DepositPromptsOut> {
    return this.http.get<DepositPromptsOut>(`${API_BASE}/deposit-prompts`, {
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

  /** Everybody who can sign in, and everybody who used to. Admin only. */
  people(): Observable<PeopleOut> {
    return this.http.get<PeopleOut>(`${API_BASE}/people`, {
      headers: this.authorised(),
    });
  }

  /**
   * Creates somebody who can sign in.
   *
   * The PIN goes up once and never comes back. The *first* admin still needs
   * shell access to the box -- this only saves a terminal for the second
   * person onwards.
   */
  addPerson(person: AddPersonIn): Observable<PersonOut> {
    return this.http.post<PersonOut>(`${API_BASE}/people`, person, {
      headers: this.authorised(),
    });
  }

  /**
   * Ends somebody's access, and reports how many handsets that signed out.
   *
   * Never deletes: their quotes and payments still name them. Sessions never
   * expire, so this is the only thing that stops the phone in their pocket.
   */
  deactivate(id: string): Observable<DeactivateOut> {
    return this.http.post<DeactivateOut>(
      `${API_BASE}/people/${id}/deactivate`,
      {},
      { headers: this.authorised() },
    );
  }

  /** Lets somebody back in. Their old sessions stay revoked. */
  reactivate(id: string): Observable<PersonOut> {
    return this.http.post<PersonOut>(
      `${API_BASE}/people/${id}/reactivate`,
      {},
      { headers: this.authorised() },
    );
  }

  /**
   * A person picking their own language. Self-service — no admin check on
   * the server, because reading the system in your own language needs
   * nobody else's permission (SPEC.md §13 C9).
   *
   * This is what makes the choice follow the **account**: the next machine
   * that person signs into reads `GET /api/auth/me` and picks it straight
   * back up, rather than starting over at the default every time.
   */
  setMyLanguage(language: string): Observable<MyAccountOut> {
    return this.http.post<MyAccountOut>(
      `${API_BASE}/auth/language`,
      { language },
      { headers: this.authorised() },
    );
  }

  /**
   * Everything waiting on an admin's decision, or everything full stop.
   * SPEC.md Phase 8.
   *
   * The server eager-loads every version's openings and rooms onto each
   * row: this is the one screen where an admin has to see the actual
   * submission, not just its name, before deciding on it.
   */
  unitTypes(status?: UnitTypeStatus): Observable<UnitTypesOut> {
    let params = new HttpParams();
    if (status) params = params.set('status', status);
    return this.http.get<UnitTypesOut>(`${API_BASE}/unit-types`, {
      params,
      headers: this.authorised(),
    });
  }

  unitTypeDetail(id: string): Observable<UnitTypeDetailOut> {
    return this.http.get<UnitTypeDetailOut>(`${API_BASE}/unit-types/${id}`, {
      headers: this.authorised(),
    });
  }

  /** Admin only, server-enforced. Makes the latest version live. */
  approveUnitType(id: string): Observable<UnitTypeDetailOut['unit_type']> {
    return this.http.post<UnitTypeDetailOut['unit_type']>(
      `${API_BASE}/unit-types/${id}/approve`,
      {},
      { headers: this.authorised() },
    );
  }

  /** Admin only, server-enforced. Sends a part-timer's submission back. */
  rejectUnitType(id: string, reason: string): Observable<UnitTypeDetailOut['unit_type']> {
    return this.http.post<UnitTypeDetailOut['unit_type']>(
      `${API_BASE}/unit-types/${id}/reject`,
      { reason },
      { headers: this.authorised() },
    );
  }

  /** What a salesperson finds by typing an area or a development name. */
  projects(query?: string): Observable<ProjectsOut> {
    let params = new HttpParams();
    if (query) params = params.set('q', query);
    return this.http.get<ProjectsOut>(`${API_BASE}/projects`, {
      params,
      headers: this.authorised(),
    });
  }

  /**
   * Attaches an image to a unit type's latest version. Refused (409) once
   * that version is approved -- a correction needs a new version, never an
   * edit to this one.
   */
  uploadFloorPlan(unitTypeId: string, file: File): Observable<FloorPlanOut> {
    const body = new FormData();
    body.append('file', file);
    return this.http.post<FloorPlanOut>(
      `${API_BASE}/unit-types/${unitTypeId}/floor-plan`,
      body,
      { headers: this.authorised() },
    );
  }

  /**
   * The image itself, as a blob. An `<img src>` cannot carry the
   * Authorization header this endpoint requires, so the component reads
   * this into an object URL instead.
   */
  floorPlanImage(floorPlanId: string): Observable<Blob> {
    return this.http.get(`${API_BASE}/floor-plans/${floorPlanId}/image`, {
      headers: this.authorised(),
      responseType: 'blob',
    });
  }

  /** Two clicks on the image and a real-world distance become a scale. */
  calibrateFloorPlan(
    floorPlanId: string,
    pixelDistance: number,
    realDistanceTmm: number,
  ): Observable<FloorPlanOut> {
    return this.http.post<FloorPlanOut>(
      `${API_BASE}/floor-plans/${floorPlanId}/calibrate`,
      { pixel_distance: pixelDistance, real_distance_tmm: realDistanceTmm },
      { headers: this.authorised() },
    );
  }

  /**
   * Proposes openings and rooms from a floor-plan image. SPEC.md Phase 8,
   * "Future: assisted digitisation" -- stateless, so this re-sends the blob
   * already fetched via `floorPlanImage` rather than passing a floor plan
   * id; the same route also serves the handset, which calls it before a
   * floor plan id exists at all. Never a write: a proposal only ever
   * prefills the review form, which still goes through the ordinary
   * draft/pending_review/approved gate.
   */
  recognizeFloorPlan(blob: Blob, contentType: string): Observable<ExtractionOut> {
    return from(blobToBase64(blob)).pipe(
      switchMap((imageBase64) =>
        this.http.post<ExtractionOut>(
          `${API_BASE}/recognize`,
          { content_type: contentType, image_base64: imageBase64 },
          { headers: this.authorised() },
        ),
      ),
    );
  }

  private authorised(): Record<string, string> {
    const token = this.token();
    return token === null ? {} : { Authorization: `Bearer ${token}` };
  }
}
