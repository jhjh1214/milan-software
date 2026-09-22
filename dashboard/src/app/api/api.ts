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
  AllocationOut,
  AllocationsOut,
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
  MaterialOut,
  MaterialsOut,
  MeasurementQueueOut,
  OrderDetailOut,
  OrderStatus,
  OrdersOut,
  OverridesOut,
  PeopleOut,
  PersonOut,
  ProductPriceEditOut,
  ProductsOut,
  ProjectOut,
  ProjectsOut,
  PublishOut,
  RecognitionJobOut,
  ReorderAlertsOut,
  SiteAddressOut,
  StockLotOut,
  StockLotsOut,
  StockMovementOut,
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
  /** Who confirmed it. SPEC.md §11 Phase 5's own wishlist names this the
   * salesperson filter, alongside channel. */
  readonly confirmedByUserId?: string;
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
    if (filters.confirmedByUserId) {
      params = params.set('confirmed_by_user_id', filters.confirmedByUserId);
    }
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

  /**
   * A free-text note on where a visit actually is, typed in by staff
   * planning the day's route. Not a real address record -- empty clears it.
   */
  setSiteAddress(
    orderId: string,
    note: string | null,
  ): Observable<SiteAddressOut> {
    return this.http.patch<SiteAddressOut>(
      `${API_BASE}/orders/${orderId}/site-address`,
      { site_address_note: note },
      { headers: this.authorised() },
    );
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

  /**
   * The active card's products, for the live per-product price screen.
   * Staff or admin -- part-timers never see a rate at all (hard rule 8).
   */
  products(listId: ListId): Observable<ProductsOut> {
    return this.http.get<ProductsOut>(
      `${API_BASE}/rate-cards/${listId}/products`,
      { headers: this.authorised() },
    );
  }

  /**
   * Changes one product's price directly, live immediately -- no whole-card
   * upload, no preview step. Still publishes a new `RateCardVersion` under
   * the hood, so a quote already priced at the old rate stays explainable.
   * Staff or admin, mandatory reason -- the same discipline §6.5 already
   * asks of an order-line override, applied here to a catalog price.
   */
  editProductPrice(
    listId: ListId,
    ruleId: string,
    edit: { rate_sen: number; mvp_rate_sen: number | null; reason: string },
  ): Observable<ProductPriceEditOut> {
    return this.http.post<ProductPriceEditOut>(
      `${API_BASE}/rate-cards/${listId}/products/${ruleId}/price`,
      edit,
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
  /**
   * Who this token belongs to, read fresh from the server. The backend's
   * own docstring says what this is for: "the app calls it on reconnect to
   * notice a revoked session, and to pick up a role or language changed in
   * the office" -- the mobile app already does exactly that on resume;
   * `Session.restore()` is the dashboard's equivalent, now that a session
   * survives a refresh.
   */
  me(): Observable<MyAccountOut> {
    return this.http.get<MyAccountOut>(`${API_BASE}/auth/me`, {
      headers: this.authorised(),
    });
  }

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
   * The shell a unit type lives under. Not admin-only on the server --
   * creating one is ordinary data entry, the same trust level as a quote
   * or a payment -- but a part-timer's own device can only ever pick from
   * projects it has already seen with a connection in hand (Phase 8's own
   * design), never create one. Somewhere has to be able to add the first
   * one, or the whole library has nothing to submit against.
   */
  createProject(project: {
    name: string;
    developer?: string | null;
    area?: string | null;
  }): Observable<ProjectOut> {
    return this.http.post<ProjectOut>(`${API_BASE}/projects`, project, {
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

  /**
   * Starts recognition in the background and returns immediately -- the
   * office upload path, where nobody is standing there waiting the way a
   * fair's own quoting is. Poll `recognitionJob` for the result.
   */
  startRecognitionJob(floorPlanId: string): Observable<RecognitionJobOut> {
    return this.http.post<RecognitionJobOut>(
      `${API_BASE}/floor-plans/${floorPlanId}/recognize-async`,
      {},
      { headers: this.authorised() },
    );
  }

  /** The latest background recognition attempt for this floor plan. */
  recognitionJob(floorPlanId: string): Observable<RecognitionJobOut> {
    return this.http.get<RecognitionJobOut>(
      `${API_BASE}/floor-plans/${floorPlanId}/recognition`,
      { headers: this.authorised() },
    );
  }

  // ---------------------------------------------------------------------
  // Inventory. SPEC.md Phase 9. Every route is admin-only, server-enforced
  // (§13 F2).
  // ---------------------------------------------------------------------

  materials(activeOnly = true): Observable<MaterialsOut> {
    const params = new HttpParams().set('active_only', String(activeOnly));
    return this.http.get<MaterialsOut>(`${API_BASE}/materials`, {
      params,
      headers: this.authorised(),
    });
  }

  createMaterial(material: {
    family: string;
    variant_compat: readonly string[];
    code: string;
    names: Readonly<Record<string, string>>;
    uom: string;
    coverage_per_unit?: string | null;
    reorder_level?: string | null;
  }): Observable<MaterialOut> {
    return this.http.post<MaterialOut>(`${API_BASE}/materials`, material, {
      headers: this.authorised(),
    });
  }

  deactivateMaterial(id: string): Observable<MaterialOut> {
    return this.http.post<MaterialOut>(
      `${API_BASE}/materials/${id}/deactivate`,
      {},
      { headers: this.authorised() },
    );
  }

  stockLots(materialId: string): Observable<StockLotsOut> {
    const params = new HttpParams().set('material_id', materialId);
    return this.http.get<StockLotsOut>(`${API_BASE}/stock/lots`, {
      params,
      headers: this.authorised(),
    });
  }

  receiveStock(receipt: {
    material_id: string;
    lot_ref: string;
    qty: string;
    cost_sen?: number | null;
    location?: string | null;
    note?: string | null;
  }): Observable<StockLotOut> {
    return this.http.post<StockLotOut>(`${API_BASE}/stock/receive`, receipt, {
      headers: this.authorised(),
    });
  }

  adjustStock(adjustment: {
    lot_id: string;
    delta: string;
    reason: string;
    note?: string | null;
  }): Observable<StockMovementOut> {
    return this.http.post<StockMovementOut>(
      `${API_BASE}/stock/adjust`,
      adjustment,
      { headers: this.authorised() },
    );
  }

  /** Defaults to the review queue -- everything `proposed`. */
  allocations(status: string = 'proposed'): Observable<AllocationsOut> {
    const params = new HttpParams().set('status', status);
    return this.http.get<AllocationsOut>(`${API_BASE}/allocations`, {
      params,
      headers: this.authorised(),
    });
  }

  /** An admin allocates directly, already decided -- for a material with no
   * exact auto-proposal conversion (§13 F3), or a manual split across a
   * second lot. */
  createManualAllocation(allocation: {
    order_line_id: string;
    order_id: string;
    material_id: string;
    lot_id: string;
    qty: string;
  }): Observable<AllocationOut> {
    return this.http.post<AllocationOut>(
      `${API_BASE}/allocations`,
      allocation,
      { headers: this.authorised() },
    );
  }

  /** `lotId` overrides the auto-picked lot -- required when a proposal had
   * none (§13 F3's "no single lot covers it" case). */
  approveAllocation(id: string, lotId?: string | null): Observable<AllocationOut> {
    return this.http.post<AllocationOut>(
      `${API_BASE}/allocations/${id}/approve`,
      { lot_id: lotId ?? null },
      { headers: this.authorised() },
    );
  }

  rejectAllocation(id: string, reason: string): Observable<AllocationOut> {
    return this.http.post<AllocationOut>(
      `${API_BASE}/allocations/${id}/reject`,
      { reason },
      { headers: this.authorised() },
    );
  }

  /** An order cancelled after stock was set aside for it. Puts the
   * quantity back on the lot it came from. */
  releaseAllocation(id: string, note?: string | null): Observable<AllocationOut> {
    return this.http.post<AllocationOut>(
      `${API_BASE}/allocations/${id}/release`,
      { note: note ?? null },
      { headers: this.authorised() },
    );
  }

  /** "Available", not raw on-hand -- SPEC.md §11 Phase 9. Not a forecast:
   * every figure is a row the server already has. */
  reorderAlerts(): Observable<ReorderAlertsOut> {
    return this.http.get<ReorderAlertsOut>(`${API_BASE}/inventory/alerts`, {
      headers: this.authorised(),
    });
  }

  private authorised(): Record<string, string> {
    const token = this.token();
    return token === null ? {} : { Authorization: `Bearer ${token}` };
  }
}
