# Milan Software

Soft furnishings order system for a Malaysian retailer (Melaka).
Curtains, blinds, SPC / vinyl / laminate flooring, wallpaper.

**Flutter** mobile app (quote, measure, deposit) · **Angular** web dashboard ·
**FastAPI** backend (sync, publishing, export).

Full detail in `SPEC.md`. This file is the context that must never be violated.

---

## Current state

**Phases 1-6 complete. Phase 7 next** — Flutter app,
FastAPI backend, Postgres, and sync between them.

Built and green on the device: `Length`, `Money`, `Rational`, the unit parser,
the soft warnings, the pricing engine over the real 77-row fair card, the custom
keypad, the quote wizard in zh / en / ms, local persistence (a quote survives a
force-quit), special-track and add-on upgrades, whole-order product rules, the
delivery zone charge, customer details, a photo per window, and the on-device
trilingual PDF.

Built and green on the server: the Python engine passing the same fixtures, the
sync endpoints, Alembic migrations with a test that they match the models, users
and roles, and rate card publishing. **792 Dart tests, 595 Python tests.** 100%
coverage on `Length`, `Money` and `Rational`.

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
can add people, change a PIN, and remove access; the **first** admin still needs
shell access, so no bar was lowered — and a real one was raised, because the
alternative is the boss keeping one shared login that reaches every handset.

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

**Every dashboard screen now has a spec.** 149 dashboard tests.

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

**A21 is answered in principle, and the principle is conditional.** A printed
minimum is a floor on the **job**, not the line: a small blind on its own bills
its 18 sqft, the same blind inside a house of curtains bills what it measures.
Four order-of-operations questions that answer raises are recorded as **A21a–d**
rather than guessed. Until they are settled both engines keep applying `min_qty`
unconditionally — the conservative reading, already built and fixture-tested.

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

Two smaller things the dashboard still lacks: a session that survives a page
refresh (deliberate for now — a token in `localStorage` on a shared office
machine is one the next person inherits, and §13 has no question about it yet),
and any Malay or Chinese. The handset is trilingual because a part-timer who
reads only Malay has to be able to quote; whether the office screens need the
same is worth asking rather than assuming.

**Five CI jobs**, all green: Flutter, Python, the deploy stack, Angular, and the
shared files.

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
