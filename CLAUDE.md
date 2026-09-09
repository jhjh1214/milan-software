# Milan Software

Soft furnishings order system for a Malaysian retailer (Melaka).
Curtains, blinds, SPC / vinyl / laminate flooring, wallpaper.

**Flutter** mobile app (quote, measure, deposit) · **Angular** web dashboard ·
**FastAPI** backend (sync, publishing, export).

Full detail in `SPEC.md`. This file is the context that must never be violated.

---

## Current state

**Phases 1-6 complete. Phase 7 in progress. Phase 8 started, server side
only** — Flutter app, FastAPI backend, Postgres, and sync between them.

**Phase 7 so far.** The buyer-detail capture screens, both sides, the sync
between them, and the document labelling audit. **Only the export is left, and
it is blocked**: it needs a sample import template (§13 **E1**) and the
accountant's ruling on **E2**, and §13 **C12** and **C13** decide where the
guard bites and which fields MyInvois actually rejects. Do not guess any of the
four. Everything else on Phase 7's "In" list is built.

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

**Not built yet, and named rather than skipped silently:** the admin
floor-plan upload + tap-to-calibrate UI, and the part-timer submission
screen on the handset — both still need a decision this session flagged
rather than guessed: where an uploaded floor-plan image actually lives.
Nothing in `deploy/docker-compose.yml` names an object store or a mounted
upload volume today, and inventing one silently is exactly the kind of
infrastructure choice CLAUDE.md's working agreement reserves for a person,
not a guess.

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

One left open: `order-board.ts`'s doc comment quotes SPEC.md's original
"filter by channel/project/salesperson/fair" wishlist, but only channel and
status are implemented. Genuinely ambiguous whether that is an oversight or
a deliberate subset (no §13 entry says either way), and building the missing
filters is a real feature addition, not a bug fix — left as a question
rather than guessed at.

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

One thing the dashboard still lacks: a session that survives a page refresh —
deliberate for now, because a token in `localStorage` on a shared office
machine is one the next person inherits, and §13 has no question about it yet.
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

**Two new blocking questions**, both about money, both built the conservative
way rather than guessed: §13 **B9** (what identifies a returning customer —
phone is in force, a real customer record is the open part) and **B10** (two
handsets each taking a deposit for one category; both rows kept, the first
prices, the second marked `superseded`, nothing refunded automatically).

**Schema snapshots start at v10.** `dart run drift_dev schema dump` writes
them, and CI fails a `schemaVersion` bump that arrives without one.

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
