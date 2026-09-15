# Milan Software

Soft furnishings order system for a Malaysian retailer (Melaka).
Curtains, blinds, SPC / vinyl / laminate flooring, wallpaper.

**Flutter** mobile app (quote, measure, deposit) · **Angular** web dashboard ·
**FastAPI** backend (sync, publishing, export).

Full detail in `SPEC.md`. This file is the context that must never be violated.

---

## Current state

**Recognition runs in the background for the one place that can afford to
wait, and now suggests a track width, not just an opening size** (Sep
2026), both asked for directly after the real local model tested above
turned out to take several minutes on a genuinely complex plan.

`app/services/recognition_jobs.py` adds `POST /api/floor-plans/{id}/
recognize-async` (starts a `RecognitionJob` row, returns immediately) and
`GET .../recognition` (reads the latest one) -- SPEC.md §14.7's own
suggested shape for exactly this ("a status a client polls... without
reaching for infrastructure this system does not otherwise run"): a
FastAPI `BackgroundTasks` callback threadpooled off the request, one new
table, no queue, no worker process. `POST /api/recognize` (stateless) is
untouched and stays the fast path for everything that still needs one.

**The two paths split on a real distinction, not a preference**: a
part-timer recognising a photo at a fair table needs an answer in seconds,
so the handset's own "try recognition" was deliberately left calling the
synchronous route unchanged -- that path should reach a fast hosted
vendor, or nothing (manual entry is never gated on recognition). An admin
digitising a plan after an upload is not standing there waiting, so only
the dashboard's review screen moved to the background job; a locally
hosted model taking minutes costs nothing there and keeps the image off a
third-party server entirely. `unit-type-review.ts` polls every 3s via a
plain `setTimeout` (this codebase's first, deliberately not reaching for
RxJS's `interval`/`switchMap` for one polling loop) and cleans up via
`DestroyRef.onDestroy` if the admin navigates away mid-job.

**`ProposedOpening` gained `suggested_track_w_tmm`/`suggested_drop_h_tmm`**
(`app/services/recognition.py`, all three provider adapters, the dashboard
review screen), separate from the opening's own `nominal_w_tmm`/
`nominal_h_tmm` -- what a curtain track needs is not always what the
window itself measures. Deliberately asymmetric, because the two
questions are not equally answerable from a floor plan: wall space beside
an opening is exactly what a top-down drawing shows, so a track-width
suggestion is legitimate; a floor plan has no elevation view and
essentially never shows a ceiling height, so the prompt is explicit that
`suggested_drop_h_tmm` stays null unless one is actually printed on the
plan, never estimated. In practice this field is almost always null,
honestly, rather than a guessed "typical ceiling" that would be exactly
the confident-wrong-number Phase 8 already warns against. Both fields are
shown, never auto-applied -- there was never a field on this screen they
could silently fill.

Confirmed while answering this: the property library's existing
project/unit-type search and the wizard's "start from a saved plan"
picker already let any signed-in user, including a part-timer, pull up a
previously digitised window or room -- nothing new was needed there.

19 new backend tests (`test_recognition_jobs.py`,
`TestRecognitionJobApi` in `test_library_api.py`, plus new
`suggested_track_w_tmm`/`suggested_drop_h_tmm` parsing cases in
`test_recognition_providers.py`), mutation-confirmed on the job-ordering
logic. 5 new/replaced dashboard tests drive the async flow through real
DOM clicks with vitest's fake timers standing in for the poll interval.
890 backend tests, 335 dashboard tests.

**Floor-plan recognition has three real providers now, asked for directly**
(Sep 2026): SPEC.md §14.7 and "Future: assisted digitisation" both
deliberately left *which* vendor to a later decision, made explicitly this
session rather than guessed at. `app/services/recognition_providers.py`
registers `anthropic`, `openai` and `gemini` alongside
`NullRecognitionProvider` (still the default): each sends the floor-plan
image with a forced structured-output call -- a tool call, a function call,
or a constrained JSON schema, whichever that vendor calls the same idea --
so a malformed or missing field is a parse failure to catch, not prose to
trust. Every one of §14.7's reliability rules is what the tests actually
pin: no API key set, a timeout, a refusal, or a response that does not fit
the schema all degrade to the same typed `configured`-aware result
`NullRecognitionProvider` already returned, never an exception a caller has
to handle specially, and one malformed item in an otherwise-good response
does not sink the rest of the proposal.

**Also the seam for "wrap a local model as one of these later,"** which is
the specific direction asked for: each adapter reads its own `_BASE_URL` env
var (`ANTHROPIC_BASE_URL` and its OpenAI/Gemini equivalents) and, when set,
points that vendor's own official SDK at it instead of the real API --
so a self-hosted model, once wrapped to answer in whichever vendor's
request/response shape is easiest to implement, plugs in as a config change
on a box that already has this code, exactly like switching between the
three hosted vendors is. No fourth adapter was built for "local" specifically,
because there is nothing a local-only adapter would do differently from
pointing an existing one's base URL at `localhost`.

Going live with any one of them is now genuinely just an env var and a key:
`RECOGNITION_PROVIDER=anthropic` (or `openai`/`gemini`) plus that provider's
own `_API_KEY` in `.env` -- `docker-compose.yml`'s `api` service already
passes all three keys and all three base-URL overrides through
unconditionally, each blank and inert until named. Which one (if any) is
actually worth running against real developer floor plans, and at what cost
per call, is exactly the open question SPEC.md's own §13 H2 says this
session had no grounds to answer on the client's behalf -- wiring in three
real options makes trying any of them free, not the same thing as picking
one.

31 new backend tests (`test_recognition_providers.py`, plus new selection
cases in `test_recognition.py`), every provider's own extract() mocked at
the SDK client level so none of them make a real network call; mutation-
confirmed on the base-URL wiring. 863 backend tests.

**A security review of the API itself, asked for directly rather than found
by a sweep** (Sep 2026, same session as the deploy work below): rate
limiting, a request-size ceiling, and a deliberate explanation of two things
already built rather than missing -- because "add JWT" and "add input
sanitisation" were both asked for by name, and the honest answer for each is
that this system already made a different, better-fitting choice, not that
either was forgotten.

**No JWT, on purpose, and this should not change.** `app/core/security.py`
already does the harder thing properly: a 256-bit random token, its SHA-256
fingerprint (never the token itself) is what is stored, and revocation is a
row update, not a blocklist. SPEC.md §12 requires sessions that never expire
-- expiry mid-fair with no signal holds a customer's deposit -- and a JWT
answering that requirement needs either a long-lived signed token with no
revocation path (a stolen one is valid forever, no matter what an admin does
in `/api/people/{id}/deactivate`) or a server-side revocation list anyway, at
which point it is this design with worse failure modes: algorithm-confusion
and `alg: none` attacks that only exist because a JWT carries its own
verification instructions, and a stored secret whose rotation invalidates
every session at once instead of one at a time. Introducing one here would
be a downgrade dressed as a best practice.

**Input handling was already careful; this looked for the gaps rather than
assuming there were none.** SQLAlchemy's query builder throughout (`grep`
for raw `text()`/string-built SQL found none), Pydantic validation on every
request body, a path-pattern allowlist on `list_id` (`^(fair|standard)$`)
rather than a free string reaching a query, `base64.b64decode(...,
validate=True)` rather than silently dropping bad characters, and
`library.py`'s own `ALLOWED_FLOOR_PLAN_CONTENT_TYPES` -- already commented,
before this review touched it, as a deliberate stored-XSS guard: serving a
client-supplied `content_type` back verbatim on `GET /api/floor-plans/{id}/
image` would let an `image/svg+xml` or `text/html` upload render as a
document instead of a picture the moment anything fetches that URL outside
an `<img>` tag. `MAX_FLOOR_PLAN_BYTES` (10MB) already bounded a single
upload before this review, in all three places that accept one.

**What was actually missing: nothing stopped one source from hammering the
API at all**, as opposed to `app/services/auth.py`'s existing throttle, which
answers a narrower question -- is *this phone number* being brute-forced --
and never accumulates against an attacker spraying many different numbers
from one address. `app/core/rate_limit.py` is a sliding-window counter,
per-source-IP, checked by a new `rate_limit_middleware` on every request
except `/api/health` (the one route a container health check and an
external uptime monitor both hit on a schedule neither backs off from): a
tight rule on `/api/auth/login` (20/min) layered under the existing per-phone
backoff, and a loose backstop everywhere else (300/min) that nothing in
normal use -- a handful of handsets, one dashboard -- comes near. **In-memory,
correct only because this API is exactly one worker process** (`backend/
Dockerfile`'s own comment says why: so Alembic cannot race itself on boot) --
a second worker or a replica would each keep a blind counter, silently
multiplying every limit by however many there were, and would need a shared
store (the database, the way the phone throttle already uses one) first.
Both the pure sliding-window arithmetic and the middleware wiring are tested
(`test_rate_limit.py`, a new `TestRateLimiting` in `test_api.py`); a new
`tests/conftest.py` -- the first in this repo -- resets the limiter's state
between tests, since it lives on the same module-level `app` object every
test file's own `client` fixture reuses, and without the reset one test's
burst of requests would start failing a later, unrelated one. Mutation-
confirmed: disabling the threshold check killed exactly the four tests that
should catch it and nothing else.

**`deploy/Caddyfile` gained a request-size ceiling on `/api/*`** (`request_body
{ max_size 20MB }`, validated with `caddy validate` the same way CI already
does), ahead of `MAX_FLOOR_PLAN_BYTES` rather than instead of it -- that check
runs only after FastAPI has already parsed the whole body into memory, so a
transport-level cap is the layer that also protects against a body that is
just bytes, no image, sized to hurt. Not functionally exercised end-to-end
locally: doing so needs a resolvable domain for Caddy's automatic HTTPS, the
same obstacle CI's own "Compose file and Caddyfile are valid" step already
names and works around by validating rather than serving.

**Recommended, not built:** a Content-Security-Policy header on the
dashboard. `dashboard/src/index.html` already preconnects to Google Fonts,
so a CSP needs `style-src`/`font-src` entries for it, and getting a CSP
wrong fails closed -- the whole app stops rendering, silently, with nothing
but a browser console to say why. That is a real risk to carry without a
browser to load the built app in and watch for violations, which this
session did not have; flagged rather than guessed at.

CORS middleware was deliberately not added: the dashboard never calls the
API cross-origin in any real path -- Caddy serves both from one origin in
production, and `dashboard/proxy.conf.json` proxies `/api` server-side for
`ng serve` -- so a CORS policy here would be permissive configuration
guarding a request that can never actually happen from a browser.

**Deploy gained the pieces "one node" was always going to need before a real
customer's money sat on it** (Sep 2026): resource limits, a rollback-capable
release path, a second environment, a firewall, and an external heartbeat.
None of it changes what runs -- `docker-compose.yml`'s services are the same
three containers -- it changes what happens when one of them misbehaves.

**Every service now has a memory/CPU ceiling and a capped, rotating log**
(`deploy/docker-compose.yml`). Without either, the actual failure mode on a
small VPS is not "slow" -- it is the box going down at 3am, OOM with nothing
to stop at or a json-file log with no cap filling the disk, and the first
anyone hears of it is a customer at a fair with a screen that will not load.

**Releases can now be pulled instead of rebuilt, and rolled back.**
`release.yml` has published probed images to GHCR since Phase 5, and until
now nothing on the VPS ever used them -- "Upgrading" rebuilt from source on
the box itself every time, which is slower on small hardware and is not
provably the same bytes CI just tested. `docker-compose.prod.yml` (a Compose
override using `!reset` to drop `build:` entirely, Compose v2.24+) points
`api`/`caddy` at a specific tag instead; `deploy.sh <tag>` backs up, checks
out that tag, pulls both images, brings the stack up, and polls the API
image's own `HEALTHCHECK` (already baked into `backend/Dockerfile`, unused
by anything until now) rather than re-deciding what "healthy" means. It
fails loud with no automatic rollback -- guessing that the previous tag is
safe to silently reinstate is the same kind of guess this repo does not make
about money, applied to a deploy. Rolling back is running it again with the
previous tag. The dashboard's own Caddy image gained a matching
`HEALTHCHECK` (a plain liveness curl against :80, deliberately not
requiring 2xx -- the ACME/redirect port answering at all is Caddy being up),
since nothing had ever asked it that question either.

**Staging exists**: the same `docker-compose.yml`, on its own box, with its
own `.env` (`deploy/.env.staging.example`) and its own database -- not a
Compose override, because the whole point is that nothing behaves
differently from production except which box it is. `.github/workflows/
deploy.yml`'s `staging` job deploys every tag there automatically, gated on
`release.yml` having actually built and probed that tag's images first
(`workflow_run`, mirroring how `release.yml` itself waits on CI); its
`production` job is `workflow_dispatch` only, so a production deploy is
always a person opening Actions and typing a tag, never a side effect of
anything else. `environment: staging`/`production` on each job is a hook for
required reviewers to be added later in Settings -> Environments; the
asymmetry between the two jobs is the actual safety net today.

**A background security review of that workflow found a real actions-
injection hole, same day.** A git tag's ref-name rules forbid spaces and a
handful of symbols -- `;`, `` ` ``, `$()` are not on that list -- so
`deploy.yml`'s first draft interpolated the tag straight into a `script:`
block's text (`./deploy.sh "${{ ... }}"`), and a tag containing any of those
would have run as shell on the SSH target rather than as a filename. Fixed
by reading the tag through `env:`/`envs:` instead -- GitHub sets it as a real
environment variable there rather than substituting text into the script,
the same data-vs-code line this repo already draws for SQL -- and by
replacing the case-glob shape check with an anchored regex, since `*`
swallows trailing garbage a glob was never told to reject. `deploy.sh`
re-checks the same regex itself rather than trusting the workflow's gate to
be the only caller ever, matching the same "don't trust the caller's
gating alone" rule `recordMeasurement` already follows. `appleboy/ssh-action` also moved off
the floating `@v1` tag to a pinned commit SHA -- stricter than every other
third-party action in this repo, which all still pin a floating major
version (`docker/build-push-action@v6` and the rest), and deliberately so:
this is the one action that runs arbitrary commands against real
infrastructure over SSH rather than inside a throwaway CI container, so a
maintainer quietly moving what `@v1` points to is a materially worse outcome
here than anywhere else it is used today.

**`harden.sh`** is the one-time OS setup "First boot" always should have
named: ufw (22/80/443 only, SSH allowed before the default-deny takes
effect, or a fresh box locks out the session that just ran it) and fail2ban
on sshd. Neither was ever a Docker Compose concern, which is exactly why it
had never been written down.

**Monitoring is explicitly not code**: an UptimeRobot check against
`/api/health` on both domains, documented in `deploy/README.md`'s new
"Monitoring" section rather than built, because the one failure mode that
matters most -- the whole box is unreachable -- is exactly the one a
monitor running on that box cannot report on its own.

**The property library had no way to create its own first row.** The same
unused-`Api`-method sweep that found the two Phase 9 gaps below turned up
a bigger one: `POST /api/projects` existed, was tested, and was
unreachable from *either* client. Mobile's own project picker is
deliberately read-only (Phase 8: "a submission can only ever point at a
project this handset has already seen with a connection in hand"), which
is correct for a part-timer at a fair -- but it means nothing, anywhere,
could ever create the project a first submission would need to point at.
No CLI command for it either. `unit-type-review.ts` gains a small "Add a
project" control -- name, developer, area, matching `ProjectIn` exactly --
since the admin review screen is where "the office is setting up a new
development before anyone visits it" already belongs. 3 new dashboard
tests. 333 dashboard tests.

Two more routes turned up in the same sweep, named rather than built:
`POST /api/unit-types/{id}/submit` (draft-then-submit) and `POST
/api/unit-types/{id}/versions` (a correction to an *approved* unit type)
are both tested and both unreachable, and both need the same missing
piece — an admin-authoring surface for the library beyond the review
queue. That is a real feature, not a small patch (an openings/rooms/
floor-plan form matching the mobile submission screen's own complexity),
so it is SPEC.md §13 **C17** rather than a guess.

**Two more Phase 9 routes existed, tested, with no way to reach them** —
found the same way the `me()` gap above was: grepping every `Api` method
the dashboard defines against what actually calls it. Two came back
unused outside `api.ts` itself and their own tests.

**Stock adjustment.** `adjust_stock` (damage, an offcut returned, a
stock-take correction, a return to the supplier) has been in
`app/services/inventory.py` since Phase 9 shipped, and the dashboard's own
`InventoryStrings` already carried every label the four reasons need
(`reasonDamage`, `reasonOffcutReturn`, `reasonAdjustment`,
`reasonReturnToSupplier`) — planned, never wired to a screen. `materials.ts`
gains an "Adjust" control per lot, next to "Receive stock" in the same
expanded row: a signed delta, a reason picked from the four the backend
actually accepts (`receipt` excluded -- that is the separate receiving
form this screen already has), an optional note. Refreshes the lot and the
material list on success, the same as receiving stock already did. 2 new
dashboard tests.

**Releasing an allocation.** `release_allocation` -- reversing an approved
allocation, "an order cancelled after stock was set aside for it" per its
own docstring -- existed, was tested, and had no control anywhere. Closing
it needed one real schema addition, not just a dashboard change:
`OrderDetailOut` never carried an order's own allocations at all, so there
was nothing to show a release button against. `order_detail()` now joins
them in (`reads.py` gained a shared `allocation_out()`, moved out of
`main.py` where it was private and duplicated across five routes rather
than copied a sixth time). The order detail screen shows what is already
claimed against each line -- proposed, approved, or released, never
rejected, which is the review queue's own history and not a fact about
the line today -- with a "Release stock" button on an approved one, right
where an admin is already looking at the line it explains. 1 new backend
test, 5 new dashboard tests. 823 backend tests, 330 dashboard tests.

**The handset had the same gap, worse: `ApiClient.me()` was dead code, and
a real bug meant its own manual sign-out branch could never fire either**
(found while sweeping for other instances of the dashboard gap above, Sep
2026). `me()` — `GET /api/auth/me`, calling out to notice a revoked session
and pick up a role or language changed in the office — was defined,
correctly wired into the fake test server, and never called from anywhere
in `lib/`. A deactivated part-timer's handset kept quoting, kept whatever
admin UI its cached role unlocked, and kept queueing to an outbox that
would never drain, indefinitely, until something else happened to notice.

Separately, `SyncController.syncNow()`'s own revocation handling
(`state.signedOut` → `signOutLocally()`) sat *after* the rate-card pull —
but a revoked token 401s the pull itself first, which takes an **early
return** a few lines above that check. The one branch built to catch this
could not be reached by the exact case it was built for; nothing in
`test/` referenced `signedOut` or `signOutLocally` at all, so nothing had
ever exercised it either way.

Fixed together: `syncNow()` now calls `me()` first, before the pull.
`unauthenticated` signs out immediately, spending nothing on a price pull
for a token already dead. A role or language that disagrees with what the
handset is holding is written back through a new `CredentialsNotifier.
updateIdentity()`. Anything else (offline, a one-off hiccup on that one
call) falls through to the pull exactly as before `me()` existed — this
must never become a second gate on quoting, hard rule 9's whole point. The
pull's own early-return path now also checks `signedOut` before returning,
closing the original unreachable-branch gap independently of the new check
racing ahead of it. A related, smaller finding from the same sweep: a
restored session's language never re-seeded `languageProvider` on launch —
a Malay-only reader force-quitting and reopening saw the app default back
to Chinese until they re-picked it by hand; `CredentialsNotifier.build()`
now seeds it, the way `signIn()` already did for a fresh sign-in.

`SyncController` had no unit coverage at all before this — 6 new tests in
a new `test/sync/sync_state_test.dart` are the first, covering all of the
above including the pre-existing early-return bug (which the "offline
never gates a sync" case would have caught regressing). `test/sync/
fake_server.dart` gained a `meResponse` field so a test can simulate a
changed role without touching its existing, unrelated callers. 926 Dart
tests.

**A revoked dashboard session used to keep rendering as signed in** (found
and fixed in a gap sweep after the shell pass above, Sep 2026) — a real
regression risk the session-persistence work introduced rather than one it
merely inherited. `Api.token`'s own doc comment already promised "a 401 can
clear it from anywhere," but nothing ever actually did it: a 401 became a
worded "you were signed out" message on whichever one screen happened to be
mid-request, while the sidebar and every other open screen kept showing the
stale signed-in shell. A new `authInterceptor` (`auth/auth.interceptor.ts`,
wired in `app.config.ts`) now signs out and returns to `/sign-in` on any 401
raised while `session.signedIn()` was true -- scoped that way specifically
so it never fires on a wrong PIN at the login form itself, which
`Session.signIn` already classifies on its own.

The other half of the same gap: `GET /api/auth/me` already existed, tested,
and its own backend docstring already said what it was for -- *"the app
calls it on reconnect to notice a revoked session, and to pick up a role or
language changed in the office"* -- and the mobile app already calls it on
resume. Nothing on the dashboard ever called it, because before a session
could survive a refresh there was nothing stale left to reconnect. Now
`Session.restore()` does exactly what the route was built for: the cached
identity paints the shell immediately (that immediacy is the whole reason
to persist one), confirmed against the server right after, in the
background -- a role or language changed while the browser was closed is
picked up, and a token that no longer works is caught by the same
`authInterceptor` rather than a second, separate code path. 6 new dashboard
tests (the interceptor's own spec, plus two on `Session` pinning the
restore-time reconciliation and its own offline-safe fallback). 323
dashboard tests.

**The dashboard's shell and shared visual language got a second pass**
(Sep 2026), closing the drift the first design-system pass could not: nine
screens each still had their own local button, table and header
implementation, so tokens changed everywhere but nine slightly different
buttons still existed underneath them. Full detail, and the one real
finding (a test that counts `.card` elements as a proxy for queue length,
which decided how the library review screen's empty state had to be
styled), is in `dashboard/design-system/MASTER.md`'s own second section.

The top bar — ten links trying to fit one row — is now a fixed sidebar
grouped into sections (everyone's own links, then admin-only Pricing,
Operations, Insights), with a small shared icon component
(`shared/nav-icon.ts`) rather than inline SVG repeated at every link. Three
new shared shapes in `styles.css` (`.page-header`, `.stat-card`, a
segmented-control pattern for every list/channel/period filter) replace
what each screen was separately approximating, and every screen's buttons
now come from `.btn`/`.btn-primary`/`.btn-danger` rather than a local
near-copy. The sign-in screen gained a two-panel brand layout in place of a
bare centred card. No business logic changed, no screen's information
changed, and all 317 dashboard tests were re-verified against the new
markup rather than rewritten.

**Stage 1 — the core Milan system — is complete through Phase 8.** Flutter
app, FastAPI backend, Postgres, and sync between them. Phase 7 has exactly
one remaining piece — the SQL Account export — and that blocker is isolated
to it; it does not describe Stage 1 as a whole, and it does not hold up
Stage 2 (SPEC.md §2.4, §11).

**Phase 7 so far.** The buyer-detail capture screens, both sides, the sync
between them, and the document labelling audit. **Only the export is left, and
it is blocked**: it needs a sample import template (§13 **E1**) and the
accountant's ruling on **E2**, and §13 **C12** and **C13** decide where the
guard bites and which fields MyInvois actually rejects. Do not guess any of the
four. Everything else on Phase 7's "In" list is built.

**Stage 2 — the next tier — has a defined shape, and Phase 9 has started.**
SPEC.md §2.4 and §11's roadmap table say what it holds: Phase 9
(Inventory), further property-library depth, and the AI-capability
boundary SPEC.md §14.7 documents. **AI is not implemented and is not
required for anything.** §14.7 fixes where a future capability would plug
in — domain → capability → provider interface → adapter → provider, one
interface per capability, provider/model chosen by env var, credentials
backend-only, a proposal never production truth without a human step —
using `app/services/recognition.py` (Phase 8) as the one existing instance
of the pattern. Choosing an actual provider, or building a second
capability, is future work named in SPEC.md §13 **H**, not scheduled here.

**Phase 9 — Inventory — started, Sep 2026, once §13 F2 had a real
answer**: the office's own purchasing/supplier-ordering person, a specific
individual rather than a department, which is what the phase's own opening
paragraph asked for before anything got built. Migration 0009 (`materials`,
`stock_lots`, `stock_movements`, `allocations`). `app/services/inventory.py`
carries the ledger discipline in one place — `qty_on_hand` only ever moves
alongside a `StockMovement`, in the same transaction, and a movement that
would take a lot negative is refused. Two routes to an approved allocation,
one gate, the same shape the library already uses: an area-priced material
(box-counted, billed `per_sqft`) auto-proposes from `push_measurement`
itself, sized off the **exact final quantity** `reprice_order` just
computed — never `OrderLine.billed_qty`, which stays the fair's rounded-up
estimate forever, so an allocation cannot end up sized off a guess. Every
other material (fabric, where the billed width is not the yardage — §13
F3 says why that conversion is not guessed) is allocated manually, already
decided, through the same route an admin already has. "Available", the
figure reorder alerts and the dashboard both read, is on-hand minus what
is only `proposed` — not a forecast, every number in it a row the system
already has. Admin-only throughout (§13 F2's own answer). The dashboard
gained two screens: `/inventory` (materials, their lots, receiving stock,
a reorder-alert badge) and `/inventory/allocations` (the review queue,
approve or reject, a lot picker when auto-proposal could not choose one).
54 new backend tests, 15 new dashboard tests.

**The order detail screen now has the manual-allocation control** (Sep
2026), closing the one gap Phase 9 shipped with. `POST /api/allocations`
already existed and was tested; this is its natural home, where an admin
is already looking at the line and its material. Materials are fetched
only once the control is opened on some line — most orders are curtains
or blinds, never inventory-tracked, and a screen opened on every order
should not fetch a list it will almost never use. Choosing a material
loads its lots; a lot must be picked explicitly (no auto-pick here, unlike
approval) because a manual allocation has no proposal behind it to trust.
No backend change was needed — purely the dashboard control the API was
already waiting for. 7 new dashboard tests, driven through the DOM the
same way the buyer-correction form's own tests are, so what is checked is
the form somebody actually clicks through. 296 dashboard tests.

**A bug hunt on Inventory (Sep 2026)** — never swept before, since Phase 9
shipped after both earlier sweeps — found two real gaps, both fixed and
each pinned by a test proven to fail before the fix and pass after. A
manual allocation's `order_id` was never checked against the order the
given `order_line_id` actually belongs to, so a mismatched or made-up id
was silently stored on the `Allocation` row; the route now refuses (404)
on mismatch. And both `allocation-review.ts` and the manual-allocation
control above cached a material's stock lots and never refreshed them
after an approval or an allocation decremented one, so a second pending
item on the same material kept showing the pre-decrement quantity; both
now force a refresh after the mutation that invalidates the cache.
Full detail in `FINDINGS.md`'s third dated section. 787 backend tests,
298 dashboard tests.

**The pricing engine can now price a pre-known area directly, on both
sides** (Sep 2026) — the real gap behind the client's "auto-calculate a
full SPC flooring quote" ask (§ Property Library). Tracing the actual
code before touching it found the gap was deeper than a missing picker
screen: every `per_sqft` line, at quote time and at final measurement,
has always priced from `width x height`, but a saved room's
`nominal_area_mm2` deliberately stores only the *result* — a real room
isn't always a rectangle, so there was never a width/length pair to keep.
A saved room's area could not be dropped into the existing sizing step
because there was nothing honest to drop in.

`LineRequest.width` is now nullable on both engines (Dart and Python),
and a new `directAreaSqft`/`direct_area_sqft` field lets a `per_sqft` line
price from a pre-known exact-rational area instead of multiplying two
dimensions — meaningful only for that one basis, ignored by every other.
Every other place that read `request.width` unconditionally (`per_ft_width`,
`per_m_length`, the measured `per_roll` branch) now null-checks it and
refuses cleanly rather than crashing, which `flutter analyze` forced site
by site rather than leaving any to find by testing. **Refused, not
guessed, at final pricing**: a plan-derived area is an estimate, and site
measurement remains production truth (Phase 8's own "line that must never
blur"), so `directAreaSqft` at `PricingStage.finalPricing`/`FINAL` raises
`NoApplicableRate` on both sides rather than letting a stale room figure
stand in for a real tape measurement. A non-positive area is refused the
same way.

Two new cases in `shared/pricing-fixtures.json` (`direct-area-flooring-
below-minimum`, proving the printed 200 sqft floor still applies; `direct-
area-flooring-fractional-area-rounds-up`, proving `700/3` ceils to exactly
234 sqft, never a float) hold both engines to the same numbers, plus four
hand-written tests (two per side) pinning the final-pricing and
positive-area refusals — each proven to fail before its guard and pass
after by reverting the guard and re-running. 911 Dart tests, 791 backend
tests.

**Now wired all the way through, same session.** What started as "add a
picker screen" turned out to need real schema work on both sides, done in
full rather than left half-connected.

`QuoteLines.widthTmm` and `OrderLines.estWidthTmm` are nullable (Drift
schema v15) — the first migration in this project to widen a constraint
rather than only add a column, so it runs through `alterTable`/
`TableMigration` (a real table recreate on SQLite) instead of `addColumn`,
which cannot change nullability. `direct_area_sqft` (exact rational as
text, `QuoteLines` and `OrderLines`) carries the area alongside. Mirrored
on the server: an Alembic migration (`0010`, `batch_alter_table` so the
same file runs correctly on SQLite in tests and Postgres in production)
widens `quote_lines.width_tmm`/`order_lines.est_width_tmm` and adds the
matching column; `QuoteLineIn`/`OrderLineIn`/`OrderLineOut` all carry it
now. `ApprovedUnitType` (mobile) parses a unit type's `rooms` alongside its
`openings`, previously dropped on the floor.

**The wizard's picker now offers a room, not only a window.** Picking one
seeds a `per_sqft` flooring line straight from its stored area: no family
step (a room can only ever be flooring, so there is nothing to choose) and
no sizes step (the area is already known, so there is nothing to prefill
or edit) — one fewer screen for the one case where the next two answers
were already decided. `_back()` skips the same two steps in reverse. A
room-sourced add-on (dismantling old flooring, self levelling) bills on
the parent line's own area rather than a width it does not have — the same
"same square footage" rule CLAUDE.md already documents for a measured
line's add-on. The measurement screen's "quoted as" preview shows the area
in `sqft` for a room-sourced line rather than crashing on a null width, and
the dashboard's order-detail screen does the same (`sizeAreaSqft`).

Two widget tests drive the real wizard end to end against a fake server:
picking a room with no sizes step in between, and a room-sourced add-on
correctly billing on the parent's area instead of crashing on a missing
width. 918 Dart tests, 794 backend tests, 300 dashboard tests — all three
suites green, `flutter analyze`/`dart format`/ruff clean. CI's own
Postgres job (`deploy`) confirmed the Alembic migration on the real
database, not only against `test_migrations.py`'s SQLite.

**Skirting is now offered too** (Sep 2026), the piece named as a smaller
follow-up above. `rooms.skirting_run_tmm` is a real length — skirting is
its own `per_ft_width` product (RM4/ft), not part of the flooring line's
`per_sqft` area — so it needed no engine change, only wiring: picking a
room with one recorded shows a bottom sheet (`_SkirtingSheet`, matching
`deposit_prompt_sheet.dart`'s own shape for a yes/no decision that is not
really a wizard step) offering to add it as its own line, asked before the
flooring product step rather than folded into it or buried as an upgrade
under whichever floor gets chosen. Two more widget tests cover accepting
and declining. 920 Dart tests.

**Every product's price can now be moved live, on the spot, with no upload
and no preview step** (client, Sep 2026): *"even at a fair can adjust price
of certain item to fight competitors."* The whole-card upload/preview/
publish screen (`/rates`, admin-only) stays exactly as it was, for what it
is actually good at — bringing in a whole new printed season's list, where
seeing every row move before committing matters. This is the other case:
one product, one price, changed in the time it takes to type a reason.

**Staff or admin, never a part-timer** (hard rule 8), and it is still never
an edit in place: `POST /api/rate-cards/{list}/products/{rule}/price`
publishes a new `RateCardVersion` with just that one rule changed, through
the same `publish_card` the whole-card route already calls — a quote priced
at the old rate, or a rate lock pinned to it, stays exactly as explainable
as it always was. `rate_cards.version` is a **global** sequence shared by
both the fair and standard lineages (fair started at 1, standard at 101 in
production), so the next version has to be computed as one past the
highest version either list has ever used, never "one past this list's
own" — the first live edit to a long-untouched list jumps straight past
whatever the other list is already at.

Every edit is `RateCardEdit`, a new append-only audit table alongside
`price_overrides` and `stock_movements` — before/after on both the rate and
the MVP tier, a mandatory reason, who, and when. `decide_rate_edit`
(`app/pricing/rate_edit.py`) is the pure decision function, mirroring
`price_override.py`'s own shape but taking no role to check: unlike that
file's caller, a device merely claiming a role, this is only ever reached
through a route already gated to staff or admin, so re-checking here would
just be the same rule twice. A22 keeps working unmodified through this
path: supplying a real rate on a `provisional` placeholder clears the flag
in the same edit, because the rule lives in `edit_product_price`
(`app/services/ingest.py`), which both routes now share.

**A schema trap caught before it shipped.** `ProductPriceEditIn.
mvp_rate_sen` first had `default=None`, so a caller that meant to touch
only the plain rate but omitted the MVP field would silently *clear* a
real MVP rate it never intended to touch — the same absent-vs-null trap
§13 C14 already names for buyer details. Caught by a failing test
(`test_no_change_is_422`, which unexpectedly returned 200) before ever
reaching the dashboard; the field is now required in the request body,
`null` sent explicitly for a product with no MVP tier, exactly as a real
edit form always submits both fields it shows.

The dashboard gained `/rates/products` (nav link for staff and admin, next
to the admin-only publish link): every product on the chosen list, its
rate and MVP rate, a provisional badge, and an inline edit form per row —
rate, an MVP-rate checkbox and box, a mandatory reason. Client-side
validation re-derives the same three refusals the server's pure function
would give (non-positive, unchanged, reason too short) so a fair-table
edit gets an instant answer rather than a round trip that comes back
refused; the server's decision still wins if the two ever disagree. 27 new
backend tests for this feature (13 in `test_rate_edit.py`, 14 in the new
`TestLiveProductPriceEdit` class in `test_api.py`), 11 new dashboard tests
(`products.spec.ts`).

**Two of the smaller named gaps above are closed, same session.**

The order board's salesperson filter is built: `confirmed_by_user_id` on
`GET /api/orders`, a plain equality on a column `Order` already carried,
admin-only in the dashboard (matching `GET /api/people`'s own gate — a
filter whose names came from a route that would 403 for anyone else is not
a filter, it is a broken control). The other two named in that same
sentence stay open, and for reasons worth recording rather than guessing
past: "fair" means *which* fair, which lives only as the promo code on
whichever `RateCardVersion` an order's deposit pinned — a real join and a
real performance question, the same class of "statement count must not
grow with the board" question §11 Phase 5 already had to answer once for
`held_until`, not a filter to bolt on by inference. "Project" has no
column on `Order` at all — provenance lives on an order *line* (Phase 8),
and picking one of several lines' `source_project_id` to represent the
whole order is a design call, not a bug fix. 1 new backend test, 3 new
dashboard tests.

The dashboard session now survives a page refresh, in `sessionStorage`
rather than the in-memory-only signal it was. The reasoning that kept it
in-memory is the same one this file already retired above for the
language picker: *"a token in `localStorage` on a shared office machine is
one the next person inherits"* was true when written and false since every
office PC turned out to belong to one person. `sessionStorage`, not
`localStorage`: gone the moment the tab or browser closes, so it never
becomes a standing secret the way a `localStorage` token would, but it
survives exactly the refresh that used to cost a second sign-in. Nothing
about §12's "sessions never expire" changes — the token is exactly as
long-lived as before; this only changes where the browser may remember one
it already holds.

**A new trap, found writing this feature's own tests.** Persisting the
session to a real `sessionStorage` means any spec that drives an actual
sign-in (submitting the real form, not just `session.user.set(...)`)
leaves a token behind that a *later* test's own fresh `Session` silently
rehydrates — `sign-in.spec.ts`'s "the account language wins" test read as
signed-out and wasn't, because an earlier test in the same file had really
signed in and nothing cleared `sessionStorage` after. Fixed there, and
`session.spec.ts` clears it too: any future spec that exercises a real
sign-in needs `sessionStorage.clear()` (and `localStorage.clear()` for
parity) in its own `beforeEach` — this is not caught by the framework,
only by a test failing in a way that looks like an unrelated bug. 3 new
tests on `session.spec.ts` pin the new behaviour (survives a simulated
refresh, `signOut` clears the persisted copy too, a corrupted entry reads
as no session rather than throwing). 822 backend tests, 317 dashboard
tests, all three suites green.

**The dashboard has a real design system now** (client, Sep 2026): light and
dark mode, a token-driven palette (`dashboard/design-system/MASTER.md`
records why, mirroring the handset's own doc), skeleton loading and empty
states on every screen that lacked one, and a self-service `POST /api/auth/
language` so a language pick now follows the **account** rather than dying
with the browser tab — the office turned out to be one PC per person, not the
shared machine the original design assumed, so that reasoning is retired. The
sign-in screen lost its own language picker (nothing there yet to ask) and
gained a reserved space for the client's logo, still a placeholder. Dark mode
is a `localStorage` browser preference, deliberately not tied to the account:
unlike language, it is not a fact about the person. 258 dashboard tests.

**Phase 8 — Property / Project / Unit Library — has started, server side
only.** Brought forward from its stated "Stage 2, quoted after Phase 5 runs
live two months" per direction given this session; the client's own Sep 2026
request (store repeat-project measurements) already maps onto this exact
design, per SPEC.md's own Phase 8 section, so the commercial case predates
this build rather than being assumed by it. Migration 0007: `projects`,
`unit_types`, `unit_type_versions`, `openings`, `rooms`, `floor_plans`, and
provenance columns on `order_lines` (`measurement_source`,
`source_project_id`, `source_unit_type_id`, `source_version`) — an enum from
day one rather than a boolean, because adding a third measurement source
later to `is_site_measured` would be a migration across every order ever
written, and this is that third source arriving.

**Reference measurements are not site measurements**, enforced by omission:
`app/services/library.py` has no idea what an order is, and nothing it
returns can become an `OrderLine` except through the pipeline's existing
site-visit gate. Two routes into the library, one gate out of it: an admin's
own upload passes `draft -> approved`; a part-timer's one-shot submission
(`submit=true`) lands straight at `pending_review` and is invisible to
quoting until an admin approves or rejects it, both audited with the
reviewer's name. A correction is a new `unit_type_version`, never an edit —
the same never-updated-in-place rule as a rate card, so an order that
instantiated from version 1 stays explainable after version 2 is approved.
`floor_plans.scale_tmm_per_px` is an exact rational string, matching
`applied_discount_pct` — a calibration aid is still a quantity, and
CLAUDE.md's no-float invariant does not carve out an exception for one.

§13 gained **C15**: the status enum's `superseded` value has no column or
event that ever sets it — versioning already handles "the plan changed"
without retiring the type — so nothing writes it yet. And a rejection
reverts the type to `draft` and records the reviewer and reason on the
*version*, the conservative reading of a workflow whose enum names no
separate rejected state; flagged rather than assumed final.

**The dashboard review screen is in** — `/library/review`, admin-only,
mirroring override-review's own "the whole control is on this being read"
ethos. Lists everything at `pending_review` with the actual submission
attached (openings, rooms, who sent it), not just a name: approving or
rejecting removes it from the queue and the list endpoint now carries each
row's full latest version so the screen needs one request, not one per row
(`UnitTypeWithVersionsOut`, and `project_name` denormalised onto the row for
the same reason). A reject cannot be sent with an empty reason. 39 backend
tests for the library (`test_library.py`, `test_library_api.py`), 8 new
dashboard tests.

**The piece that actually pays for all of it is in: a quote can start from a
saved plan.** In the wizard, "Start from a saved plan" opens a three-step
picker — project, unit type, window — that only ever asks the server for
`status=approved`, the same two-step gate the review screen enforces on the
write side. Picking an opening pre-fills the room and the sizes step, and
Done is enabled immediately: "choose products and a reference quotation
exists in seconds," not "type it in again."

**Deliberately online-only**, unlike the rate card pull: no local cache, no
outbox, a call to the server at the moment of picking. §13 gained **C16**
for the question this leaves open — whether a fair with no signal is ever
where this actually gets reached for — and named the second design call
that shipped without one: editing a pre-filled dimension clears the line's
library provenance entirely rather than keeping it with a note, because a
provenance column that can disagree with the number beside it is worse than
one left absent.

The exact tenths-of-a-millimetre value is used directly from the opening,
never by re-parsing the rounded display text back into a length — the same
round-trip CLAUDE.md's arithmetic invariant already forbids everywhere
else. Provenance (`measurement_source`, `source_project_id`,
`source_unit_type_id`, `source_version`) threads all the way through: new
columns on both `QuoteLines` and `OrderLines` (Drift schema v13), the pure
quote-to-order conversion layer, the order push payload, and a new
`OrderLineIn` field on the server that a device may only ever set to
`manual` or `project_library` — never `site_measurement`, which is earned
solely through the dedicated measurement endpoint after a real visit.

A real bug surfaced building this, not by inspection but by a widget test
hanging: the picker's own loading spinner could get stuck forever if
`credentialsProvider` had not resolved on the very first frame, because the
early-return path never cleared it. Fixed by awaiting the session properly
(`.future`) instead of racing a synchronous read of it — the kind of gap a
pure unit test cannot see and only driving the real widget tree catches.

**The admin floor-plan upload + tap-to-calibrate UI is in** (Sep 2026),
closing the decision flagged above rather than guessing it: nothing in
`deploy/docker-compose.yml` names an object store or a mounted upload
volume, and nothing is deployed yet to give one real credentials, so the
image itself lives in Postgres as bytes (migration 0008, `FloorPlan.
image_data`) rather than behind a service that does not exist — a handful
of floor plans is not a media library, and `backup.sh`/`restore.sh` already
cover the table for free. An admin's own upload replaces a version's floor
plan in place; a second upload after that version is approved is refused,
because a correction is a new version, never an edit to this one, the same
rule every other part of this library already follows. Calibration takes a
single pre-computed integer pixel distance rather than two coordinate
pairs, so the server's own arithmetic (real distance over pixel distance,
via `Fraction`) stays exactly rational — the `sqrt` an on-screen distance
needs happens once, in the dashboard, never on the server. The review
screen gained the upload control, the image itself (fetched as an
authenticated blob, since `<img src>` cannot carry the session token), and
a two-click calibrate flow, in all three languages. 34 new backend tests,
5 new dashboard tests, both suites green.

**The part-timer's own submission screen is in (Sep 2026), and Phase 8 is
now complete.** The handset's sibling of the admin's dashboard upload,
built for exactly the scenario the client described: a customer WhatsApps a
floor plan to a part-timer's phone at a fair, and it needs to become
something quotable without a desk or a connection. Reachable from the quote
screen's own app bar, for every signed-in user — a part-timer is exactly who
this is for, so it is never admin-gated.

**Two routes in, one idempotency scheme.** `library.py` gained
`submit_from_device`, the offline sibling of `create_unit_type`: it takes a
**client-generated** id (unlike the admin route, which still generates one
server-side — see `Project`'s own docstring for why that stays true) and is
idempotent on it, mirroring `push_order` exactly, because a submission
queued through the outbox can retry after a dropped fair-tent connection the
same way an order can. `POST /api/unit-type-submissions` carries the whole
thing — name, openings, rooms, the floor-plan image, its calibration — as
one JSON body with the image as base64, not the admin route's multipart
upload, because the whole submission is one outbox row frozen at enqueue
time and a flaky connection gets one request to complete rather than two
that must both land. Calibration takes the same single integer pixel
distance as the admin flow (`_scale_from_calibration`, now shared by both
routes), computed by a `sqrt` that happens once, on the device, never on the
server.

**Mobile side:** Drift schema v14 adds `LibrarySubmissions` — a client-side
draft (project, unit type name, openings/rooms as JSON, a photo path, its
calibration) that a new `LibrarySubmissionRepository` owns until it is
handed to the outbox. **A resumable multi-visit draft, the way the quote
wizard persists on every keystroke, was deliberately not built** — this is
shorter, lower-stakes data entry than a quote, and if the app is killed
mid-form the part-timer simply starts again; named as a real simplification
rather than silently accepted. The project picker reads a **cached** list
(`Settings`, pulled via the existing `GET /api/projects` whenever a
connection exists) rather than the wizard's own online-only picker, because
`Project.id` staying server-generated means a submission can only ever
point at a project this handset has already seen with a connection in
hand — a genuinely offline-capable submission screen, built on top of a
project-creation step that still is not. Openings and rooms are typed
using the same exact `Length`/`parseLength` machinery as the measurement
screen — a room's area comes from width × length, rounded once to the
plain mm² `Room.nominal_area_mm2` actually stores, never typed as a raw
number. Submitting never blocks on the network: it writes the row and calls
`Outboxer.enqueueLibrarySubmission`, the same "this never blocks and never
fails visibly" promise `queueQuoteForOffice` already makes, and shows the
confirmation immediately — an admin still has to approve it before it
reaches a quote, the same two-step gate the dashboard's own upload goes
through.

**AI-assisted recognition exists as a placeholder, deliberately.** The
client's own request was to have the seam built now and the actual
provider chosen later, whether a hosted API or something run locally.
`app/services/recognition.py` defines a `RecognitionProvider` protocol and
a registry keyed by the `RECOGNITION_PROVIDER` env var (`RECOGNITION_MODEL`
passed through for whichever one is chosen); `NullRecognitionProvider` is
what runs today — it proposes nothing, says so (`configured: false`), costs
nothing, and never guesses. `POST /api/recognize` is **stateless**: no
floor-plan id, no persistence, just image bytes in and a proposal out, so
one route serves both the handset (a photo not yet submitted anywhere) and
the dashboard (an already-uploaded image, re-sent as the blob it already
fetched) without either needing a database row to exist first. SPEC.md's
own "Future: assisted digitisation" section already named the rule this
keeps: **a proposal is never production truth** — nothing it returns can
become an `Opening` or a `Room` except by a person copying it into the form,
the same two-step gate a part-timer's own submission already goes through.
Both UIs are wired against this contract now, so turning on a real
provider later is a config change, not a UI change.

25 new backend tests (`test_recognition.py`, and additions to
`test_library.py`/`test_library_api.py`), 3 new dashboard tests, and on the
handset: 3 new migration tests, 5 repository tests, 4 payload-builder tests, 4
outbox tests and 3 widget tests. 732 backend tests, 274 dashboard tests, 907
Dart tests — all three suites green.

**§13 A25 is answered and built** (client, Sep 2026). Korea wallpaper does not
have to be measured at the fair — leaving it blank quotes the default one
pack, RM800, and measuring it **auto-bills** whatever the wall needs, ceiled
to whole packs, never a suggestion left for somebody to apply by hand. Final
pricing is untouched: a per_roll line still refuses without a real
measurement once the site has been seen, the same as every other basis — the
engine change is stage-gated on `PricingStage.estimate` alone. Wallpaper's
`per_roll` unit stopped printing the raw wire word `roll` and now shows the
localised "pack" (zh/en/ms), since it is a live, customer-facing basis rather
than the deferred perPiece/perSet ones. Both engines, the wizard's Done
gating, the quote screen and PDF, and the revised-order document all changed;
`shared/pricing-fixtures.json` carries the new default-pack case as the
three-way contract, and each engine separately tests the final-stage refusal
that the shared-fixture format has no way to express.

**Mutation-checking A25 found one real gap.** `measure_sheet.dart`'s
`needsHeight` was derived from *whether the quote happened to record a
height* (`line.estHeightTmm != null`), not from the product's basis. Before
A25 those always agreed, because quote-time height was never optional for
anything — the mutation reverting the fix passed the **entire 861-test
suite**. A wallpaper line quoted with no measurement would never show the
height field at all, and Save would enable off a width alone, so a measurer
could finish "measuring" a wall nobody's tape ever touched. Fixed to ask the
applied rule's basis directly rather than the quote-time coincidence, and a
widget test now pins it.

**A targeted bug hunt on the strength of that finding surfaced six more.**
Full detail in `FINDINGS.md`. Three are fixed, each with a test that failed
before the fix and passes after, mutation-confirmed:

- The Dart and Python engines disagreed on an unrecognised `ProductRule.
  dimension` — Dart skipped the rule, Python defaulted it to height. Dormant
  today (every rule on the real card says `"width"`), but the next
  height-dimension rule would have passed on the handset and been
  hard-rejected by the server on sync. Python's check is now symmetric with
  Dart's.
- A buyer-details push the server refused as `stale` or `unknown_order` was
  silently treated as delivered — `outbox.dart`'s `drain()` had no branch
  for `BuyerDetailsAccepted`, so it fell into the generic success path and
  the row vanished with no retry and no signal. It now reports as a
  disagreement, the same as every other refusable push. Whether an
  `unknown_order` refusal should retry rather than just flag — the capture
  is genuinely lost either way right now — is still open.
- **Site measurements never reached the server after confirmation**, and it
  was the one that mattered most. `enqueueOrder` fires exactly once, before
  the site visit; nothing in `measurement_repository.dart` ever pushed a
  final measurement up, and even a naive retry was silently ignored
  (`push_order` treats any order with an existing id as a pure duplicate).
  The server's `is_site_measured` stayed `False` forever, so
  `advance_order_status`'s guard refused `measured` server-side on every real
  order, and the office's measurement queue showed everything as permanently
  unmeasured no matter what was done in the field — Phase 6/7 looked complete
  in every test that ran on the device and meant nothing to the dashboard.

  Fixed with a new `POST /api/orders/measurement` endpoint, planned before
  writing any code and mirroring `POST /api/orders/buyer`'s shape: staled on
  the **line's own** `measured_at` rather than the order's (a measurement is
  naturally per line), refusal-as-200, `measured_by_user_id` sourced from the
  session rather than the payload. It reprices the whole order server-side —
  `reprice_order` existed, pure and fixture-tested, but was wired to nothing;
  `Order.final_total_sen`/`has_unmeasured_lines` are now real. A device/server
  total mismatch on the measured line logs to the existing
  `pricing_discrepancies` table rather than blocking the push (hard rule 4).
  `advance_order_status`'s guard itself needed no change — it always read
  `OrderLine` fresh on every call; it was purely starved of data. Proven by
  `backend/tests/test_measurement_push.py` (11 cases, including the exact
  scenario that motivated this: push a measurement, then watch
  `advance_order_status` succeed to `measured` where it previously refused
  with `lines_not_measured`) plus outbox and widget tests on the device side.

**All six findings are now fixed.** The remaining two: removing an
auto-adding upgrade (Motor) could delete an independently-chosen line sharing
a variant with its `auto_adds` list (e.g. a hand-picked Motor Track) — fixed
with `_autoAddedBy`, which records which upgrade actually created each
auto-added line, so removal only cascades to what that specific upgrade
brought. And rapidly double-tapping an upgrade chip had no re-entrancy guard
and could add two lines instead of one — fixed with `_togglingUpgrades`,
gating re-entry per variant while a toggle is in flight. `recordMeasurement`
also gained its own defense-in-depth check (finding #6): it now looks up the
line's rule and refuses `missingHeight` itself, rather than trusting
`MeasureSheet`'s gating to be the only caller forever.

**Two more UX bugs, reported directly rather than found by the sweep, fixed
the same session.** The band-edge nudge (§5.5, "the highest-value validation
in the app") computed `isAboveEdge` correctly but the rendered message
hardcoded "just over" regardless — so a curtain drop of exactly 10ft, which
A1 makes the LOWER band, was told it was just over the edge when it was
genuinely under. Split into `warnNearBandEdgeOver`/`warnNearBandEdgeUnder`,
selected by `isAboveEdge`.

And the unit-slip suggestion (`unitLooksWrong`/`implausibleForCategory`)
always proposed millimetres whenever the entered unit was inch or foot,
regardless of the raw number typed — so a real 20-21ft curtain drop, just
over the category's generous plausible ceiling, was asked "did you mean 21
millimetres?", which is not a fix anyone who typed a real window ever meant.
`_plausibleSmallerUnit` now recovers the raw number as typed and only
suggests mm when it is itself squarely mm-scale (over §5.3's own named
50–300 ambiguous band) — `2000` (a typical floor-plan number, the client's
own example) suggests mm; `20` or `21` does not. Below the ambiguous band the
warning is suppressed entirely rather than guess, matching §5.3's existing
"do not guess unit from magnitude" rule — this only changes which one-tap
fix a warning offers, never what a value is interpreted as.

**A second bug hunt, this one on `dashboard/` — the area the first sweep
explicitly skipped.** Full detail in `FINDINGS.md`'s second dated section.
Five of six fixed:

- **Publishing a card could go out against a diff describing different
  text.** `stage` stays `'editing'` for the whole preview round trip, so an
  edit or a list switch landing while one was in flight saw nothing to
  invalidate — then the response arrived and stamped `'previewed'` over text
  it never priced. The one thing that screen's own doc comment says it
  exists to prevent. A `previewSeq` counter now tags each request and
  discards a response overtaken by a later edit.
- **A hold's amber/red colour depended on what hour the office opened the
  board.** `daysUntil` bucketed **UTC** calendar days for "now" while
  `formatDate` right next to it correctly used local ones — for the eight
  hours between midnight and 8am in Kuala Lumpur (UTC+8), the two clocks
  disagree about what day it is. Now both read local fields, and
  `money.spec.ts` pins `TZ=Asia/Kuala_Lumpur` for the whole file so the
  suite can't pass by accident of whatever timezone runs it.
- **None of `people.ts`'s three write actions (add, deactivate, reactivate)
  guarded against a request already in flight** — a double click before the
  first response landed could fire the same POST twice. A `saving` signal
  now gates all three, matching the guard `order-detail.ts`'s buyer form
  already had.
- **`check-templates.mjs` itself had a gap in the exact thing it exists to
  catch**: it decided a module was "imported" by a substring match against
  the whole file, so a component that imports `FormsModule` but never adds
  it to its own `imports: [...]` array would pass. Now checks inside that
  array specifically.
- **CLAUDE.md itself was wrong.** It claimed an admin could "change a PIN"
  from the dashboard; no dashboard code does this — only the backend and its
  CLI can. Reworded rather than built, since whether a dashboard should let
  an admin reset someone else's PIN at all is a real product question, not
  a one-line gap.

One left open at the time: `order-board.ts`'s doc comment quotes SPEC.md's
original "filter by channel/project/salesperson/fair" wishlist, but only
channel and status were implemented. **Salesperson is now built** (see
above, Sep 2026) — a plain equality on a column `Order` already carries.
"Fair" and "project" stay open for reasons that are not the same kind of
gap: neither has a column to filter on directly, and each needs its own
design call rather than a guess.

- **The handset form.** Without it an order over RM10,000 was *stuck* —
  `advanceOrder` refused to move it and nothing could supply what the refusal
  asked for. The refusal now opens the form, and the form is also reachable
  without being refused first. It says **why** before it asks (three different
  reasons, not interchangeable), states everything outstanding **at once**
  because §10.2 gives one conversation, and **never gates saving on
  completeness** — half the details now beats nothing.
- **Migration 0006 and `POST /api/orders/buyer`.** Its own endpoint, because an
  order is pushed once at confirmation and these are captured after
  measurement. It **merges** (a field the payload does not carry keeps what is
  stored, so two handsets' captures both survive) and **refuses a stale push**
  rather than letting the last arrival win.
- **The read side**, so the office can see what is on file and what is missing
  before it telephones anybody. Same rule as the handset, never a second answer.
- **The office can now correct them, not only read them.** It runs the export,
  so it is who finds out weeks later that an IC number was mistyped. The form
  sends **only what somebody changed** — a measurer can be capturing a TIN at a
  house while the office types an address at a desk, and a payload carrying
  every field would silently undo whichever landed first. An emptied box goes
  up as `""`, the server's explicit clear, which is the one thing a handset
  cannot express. A `stale` refusal arrives as a **200** and reads as a
  failure, keeping the form open: saying "saved" there would tell somebody a
  legal requirement was met when it was not.
- **The document labelling audit.** `tool/check_labelling.py` replaces a shell
  grep that could see only English, looked only at `mobile/lib`, and never
  looked for a UIN or a QR at all. Now every ARB value in **zh, en and ms**,
  the handset source, every dashboard template and heading, and the rate card's
  own `{zh, en, ms}` labels — the one printable surface an admin edits with
  nobody reviewing it. The rule is that the phrase must **be** the string, not
  appear in it: *"the customer asked for an e-invoice"* is correct copy, and
  banning the phrase would delete the screen the rule exists for. It fails when
  a surface matched **no files**, and its self-test plants each violation and
  fails if the audit stays quiet.

A latent outbox bug found on the way: `_enqueue` matched on the entity id alone,
and an order push and a buyer capture are both keyed on the **order id** — so
capturing details while the order push was still queued replaced it, and the
order never went up. Now matched on the kind as well.

§13 gained **C14**: a field *cleared* on a handset stays on the server, because
the device stores a blank as null and null on the wire means "leave it". Merging
fails toward keeping too much and replacing fails toward losing a colleague's
work; §10.2's penalty is for **missing** details, not spare ones. **Half of it
is now answered** — the office form sends the empty string, so the correction
exists somewhere. Still open: a handset cannot clear, and nothing records
**who** typed a buyer field (§6.7 defers that to B9's customer record). C8
gained the same question about who may edit these at all; the endpoint accepts
any signed-in user, deliberately, rather than inventing a role rule.

**`(ngSubmit)` in a component that does not import `FormsModule` does nothing.**
Angular does not error on an unknown event name on a DOM element — it binds a
listener for an event called "ngSubmit", which nothing fires. The **Add
somebody** button had shipped that way: the form rendered, the button enabled
itself correctly, and clicking it did nothing. Nothing caught it because every
test on that screen called `add()` directly, so the unit was right and only the
wiring to it was wrong. Drive a form through the DOM in its test, and
`dashboard/tools/check-templates.mjs` now fails the binding in CI.

**Every dashboard control is now clicked by a test**, which is the sweep that
bug earned. Thirteen bindings — the whole publish sequence, the week arrows,
the report window buttons, the deactivate dialog, and every Try again — were
each replaced with `(ngSubmit)` in turn, and every one made a test go red. **No
new dead wiring was found**; what changed is that a future one cannot hide. The
publish screen had *zero* DOM coverage and it is the screen that sets the price
of everything: under the dead-publish-button mutation all thirteen of its
existing tests still passed.

**The dashboard is trilingual** (§13 **C9**, answered by the client: yes). A
**typed dictionary looked up at runtime** in `dashboard/src/app/i18n/`, not
`@angular/localize` — Angular's own i18n is a build-time substitution, one
bundle per locale, and CLAUDE.md wants *per user, not per device*. `ZH` and
`MS` are declared as `Strings`, so **a missing translation is a compile
error**. Every message carrying a value is a **function**, never a placeholder
template: the alphabetical-placeholder trap cannot happen to a named parameter,
and it is what lets English take its plural `s`, Chinese its measure word, and
Malay neither.

**The picked language now persists to the account** (client, Sep 2026,
superseding the shared-office-machine assumption below the picker was
originally built under — every office PC now belongs to one person). Picking
from the nav-bar switcher calls the new self-service `POST /api/auth/language`
and updates the local copy at once; a failed persist is swallowed rather than
undoing the pick, since this is a preference, not money moving. Precedence is:
what somebody picked on this browser this session, then the account's
`language`, then `zh` — the first two collapse to one path in practice, since
a pick immediately becomes the account's `language` too. The sign-in screen
lost its own picker: there is no account yet to ask, and it was needless
friction on a per-person machine. A logo placeholder sits where it stood,
reserved for the client's mark. The session **token** stays memory-only
(unrelated decision, §12) — nothing here changes that.

A failure or a note is held as **what happened**, never as a rendered sentence,
so switching language re-renders it; freezing it leaves one line of the old
language on the very line explaining why somebody cannot see their work.

Two real bugs surfaced by doing it. The rate-card preview asked the server for
the diff in a hardcoded `'en'`, so a Malay reader would have seen every product
named in English in the one table whose job is naming what is about to change
price. And `AgeingBucket` carried `"0-30 days"` **on the wire**; it now carries
the day range and the client says the words. Nothing user-visible in the API
should be a word.

Built and green on the device: `Length`, `Money`, `Rational`, the unit parser,
the soft warnings, the pricing engine over the real 77-row fair card, the custom
keypad, the quote wizard in zh / en / ms, local persistence (a quote survives a
force-quit), special-track and add-on upgrades, whole-order product rules, the
delivery zone charge, customer details, a photo per window, and the on-device
trilingual PDF.

Built and green on the server: the Python engine passing the same fixtures, the
sync endpoints, Alembic migrations with a test that they match the models, users
and roles, and rate card publishing. **888 Dart tests, 683 Python tests,
266 dashboard tests.** 100% coverage on `Length`, `Money` and `Rational`.

**An upgrade is only offered where it can belong** (client, Sep 2026). Four
add-ons carried `attaches_to: null`, which the wizard reads as *offer this on
anything* — so quoting SPC flooring showed a RM800 motor and a RM200 remote,
and every product on the list was offered RM400 of stainless steel side-guide
cable. Now:

- **Motor, remote and intermediate joint → curtains on a TRACK.** A motor
  track replaces the track, and a rod-hung curtain has none to replace.
- **Stainless steel side guide → the outdoor roller blind**, where it is
  `mandatory`: added automatically, shown locked, still charged RM400. It is
  what the blind runs in, and a tick box is what somebody forgets.
- **The motor `auto_adds` its motor track** — RM40/ft on the curtain's own
  width. Taking the motor off takes the track with it, or the quote keeps a
  track driving nothing. `pr-motor-track` is the net under that.
- **The three services became add-ons.** Dismantling old SPC was a selectable
  *product*, so it was quoted with its own measurements — a second chance to
  type a different number for the same room. Offered on the product now, and
  billed on the same square footage. **Still charged, same rates.**

Two mechanisms, deliberately distinct: `mandatory` is about the **parent
product** (this add-on comes with it), `auto_adds` is one **upgrade bringing
another**.

**Every `family: addon` line used to crash the quote.** `PricedLine.
depositCategory` called `depositCategoryOf(family)` with no parent, so ticking
the RM800 motor replaced every price on the screen with an
`UnknownDepositCategory`. `LineRequest` now carries `parentFamily`, mirroring
`depositCategoryOf`'s own signature, and three fixture cases hold both engines
to it. Nothing had ever caught it because nothing had ever added an add-on
without somebody choosing one.

**Somfy and AOK are one variant with two material keys**, not two upgrades —
the tile names them (`material chosen at measurement: aok / somfy`) while B7
still defers the pick and quotes the dearest, so §8.5's promise holds.

**Prices are server-owned now.** One card is published and pulled by every
handset. On-device editing is read-only except for an admin, and an admin's
change is *published* rather than saved — it needs a connection and is refused
without one, because a price change sitting in an outbox would be live on one
phone and no other. A leftover Phase 2 local edit is replaced on the first
successful pull, whatever version it claims: that number was invented on the
device, so comparing it against the server's means nothing.

**Sessions never expire** (SPEC.md §12). A token that expires does so mid-fair,
with no signal, holding a customer's deposit. Revocation is the control instead,
plus scrypt on PINs, a login throttle that backs off but never locks out, and an
append-only attempt ledger.

Release APK **22.4MB arm64, `--split-per-abi`**, against the 30MB target. Build
that way and measure that way: a single fat APK carries all three ABIs and is
62.9MB, which is not what anybody installs.

**Still open, and each needs something a test cannot give:**

- The two Phase 2 criteria that need a stopwatch — a six-window house quoted in
  under four minutes, and an untrained person producing a correct quote within
  thirty. Run both before the client meeting.
- Caddy. The rest of `deploy/` has now been run for real against Postgres 16 —
  the stack came up, `backup.sh` restored the dump it had just taken and failed
  loudly when `rate_cards` was emptied, and `restore.sh` put a dump back over
  the live database — but starting Caddy would chase a certificate for a domain
  that does not resolve, so it stays unexercised until there is a host.

**Phase 4 so far.** The rate lock resolver and the lock-granting rule, both
engines, fixtures-first and mutation-checked. Only a **fair** deposit opens a
lock -- a showroom RM300 confirms an order and buys nothing else. The category
prompt asks for each category's RM300 once, logs whichever button was pressed,
and never appears away from a fair. Fair mode is a toggle bounded by the card's
promo window, so it cannot quote promo rates after the fair ends.

Payments are recorded, tied to the hold they bought, and pushed through the same
outbox as quotes. The **receipt number is server-issued** -- the one identifier a
device may not invent, because it goes on paper a customer keeps. Until it
arrives the app shows `pending sync`. The daily cash-up totals by method and
refuses to call a day balanced when nobody counted.

**A deposit confirms the order**, and the quote is kept as its reference -- the
rough estimate the measurement team reads, and what the variance report compares
the final against. Order lines are copies that snapshot the rule, band, rate and
card version that priced them, so a number stays explainable a year later. The`order_no` is server-issued for the same reason as a receipt number.

**Phase 4's three remaining pieces are all in**, fixtures-first, mirrored on
both sides and mutation-checked.

**The order status pipeline.** `confirmed -> measurement_booked -> measured ->
material_selected -> in_production -> ready -> installed -> closed`, `cancelled`
reachable up to and including `ready`, the last two terminal. No shortcuts, no
backwards moves -- a remeasure is new dimensions on the same order, not a
rewind. Two guards: `measured` needs every line that wanted a visit to have
final dimensions, `material_selected` needs every deferred material chosen.
Cancelling needs four trimmed characters and **touches no money** -- B3 is
unanswered, so the deposit stays exactly where it is.

**Price override.** Admin only, mandatory reason, and it must **name a person**:
`is_admin` with no user id is refused. An override that changes nothing is
refused too, because a row saying RM552 became RM552 is the noise that stops the
weekly review being read. Zero allowed, negative not, a finished order not
repriced. The audit row, the marker and the event are one transaction or none.

**Orders push to the server.** Migration 0004. `order_no` is server-issued
(`MLK-2608-0001`, per branch per month) for the same reason a receipt number is.
The push is idempotent on the device's id and a retry hands back the same
number. **Nothing rejects an order outright** -- the money is already taken, so
a status or override the server would not allow is left out and named in the
result. `POST /api/orders/status` carries every later step, keyed on the **event
id**, because an order walks the pipeline many times.

**Three screens.** The order screen (status, history, lines, the one next-step
button, cancel with its reason), the override sheet (admin only, pre-filled,
says the change is recorded against you), and the weekly override review --
which §6.5 says *is* the control. All three languages; 42 new strings merged
through file bytes.

**Phase 4's acceptance list is complete**, and every criterion in SPEC.md §11
now names the test behind it. The declined-deposit report is built, with the
arithmetic pure in `summariseDeposits`.

**Two rate-lock bugs, both found by asking what the dashboard could read.**
The lock machinery was correct and tested throughout; it was keyed and stored
in ways that meant it could never actually apply.

1. **The hold could never be used.** The lock was keyed on the **quote id**, so
   a customer who deposited at the fair and came back in March — a new quote,
   a new id — was quoted the standard rate. *More* than the hold they bought,
   after the app told them the promo was held until next August. Nothing caught
   it because no test used a second quote. `pricing/customer_key.dart` now keys
   on a normalised phone, falling back to the quote id when there is no usable
   one — which preserves the reason the old key existed (two anonymous quotes
   must not share a hold).
2. **A hold was one handset's secret.** `category_locks` and `deposit_prompts`
   existed only on the device and were never pushed, so `order_lines.
   category_lock_id` pointed at a row the server had never seen. Migration 0005
   and `GET /api/locks` fix the server half.

**The lock sync is complete end to end.** A hold and every prompt answer go up
through the same outbox as quotes, payments and orders, and a handset pulls a
customer's holds when a phone number is saved — the only moment a returning
customer becomes identifiable. The pull only ever *adds*: a server copy never
overwrites a deposit taken on this handset and not yet pushed, because that
local row is the one somebody watched the money change hands for. With no
signal it adds nothing and raises nothing, which leaves the quote higher than
it needs to be — permitted by §8.5, and corrected on the next connection.

**The read side exists**, which is what made the two lock bugs findable in the
first place — until then every endpoint was a push and nothing ever read the
data back. `GET /api/orders` with combining filters and a real `total`,
`GET /api/orders/{id}` returning lines, history and overrides in one response,
and the two review queries. CI now proves an order and a hold survive a round
trip against **real Postgres**, not SQLite — which drops the timezone off a
`timestamptz` and is relaxed about the partial unique index, both of which this
depends on.

**Phase 5 has started.** `dashboard/` is Angular 21 standalone, lazily routed,
with the order board as its first screen: sorted by how soon a rate hold runs
out, amber at 60 days and red at 30, and a fourth state for one that has already
gone — that is not a thing to hurry, it is a customer who paid RM300 and got
nothing. Filters live in the URL and nowhere else, which is §11 Phase 5's
acceptance criterion. Money is integer sen here too, and there is deliberately
no function that turns sen into a fractional number.

Dependencies are pinned exactly, matching the rest of the repo.
`dashboard/tools/check-pins.mjs` fails a caret, because `npm install` rewrites
the lockfile from the ranges — so the range is what actually decides, and the
committed lockfile alone guarantees nothing.

**Four dashboard screens are in:** sign-in, the order board, one order in
detail, and the weekly override review — plus a thin nav shell that appears
only once somebody is signed in. Admin-only links are hidden rather than shown
and refused; the server refuses them either way, and none of the hiding is
relied on as a permission check.

51 dashboard tests, each screen mutation-checked. The ones worth knowing about:
dividing by millimetres instead of tenths would have produced dimensions ten
times too large and entirely plausible; the override review's week starting on
Sunday would have dropped rows out of both weeks either side.

**Publishing a price list is done, end to end** — §11 Phase 5's first
acceptance criterion. Two steps, and the second is unreachable until a preview
has been seen; any edit to the card, or switching between the fair and standard
lists, takes it away again. The diff is computed **on the server**, so the thing
that shows what will change is the same thing that decides what lands — a
preview worked out in the browser could disagree with the publish it precedes,
and once it has done that once nobody trusts it again.

**The dashboard is served.** Caddy has it baked into the image at build time
rather than reading from a shared volume, so what runs is what CI built. Both
images — API and web — are published to GHCR and probed before their tags are
trusted.

Probing the web image found two things reading the config had not: a missing
`.js` was answered with the HTML shell and a 200, which arrives as a parse error
nobody can read; and the app shell carried no cache header, so a browser would
keep loading the old app after a deploy. Both fixed, both now checked in the
release job.

**Users and roles are in**, on both sides. An admin who is already signed in
can add people and remove access from the dashboard; the **first** admin still
needs shell access, so no bar was lowered — and a real one was raised, because
the alternative is the boss keeping one shared login that reaches every
handset.

**Correction, bug hunt 2026-09-09: "change a PIN" was never actually a
dashboard feature.** `PUT /api/people/{id}/set-pin` and `users pin --phone`
(the CLI) both exist and work; no dashboard control ever called either —
`people.ts`/`people.html`/`api.ts` have no PIN-change code at all, and this
paragraph claimed one that isn't there. Not built here: whether a forgotten
PIN should be resettable from the dashboard at all is a real question (who
gets to see or set someone else's PIN, and how the new one reaches them
securely) rather than a one-line gap, so it stays CLI-only until asked for.

Deactivating asks for the person's name to be typed, which is §11's acceptance
criterion. Sessions never expire (§12), so it is the only thing that stops the
handset in a leaver's pocket, and doing it to the wrong person locks somebody out
mid-fair. It never deletes: their quotes and payments still name them, and
leavers stay on the roster because a list that hides them cannot answer "who used
to have access". An admin cannot deactivate themselves, on the server as well as
in the screen.

**The measurement queue is in**, both sides. §11 wants it grouped by project so
one trip covers several units — and there is no project library until Phase 8,
nor an address anywhere. So it groups by **customer**, on the normalised phone,
the same key a rate lock uses: one customer with three units is one card that
says so, and a phone typed two ways is still one house. An order with no usable
phone is its own group; pooling the phone-less ones would invent a trip and send
somebody out for it. §13 **C10** asks what should really group a day's route,
because if the answer is "by area" that wants an address field now rather than
the project library later.

Everything at `confirmed` or `measurement_booked` is in it, **including an order
with nothing left to measure** — C7 is unanswered so the pipeline refuses to
skip those steps, and filtering on the unmeasured count would make exactly those
orders invisible while they sat at `confirmed` forever. Ordered by who has
waited longest, not by hold expiry: an order pinned its card version when the
deposit confirmed it, so measuring it late does not reprice it.

**All four reports are in.** Variance by salesperson, fair performance,
outstanding balances aged, and declined deposits.

The variance table **says the column is biased before showing it**. A quotation
rounds every quantity up and the bill uses the exact tape, so every honest
estimate comes in high; read cold the table accuses honest people of padding.
An order whose final came out *above* its estimate is flagged rather than
averaged in — §8.5 says that cannot happen, so it is a broken promise, not a
statistic. Equal is the promise kept; one sen over is not.

Balances **never say overdue**: there is no invoice date and no payment terms in
this system, so it reports days since the deposit and lets the reader conclude
(§13 **C11**). A total still built from a quotation is marked on the row and
named above the table, because §8.5 makes it an upper bound rather than a debt,
and the two are totalled separately. Cancelled orders are in none of the three
server reports — B3 is unanswered and a report is not the place to answer it.

The declined-deposit summary is computed **in the dashboard**, mirroring the
handset's `summariseDeposits`: the two count different data (one phone versus
every phone), and one server-side aggregate would fix the slicing at whichever
caller asked first.

Nothing in the reports averages anything. An average of integer sen needs a
rounding rule, and inventing one to tidy a screen is how a rounding rule ends up
being used for something that matters.

**All four of Phase 5's acceptance criteria are met, and each names a test.**
Publishing shows what moves before commit. Deactivating requires the name.
Every filter state is reachable by URL — checked end to end through a **real
router** on the order board, the measurement queue and the reports, because a
filter held in a component field passes every behavioural assertion and still
fails the criterion the moment somebody pastes the link. And the board loads
500 orders without lag.

**That last one found two real queries reading the whole table to answer a
question about one page** — the line counts counted every line ever written,
and the hold expiries read every active lock in the business, both regardless
of the filter. Neither was slow today; both grew with the business while the
screen did not. What the test asserts is not a wall-clock number but the thing
that causes the lag: **the statement count does not grow with the board.** Ten
orders and five hundred cost the same round trips. That is the failure this
design invites, because `held_until` comes from a table keyed on a string
`orders` does not hold, so the obvious simplification is a lookup per card.
Measured for the record: 500 orders, three lines each, holds on a third —
median 11.5 ms against in-process SQLite.

**Every dashboard screen now has a spec.** (149 at the end of Phase 5; the
current count is above.)

**Phase 6 has started, fixtures-first.** 13 `final_pricing_cases` in
`shared/pricing-fixtures.json`, then both engines against them. Every
expectation was derived from §4.3's formula with exact `Fraction` arithmetic,
independently of both engines, so three-way agreement is evidence rather than a
tautology. 20 mutations across the two, all killed.

**A line reprices at the version and discount IT recorded** — never the active
card, never the order's pinned version, because a line's lock is its own. When
the held card is not to hand it **refuses**: falling back to today's is exactly
what the RM300 was taken to prevent, and it is the fallback that looks most
reasonable. Quantity is exact here; the quote rounded up and the bill does not.

A line the tape has not reached and a material nobody chose both refuse, and a
refused line stops the **order** total, not just its own — a total that quietly
excluded a line would be a balance somebody collects and a window nobody bills
for. An order with no lines has not been priced; zero is a number somebody would
act on. A final **above** its estimate is flagged, not refused: §8.5's promise is
about rounding, not the customer's own wrong dimensions.

§13 **A21** raised rather than guessed — §4.3 has carried *"`min_qty` applies at
both stages, confirm before Phase 6"* as an assumption, and this is Phase 6.
Both engines keep applying it, so a 3ft × 3ft roller bills its printed 18 sqft
minimum; the exact-tape reading would bill RM81 where this bills RM162.

**CI now fails a fixture section that only one suite loads**, which is hard rule
3 made mechanical.

**A new trap, and it cost a red CI run.** Never write a workflow file — or
anything with `\r`, `\n` or `\\` in it — through a bash heredoc feeding a Python
string: the escapes are interpreted twice and a literal carriage return lands in
the file. `ci.yml` stopped parsing and nothing ran. Author that content with the
Write tool, and **verify a workflow before pushing**: parse it, extract the
step's `run:` back out of the parsed YAML, and execute it.

**The RM10,000 rule is in**, both engines and the state machine. Checked twice
per §10.4: at the fair on the estimate it *asks* from RM8,000, and after
measurement it *blocks*. The margin belongs to the estimate alone — an estimate
is rough, a final is exact. Both figures are config **on the rate card**, so
changing one is a card publish, and a card published before this defaults to the
law rather than to no check at all.

Buyer details live on the **order** (schema v12), not a customer record, because
there is no customer table yet (B9). Completeness is a **rule, not a flag**: a
name, one identifier (a TIN, or an ID *with* its type), and a full address.
Everything missing is reported at once, so somebody collects it in one
conversation.

§13 gained **C12** (which pipeline step is "invoicing" — the guard bites from
`material_selected`) and **C13** (which buyer fields MyInvois actually rejects).

**SPEC.md is now the authoritative product direction**, reviewed end to end and
brought in line with what was actually built. New §2 (what the product is, and
the V1/V2 boundary) and §14 (architecture, boundaries, extensibility). §5 rewritten
around parse → normalise → validate → suggest → confirm, with the parser table
corrected to `_tmm` — it had promised millimetres, which is the rounding bug the
invariant exists to prevent. §6.6 (the lifecycle is the authority) and §6.7 (what
must be traceable) are new. Phase 8 is now the Property / Project / Unit Library,
with provenance, versioning and a two-step floor-plan review; AI extraction is
documented as a future extension that proposes to a human, never production
truth.

**The measurement screen is in**, and with it Phase 6's fourth criterion. An
order's lines worked through one at a time, the estimate beside the field being
typed into, the fair photo on each row, the material chosen here, the variance
visible without leaving the screen. The order total is **absent, not zero**
until every line prices, and what is outstanding says *why* for each.

**Offline is proved, not asserted.** The whole flow runs under an
`HttpOverrides` that throws on every socket, and the tape is checked in the
database afterwards — stronger than the source scan the PDF test uses.

**Two real bugs, both found by building the screen.** The sheet rendered
`9' × 12'` for a 12ft-wide window: **gen-l10n orders positional placeholders
alphabetically**, so `height` came first — on the one screen whose job is
catching a wrong dimension. A message with two placeholders has an order you
did not choose; compose the string at the call site instead. And the order
screen's line rows fell below the 800×600 test fold once a button was added, so
both UI tests now use a phone-shaped surface.

**Two earlier spec-alignment items also turned out to be hiding defects.** The
parser table test read `.mm`, so it could not tell an exact tenth from one
rounded through millimetres — forcing that rounding left it green. And `8000in`
typed with the suffix produced **no warning at all**, because an explicit unit
exempted the value from every plausibility check; that exemption now covers only
the "did you mean a smaller unit" nudge, and ranges are per category and per
field off the card.

**Phase 6 is complete.** Its acceptance list (§11) was the sharpest yet and
every criterion names a test: *a measured order reprices at the old card even
after two rate publishes*, *variance visible to the measurer before they leave
the house*, *an order crossing RM10,000 cannot advance without buyer details*,
and *works fully offline in a house with no signal*.

**The revised order document is in**, and shared from the measure screen before
the measurer leaves. Every line carries **both** numbers — the fair size and
the measured size, the amount quoted and the amount now — because the document
exists to answer *"why is this different from the quotation you gave me?"*, and
only the new figure would start the argument it exists to prevent.

Three refusals, each a decision not to print something plausible: an order that
has not fully priced has **no document at all** (`RevisedOrderData.of` returns
null and there is no way past it); the balance never goes negative, because a
deposit can exceed a small final and B4 has not said what happens to the
difference; and an unsynced order prints *pending sync* rather than inventing an
order number. A line that measured **larger** than quoted is named and itemised
**above** the reference-price promise, not below it — where the price did not
fall, the customer reads why first or the two together look like a lie.

`tool/check_pdf_text.py` now extracts the revised documents too, so the claims
are checked against rendered text rather than bytes — a subset font stores
glyph indices and a grep would pass either way.

**Stairs, landings and skirting.** A staircase is charged **per step**, a
landing separately, and both band on the **width** of the step at 5ft (exactly
5ft is the cheaper side, A1's fencepost). SPC skirting is RM4 a running foot.

The four stair rates are not known. Rather than guess a number that reaches a
customer, the rows carry `provisional: true` with a rate of 0 and **both
engines refuse to price them** — RM0 is a number somebody acts on, and "no
price yet" and "free" must never be the same state. Supplying the rate is a
data edit: the CSV import accepts a real price on a placeholder and clears the
flag **in the same edit**, because a flag and a number that could drift apart
would mean the admin types RM120, is told it was accepted, and the engine still
refuses. §13 **A22**. The card file now holds 81 rows; 77 is still the count of
sellable ones, and a test asserts both separately.

**A21 is answered, corrected by the client, and built.** `min_qty` applies on a
**quotation only**. At final pricing every line bills the exact tape and the
order is floored at §8.4's **RM300 per deposit category** — which now applies at
**both** stages, not just the estimate.

The first answer applied the minimum at both stages and waived it once the job
cleared RM300. That made a 12 sqft timber blind bill RM360 and a **larger**
15 sqft one bill RM300, and the client rejected it: *"dont make it so that lower
sqft more expensive than higher sqft"*. The rule now in force is **monotonic by
construction** — flat at RM300 below the floor, the exact tape above it — so a
billed total can never fall as a window grows. There is no threshold to
configure and no two-pass ordering to get wrong.

Checked as a **property**, not by example: a sweep of every sellable row at 3ft
by 1–25ft gives 1,650 sizes with zero inversions, and `engine_test.dart` walks
the same sizes for the blind that caused the complaint.

Two things the work surfaced that were not obvious going in. **The estimate side
has to be floored too** — the quotation already had §8.4's floor but as an
order-level uplift, so a sum of the recorded *line* estimates is short by it,
and flooring only the final made every small order look like its price went
**up**. And **an unparented add-on has no deposit category**, where
`depositCategory` raises rather than guessing; flooring called it
unconditionally and turned a priceable order into a crash.

**Two l10n traps, both now recorded.** The gen-l10n template is **`app_zh.arb`,
not English** — which is why adding `@`-metadata to the English file never
changed a generated signature. And the alphabetical placeholder ordering bit a
third time: `{room}/{product}/{amount}` generated `(amount, product, room)`.
Any message with two or more placeholders has an argument order nobody chose;
collapse it to one and compose at the call site.

**A repeated mistake worth knowing about:** a plain class field read inside an
Angular `computed` never recomputes, so the button it gates stays disabled
forever. It has happened twice — the publish screen's card text and the people
form — and both times it was caught by a test rather than by reading. Make every
piece of component state a signal.

One thing the dashboard used to lack: a session that survives a page
refresh — deliberate at the time, because a token in `localStorage` on a
shared office machine is one the next person inherits. **Built, Sep 2026 —
see above** — once every office PC turned out to belong to one person, the
same fact that already answered this for the language picker.
*(Malay and Chinese were the other one. C9 is answered and they are built —
see above.)*

**Six CI jobs, STAGED**, all green:

```
shared  ->  lint  ->  backend   ->  mobile
                      dashboard     deploy
```

Nothing downstream starts until its gate passes. A ruff error used to sit behind
a 4½-minute Flutter run, a Postgres container and a Docker stack, all burnt
before anybody learned a lambda argument was called `l`.

**Run the linter at the PINNED version.** `backend/requirements-dev.txt` pins
`ruff==0.8.4`; the formatter changes between releases, so a newer global ruff
reformats files nobody touched and disagrees with CI. Easiest: a throwaway venv
with that pin. **`ruff` was never run locally before, and it is what broke CI.**

**Repeated, Sep 2026: `ruff check` and `ruff format --check` are two separate
commands, and CI's `lint` job runs both.** Two pushes in a row (the Phase 8
AI-recognition commit, then Phase 9) passed `ruff check .` locally and still
failed CI, on `Format`, because only `check` had been run — `format --check`
disagreed with 5 files that `check` alone saw nothing wrong with (ruff's
formatter has opinions about line-wrapping that its linter does not enforce).
**Before every backend push: `ruff check .` AND `ruff format --check .`, both
at the pinned version, in the same venv.** `ruff format .` fixes it in place
when it disagrees.

**Two new blocking questions**, both about money, both built the conservative
way rather than guessed: §13 **B9** (what identifies a returning customer —
phone is in force, a real customer record is the open part) and **B10** (two
handsets each taking a deposit for one category; both rows kept, the first
prices, the second marked `superseded`, nothing refunded automatically).

**Schema snapshots start at v10.** `dart run drift_dev schema dump` writes
them, and CI fails a `schemaVersion` bump that arrives without one.
**Repeated for v14 (Sep 2026):** the bump shipped with Phase 8's floor-plan
submission table, `flutter test` and `dart analyze` were both run and green,
and the missing snapshot still wasn't caught locally — CI's own check for
it never got a chance to run because an unrelated `dart format` gap failed
the job before that step. Two mobile gates now belong on the same checklist
as the backend's `ruff check` + `ruff format --check` pair: **after any
`schemaVersion` bump, `dart run drift_dev schema dump lib/data/database.dart
drift_schemas/` before committing** — analyze and test do not exercise this
at all, only CI's own grep does, and a job earlier in the pipeline failing
for an unrelated reason does not mean this one would have passed.

**Migrations are tested, but only the last step.** v9 -> v10 runs against a
database with data in it. `Migrator.createTable` is `IF NOT EXISTS`, so a loose
guard on a create step is harmless -- but v2, v3, v4 and v7 use `addColumn`,
where the same mistake throws on launch, and nothing reaches those without a
captured schema. `dart run drift_dev schema dump` writes one.

**Two questions must not be guessed** -- §13 C7 (may a supply-only order skip
the measurement steps?) and C8 (who may move an order along, or cancel one?).
The pipeline enforces *what* can happen, not *who* may do it: the override sheet
checks the role, the status buttons do not.

**The PowerShell encoding trap is live and has now bitten twice.** Never write a
`.dart`, `.arb` or `.md` file through `Set-Content`/`Out-File` if it contains
`§` or Chinese -- it writes ANSI or adds a BOM. Author the content with the
Write tool, or merge it with a Python script that reads and writes explicit
UTF-8 from files.

**The real price list is in.** `shared/rate-card-fair-2026-08.json` carries the
MITC Aug 2026 fair list in full — 77 rows, two delivery zones, three product
rules. It is **data**: a price change is an edit to that file, with no code
change and no rebuild of anything but the asset. Nothing may put a rate back
into Dart.

A1: exactly 10ft is the **lower** band, `band_max_tmm = 30481`.
A10: quotation rounds up. A11: final pricing is exact.
B7: material is **always** deferred to measurement, and a deferred material is
quoted at the **dearest** option in its group — the only reading that keeps the
§8.5 promise. A3 and A4 stay `BLOCKING P2`.

A13 and A14 answered: all SPC rows share the 200 sqft minimum, decorative tape
is included in the printed timber rates, and RM800 of Korea wallpaper covers
280 sqft. Still open: **A15** — whether the banded tracks and rods band on the
curtain drop.

---

## Non-negotiable invariants

**Lengths are integer TENTHS of a millimetre.** Field naming `*_tmm`. No
`double` ever holds a dimension. Convert at the UI boundary only.

*This replaces "integer millimetres", which was wrong and provably overcharged.*
A foot is 304.8mm, so no whole-mm value represents it. Storing millimetres made
`12ft → 3657.6 → 3658mm → 12.0013ft → ceil 13ft`, quoting RM598 where golden row
1 demands RM552 — the exact `mm → ft → mm` round-trip this invariant forbids,
made unavoidable by the storage unit itself. In tenths every accepted unit is an
exact integer:

| mm | cm | m | inch | foot |
|---|---|---|---|---|
| 10 | 100 | 10000 | 254 | 3048 |

so nothing rounds on conversion, `3ft × 4ft` is exactly 12.0000 sqft rather than
11.9928, and `5ft × 4ft` at RM9/sqft is RM180.00 rather than RM179.97.
`Length.mm` remains, as a **display accessor only** — never feed it back into a
length or a price.

**Money is integer sen.** Field naming `*_sen`. RM46.00 is `4600`. `double` for
currency is forbidden. Python: `int` sen, `Decimal` at boundaries only, never
`float`.

**Two distinct roundings, never conflated.**
- *Quantity, and it differs by stage.* On a **quotation**: up to a whole unit,
  once, every basis — ft, sqft, m, roll — applied after `min_qty`, never before.
  At **final pricing** after site measurement: **exact, no rounding.** The quote
  rounds up, the bill does not. Two rules on purpose; never collapse them.
  So the estimate is always ≥ the final — subtract that bias before reading the
  variance report.
  `MM_PER_FT` is 304.8, not an integer — compare in tenths of a mm. Test
  `3048 → 10` and `3049 → 11`.
- *Band edges*: max is **exclusive**. In tenths a 10ft cutoff is
  `band_max_tmm = 30481` — exactly 10ft is 30480 and lands in the lower band
  (A1); one tenth of a millimetre more does not. Getting this fencepost wrong
  overcharges RM144 on a 12ft curtain, and the spec already got it wrong once.
  **Assert the constant in a test, not just the resulting price.**
- *Money*: round half-up to the nearest sen, **once**, at the line total. Never
  round intermediates.

**Quantity arithmetic is exact rational, never float.** A foot is 304.8mm, so
ft→mm→sqft cannot be exact in binary, and `96.0000000001` ceils to 97 and
overcharges by a whole sqft. Integer numerator over integer denominator; divide
last. This is what keeps the Dart and Python engines bit-identical.

**A quotation is a reference price, and it is a promise that the final will not
exceed it.** The quote rounds every quantity up; the bill uses the exact tape.
That asymmetry is the product, not an artefact. Every quote screen and every
printed quote states it plainly, in the reader's language: *after site
measurement the price will be the same or lower, never higher.* Removing that
line turns an honest over-estimate into something that looks like a bait price.

**Material is chosen at measurement, and a deferred material is quoted at the
DEAREST option in its group.** At a fair the job is to lock the deposit, not to
settle the specification. Seven variants have material-dependent rates, and
quoting the cheaper one would make the final price go **up** — exactly what the
reference-price disclaimer says cannot happen. At final pricing a missing
material raises rather than guessing; nobody is invoiced for a material they
never picked.

**A quotation never shows less than the deposit.** RM300 per deposit category is
the floor on a quoted category subtotal, because a customer who is quoted RM250
and pays a RM300 deposit has overpaid and will argue. The uplift is shown, never
silent — the customer sees the line total and sees the floor applied. The RM300
is config, not a literal in code.

**Version pinning.** A rate lock pins **both** `held_rate_card_version` **and**
`held_discount_pct`. Pinning only the version silently reprices held orders when
the promo % moves. Rate card rows are never updated in place and never deleted —
a price change publishes a new version and marks old rows `superseded_at`.

**IDs are client-generated UUID v4.** Two part-timers offline at one fair must
never collide. Server-issued exceptions: payment receipt numbers and anything on
a legal document — null until sync, shown as "pending sync", **never fabricated
on-device**.

**The pricing engine is pure.** No Flutter imports, no I/O, no clock reads except
an injected one. Runnable in a test with no UI, no DB, no network.

**Ledgers are append-only.** `order_events`, `payments`, `price_overrides`,
`stock_movements`. Corrections are new rows with a reason. Never edits or deletes.

---

## Hard rules

1. **Never hardcode a price.** Rates come from data — one JSON file the admin
   edits. Tests may use literals; nothing else may. A price change must never
   need a code change, a rebuild or a release.
2. **When a business rule is unclear, add it to `SPEC.md` §13 and stop.** Do not
   guess. A wrong guess about money is silent and expensive.
3. **`shared/pricing-fixtures.json` is the contract** between the Dart and Python
   engines. Every case lives there once; both suites load it. A rule change means
   editing the fixture, then making both sides pass.
4. **Server wins on pricing disagreement**, and the discrepancy is logged for
   review. Never silently accept the client's number.
5. **Height selects the band. Height never multiplies.** For `per_ft_width` only
   width is charged.
6. **A line whose category has no active lock is never priced at a held version.**
   Applying a curtain lock to a flooring line is the expensive bug in this design.
   An **add-on takes its parent's category** and raises without one — never
   defaults, because the default would be a guess about money.
7. **Nothing this system prints may say "Tax Invoice" or "e-Invoice", or display
   a UIN or validation QR.** SQL Account is the sole issuer of record. This is a
   legal constraint, not a labelling preference.
8. **Part-timers never see a rate, cost, or margin.** They pick a product; the
   system picks the rate. Nothing selectable means nothing to get wrong.
9. **Offline is the default, not a fallback.** Quote, PDF and deposit must all
   work with no signal. Never block the UI on sync. No token expiry may lock a
   user out mid-fair.
10. **Each phase ships something demonstrable.** If a phase ends with nothing the
    client can hold, it was scoped wrong.

---

## Stack

| Layer | Choice |
|---|---|
| Mobile | Flutter 3.x, Dart 3 |
| Mobile DB | **Drift (SQLite)** — relational data. Not Hive, not key-value. |
| Mobile state | Riverpod |
| Dashboard | Angular 17+, standalone components |
| Backend | Python 3.12 + FastAPI |
| Server DB | PostgreSQL 16 |
| Migrations | Alembic · **ORM** SQLAlchemy 2.0, typed |
| PDF | `pdf` + `printing` (Dart), **on device** — must work offline |
| Deploy | Docker Compose, single VPS, Caddy, nightly backup |

No Kubernetes, no microservices. One node, restorable in under an hour, is the
right shape for one developer supporting one client.

## Repo layout

```
mobile/lib/
  core/       Length, Money, parser, formatters
  pricing/    PURE engine, zero Flutter imports
  data/       Drift schema, DAOs, outbox
  features/   quote/ measure/ payment/ settings/
  sync/
backend/app/
  core/       money.py, length.py — mirrors Dart core
  pricing/    PURE engine — mirrors Dart
  models/ api/ services/
dashboard/src/app/
  orders/ rates/ users/ reports/ shared/
shared/
  pricing-fixtures.json    ← ONE file, BOTH test suites load it
```

---

## Conventions

- Money columns end `_sen` and are `int`. Lengths end `_tmm` and are `int`,
  in tenths of a millimetre. A column named `_mm` is a bug.
- Every table: `id uuid PK`, client-generated. Syncing tables carry `synced_at`.
- Timestamps `timestamptz`, stored UTC, displayed `Asia/Kuala_Lumpur`.
- Postgres enums server-side, Dart enums client-side, kept in step by a
  **generated** file, never by hand.
- **Three languages: Chinese, English, Malay** (`zh`, `en`, `ms`), switchable
  **per user**, not per device. Default `zh`. Workers differ; a part-timer who
  reads only Malay must be able to quote. No string is ever hardcoded in a
  widget — every user-visible string comes from the ARB files.
- **Labels on data are a map, not parallel columns.** `{zh, en, ms}` in the seed
  JSON, JSONB server-side. Adding a language must never be a migration per table.
- Money displays with two decimals and the RM prefix. Dates as `12 Mar 2027`.
- Dimensions display entered **and** billed: `12尺 4寸 → 按 13 尺计`.
- Pin all dependencies. Lockfiles committed.

---

## Where to look in SPEC.md

| Need | Section |
|---|---|
| How the business actually works | 3 |
| Rate card structure, engine algorithm, golden tests | 4 |
| Unit parser table, soft warnings | 5 |
| Deposits, rate locks, payments, overrides | 6 |
| Remaining tables, indexes | 7 |
| Binding UI rules | 8 |
| Sync design | 9 |
| RM10,000 rule, SQL Account handoff | 10 |
| Phase scope and acceptance criteria | 11 |
| Open questions, blocking flagged | 13 |
