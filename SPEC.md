# Milan Software — Full Spec

Domain detail, data model, phases, open questions.
**Invariants, tech stack and build rules live in `CLAUDE.md`.** Read that first.

Section map:
| # | Section |
|---|---|
| 2 | What this product is, and where V1 stops |
| 3 | Business context, flow, roles, deposit categories |
| 4 | Pricing — real rate card findings, schema, engine, golden tests |
| 5 | Units — parser table, warnings |
| 6 | Orders, deposits, rate locks, payments, overrides |
| 7 | Data model — remaining tables, conventions, indexes |
| 8 | UX rules |
| 9 | Offline and sync |
| 10 | e-Invoice and SQL Account |
| 11 | Phases 1–9, scope and acceptance criteria |
| 12 | Non-functional targets |
| 13 | Open questions |
| 14 | Architecture, boundaries, extensibility |

---

# 2. WHAT THIS PRODUCT IS

## 2.1 One sentence

An **internal** sales, quotation, order, measurement and fulfilment system for a
soft-furnishings retailer. Staff-facing only. No customer ever logs into it.

## 2.2 The quotation workflow is for dimension-dependent products

Curtains, blinds, tracks, flooring and wallpaper are priced from **measurements**,
so a quote for them needs a wizard, a unit parser, bands, minimum quantities and
a site visit. That is what §4, §5 and §6 exist for.

Fixed-price goods — sofas, beds, ready-made items — need none of it. They have a
price, not a formula. **Do not force them through the measurement workflow**, and
do not let their eventual arrival dilute the dimension-dependent path into
something generic enough to hold both.

A fair can run a separate booth per category, so a part-timer may work an entire
day inside `flooring` alone and never open a curtain. Category is a first-class
axis, not a filter added later.

## 2.3 The shape of a sale

```
enquiry
  -> fast REFERENCE quotation           (§4 estimate stage, §8.5 disclaimer)
  -> minimum deposit PER CATEGORY       (§6.1, RM300, fair deposits also lock)
  -> CONFIRMED ORDER                    (§6.3, a commercial record, not a lead)
  -> measurement booked -> site visit   (§11 Phase 6)
  -> exact dimensions                   (§4.3 final stage)
  -> FINAL pricing at the HELD card     (§6.1, never today's)
  -> material / series finalised        (§13 B7)
  -> production -> ready -> installed
  -> balance -> closed
```

**The quotation is deliberately not accurate.** It exists to be fast, safe and
good enough to secure a deposit while the customer is standing there. Precision
arrives at measurement. Everything downstream is designed around that: the
estimate rounds every quantity up, the disclaimer says so in the customer's
language, and the final can only land at or below it (§8.5).

Say this plainly in every design conversation. A change that makes the quote more
accurate at the cost of making it slower is usually the wrong trade.

## 2.4 V1 — what is being built

The system above, end to end:

quotation · pricing · deposits and rate locks · orders · payments · site
measurement · final pricing · fulfilment lifecycle · printed documents ·
offline operation · auditability · the property/project library foundations.

## 2.5 V2 — the customer-facing ecosystem, later

Not in scope, not costed, not a requirement of any current phase:

a customer app or web portal · customer accounts · rewards and loyalty ·
referral incentives · a customer-facing catalogue · fabric and material
browsing · product discovery · customer order tracking · self-service ·
home-photo capture · AI-generated curtain and interior visualisations ·
AI-assisted design suggestions.

**The only V1 obligation is not to make V2 hard.** Concretely, and these are the
decisions that would be expensive to reverse:

- **Stable identifiers, not display strings.** Products, families, variants,
  materials and collections are identified by stable keys. Pricing already
  matches on `variant` and `material_key` rather than on a label, and labels are
  already `{zh, en, ms}` maps (§7). Keep it that way: a customer catalogue will
  layer its own presentation on top of the same keys.
- **A customer is a thing, eventually.** §13 B9 is open precisely because there
  is no `customers` table yet. Whatever answers it becomes the identity a
  customer account would attach to.
- **Generated imagery never becomes a specification.** An AI visualisation is a
  picture. It must never flow into pricing, measurements, order lines or
  production paperwork. See §14.5.

---

# 3. BUSINESS CONTEXT

## The flow

```
CAPTURE  (showroom daily / home visit / fair twice a year)
  staff or part-timer builds a rough estimate from approximate sizes
  customer pays RM300 minimum deposit PER PRODUCT CATEGORY
  -> ORDER IS CONFIRMED. Not a quote, not a lead. A confirmed sale.
  -> at a fair, promo rates held 12 months for that category, unlimited windows

LATER  (days to 12 months, often waiting on house handover)
  book measurement -> site visit -> exact dimensions
  recalculate at the HELD rate, never today's rate
  customer picks fabric / material
  -> final price, balance due

THEN
  material ordered or allocated
  production -> ready -> install -> balance paid -> invoice -> closed
```

Two consequences that drive everything:

1. **The estimate exists to get a deposit, not to be accurate.** Fast, and
   impossible to get catastrophically wrong. Precision arrives at measurement.
2. **The fulfilment window is up to 12 months.** Customers wait for house
   handover. The dashboard tracks orders through that window; it is not a
   lead-chasing tool.

## Pricing model

> ⚠ **This section previously said the fair promo was a discount percentage on
> one standard list.** The supplied MITC Aug 2026 list settled it the other way
> and the code follows the list, not the old text.

- **Two published lists, and the date picks one.** `fair` and `standard` are
  separate card lineages, each versioned. The fair card carries the printed fair
  prices directly — they are *not* a percentage taken off the standard list.
  Inside a fair's promo window the fair card applies; every other day the
  standard one does (A3).
- **The standard list is derived from the fair list**, by
  `tool/build_standard_card.py`, and CI fails if the committed file is not what
  the generator produces. Only curtains and blinds are marked up; the other 45
  rows are the same price on both (A3a).
- **A discount percentage still exists** in the model (`held_discount_pct`,
  `promos.discount_pct`) and is pinned alongside the version on every lock and
  every order line. It is currently zero on both lists. Keep it: A4 and A12 are
  unanswered, and a promo expressed as a percentage is what those answers would
  need.
- **The 12-month lock is fair-only.** A deposit taken anywhere else confirms an
  order and buys nothing else (§6.1, B1).
- Every order pins a card version at order date, so a price rise between deposit
  and measurement does not reprice a confirmed order.

## Deposit categories

RM300 buys a 12-month rate hold on **one category**, unlimited windows inside it.

| Category | RM300 covers |
|---|---|
| `curtain` | sg_pleat, s_fold, day and night layers, **and all blinds and tracks** |
| `flooring` | all SPC / vinyl / laminate thicknesses |
| `wallpaper` | all wallpaper |

Curtains plus flooring = RM600, two deposits.

## Roles

| Role | Where | Can |
|---|---|---|
| `admin` | Office | Everything. Rate card, publishing, users, overrides, exports. |
| `staff` | Showroom, site, fair | Quote, measure, update orders, take payment. **Sees rates**, cannot edit. |
| `parttime` | Fair, showroom peak | Quote, take deposit, take payment. **Never sees a rate, cost, or margin.** |

Same wizard for all three. Only rate visibility differs. **Do not build two
quoting flows.**

### Visibility is a domain rule, not a UI preference

"A part-timer never sees a rate, cost or margin" is a **security requirement**.
It is satisfied by the server not sending the number, not by a screen choosing
not to draw it.

- **The backend authorises every request**, and it is the authority. Every
  rate-card write, every override, every report that names people or carries
  margin is refused server-side to anybody without the role, whatever the client
  believes.
- **The UI hides what it knows will be refused**, because offering somebody a
  screen that answers 403 wastes their time and teaches them the app is
  unreliable. That hiding is a courtesy. It is never the check.
- **Nothing selectable means nothing to get wrong.** A part-timer picks a
  product; the system picks the rate. This is why §8.1 can say errors are
  prevented rather than reported.

Authorisation lives in one place per side. A permission checked in two files
eventually disagrees with itself — see §14.3.

**Open: §13 C8.** Role checks are wired to the override sheet and to the
admin-only endpoints. They are **not** yet wired to order status transitions, so
the pipeline enforces what can happen and not who may do it.

## Channel

```
orders.channel  enum(showroom, home_visit, fair, referral, phone)
```
Every report segments by channel. The company currently cannot answer whether a
fair beats three months of showroom traffic.

## Environment constraints

- **Fairs have poor or no connectivity.** Must quote, PDF, and record a deposit
  fully offline.
- **Personal phones**, mixed Android and iOS, mixed age. Target low-end Android.
- **Part-timers trained in under 30 minutes**, and they change between fairs.
- Fair halls are bright. Screens must be readable in daylight.

## What the system does NOT do

- Does not process card payments. **Records** them. Existing terminal stays.
- Does not issue e-invoices. SQL Account does. See section 10.
- Does not read floor plans automatically. Plans are digitised once by an admin
  who can check the numbers; automated extraction is a documented future
  direction, not a V1 feature. See Phase 8 and §14.5.
- Does not sell to customers. There is no customer login, no catalogue and no
  online ordering. See §2.5.

---

# 4. PRICING

## 4.1 What the real rate card contains

From the MITC Mega Home Expo Aug 2026 list. **A simple three-family model does
not survive contact with it.**

### Their own band header is ambiguous
Columns read **"Below 10ft (H)"** and **"Up to 10ft (H)"**. Both mean 10ft or
under. The second must mean "over 10ft". This is a live price list and it is
unclear as printed. **Blocking, and their document needs correcting.**

### RM46 / RM58 is Night Curtain
```
Day Curtain    RM36/ft  |  RM48/ft
Night Curtain  RM46/ft  |  RM58/ft   (Dimout)
```
"Sgp Pleat" appears only in rod combinations (`Wooden Rod With Sgp Pleat
RM56/ft`), so pleat style looks like a heading bundled with hardware, not a
standalone fabric product. Confirm.

### A curtain is ONE line. The normal track is already in the price.

> ⚠ **This section previously said the opposite** — "a curtain is at least two
> lines… the wizard adds the track line automatically". **That is wrong.**
> Corrected by the client, Sep 2026: the curtain rate already includes a normal
> track, and every track and rod rate on the list is for a **special** track.
>
> Building the automatic track prompt would have added RM9–10/ft to every
> curtain — roughly **RM108 extra on a single 12ft window**, on every quote,
> silently. Do not reintroduce it.

`Doso RM9/ft` and `Meyer RM10/ft` are printed "Track Only" — the price for
buying track **without** a curtain.

**A track line is an upgrade the customer chooses, never a line the system adds
on their behalf.** And a genuine upgrade **adds** to the curtain rate rather
than replacing it (A16): a motor track on a night curtain is RM46 + RM40 =
RM86/ft.

### Half the "track" rows were never track — they are curtain STYLES
Client, Sep 2026, on being shown that every banded track row carries the same
+RM12 drop step as the curtains:

> The S track is actually S fold, as opposed to sgp pleat, different style of
> curtain so different rates, it includes the same railing everything. so all
> other special tracks are direct add on.

So `S Track (Night Curtain) RM80/ft` is **a whole night curtain in S-Fold, with
its railing**, not RM80 of hardware. The same for the four rod composites: a
made-up curtain in that heading style, on that rod.

Twelve rows moved from `family: track` to `family: curtain`, which is all it
took — the engine offers track rows as upgrades and curtain rows as products,
so the family decides everything. They are relabelled to say so, because
"S Track (Night Curtain)" reads like something you add to a night curtain and
`Night Curtain (S-Fold)` cannot.

**This was a 58% overcharge.** A 12ft × 9ft S-Fold window quoted RM1,512
(RM552 + RM960) where the answer is RM960 — RM552 too much, on every S-Fold and
every rod composite, and it was in the demo script.

The tell was in the data all along: the banded rows step +RM12 between bands
exactly as the curtains do (46→58, 80→92, 36→48, 60→72), which no hardware
add-on would; and real track hardware in this card is RM9–RM40/ft.

### Composite variants exist
`Wooden Rod With Sgp Pleat RM56/ft` is not RM18 plus something. It is its own
variant at its own rate, and that rate is the whole curtain. **Do not compute
bundles from components.**

### MVP tier is a FLAT discount, not a percentage
```
Night Curtain  RM46 -> MVP RM40   (-RM6)
               RM58 -> MVP RM52   (-RM6)
S Track Night  RM80 -> MVP RM70   (-RM10)
               RM92 -> MVP RM82   (-RM10)
```
Constant sen off, same in both bands, only on some products.
`pricing_rules.mvp_rate_sen`, `customers.tier`.
**Do not implement MVP as a percentage.** It will drift off the printed list.

### Minimum QUANTITY, not minimum charge
`Min 18sqft`, `Min 20sqft`, `Min 200sqft`, `Min 30sqft`, `Min 45sqft`, `min 4ft`.
These floor the **billed quantity** before the rate multiplies. A 12sqft roller
blind bills as 18sqft. Show it on the line or the customer will query it.

### Blinds DO have height bands
`Outdoor Wooden Chicks RM10/sqft | RM11/sqft Over 10ft(H)`.
`band_field` applies to **any** family, not just curtains.

### Material and series change the rate
- `Zebra Blackout: J/BL RM12/sqft, TBL RM15/sqft`
- `Outdoor ZIP: RM55/sqft (1%), RM60/sqft (0%)` — openness factor
- Slat sizes 25 / 35 / 50 / 63mm priced differently

**This looks like it contradicts "customer picks fabric later".** It does not,
and §13 B7 settled which way: **every product defers material to measurement**,
including these seven. At a fair the job is to secure the deposit, not to settle
the specification.

What makes that safe is the quoting rule: **a deferred material is quoted at the
DEAREST option in its group.** Quoting the cheaper one would let the final price
rise, which §8.5 says cannot happen. The line says on its face that the material
is not yet chosen, and the drop when the customer picks a cheaper option is the
promise being kept rather than a discount.

At **final** pricing a missing material refuses rather than guessing — nobody is
invoiced for a material they never chose.

### Add-ons and services are lines with their own basis
```
per_piece / per_set : Motor RM800, Remote RM200, Dream Blind Motor RM1500/set,
                      Side Guide Cable RM400/set, Intermediate Joint RM400/set,
                      Outdoor Roller Motor: Somfy RM1800 / AOK RM1000
per_ft add-on       : Roller "Add box RM10/ft, min 4ft"
per_sqft service    : Dismantle old SPC RM1/sqft, self levelling
per_roll service    : Wallpaper dismantle RM80/roll
```

### Constraint rules, not prices
- SPC Herringbone **requires** self levelling
- Intermediate Joint **requires** motor
- Outdoor ZIP Blinds **max 20ft width**

### Order-level zone charges
```
KL / Seremban / N.Sembilan        +RM300 round trip
Muar / Tangkak / Jasin / Tampin   +RM100 transport
```
Driven by delivery address, not by line. **Ask for the delivery area early** and
surface the charge before the total, never after the customer has agreed a number.

### Wallpaper
`Korea Wallpaper (Buy 1 Free 1) 14ft x 10ft RM800 (2 roll)`.
Basis `per_roll`, coverage 14ft x 10ft, sold as a BOGO pair. Round up to whole
bundles. Pattern-repeat wastage still unanswered.

## 4.2 Schema

```sql
rate_cards
  version            int PRIMARY KEY
  published_at, published_by
  is_active          bool

promos
  id                 uuid PK
  code               text                -- 'FAIR-2027-03'
  discount_pct       numeric(5,2)
  scope              enum(all, by_family)
  family             text NULL           -- only when scope = by_family
  valid_from, valid_to

pricing_rules
  id                 uuid PK
  rate_card_version  int
  family             enum(curtain, blind, track, flooring, wallpaper, addon, service)
  variant            text                -- 'night_curtain','roller','spc_5mm','doso'
  layer              enum(single, day, night)
  material_key       text NULL           -- series / openness / slat that moves rate
  fulfilment         enum(supply_install, supply_only)
  labels             jsonb               -- {zh, en, ms} — a MAP, never columns
  basis              enum(per_ft_width, per_sqft, per_m_length,
                          per_piece, per_set, per_roll)
  band_field         enum(height, width, none)
  band_min_tmm       int                 -- INCLUSIVE, tenths of a mm
  band_max_tmm       int NULL            -- EXCLUSIVE, tenths of a mm
  rate_sen           int
  mvp_rate_sen       int NULL            -- FLAT tier price
  min_qty            numeric NULL        -- minimum BILLED quantity
  min_charge_sen     int NULL            -- different concept, both may be null
  coverage_sqft      numeric NULL        -- per_roll / per_box
  bundle_qty         int DEFAULT 1       -- BOGO: charge 1, deliver 2
  wastage_pct        numeric(5,2) DEFAULT 0
  is_addon           bool DEFAULT false
  attaches_to        text[] NULL         -- variants this add-on is offered on
  warranty_notes     jsonb NULL          -- {zh, en, ms}
  sort_order         int
  superseded_at      timestamptz NULL

product_rules
  id, variant
  kind        enum(requires, excludes, max_dimension, min_dimension)
  target      text NULL                  -- required/excluded variant
  dimension   enum(width, height) NULL
  value_tmm   int NULL
  messages    jsonb                      -- {zh, en, ms}

delivery_zones
  id, name, area_labels text[], charge_sen,
  charge_kind enum(round_trip, transport)
```

**Band semantics:** `band_min_tmm <= value < band_max_tmm`, max **exclusive**.

**A1 ANSWERED: exactly 10ft is the LOWER band.** A 10ft height bills at RM46,
not RM58. The step happens at 10ft 1in.

Lengths are stored in **tenths of a millimetre** (`*_tmm` — see CLAUDE.md), so
the 10ft cutoff is **`band_max_tmm = 30481`**. Exactly 10ft is 30480 and falls
below it; one tenth of a millimetre more does not.

The spec previously said `band_max_mm = 3048` *and* said that produced the lower
band. Under an exclusive max it does not — `3048 < 3048` is false — so it would
have pushed exactly 10ft into the upper band and overcharged RM144 on a 12ft
curtain. **Assert the constant in a test, not just the resulting price.**

Their printed list heads the columns "Below 10ft (H)" and "Up to 10ft (H)", both
of which read as 10ft or under. **Their document needs correcting** to "Up to
10ft (H)" and "Over 10ft (H)". Print the ruling in words on the rate card screen:
10 尺以内（含 10 尺）.

## 4.3 Engine

```
priceLine(family, variant, layer, material_key, fulfilment,
          widthMm, heightMm, qty, card, promoPct, tier, stage):

  stage = estimate  ->  billed quantity rounds UP to a whole unit
  stage = final     ->  billed quantity is EXACT, no rounding of quantity

1. candidates = rules.where(family, variant, layer, material_key, fulfilment)
2. if band_field != none:
     v = (band_field == height) ? heightMm : widthMm
     rule = first where band_min_tmm <= v < band_max_tmm
     no match -> throw NoApplicableRate       # NEVER pick the cheapest
   else:
     rule = candidates.single()
3. rawQty by basis, held EXACTLY, never as a float.
   Dimensions are in tenths of a millimetre (`_tmm`), so these are exact:
     per_ft_width : widthTmm / 3048                         unit 'ft'
     per_sqft     : widthTmm * heightTmm / 9290304          unit 'sqft'
     per_m_length : widthTmm / 10000                        unit 'm'
     per_piece    : 1                                       unit 'pc'
     per_set      : 1                                       unit 'set'
     per_roll     : rawSqft / coverage_sqft / bundle_qty    unit 'roll'
4. if wastage_pct > 0: rawQty *= (1 + wastage_pct/100)
5. if min_qty:         rawQty = max(rawQty, min_qty)          # BEFORE multiply
5b. billedQty = (stage == estimate) ? ceil(rawQty)   # A10  — quote rounds UP
                                    : rawQty         # A11  — final is EXACT
6. rate = (tier == mvp && mvp_rate_sen != null) ? mvp_rate_sen : rate_sen
7. if promoPct > 0: apply per A4 (unit rate vs line total — UNANSWERED)
8. total = roundHalfUp(billedQty * rate) * qty
9. if min_charge_sen: total = max(total, min_charge_sen * qty)
```

**Then, once per deposit category, at the order level — not per line:**

```
categorySubtotal = sum(line.total for lines in that deposit category)
if stage == estimate:
    categorySubtotal = max(categorySubtotal, MIN_DEPOSIT_SEN)   # 30000 = RM300
```

A customer quoted RM250 who then pays a RM300 deposit has overpaid, and will
argue about it at measurement. The floor removes that conversation. It applies to
the **quotation only** — final pricing is what it is, and §13 B4 still owes an
answer on what happens when a *final* lands under the deposit already taken.

`MIN_DEPOSIT_SEN` is config, per hard rule 1. **The uplift is shown, never
silent:** the lines display their real totals and the floor appears as its own
labelled row. Quietly inflating lines to reach RM300 would be the exact dishonesty
the reference-price disclaimer in §8.5 exists to prevent.

**Height selects the band. Height never multiplies.** For `per_ft_width` only
width is charged. Single most likely thing to get wrong.

**The two stages round quantity differently. This is deliberate — do not
"fix" it into one rule.**

- *Estimate* (A10): billed quantity is a whole unit, rounded **up**, exactly
  once, after wastage and after `min_qty`. Never before — rounding up twice
  overcharges. There is no 19.99 sqft on a quotation.
- *Final*, after site measurement (A11): billed quantity is **exact**. The tape
  is the truth and the held rate multiplies it directly.

**Consequence: the estimate is systematically ≥ the final, on every line.**
Rounding up only ever moves one way, so a customer's final price can only land
at or below what they were quoted. That is the safe direction commercially — no
rounding artefact ever produces a surprise increase — but §6.3's estimate-vs-final
variance report must subtract this known bias before it can say anything about a
salesperson's guessing. A line quoted at 13ft and billed at 12.33ft is not a bad
estimate.

**`min_qty` applies at BOTH stages — see §13 A21, which is open.** "Min 18 sqft"
is printed on the price list as a commercial floor, not a rounding artefact, so a
site-measured 9 sqft roller blind still bills 18. Both engines do this and a
fixture pins it. It is the reading the printed list supports and it is not in
tension with §8.5, because the estimate applies the same floor — but it is worth
having in writing, since the other reading bills RM81 where this bills RM162.

**`rawQty` must be exact rational arithmetic, not a float.** A foot is 304.8mm,
so ft→mm→sqft can never be exact in binary. A 12ft × 8ft blind that computes as
96.0000000001 sqft would ceil to 97 and overcharge by a whole sqft. Integer
numerator and denominator only; the divisions above are deferred, not evaluated.
The two engines must agree bit for bit — see §9.4.

## 4.4 Golden tests

Live in `shared/pricing-fixtures.json`, run by **both** the Dart and Python
suites. CLAUDE.md hard rule 3: every case lives there once and both sides load
it. **CI fails a section that only one suite loads**, so the contract cannot
quietly become one-sided.

The file now carries a section per rule, not only the six original line cases:

| Section | Covers |
|---|---|
| `cases` | One line priced, estimate stage — the golden table below |
| `quote_total_cases` | Category subtotals, the RM300 floor, delivery |
| `rate_lock_cases` | Which version and discount price a line (§6.1) |
| `lock_grant_cases` | When a deposit opens a lock (fair-only, B1) |
| `customer_key_cases` | What identifies a returning customer (B9) |
| `order_status_cases` | Every legal and refused transition (§6.6) |
| `price_override_cases` | Admin override rules (§6.5) |
| `final_pricing_cases` | Repricing a measured order at the held card |
| `einvoice_threshold_cases` | The RM10,000 rule (§10) |
| `buyer_details_cases` | What counts as having the buyer's details (§10.3) |

**Expectations are derived from this spec, never from an engine.** The
final-pricing figures were worked out from §4.3's formula with exact rational
arithmetic before either engine ran, so three-way agreement is evidence rather
than a tautology.

Worked example, and the one that shows the two stages apart: a night curtain
measured on site at 12ft 4in (37592 tenths of a mm) bills
`37592/3048 = 37/3 = 12.3333 ft × RM46 = 56733.33 sen → RM 567.33`, against
**RM 598.00** quoted at a rounded-up 13ft.

The six below are all `stage = estimate`.

| variant | W | H | band | billed | rate | total |
|---|---|---|---|---|---|---|
| night_curtain | 12ft | 9ft | lower | 12 ft | 4600 | **RM 552.00** |
| night_curtain | 12ft | 10ft 6in | upper | 12 ft | 5800 | **RM 696.00** |
| night_curtain | 12ft 4in | 9ft | lower | 13 ft | 4600 | **RM 598.00** |
| night_curtain | 12ft | exactly 10ft | lower | 12 ft | 4600 | **RM 552.00** |
| night_curtain (MVP) | 12ft | 9ft | lower | 12 ft | 4000 | **RM 480.00** |
| roller_blackout | 3ft | 4ft | none | **18 sqft** (min) | 900 | **RM 162.00** |

---

# 5. UNITS

The person typing is a part-timer hired last week, standing up, in a loud hall,
with a customer waiting. **The unit system has to be robust against them, not
dependent on them.**

## 5.1 The pipeline: parse → normalise → validate → suggest → confirm

Five stages, and each one is somewhere different in the code:

| Stage | What it does | Where |
|---|---|---|
| **Parse** | Text → a value and a unit, or a refusal | `core/length_parser.dart` |
| **Normalise** | That value → canonical `_tmm` | `core/length.dart` |
| **Validate** | Is this physically plausible here? | `core/dimension_warnings.dart` |
| **Suggest** | Offer the likely correction | UI, from the validator's output |
| **Confirm** | The **person** decides | UI |

Two rules hold the whole thing together:

1. **The pricing engine only ever receives canonical `_tmm`.** It never sees a
   string, a unit, a suggestion or a warning. Parsing is not pricing.
2. **Nothing is silently corrected.** The system may say "that looks wrong, did
   you mean X?" and make X one tap away. It may never quietly become X. A
   silent correction is a wrong price with no visible error, which is the exact
   failure §5.2 exists to prevent.

## 5.2 Do not guess unit from magnitude

Rejected design, and it stays rejected. `84` is a plausible inch drop and a
plausible cm width. `180` likewise. The ambiguous band 50–300 is where most real
input lands. A wrong guess produces a wrong price with no visible error.

Magnitude drives **warnings** (§5.4). It never drives interpretation.

## 5.3 What ships

- Per-field **default unit**, set by admin
- **Always-visible tappable unit chip** beside every dimension field
- **Suffix parsing** overrides the chip
- Magnitude used **only as a soft warning**, never as a decision

### Parser

`Length? parseLength(String input, LengthUnit defaultUnit)` → `Length` (`_tmm`)

**Parses to tenths of a millimetre, not millimetres.** Rounding to whole
millimetres on parse is the bug the `_tmm` invariant exists to prevent: a foot
is 304.8mm, so `12ft → 3658mm → 12.0013ft → ceil 13ft` overcharges RM46 on one
window. In tenths every accepted unit is an exact integer, so nothing rounds on
the way in. See CLAUDE.md.

| Input | tmm | note |
|---|---|---|
| `84` | per chip | bare number |
| `84in` `84"` `84 inch` | 21336 | |
| `7ft` `7'` `7尺` | 21336 | |
| `7'6` `7'6"` `7ft6` `7ft 6in` `7尺6寸` | 22860 | **must work** — how the trade talks |
| `8000mm` | 80000 | |
| `2400mm` | 24000 | |
| `2.4m` `2.4米` | 24000 | |
| `240cm` | 24000 | |
| `7.5ft` | 22860 | |
| `12'0` | 36576 | |
| `96in` | 24384 | |
| `8ft` `8'` | 24384 | |
| empty | null | |
| `abc` `7''6` `-5` | null → inline error | **never fall back to a guess** |

Chinese numerals are not parsed — out of scope.

## 5.4 Plausibility validation

Non-blocking, one tap to fix, and **configurable rather than a pile of
hardcoded guesses**.

A plausible curtain drop is not a plausible flooring run, and a plausible
wallpaper width is not a plausible motor. So a plausible range is a property of
**the field, in its product category**, carried on the rate card next to the
rates it belongs with — the same place `BAND_EDGE_WARN_TMM` and
`MIN_DEPOSIT_SEN` already live (hard rule 1: config, not code). A category with
no configured range warns on nothing, which is the safe default: a missing
config must not invent a limit that blocks a real order.

| Condition | Behaviour |
|---|---|
| Outside the configured plausible range for this field and category | Strong warning naming the likely unit, with a one-tap switch |
| Suspiciously large for the chip's unit | `2400 寸 = 61 米，是不是要打 mm？` + `[改成 mm]` |
| Suspiciously small for the field | `高度只有 30cm，确认吗？` |
| Within `BAND_EDGE_WARN_TMM` (default 76mm ≈ 3in) of a band boundary | Warns and **shows both prices** |

### The worked example: `8000in`

A part-timer means `8000mm` — 8 metres, a wide sliding door — and the chip is
on inches, or they typed the suffix. `8000in` is **203 metres**. No curtain, no
window and no floor in this business is 203 metres.

What must happen:

- **Parse succeeds.** `8000in` is well-formed input; refusing it as a parse
  error would say "that is not a number", which is not the problem.
- **Validation flags it hard**, because it is far outside the plausible range
  for that field in that category.
- **The suggestion is specific**: *"203m is not a curtain width. Did you mean
  8000mm?"* with `[改成 mm]` beside it.
- **The person confirms.** If they insist, it is allowed — but they have seen
  the number in metres and pressed past it.

Never silently reinterpret the unit. The customer is watching the total; a
number that changes itself is worse than a number that argues.

**The band-edge warning is still the highest-value validation in the app.** On a
12ft curtain, `10ft 1in` vs `9ft 11in` is a RM144 swing.

## 5.5 Display

Show entered value **and** billed value: `12尺 4寸 -> 按 13 尺计`.
Never show more precision than was entered.

`Length.mm` exists as a **display accessor only**. Never feed it back into a
length or a price.

---

# 6. ORDERS, DEPOSITS AND RATE LOCKS

## 6.1 The lock is on customer + category, not on the order

A single order can carry curtain lines at held promo rates and flooring lines at
standard price, if only one RM300 was paid.

```sql
category_locks
  id uuid PK
  customer_key            text        -- see below: NOT a customer_id yet
  category                enum(curtain, flooring, wallpaper)
  deposit_payment_id      uuid
  held_rate_card_version  int
  held_promo_id           uuid
  held_discount_pct       numeric(5,2)    -- denormalised; promos rows may change
  held_until              date            -- deposit date + 12 months
  status                  enum(active, expired, cancelled, refunded)
  UNIQUE(customer_key, category) WHERE status = 'active'
```

### What a lock hangs on

`customer_key`, not `customer_id`. **There is no `customers` table yet** (§13
B9), so the key is the customer's **phone number, normalised** — digits only,
`+60` folded to a leading `0`, and refused under nine digits — falling back to
the quote id when there is no usable phone.

This is not a shortcut, it is the answer to a bug that had already shipped. The
lock was keyed on the **quote id**, which meant the twelve-month hold could
never be used: the customer deposits at the fair, returns in March, a new quote
is started with a new id, and they are quoted the standard rate — *more* than
the hold they paid for, after the app promised it until next August.

The same normalised phone keys the measurement queue (C10), so one customer with
three units is one trip. **Keep the normalisation in one function**
(`pricing/customer_key.dart`, mirrored in Python). When B9 is answered and a real
customer record exists, that function is the single place this changes.

`family` and deposit category are **different fields**. Blinds and tracks have
their own rates but ride the curtain deposit. Keep the mapping in one function.

```python
def deposit_category(family):
    return {'curtain': 'curtain', 'blind': 'curtain', 'track': 'curtain',
            'flooring': 'flooring', 'wallpaper': 'wallpaper'}[family]

def price_basis_for(line, order):
    lock = active_lock(customer_key(order), deposit_category(line.family))
    if lock:                                    # fair customer, within 12 months
        return lock.held_rate_card_version, lock.held_discount_pct
    if order.channel == 'fair':                 # fair, no deposit yet
        return current_version, current_promo_pct(line.family)
    return order.pinned_rate_card_version, 0    # showroom: standard, no discount
```

Three cases. Do not collapse them.

**Hard rule:** a line whose category has no active lock must not be priced at a
held version. **Silently applying a curtain lock to a flooring line is the
expensive bug in this design. Write that test before the resolver.**

### Only a fair deposit opens a lock

Client, Sep 2026: *"no second rm300 paid later in showroom, only depo at fair can
lock price."*

A deposit taken in the showroom, on a home visit, over the phone or through a
referral confirms an order and buys nothing else. There is no way to acquire
held prices after the fair has packed up, and no way to top up a category later.

Two consequences:

- `open_category_lock` **refuses** unless the order's channel is `fair`. It is
  the only place a `category_locks` row is created, so the rule cannot be
  bypassed by a screen that forgets it.
- The §6.2 prompt below is **fair-only**. Away from a fair there is no second
  RM300 to offer, because it would not lock anything, and offering it would be
  selling something that does not exist.

## 6.2 The category prompt is a revenue feature

When a line is added in a category with no active lock:

> 这单有地板，地板要另外 RM300 才锁到促销价。
> `[收 RM300]` `[照原价，不锁]` `[取消这项]`

Not a silent fallback to full price. Not a silent extension of the existing lock.
This is the moment the second RM300 gets collected, and it is almost certainly
being missed at fairs today.

**Log which button was pressed.** The declined-deposit report tells the boss what
fairs are leaving on the table.

## 6.3 Orders

```sql
orders
  id uuid PK                              -- client-generated, never waits on sync
  order_no                  text NULL     -- SERVER-issued {branch}-{yymm}-{seq}
  quote_id                  uuid          -- the estimate this came from, never consumed
  customer_name, customer_phone           -- until B9 gives us a customers table
  channel                   enum(showroom, home_visit, fair, referral, phone)
  project_id, unit_type_id  uuid NULL     -- Phase 8, see section 11
  pinned_rate_card_version  int
  delivery_zone_id          uuid NULL
  delivery_charge_sen       int DEFAULT 0
  status                    enum(confirmed, measurement_booked, measured,
                                 material_selected, in_production, ready,
                                 installed, closed, cancelled)
  estimate_total_sen        int
  final_total_sen           int NULL      -- NULL until EVERY line has priced
  deposit_paid_sen, balance_due_sen
  has_unmeasured_lines      bool
  -- buyer details for an e-invoice; see section 10.3
  buyer_tin, buyer_id_type, buyer_id_number
  buyer_address_line1, buyer_address_line2
  buyer_city, buyer_state, buyer_postcode, buyer_msic_code
  einvoice_requested        bool DEFAULT false
  created_by, created_at, synced_at

order_lines
  id, order_id, sort_order
  quote_line_id             uuid          -- the trail back to the estimate
  family, variant, layer, material_key, fulfilment
  category_lock_id          uuid NULL     -- which lock priced this, null = none
  parent_line_id            uuid NULL     -- add-ons attach to their parent
  room, label

  -- WHAT WAS QUOTED. Never overwritten.
  est_width_tmm, est_height_tmm
  billed_qty text, billed_unit text       -- exact rational as text, never a float
  applied_rule_id, applied_band_label
  applied_rate_card_version int
  applied_discount_pct      text          -- exact rational as text
  standard_rate_sen         int           -- before discount, printed on the quote
  rate_sen, line_total_sen
  material_deferred         bool          -- quoted at the dearest option (B7)

  -- WHAT THE TAPE PRICED. NULL until measured. Written BESIDE the above.
  final_width_tmm, final_height_tmm
  is_site_measured          bool DEFAULT false
  measured_by, measured_at
  final_billed_qty text, final_billed_unit text
  final_rule_id, final_band_label         -- a measured drop can change the band
  final_rate_sen            int
  final_line_total_sen      int

  photo_ids                 uuid[]
  is_overridden             bool

order_events                              -- APPEND ONLY
  id, order_id, event, note, by_user, at, synced_at
```

**Estimate and final live side by side, never one over the other.** Six pairs of
columns say the same thing six times because the alternative is losing the
answer to *"but you quoted me RM598"*. The variance report needs both; so does a
customer conversation a year later.

**A line records the rule, band, version and discount that priced it.** A year
on, a customer asks why a curtain cost RM552 and the answer must not require
reconstructing which card was in force that afternoon — by then it may have been
superseded twice.

**An order total is absent, not partial.** `final_total_sen` stays NULL until
every line has priced. A total that quietly excluded an unmeasured window would
be a balance somebody collects and a window nobody bills for.

**Estimate and final are both kept.** The variance report by salesperson tells
the boss who is guessing badly and needs retraining.

**The quote is referenced, never consumed.** Client, Sep 2026: *"the quote
should be recorded as reference to the order, so have rough estimate of what to
do."* `orders.quote_id` points back at it and the quote is left exactly as it
was — it is what the measurement team reads before going out, and what the
variance report compares the final against. `order_lines` are **copies** of the
quote's lines, so editing an old quote cannot change a confirmed order and
measuring an order cannot change the estimate it came from.

**`order_no` is server-issued, not client-generated.** This deviates from the
column comment as originally written, deliberately. It appears on a document the
customer takes away, and `{branch}-{yymm}-{seq}` has no per-device component:
two part-timers offline at one fair would both mint `MLK-2608-0007`. CLAUDE.md's
rule — *"anything on a legal document: null until sync, shown as 'pending sync',
never fabricated on-device"* — is the stronger constraint, and it is the same
mechanism receipt numbers already use. The order's **id** stays a
client-generated UUID, so nothing waits on a server to exist.

### Quotation and order are different records

A **quotation** is a reference estimate (§8.5). It is cheap, it is expected to be
edited, and it binds nobody.

A **confirmed order** is a commercial record. Money has changed hands. It is read
by the measurement team, the workshop, the accounts person and, eventually, a
customer arguing about a number.

Three rules keep them apart, and none is negotiable:

1. **Order lines are copies, not references.** Editing an old quote cannot change
   a confirmed order, and measuring an order cannot change the estimate it came
   from.
2. **The quote is referenced, never consumed.** `orders.quote_id` points back at
   it and it is left exactly as it was. Client, Sep 2026: *"the quote should be
   recorded as reference to the order, so have rough estimate of what to do."*
3. **A future developer must be able to answer "why did this customer pay this
   amount?" from stored data alone** — without the rate card of the day, without
   the app, and without asking anybody. Everything the answer needs is on the
   order.

### Quotation revisions

A quote is edited freely **before** it becomes an order. After that it is
frozen, because it is the reference the order was built from.

When a customer wants changes to a **confirmed** order, that is not an edit to
the original quote. It is either:

- a change recorded against the order itself — a price override (§6.5), a
  re-measurement (new dimensions on the same line, the old ones kept), or a
  material choice; each with its own audit row; or
- a **new** quote and a **new** order, if the change is large enough that the
  first one is being replaced rather than adjusted.

**Never mutate a confirmed order's history to make it match a new conversation.**
A remeasure is new dimensions on the same order, not a rewind (§6.6).

**A line whose lock disagrees with the priced version refuses conversion.**
If a line's `category_lock` holds version 55 and the quote on screen was priced
at version 1, the customer is being shown a price their RM300 did not buy — in
one direction or the other. Recording the held version on a line that was priced
at another would make the order lie about itself, and that lie is what somebody
reads a year later. It cannot arise through today's paths, because locks are
only opened at a fair where the active card is the one they pin, but it is the
§6.1 bug one level downstream and it fails loudly.

## 6.4 Payments

The system **records** payments. It does not process them. Existing card terminal
stays. No PCI scope, no merchant onboarding, no chargeback exposure.

```sql
payments
  id uuid PK
  order_id, category_lock_id NULL
  kind          enum(deposit, progress, balance, refund)
  amount_sen    int
  method        enum(cash, card_terminal, duitnow, bank_transfer, cheque)
  external_ref  text NULL      -- terminal slip no. / transfer ref, typed in
  receipt_no    text NULL      -- SERVER issued, null until sync
  taken_by, taken_at, device_id
  status        enum(pending, settled, refunded)
  synced_at
```

Works fully offline; nothing needs authorising.

**Daily cash-up screen.** End of day, per user: expected total by method versus
what they actually hold. Small to build, catches most of what goes wrong with
cash at a fair.

## 6.5 Price override

```
overrideLinePrice(lineId, newTotalSen, reason, adminSession)
```
- `reason` mandatory, minimum 4 characters. No empty-string bypass.
- Append-only `price_overrides` row. Never deletable from the app.
- Visible marker on screen and on the printed quote.

```sql
price_overrides
  id, order_line_id, before_sen, after_sen, reason text NOT NULL,
  admin_user_id, device_id, at, synced_at
```

**Be honest with the client.** An offline PIN is bypassable, and one shared admin
password reaches every part-timer within a month. The real control is the audit
log plus a weekly review screen, not the gate. Individual PINs so the log names a
person, and build the "overrides this week" screen — without it the log is never
read and the control does not exist.

## 6.6 The order lifecycle is the authority

```
confirmed -> measurement_booked -> measured -> material_selected
          -> in_production -> ready -> installed -> closed
```

`cancelled` is reachable from anywhere up to and including `ready`. `closed` and
`cancelled` are terminal.

**No shortcuts and no backwards moves.** `order_events` is append-only and the
history it accumulates is what somebody reads a year later: a skipped step is a
lie in it, and a rewound one silently overwrites a visit that really happened.
A remeasure is new dimensions on the same order, not a return to
`measurement_booked`.

Every transition is decided in **one** place — `advanceOrder`, mirrored on both
engines and pinned by `order_status_cases`. Four things belong to that decision
and nowhere else:

| | |
|---|---|
| **Allowed transitions** | The edge exists, or it does not |
| **Required data** | `measured` needs every line that wanted a visit to have final dimensions. `material_selected` needs every deferred material chosen (B7). Cancelling needs a reason of at least four trimmed characters. Past a final total over RM10,000, the buyer's details (§10.4) |
| **Authorisation** | Which role may make this move. **Open — §13 C8.** The pipeline currently enforces *what* can happen, not *who* may do it |
| **Auditability** | Every move writes an `order_events` row naming the person and the time |

**The UI is never the authority.** A screen may hide a button it knows will be
refused, and the refusal must still happen if the call is made anyway — from
another screen, from a queued outbox row, from a future integration. §10.4 says
this in the strongest form: *"Enforce in the state machine, not the UI."*

**Cancelling touches no money.** §13 B3 is unanswered, so the deposit stays
exactly where it is and nothing computes a forfeit, a refund or a credit.

## 6.7 What must be traceable

Business traceability, not logging. The question these answer is *"who changed
this, when, and why"* — asked months later, usually about money.

Every one of these is **append-only**. Corrections are new rows with a reason,
never edits or deletes:

| Event | Where |
|---|---|
| Order status changes | `order_events` |
| Payments and refunds | `payments` |
| Price overrides | `price_overrides`, with a mandatory reason and a named admin |
| Deposit prompt answers | `deposit_prompts` — which button was pressed (§6.2) |
| Rate card publication | `rate_cards`, versioned; rows never updated in place |
| Site measurements | On the line, beside the estimate, with who and when |
| Material choices | On the line |
| Stock movements | `stock_movements` (Phase 9) |
| Quote revisions | See §6.3 |
| Customer identity changes | When B9 gives us a customer record |
| Property library changes | Version bump, not an edit (Phase 8) |
| Floor plan approval or rejection | With the reviewer's name (Phase 8) |
| Permission-sensitive actions | Adding, deactivating or re-enabling a user |

**A record that cannot say who did something is not an audit trail**, it is a
note that something changed. `price_overrides.admin_user_id` is NOT NULL on both
sides for exactly this reason.

**And it only counts if somebody reads it.** §6.5 is blunt about this: an offline
PIN is bypassable and one shared admin password reaches every part-timer within a
month. What actually controls abuse is the weekly review screen, not the gate.

---

# 7. DATA MODEL — remaining tables

```sql
users
  id uuid PK
  name, phone, email NULL
  role            enum(admin, staff, parttime)
  pin_hash        text NULL       -- INDIVIDUAL, never shared
  language        enum(zh, en, ms) DEFAULT 'zh'
  is_active       bool DEFAULT true
  created_at, deactivated_at NULL

customers                        -- NOT BUILT YET. See section 13 B9.
  id uuid PK
  name, phone, email NULL
  tier            enum(standard, mvp) DEFAULT 'standard'
  created_by, created_at

  -- Today a quote and an order carry a free-text name and phone, and a rate
  -- lock hangs on the NORMALISED PHONE (section 6.1). Buyer/compliance fields
  -- currently live on `orders`, not here (section 10.3). When this table
  -- arrives, both move -- and an order keeps a SNAPSHOT of what was true when
  -- it was issued, because a customer moving house must not rewrite an old
  -- invoice.

photos
  id uuid PK
  order_line_id
  local_path      text            -- device path until uploaded
  remote_key      text NULL       -- object storage key after sync
  taken_at, taken_by, uploaded_at timestamptz NULL

devices
  id uuid PK
  user_id
  platform        enum(android, ios)
  label           text            -- '兼职手机 3'
  last_bundle_version int
  last_seen_at
```

## Conventions

- Every table: `id uuid PK`, client-generated (section 1.5).
- Every syncing table: `synced_at timestamptz NULL`.
- Soft delete only where history matters. Otherwise no delete at all.
- Money columns end `_sen`, `int`. Lengths end `_tmm`, `int` (tenths of a mm).
- Timestamps `timestamptz`, stored UTC, displayed `Asia/Kuala_Lumpur`.
- Postgres enums server-side, Dart enums client-side, kept in step by a
  **generated** file — not by hand.

## Indexes from day one

```sql
CREATE INDEX ON orders (status, created_at);
CREATE INDEX ON orders (customer_phone);          -- customer_id once B9 lands
CREATE INDEX ON orders (channel, created_at);
CREATE INDEX ON order_lines (order_id, sort_order);
CREATE INDEX ON category_locks (customer_key, status);   -- the handset lookup
CREATE INDEX ON category_locks (held_until) WHERE status = 'active';
CREATE INDEX ON pricing_rules (rate_card_version, family, variant)
  WHERE superseded_at IS NULL;                    -- the hot lookup
CREATE UNIQUE INDEX ON category_locks (customer_key, category)
  WHERE status = 'active';
```

That last one is a **constraint**, not an optimisation. It stops a customer
accumulating two active curtain locks — and it is why two handsets each taking a
deposit for one category needs an answer rather than a crash (§13 B10).

It must be declared as a **partial** unique index on both dialects. A bare unique
index would also forbid keeping the superseded rows, which CLAUDE.md requires.

---

# 8. UX RULES

Binding, not suggestions. Two products with opposite priorities.

## 8.1 Mobile

Used standing, one-handed, in a noisy hall, sometimes in daylight, by someone
hired last week.

**Thumb-first.** Primary actions in the bottom third. Nothing destructive in the
top corners. Minimum 48dp targets, 56dp for wizard primaries.

**Custom numeric keypad, never the system keyboard.** Big digits plus dedicated
`ft` `in` `'` `"` `mm` keys and `.`. The system keyboard is small, slow, and
buries the unit characters two layers deep. **This one widget removes most of the
input friction in the app.** Build it properly in Phase 1.

**One decision per screen.** Room, then product, then type, then sizes. Never a
form with eight fields. Back always available, never loses input.

**Progress visible.** "Window 3 of 7 · Living room" with a running total pinned
at the bottom. That total is the most-looked-at number in the app; the part-timer
and the customer both watch it.

**Undo, not confirm.** Deleting a line shows a 5-second undo snackbar. Modal
confirmations get tapped through blindly under pressure.

**Errors prevented, not reported.** Rates are not selectable, so they cannot be
wrong. Units default per field. Impossible values caught at the keypad. A red
error message means the design already failed once.

**Daylight legible.** High contrast, no grey under 60% on white, no weights under
14sp. **Force light theme in the wizard** rather than inheriting a dark system
setting that washes out outdoors.

**Offline is quiet.** A small persistent chip. Not a banner, not a modal, never a
blocking spinner. `3 单待上传` and nothing more.

**Survive interruption.** The app will be backgrounded mid-quote by a phone call.
Every keystroke persists locally. Reopening returns to the exact window.

**Photo capture is one tap** from inside the line. No gallery round-trip, no crop.

## 8.2 Web dashboard

**Density over whitespace.** Thirty rows, not eight cards. This is a working tool.

**Keyboard driven.** `/` focuses search, `j`/`k` move rows, `Enter` opens, `Esc`
closes.

**Filters live in the URL** so a view can be bookmarked and shared.

**Bulk select** on every list where a bulk action makes sense.

**No empty state without a next action.**

**Publishing a rate card is deliberate and two-step**, with a diff preview
showing exactly which products change and by how much. Everything else
autosaves. This does not.

**Destructive actions are typed, not clicked.**

## 8.3 Both

- **Three languages — Chinese, English, Malay** (`zh`, `en`, `ms`), switchable
  **per user**, not per device. Default `zh`. Staff and part-timers differ in
  what they read; a worker who reads only Malay must be able to quote unaided.
- Money always two decimals with RM prefix, never bare numbers
- Dates as `12 Mar 2027`, never `12/03/27`
- Dimensions show entered and billed together

## 8.5 The reference-price disclaimer — binding

Every quote screen and every printed quote carries, in the reader's language:

> 此报价按整数进位计算，仅供参考。现场实际丈量后，价格只会**相同或更低**，不会更高。
>
> This quotation is rounded up to whole units and is for reference only. After
> on-site measurement the final price will be the **same or lower**, never higher.
>
> Sebut harga ini dibundarkan ke atas dan untuk rujukan sahaja. Selepas
> pengukuran di tapak, harga akhir adalah **sama atau lebih rendah**, tidak akan
> lebih tinggi.

This is not boilerplate. §4.3 rounds every quoted quantity up and bills the exact
measurement later, so an unexplained quote reads as a bait price. Stating the
asymmetry is what turns it into a reason to trust the number. **Do not collapse
it into a footnote, and do not make it dismissible.**

## 8.4 Staffing targets — acceptance criteria, not marketing

Tested with a stopwatch in Phase 2:
- **Untrained person to first correct quote: under 30 minutes**
- **Six-window house quoted: under 4 minutes**
- **Zero rate lookups.** If a part-timer ever has to ask a colleague what
  something costs, the design failed.

---

# 9. OFFLINE AND SYNC

Sync is **asymmetric**. Two one-way pipelines beat one general engine.

## 9.1 Pull — reference data

Rate card, promos, product rules, delivery zones, materials, project library.
Admin-only writes, so **no merge conflicts by construction**.

```
GET /api/bundle?since_version=N  ->  { rate_card_version, projects_version, gzip payload }
```
- Replace wholesale in a transaction. Do not diff.
- Cache on device. Survives restart and airplane mode.
- Show `资料更新于 3 天前`.
- **Explicit "Fair mode: download everything now" button.** Do not rely on
  background sync happening before the hall loses signal.

## 9.2 Push — transactions

```sql
outbox
  id, entity_type, entity_id, payload_json,
  created_at, attempts, last_error, next_attempt_at
```
- Every local write enqueues an outbox row **in the same transaction**.
- FIFO drain, exponential backoff.
- Server endpoints **idempotent on the client UUID**. Retry must be safe.
  **Write the double-submit test before the endpoint.**
- Never block the UI on sync.

### Payment idempotency is the dangerous one

A duplicated quote is noise. **A duplicated payment is money that does not
exist**, and it is found weeks later by an accounts person reconciling a bank
statement against a system that says the customer paid twice.

- A payment is idempotent on the **device-generated payment id**. Ten retries
  make one row.
- The **receipt number is server-issued** and the same retry hands back the
  *same* number — the customer may already be holding paper with it printed on.
  Until it arrives the app shows `pending sync` and **never fabricates one**.
- Same rule for `order_no`, for the same reason: `{branch}-{yymm}-{seq}` has no
  per-device component, so two part-timers offline at one fair would both mint
  `MLK-2608-0007`.
- A status change is keyed on the **event id**, not the order id — an order
  walks the pipeline many times and each step must be separately idempotent.

**Nothing is ever rejected outright once money has been taken.** An order
arriving with a status or an override the server would not allow is accepted,
the offending part is left out, and what was dropped is named in the response.
Losing the sale to protect a status field is the wrong trade.

## 9.3 Conflict policy

| Data | Rule |
|---|---|
| Reference | Server wins, full replace |
| Transactions | Client wins, server appends |
| Pricing disagreement | **Server wins, discrepancy logged** |

## 9.4 Server-side re-pricing

On receipt the server re-prices every line from its recorded
`applied_rate_card_version` and `applied_discount_pct`.
Match: accept silently. Mismatch: **accept the order** (never lose a sale), store
both numbers, raise on an admin review screen.

A mismatch means the Dart and Python engines have drifted. That is how you find
it.

---

# 10. E-INVOICE AND SQL ACCOUNT

## 10.1 One issuer, and it is SQL Account

**The company already runs SQL Account and it already handles their e-invoicing.**

**Only one system may issue the e-invoice for a given sale.** Two systems
submitting the same transaction produces two validated UINs for one sale — a
compliance problem requiring cancellation inside 72 hours, not a tidiness issue.

- **SQL Account is the issuer of record.** It talks to LHDN. We do not.
- This system captures what SQL Account needs and hands it over.
- **No MyInvois integration in this project.** No certificate custody, no XAdES,
  no UIN handling, no spec-drift liability.

### Legal constraint on our own documents

Documents this system prints are **quotations, order confirmations and payment
receipts**. They must not:
- carry the words "Tax Invoice" or "e-Invoice"
- display a UIN, a validation QR code, or anything resembling one
- imply they are a validated tax document

The customer's tax document comes from SQL Account. **Getting this wrong is a
legal problem, not a labelling one.**

## 10.2 The RM10,000 rule is the real requirement

Since **1 January 2026**, any single transaction above **RM10,000** must have its
own individual e-invoice and **cannot** go into a monthly consolidated batch.
Applies to B2C as much as B2B, regardless of implementation phase. Penalties run
RM200 to RM20,000 per non-compliant invoice.

**Full-house curtain orders routinely exceed RM10,000.** A meaningful share of
sales legally require buyer identification, not a "General Public" receipt.

SQL Account flags over-threshold transactions and automates grouping below it.
**The gap is upstream:** SQL Account can only issue that individual e-invoice if
somebody captured the buyer's details, and that has to happen while the customer
is standing there. That gap is why Phase 7 exists.

## 10.3 Buyer detail capture

```sql
orders  -- additional columns. On the ORDER, not on a customer, until B9.
  buyer_tin           text NULL
  buyer_id_type       enum(nric, brn, passport, army) NULL
  buyer_id_number     text NULL
  buyer_address_line1, buyer_address_line2
  buyer_city, buyer_state, buyer_postcode
  buyer_msic_code     text NULL        -- business buyers only
  einvoice_requested  bool DEFAULT false
```

They live on the order because there is no `customers` table yet (§13 B9). When
one arrives they move — and **the order keeps a snapshot**, because what was true
when the invoice was issued is not what is true after the customer moves house.

- Optional by default. Most walk-ins are General Public.
- **When the running total crosses the threshold, the wizard stops and requires
  buyer details.** Not a warning. A required step.
- Also required whenever the customer asks for an e-invoice, at any value.
- **Threshold lives in config, not code.** It will change. Both figures sit on
  the rate card, so changing one is a card publish — no rebuild, no deploy — and
  it reaches every handset the way a price change does.

### What counts as "having the details"

**A rule, never a flag somebody ticks.** A tick box gets ticked by anyone in a
hurry, and the row it ticks is what SQL Account has to build a real e-invoice
from. The rule reads the actual fields:

| Needed | Satisfied by |
|---|---|
| A name | `orders.customer_name`, non-blank after trimming |
| **One** identifier | A TIN, **or** an ID number **with** its type |
| A postal address | Line 1, city, state and postcode, all non-blank |

An ID number with no type does not count: an IC, a passport and a business
registration are different fields on the invoice, and guessing which one a bare
number is puts the wrong thing on a document the customer keeps. Line 2, country
and MSIC are optional.

**Everything outstanding is reported at once**, so somebody collects it in one
conversation. A form that reveals one missing field at a time is a customer asked
three times.

**Open: §13 C13** — which fields MyInvois actually rejects a submission for. The
rule above is the conservative reading and errs toward asking for slightly too
much, because §10.2's penalty is for missing details rather than for spare ones.

## 10.4 The timing trap

The fair estimate is rough. The final after measurement is not. An order
estimated at RM8,500 settles at RM11,200.

Evaluate the threshold **twice**:
1. **At the fair, on the estimate** — prompt from **RM8,000**, not RM10,000, so
   borderline orders are captured while the customer is present. Below the legal
   line this only *asks*. Refusing a RM300 deposit over paperwork the order does
   not yet need would lose the sale.
2. **At final pricing** — if crossed, the order **cannot reach invoicing status**
   until buyer details exist. Enforce in the state machine, not the UI.

The RM8,000 margin belongs to the **estimate alone**. An estimate is rough and
the margin buys a chance to ask; a final is exact, so an order that measured
under the line is under it, and asking then is friction with no compliance behind
it. An estimate that crossed and then measured back under is let through — the
commoner direction, since the quote rounds every quantity up.

**Which step is "invoicing" is open — §13 C12.** There is no `invoicing` status.
The guard currently bites from `material_selected`, the first step after a final
total exists, while the measurer has only just left the house. Cancelling is
never blocked: it has nothing to do with invoicing, and refusing it would leave
an over-threshold order trapped with no way out.

## 10.5 Handoff

**Prefer file export over live integration.** No dependency on their SQL Account
version or a Windows COM layer; the accounts person reviews before importing,
which they want anyway; a file format is far cheaper to fix.

```
POST /api/export/sqlaccount?from=&to=   -> file in their import format
```
Behind an adapter interface so a live integration can replace it later.

---

# 11. PHASES

Each phase separately quoted, delivered, paid. Client can stop after any phase
and keep something that works. 50% on start, 50% on acceptance.

| # | Phase | Hours | Price |
|---|---|---|---|
| 1 | Quotation Proof | 60 | RM 2,500 |
| 2 | Full Quotation App | 262 | RM 11,000 |
| 3 | Backend & Sync | 143 | RM 6,000 |
| 4 | Deposit, Lock & Orders | 119 | RM 5,000 |
| 5 | Web Dashboard | 167 | RM 7,000 |
| 6 | Site Measurement | 71 | RM 3,000 |
| 7 | SQL Account & e-Invoice | 60 | RM 2,500 |
| | **Total** | **882** | **RM 37,000** |
| 8 | Property / Project Library | — | Stage 2 |
| 9 | Inventory | — | Stage 2 |

Maintenance ladder (starts at Phase 3 — nothing to host before then):
RM150 (P2) → RM450 (P3–4) → RM750 (P5) → RM950 (P6–7). 12-month minimum.

### Where we are, and what comes next

| | |
|---|---|
| **Done** | Phases 1–5. Every acceptance criterion names a test |
| **Now** | **Phase 6** — finish site measurement and stabilise it |
| **Next** | Phase 7, SQL Account export and the compliance handover |
| **Later** | Phase 8, the Property / Project / Unit Library |
| **Later still** | Assisted floor-plan digitisation (a Phase 8 extension) |
| **V2** | The customer-facing ecosystem and AI visualisation (§2.5) |

**Nothing below Phase 7 is a current requirement.** They are written down so
today's decisions do not make them expensive, not so they get built early.
Bringing Phase 8 forward is a commercial decision, not a technical one — say so
rather than quietly reordering.

---

## PHASE 1 — Quotation Proof
**60h · 2–3 weeks · Flutter only, no server**

The demo. Prove the hard part works before anyone commits real money. The client
said quotation is what he wants most — he is right that it is the core, and wrong
that it is the easiest. The pricing rules are the hardest part of the system.

If this convinces him, everything after is a straightforward conversation. If it
does not, he spent RM2,500 instead of RM37,000.

**In**
- `Length` and `Money` value types, full test coverage
- Unit parser (section 5.3) with the complete table
- Custom numeric keypad with `ft` `in` `mm` keys
- Pricing engine: banded rates, min quantity, MVP flat tier, per_ft and per_sqft
- Two families only: **night/day curtain** and **roller/zebra blinds**
- Rate card from a bundled JSON file, hand-seeded
- Quote screen: add lines, running total, delete with undo

**Out**
No persistence between launches. No PDF. No login, roles, server or sync. No
deposits, orders or photos. No flooring, wallpaper, tracks, add-ons or zones.

**Build order**
1. `Length` + parser + fixture table
2. `Money` + both roundings
3. Pricing engine against `shared/pricing-fixtures.json`
4. Numeric keypad widget
5. Wizard: room → product → type → sizes
6. Quote list + running total

Steps 1–3 have no UI at all. **Resist starting with screens.**

**Acceptance**
- [ ] `dart test` green, 100% coverage on `Length` and `Money`
- [ ] All six golden cases produce exact expected totals
- [ ] `12ft` at exactly `10ft` height gives RM552; `10ft 1in` gives RM696
- [ ] A 3ft x 4ft roller blind bills as 18 sqft, not 12
- [ ] MVP toggle changes RM46 to RM40 with no percentage arithmetic anywhere
- [ ] `7'6` and `2286mm` produce identical results
- [ ] `abc` shows an inline error and does not fall back to a guess
- [ ] Someone who has not seen the app quotes a curtain in under 60 seconds

**Demo script for the client meeting**
1. Quote 12ft x 9ft night curtain. RM552.
2. Change height to 10ft 6in. Watch it become RM696. **Explain the RM144.**
3. Enter width `12'4`. Show `按 13 尺计`.
4. Enter `2400` with the chip on inches. Show the warning.
5. Quote a small roller blind. Show the 18sqft minimum.
6. Toggle MVP. Show the rate change.

**Step 2 is the one that sells it.** That is the mistake costing them money today.

---

## PHASE 2 — Full Quotation App
**262h · 6–8 weeks · Flutter, still no server**

**In**
- All families: curtain, blinds, tracks and rods, SPC/vinyl/laminate, wallpaper
- Composite variants (rod + pleat)
- Add-ons: motor, remote, side guide, box, intermediate joint
- Services: dismantle, self levelling
- Material and series selection where it changes the rate
- `product_rules` validation: requires, excludes, max dimension
- Delivery zone charge, asked early, shown before the total
- **Optional** special-track upgrade offered after a curtain, never added
  automatically — the normal track is already in the curtain rate (§4.1)
- Photo per window
- Local persistence via Drift, survives force-quit
- Customer record
- Quote PDF generated **on device**, shareable offline, bilingual
- **Price editing in the app**, two ways, both with the §8.2 discipline of a
  diff preview and a deliberate confirm:
  - tap a product and change its rate directly, for the one-off adjustment
  - export to CSV, edit in Excel, import back, for a whole-list revision

  > ⚠ **This is a Phase 2 stand-in and Phase 3 replaces it.** A price edited on
  > one phone stays on that phone, which is exactly wrong for a business where
  > six people quote from six handsets. From Phase 3 the price list is published
  > centrally and pulled by every device (§9.1), and **editing on the device
  > becomes read-only.** Do not let this local override survive into Phase 3 as
  > a second, divergent source of prices — one till showing RM46 while the next
  > shows RM50 is worse than either number being wrong.

**Acceptance** — a box is ticked only when a test covers it, never by inspection.
- [x] Quote survives force-quit, reopens at the exact window
- [x] A curtain line does **not** add a track by itself. The upgrade is offered,
      declining is the default, and a plain curtain quotes at the fabric rate
      alone
- [x] Herringbone SPC without self levelling is flagged with a clear message,
      in the reader's language, and adding the self-levelling line clears it.
      Reported rather than refused: refusing loses the sale, silence loses the
      floor.
- [x] ZIP blind over 20ft width is blocked, at 20ft 0in 1/10mm
- [x] Wallpaper rounds up to whole BOGO pairs
- [x] Delivery charge appears before the customer sees a total, never after
- [x] Quote PDF reaches WhatsApp with the phone in airplane mode
      — the document is rendered on device by `quote_pdf.dart` and shared
      through the OS sheet; no code path in that flow touches the network.
      Through Phase 2 the proof was stronger still: no `INTERNET` permission
      was declared at all. Phase 3 adds sync and with it the permission, so
      the guarantee now rests on `test/ui/quote_pdf_test.dart` rather than on
      the manifest.
- [x] Every line prints entered size, billed size, band applied, rate
- [x] Rate card imported from an admin-prepared CSV, with a diff preview and a
      two-step confirm (§8.2), and one tap to restore the shipped list
- [ ] **Six-window house quoted in under 4 minutes, stopwatch-timed**
      — needs a real person and a real phone. Cannot be asserted in a test.
- [ ] **Untrained person produces a correct quote within 30 minutes**
      — same. These two are the acceptance criteria that only a stopwatch and a
      part-timer can settle, and they are the ones worth running before the
      client meeting.

The PDF was slower than it looks, as predicted. The font was most of it: the
screen borrows Android's system CJK face for free, but a PDF carries its own
glyphs, and the full Noto Sans SC is ~9MB against the 30MB bundle budget. The
answer was to instance the variable font at Regular and subset it to GB2312
levels 1 and 2 plus every character in the app's own strings — 7,272 characters
in 2.2MB. GB2312 rather than only our strings, because a customer name is free
text and a narrower subset renders an unusual name as tofu on the one document
they take away.

---

## PHASE 3 — Backend and Sync
**143h · 4 weeks · FastAPI + Postgres**

First phase with running costs, so maintenance billing starts here.

**In**
- FastAPI, Postgres, Alembic
- Python pricing engine mirroring Dart, sharing `shared/pricing-fixtures.json`
- **Prices become server-owned.** The rate card is published once and pulled by
  every device; the on-device editing built in Phase 2 turns **read-only**, and
  the local override file is removed on first successful pull. Six handsets
  quoting six different prices is the failure this prevents.
- Auth: users, roles, offline-tolerant sessions
- `GET /api/bundle` versioned gzipped pull
- Outbox push, idempotent on client UUID
- Server-side re-pricing with discrepancy logging
- Rate card publishing as a versioned set
- "Fair mode" pre-download
- Docker Compose deploy, nightly backup, **tested restore**

**Acceptance**
- [x] Same fixtures pass in both Dart and Python suites, in CI
- [x] Quote offline for one hour, restore network, everything lands **once**
      -- `test/sync/outbox_test.dart`. The hour is simulated, not waited out:
      the queue does not care how long it sat, only that draining it twice
      sends once.
- [x] Double-submit the same outbox row: no duplicate created
      -- both sides. `backend/tests/test_ingest.py` was written before the
      endpoint, per 9.2, and ten retries still make one quote.
- [x] Publish a rate change; every device picks it up on next connect
      -- `test_api.py::test_every_device_sees_the_new_card_on_its_next_pull`
      and `test/ui/demo_script_test.dart`.
- [x] Token killed mid-fair simulation: app keeps working offline
      -- the card already pulled still prices, and queued quotes are kept
      rather than parked. Revoking is the control that replaces expiry;
      sessions never expire on their own (12).
- [x] Database restored from backup into a scratch container successfully
      -- run for real, 3 Sep 2026, against the Compose stack on Postgres 16.
      `deploy/backup.sh` dumped, restored into a scratch database and reported
      `alembic=0003 tables=11 rate_cards=1`. Emptying `rate_cards` and running
      it again failed with `FAIL: no rate cards in the restored database`, so
      the drill has teeth. `deploy/restore.sh` then put a dump back over the
      live database and the card, the admin user and a payment with its issued
      receipt number all returned intact.

---

## PHASE 4 — Deposit, Rate Lock and Orders
**119h · 3–4 weeks**

**In**
- `category_locks`: RM300 per category, 12 months, pinned version **and** pct
- Category prompt with three-button choice, logging which was pressed
- Quote → confirmed order conversion
- Payment recording, receipts, server-issued numbers, "pending sync" offline
- Order status pipeline with append-only events
- Daily cash-up screen
- Price override with mandatory reason and audit row

**Acceptance** — every one has a named test behind it.
- [x] Two category deposits recorded offline; both receipts resolve after sync
  — `outbox_test.dart`, "two category deposits offline, and both receipts
  resolve". Queued with the server offline, drained after, two distinct
  numbers.
- [x] A flooring line on a curtain-only lock prices at **standard**, not promo
  — fixture `lock-a-flooring-line-never-rides-a-curtain-lock`, loaded by both
  engines.
- [x] Adding flooring with no flooring lock triggers the prompt every time
  — `deposit_prompt_test.dart`, "adding flooring to a curtain-locked quote
  asks for flooring".
- [x] Declined category deposits appear in a report
  — `DeclinesReportScreen`, with the arithmetic in `summariseDeposits` and
  `declines_report_test.dart` behind it. The number it exists for is what was
  quoted in a category and not deposited on, not the count of refusals.
- [x] Changing the promo % afterwards does not move a locked order's price
  — fixture `lock-pins-the-percentage-not-only-the-version`: current promo
  20%, held 10%, and the held one wins.
- [x] An override made offline appears in the audit log naming the admin
  — `order_repository_test.dart` writes the row with no server, and
  `test_order_push.py` carries it up. `admin_user_id` is NOT NULL on both
  sides, so a row that cannot name somebody cannot exist.
- [x] Cash-up totals reconcile per user per day
  — `cash_up_test.dart`, and it refuses to call a day balanced when nobody
  counted.

**Still open in Phase 4, and neither is a test:** §13 C7 and C8 — whether a
supply-only order may skip the measurement steps, and **who** may move an order
along or cancel one. The pipeline enforces what can happen, not who may do it.

---

## PHASE 5 — Web Dashboard
**167h · 5 weeks · Angular**

**In**
- Angular 17+ standalone, typed API client from OpenAPI
- **Order board** — kanban by status, filter by channel/project/salesperson/fair,
  sorted by `held_until` ascending, amber at 60 days, red at 30
- **Measurement queue** — grouped by project so one trip covers several units
- **Rate card editor** — CSV import, draft edit, **diff preview**, two-step publish
- **Promo management** — create a fair promo, set the percentage
- **Users and roles** — individual PINs, deactivate leavers
- **Override review** — "this week" screen
- **Reports** — estimate vs final variance by salesperson, fair performance,
  outstanding balances aged, declined category deposits
- Keyboard nav, URL-encoded filters, bulk select

**Acceptance** — all four met, each with a named test.
- [x] Publishing shows exactly which products move and by how much before commit
  — two steps, and the second is unreachable until a preview has been seen. The
  diff is computed **on the server**, so the thing that shows what will change is
  the thing that decides what lands.
- [x] Order board loads 500 orders without pagination lag
  — `test_board_scale.py`. It asserts the cause rather than a wall-clock number:
  **the statement count does not grow with the board.** Ten orders and five
  hundred cost the same round trips. Writing it found two queries reading the
  whole table to answer a question about one page.
- [x] Every filter state is reachable by URL
  — checked through a **real router** on the order board, the measurement queue
  and the reports. A filter held in a component field passes every behavioural
  assertion and still fails this the moment somebody pastes the link.
- [x] Deactivating a user requires typing their name
  — `people.spec.ts`. Sessions never expire (§12), so deactivating is the only
  thing that stops the handset in a leaver's pocket, and doing it to the wrong
  person locks somebody out mid-fair.

**Two things the dashboard deliberately does not have yet:** a session that
survives a page refresh (a token in `localStorage` on a shared office machine is
one the next person inherits), and any Malay or Chinese (§13 C9).

---

## PHASE 6 — Site Measurement and Final Pricing
**71h · 2 weeks**

**In**
- Measurement mode: open a confirmed order, work through its lines
- Estimated size shown alongside the field being measured
- Fair photo displayed while measuring
- Re-price at `held_rate_card_version` and `held_discount_pct` — never today's
- Variance surfaced immediately, per line and per order
- Material and series finalised here
- Balance calculation, revised order document
- Threshold re-check per section 10.4

**Done so far**
- The final-pricing engines, both sides, against `final_pricing_cases`. A line
  reprices at the version and discount **it** recorded — never the active card,
  never the order's pinned version, because a line's lock is its own. When the
  held card is not to hand it **refuses**: falling back to today's is exactly
  what the RM300 was taken to prevent, and it is the fallback that looks most
  reasonable.
- Quantity is exact here; the quote rounded up and the bill does not.
- A line the tape has not reached, and a material nobody chose, both refuse. A
  refused line stops the **order** total, not just its own.
- A final **above** its estimate is flagged, not refused — §8.5's promise is
  about rounding, not about the customer's own wrong dimensions.
- The measurement repository: the tape stored beside the estimate, the whole
  order repriced on every measurement, the balance following the total and never
  negative (B4 is unanswered).
- The RM10,000 rule, both engines, enforced in the state machine (§10.4), with
  the buyer's details captured on the order and a completeness rule rather than
  a flag.

**Still to build**
- The measurement screen itself — working through an order's lines with the
  estimate and the fair photo beside the field.
- The revised order document.

**Acceptance**
- [x] A measured order reprices at the old card even after two rate publishes
  — fixture `final-reprices-at-the-held-card-not-todays`, loaded by both
  engines, with the active card two versions newer.
- [x] Variance visible to the measurer before they leave the house
  — `repriceOrder` returns it per line and per order, and `outstandingOf` says
  what still stands between the order and a bill, with the reason for each.
  **Needs the screen before this is true in the customer's house.**
- [x] An order crossing RM10,000 cannot advance without buyer details
  — `order_status_cases`, `status-over-threshold-cannot-leave-measured`, plus
  the repository tests. Enforced in `advanceOrder`, not in a screen.
- [ ] Works fully offline in a house with no signal
  — nothing in the measurement path touches the network and every card it needs
  was pulled before the visit. **Not yet asserted end to end**, and it should be
  the same shape of test as the offline-PDF one in Phase 2.

---

## PHASE 7 — SQL Account and e-Invoice Compliance
**60h · 2 weeks**

Read section 10 in full first. Those legal constraints are not optional.

**Already delivered in Phase 6**, because §10.4 puts the second threshold check
at final pricing and Phase 6 is where final pricing lives. Do not re-quote or
rebuild these:

- Buyer detail capture: TIN, ID type and number, address, MSIC, and the rule for
  what counts as complete (§10.3)
- The **RM10,000 threshold gate**, prompting from RM8,000, evaluated at both the
  estimate and the final, enforced in the state machine
- Both figures config-driven, on the rate card

**In**
- SQL Account export behind an adapter interface
- Export screen in the dashboard, date-ranged, re-export option
- Document labelling audit
- Buyer-detail capture **screens** — the handset form the measurer fills in, and
  the dashboard equivalent for the office. The rule and the storage exist; the
  UI does not
- Whatever C13 changes about which fields are mandatory

**Out**
**No MyInvois integration. No LHDN submission. No certificate handling.**

**Acceptance**
- [x] An order crossing the threshold cannot reach invoicing without buyer details
  — delivered in Phase 6. `order_status_cases`, and enforced in `advanceOrder`
  rather than in a screen. **Which step counts as invoicing is §13 C12**, open.
- [x] Threshold change is a config edit, not a deployment
  — both figures live on the rate card, so changing one is a card publish and
  reaches every handset the way a price change does.
- [ ] Export imports into SQL Account without manual correction
- [ ] Re-exporting the same range does not create duplicates
- [ ] No printed document uses "Tax Invoice" or "e-Invoice", or displays anything
      resembling a UIN or validation QR
      — a CI check greps the Dart and ARB sources for it today, and a widget test
      renders the real PDF and reads the text back. Ticked when the export and
      any Phase 7 document are covered too.

**Blocked on** a sample SQL Account import template (E1), the accountant's ruling
on E2, and C12 and C13.

---

## PHASE 8 — Property / Project / Unit Library
**Stage 2 · quoted after Phase 5 has run live two months**

### The workflow this is for

```
Development  ->  Unit Type  ->  verified stored measurements  ->  quotation
```

A salesperson hears *"ABC Development, Type B"*, picks the development, picks the
unit type, and the known windows, rooms, skirting runs and floor plan load. They
choose products and a reference quotation exists in seconds.

This is worth building for developments the company quotes **repeatedly**. Slow
for customer one, very fast from customer two.

### The line that must never blur

**Reference property measurements are NOT site measurements.**

The library accelerates *quoting*. Actual site measurement remains production
truth. A plan-sourced line is a better-informed estimate, not a measured one, and
it must reach production only through the same site visit every other line takes.

**Manage this expectation before selling it.** "Upload a floor plan, get an
instant quotation" is not something to promise. Developer plans usually do not
dimension windows, scale is inconsistent, and extraction fails **silently** — a
wrongly scaled plan produces a confident wrong number.

**What actually works:** admin uploads the plan per unit type, **calibrates scale
once** by tapping two points on a known dimension, then taps each window entering
real dimensions from the developer's schedule. Digitised once per unit type,
reused for every customer in that project. Slow for customer one, very fast from
customer two.

### What the client asked for, Sep 2026, and how it maps

Confirmed as already in scope here — no new phase needed:

1. **"Store existing measurements of homes we have already done, so next time
   you enter the area it suggests them."** This is exactly the project library.
   `projects.area` and `unit_types` are the lookup; entering the area or
   development name offers the unit types already digitised, and the openings
   come with them.
2. **"Store all floor plans in the app so it can auto-calculate a full SPC
   flooring quote."** This works, via `rooms.nominal_area_mm2` and
   `skirting_run_tmm`. A whole-house flooring quote is then one tap: every room
   area is already known, and the engine prices it like any other `per_sqft`
   line.

**But the auto-calculation comes from the stored room areas, not from reading
the image.** The plan is a backdrop for tapping and a reference for the
salesperson; the numbers come from the developer's schedule, typed once by an
admin who can check them. That distinction is the whole of the warning above:
measuring off a scanned plan produces a number that looks authoritative and is
silently wrong, and a wrong flooring area is a five-figure mistake on a full
house.

So the promise to make is **"we digitise your repeat projects once and quote
them in seconds after that"**, never "upload a plan and get a price".

```sql
projects      id, name, developer, area, updated_at
unit_types    id, project_id, name, floor_count,
              variant_of uuid NULL        -- 'Type A mirror' points at 'Type A'
              status enum(draft, pending_review, approved, superseded)

unit_type_versions            -- a plan changes; history does not
              id, unit_type_id, version int, approved_by, approved_at, note

openings      id, unit_type_version_id, label, room, floor,
              nominal_w_tmm, nominal_h_tmm, sort_order
rooms         id, unit_type_version_id, name,
              nominal_area_mm2, skirting_run_tmm, floor
floor_plans   id, unit_type_version_id, file_ref,   -- the ORIGINAL document
              scale_tmm_per_px, uploaded_by, uploaded_at
```

### Versioning

A unit type has **versions**. A new approved version applies to future
quotations and **never** touches an existing order. Version 2 of ABC Type B does
not rewrite what somebody was quoted against version 1 last March.

Variants — `Type A mirror`, `end lot`, `corner`, `A1` — are their own unit types
with a `variant_of` pointer. **A simple explicit relationship, not an inheritance
system.** A mirrored unit that shares nine openings and differs in one is easier
to read, and safer to price from, as its own list than as a diff.

### Provenance: never copy a number and lose where it came from

**Instantiate, never reference.** Values are copied into the order line, exactly
as order lines are copies of quote lines (§6.3). But a copy without provenance is
a number nobody can explain, so each dimension carries where it came from:

```sql
order_lines   -- additional columns, Phase 8
  measurement_source     enum(manual, project_library, site_measurement)
  source_project_id      uuid NULL
  source_unit_type_id    uuid NULL
  source_version         int NULL
```

`measurement_source` matters beyond bookkeeping: it is what lets the pipeline
tell a plan-derived dimension from a measured one, and the state machine already
refuses `measured` for lines with no final dimensions (§6.6). **The enum is the
architectural decision to make early** — adding a third source later to a
boolean `is_site_measured` is a migration across every order ever written.

Any plan-sourced line prints `参考尺寸，未现场丈量`. **Never let a plan-derived
dimension reach production without a site measurement.**

### The floor-plan submission workflow

Two routes in, one gate. Quality control is the point.

```
ADMIN            upload -> draft -> verify -> approved -> library
PART-TIMER       submit -> pending_review -> admin verifies / corrects
                        -> approved -> library
                        -> or rejected, with a reason
```

**A part-timer's submission is never searchable or quotable until an admin has
approved it.** This is deliberately two-step: a plan digitised in a hurry at a
fair, wrong by a factor of the scale, produces a confident wrong number on every
quote after it. Approval and rejection are both audited with the reviewer's name
(§6.7).

**Keep the original document.** The uploaded plan is stored as source material
alongside the structured measurements extracted from it, so a disputed dimension
can be checked against what was actually submitted.

### Future: assisted digitisation

**Not Phase 8, and not something to promise.** Documented here so the data model
above does not preclude it:

```
uploaded plan -> AI extracts rooms, openings, dimensions -> CONFIDENCE per value
              -> human verification -> approved version -> library
```

The extraction proposes; **a person still approves**, and the approval is what
writes an `approved` version. AI output must never become production truth on
its own — which is the same rule the part-timer route already follows, so the
workflow needs no new concept, only a new source of drafts.

**Sequencing.** This stays Stage 2, after Phase 5 has run live two months, and
that ordering is not arbitrary: a project library is only worth building once
the order board shows which developments actually repeat. Digitising twenty unit
types nobody quotes again is twenty wasted afternoons. Bringing it forward is a
commercial decision, not a technical one — say so rather than quietly reordering
the phases.

---

## PHASE 9 — Inventory
**Stage 2 · quoted after Phase 5 has run live two months**

**Tell the client before they buy it.** Stock tracking only works if **every**
movement is recorded. If the workshop cuts fabric without recording it, numbers
drift, staff stop trusting the screen, and you have built something worse than no
system: a confident wrong number. This needs a **named person** accountable.
Software cannot supply that discipline. Get the name before quoting.

- **Fabric: dye lots matter.** Same code, different lot, visible colour
  difference. One order draws from one lot. Model lot, not just total.
- **Offcuts have value.** A 1.8m remnant suits a small window. Support returning
  an offcut to stock as its own lot.
- **SPC sells by box, is quoted by sqft.** Store `coverage_per_unit`, round up to
  whole boxes when allocating.

```sql
materials      id, family, variant_compat text[], code, names jsonb,
               uom enum(metre, sqft, box, piece, roll),
               coverage_per_unit numeric, reorder_level, is_active
stock_lots     id, material_id, lot_ref, qty_on_hand, location,
               received_at, cost_sen           -- cost admin-only
stock_movements  -- APPEND ONLY. The ledger is the truth.
               id, material_id, lot_id, delta numeric,
               reason enum(receipt, allocation, consumption, offcut_return,
                           adjustment, damage, return_to_supplier),
               order_id, by_user, at, note
allocations    id, order_line_id, material_id, lot_id, qty,
               allocated_at, released_at
```

`qty_on_hand` is **derived from movements**, never edited directly. An adjustment
is a movement with a reason, not a silent overwrite.

v1 scope: materials, lots, receive, allocate, ledger, reorder alerts. Purchase
orders, supplier management and costing come later.

---

# 12. NON-FUNCTIONAL TARGETS

| | Target |
|---|---|
| Cold start to quoting screen | < 2s, low-end Android |
| Price recalculation | < 16ms, never block a frame |
| App bundle | < 30MB |
| Offline duration | Indefinite. No token expiry that locks a user out. |
| Dashboard uptime | Load-bearing for daily ops from Phase 5. Reflect in the SLA. |
| Battery | No background location, no polling. Sync on connectivity change + manual. |

---

# 13. OPEN QUESTIONS

`[BLOCKING]` means do not start that phase until answered **in writing**.

## A. Pricing structure
- ~~**A1.**~~ **ANSWERED — exactly 10ft is the LOWER band, RM46.** The step is at
  10ft 1in. Encoded as `band_max_tmm = 30481`; see §4.2. **Their printed list still
  needs correcting** to "Up to 10ft (H)" / "Over 10ft (H)".
- ~~**A2a / A2b.**~~ **ANSWERED — the MITC Mega Home Expo Aug 2026 list was
  supplied and is transcribed in full** to `shared/rate-card-fair-2026-08.json`:
  77 rows across curtain, blind, track, flooring, wallpaper, add-on and service,
  plus both delivery zones and three product rules.

  PDF text extraction flattened the two-column layout and orphaned five labels
  from four prices. The page was re-rendered at 300dpi and read visually, which
  resolved every one: **MULTI TRACK RM68/RM75**, **Roller Blinds (Printing)
  RM17/sqft**, **Timber Blinds 35mm RM21/sqft**, **Self Levelling RM3.00/sqft**
  and **SPC 8mm (HRW) RM12.00/sqft**. Nothing was inferred.

  The render also showed the **second column is not always the >10ft band**. It
  is the band for curtains, S-track, multi-track and the rod-with-pleat and
  rod-with-eyelet composites; for Doso and Meyer it is a colour note, for Zebra
  the material series, and for Fauxwood and Ultra Light Timber a slat size.
  Reading it as a band throughout would have mispriced a dozen rows.
- **A3.** **ANSWERED PROVISIONALLY — curtains +20%, blinds +50% over the fair
  rate.** Client, Sep 2026, given explicitly as a placeholder: *"will revise
  back after, just put it first."*

  `shared/rate-card-standard.json` is derived from the fair card by
  `tool/build_standard_card.py` and flagged `provisional`. Both markups are
  exact — 20% and 50% of whole-ringgit prices land on whole sen, so nothing
  rounds. Night curtain RM46 → **RM55.20**; roller blackout RM9 → **RM13.50**.

  **The date picks the list.** Fair rates inside the fair's own window, standard
  every other day (§3). Nobody has to remember to switch, and the quote screen
  always says which list it is using.

  **MVP keeps its flat differential** rather than being marked up: §4.1 requires
  MVP to be a constant sen off, and marking RM40 up 20% would turn RM6 off into
  RM7.20 off and quietly make it a percentage. So standard night curtain is
  RM55.20 with MVP RM49.20 — still RM6.
- ~~**A3a.**~~ **ANSWERED — the other 45 rows are the same price at both.**
  Client, Sep 2026: *"other prices are same."* Tracks, flooring, wallpaper,
  add-ons and services carry **no markup by design**, so the fair price is the
  year-round price for them.

  Only curtains and blinds move between the two lists. That is deliberate and
  the derivation now records it as a decision rather than a gap.
- `[BLOCKING P2]` **A4.** Is the discount applied to the **unit rate** (discount
  → round → multiply) or the **line total** (multiply → discount → round)?
  Differs by sen per line and real money across a house.
  *Retagged from P1: Phase 1 builds no discount and no golden case exercises one.*
- `[BLOCKING P6]` **A21.** **Does a printed minimum quantity survive the tape?**
  §4.3 has carried this as *"assumption pending confirmation — `min_qty`
  applies at both stages. Confirm before Phase 6."* This is Phase 6.

  Both engines apply it at both stages, so a 3ft × 3ft roller blind measures
  9 sqft and bills 18. That is the reading the printed list supports: "Min 18
  sqft" sits on the price list as a commercial floor next to the rate, not as a
  rounding note. The other reading — exact tape, no floor — bills RM81 where
  this bills RM162, and it is the customer-favourable one.

  It is **not** in tension with §8.5: the estimate applies the same floor, so
  the final still lands at or below it. What is at stake is only whether a
  small window is charged at the printed minimum or at what it measures, and
  the answer is worth having in writing before the first invoice rather than
  after.
- **A5.** One discount % for everything, or different per family?
- **A6.** Is "Sgp Pleat" a heading bundled with a rod, or standalone fabric?
- **A7.** Wallpaper pattern-repeat wastage: absorbed already, or added per range?
- **A8.** Minimum charge per panel or per order, separate from minimum quantity?
- **A9.** Flooring: skirting always separate? Wastage % by lay pattern?
- ~~**A10.**~~ **ANSWERED — round UP to a whole unit, every basis.** See §4.3
  step 5b. A quotation is not a measurement; billed quantity is never fractional.
- ~~**A11.**~~ **ANSWERED — final pricing is EXACT, no round-up.** 12ft 4in
  measured on site bills 37/3 = 12.3333ft at RM46 = RM567.33, against RM598.00 quoted.
  The quote rounds up, the bill does not. See §4.3 `stage`.
- ~~**A11a.**~~ **SUPERSEDED BY A21**, which asks the same question with the
  worked numbers attached. Do not answer both.
- **A12.** Does the fair promo % **stack on top of** an MVP flat rate? RM46 →
  MVP RM40 → then also 20% off? Or is MVP the floor, whichever is lower? Not
  Phase 1, but it is the same shape of silent-money question as A4.
- ~~**A13.**~~ **ANSWERED.**
  - **SPC minimums are all the same.** Every SPC row, Herringbone included,
    carries `min_qty 200`. The assumption held.
  - **Decorative tape is INCLUDED** in the printed timber blind rates. There is
    no upcharge and no separate variant — the note in the second column
    describes what the rate already covers.
- ~~**A14.**~~ **ANSWERED — RM800 buys two rolls covering 280 sqft in total.**
  Each roll covers 14ft x 10ft = 140 sqft, so `coverage_sqft` is **280** per
  charge and `bundle_qty` 2 stays descriptive.

  *This corrected a real over-quote.* The conservative reading in the card had
  been 140 sqft per RM800, which billed a 20ft x 10ft wall at RM1,600 where the
  right answer is RM800 — double. Erring high kept the §8.5 promise intact while
  the question was open, but it was still wrong, and it is fixed.
- ~~**A16.**~~ **ANSWERED, then CORRECTED.** A genuine upgrade adds on: a motor,
  a remote, a box, a plain rod, each an extra line on top of the curtain, never
  a replacement. A motor track on a 12ft night curtain is RM46 + RM40 = RM86/ft.

  **But half the "track" rows were never upgrades.** Client, Sep 2026: *"The S
  track is actually S fold, as opposed to sgp pleat, different style of curtain
  so different rates, it includes the same railing everything. so all other
  special tracks are direct add on."*

  The first reading of A16 applied "everything adds on" to those rows too, and
  quoted a 12ft S-Fold window at RM1,512 instead of RM960 — 58% over, on every
  S-Fold and every rod composite. Twelve rows now carry `family: curtain`; see
  §4.1. **Never treat a rate that already includes the curtain as an add-on.**

  An upgrade is a **child line** carrying its parent's dimensions, so the quote
  shows what the customer is actually buying rather than one opaque rate.
- ~~**A15.**~~ **ANSWERED by A16's correction — they band on the curtain drop,
  because they ARE curtains.** S-Fold and the four rod composites print two
  prices under the same 10ft header as the curtains for the obvious reason: the
  rate is a made-up curtain, so the drop bands it exactly as a plain curtain's
  does. Plain rods and the Doso/Meyer tracks are unbanded, as printed.
- ~~**A19.**~~ **ANSWERED — Multi Track is an add-on.** Client, Sep 2026, on
  being shown the remaining track rows: *"yes the track all are right."* So
  RM68/ft is charged **on top of** the curtain, giving RM114/ft on a night
  curtain, and it bands on the drop because a taller curtain needs heavier
  track. Only the six heading-style composites in A16 include the curtain.
- ~~**A20.**~~ **ANSWERED — Doso and Meyer stay as upgrades.** Same answer.
  "Track Only" is what the printed list calls them, not a rule about who may
  buy one: a customer replacing the standard railing with a Doso pays RM9/ft on
  top. Nothing to change.

## B. Deposits and locks
- ~~**B1.**~~ **ANSWERED.** Client, Sep 2026:

  > a rm300 locks for one category only, so they lock for curtain then during
  > measurement they can only choose to do curtains or blinds at max. if want
  > flooring they shouldve deposited another additional separate rm300 for
  > flooring itself, making it rm600 for both

  and, on what a later deposit buys:

  > no second rm300 paid later in showroom, only depo at fair can lock price

  So two rules, both hard:

  1. **One RM300, one category.** A curtain deposit covers curtains *and*
     blinds — which confirms the family-to-category map in §6.1 and the resolver
     that reads it. Two categories cost RM600.
  2. **Only a deposit taken at a fair opens a lock.** A showroom, home-visit,
     phone or referral deposit confirms an order and buys nothing else. There is
     no way to acquire held prices after the fair has packed up.

  Rule 2 makes the §6.2 category prompt a **fair-only** feature: away from a
  fair there is no second RM300 to offer, because it would not lock anything.
  Offering it there would be selling something that does not exist.
- `[BLOCKING P4]` **B2.** 12 months elapse, house still not ready. Extend,
  reprice, or case by case?
- **B3.** Cancel after deposit: forfeit, partial, or credit?
- `[BLOCKING P4]` **B4.** Final lands under RM300: refund or credit? Partly
  pre-empted — a **quotation** now floors at RM300 per category (§4.3), so the
  customer is never quoted less than they deposit. But a quote of RM300 that
  measures down to RM240 still lands here, because final pricing is exact and has
  no floor. Refund the RM60, credit it, or keep it?
- ~~**B8.**~~ **ANSWERED — per deposit category.** Client, Sep 2026, answering
  B1: *"making it rm600 for both"*. Curtain RM250 + flooring RM200 quotes as
  RM600, not RM450, because the customer will be asked for two deposits and must
  never be quoted less than they are about to pay. Already implemented that way;
  the answer confirms it rather than changing it.
- `[BLOCKING P4]` **B9.** **What identifies a returning customer?** There is no
  `customers` table yet and a quote carries only a free-text name and phone, so
  until this is answered the lock has nothing durable to hang on.

  It was hanging on the **quote id**, which meant the twelve-month hold could
  never be used: the customer pays RM300 at the fair, comes back in March, a new
  quote is started with a new id, and the lock does not match. They are charged
  the standard rate — *more* than the hold they bought, after the app told them
  "promo rate held until 29 Aug 2027". No test covered a second quote, which is
  why nothing caught it.

  The conservative reading is now in force: the key is the customer's **phone
  number, normalised**, and the quote id only when there is no usable phone —
  which is no worse than the old behaviour. Phone is what the shop actually
  collects, and honouring a hold errs in the direction the customer paid for.

  Still to confirm: is a shared household phone one customer or two? Should a
  proper customer record be created at deposit time instead? And what happens
  when a phone is corrected after a deposit — does the hold follow it?
- `[BLOCKING P4]` **B10.** **Two handsets, one category, two RM300s.** At a
  busy fair two part-timers can each take a curtain deposit from the same
  customer before either syncs. Both payments are real money.

  §6.1 allows only one active lock per customer and category, and §9.3 says
  transactions are "client wins, server appends". Those pull apart here: the
  server cannot make both active without breaking §6.1, and cannot drop either
  without losing a payment nobody could then find.

  The conservative reading is in force. Both rows are stored, the **first** hold
  keeps pricing, and the second is marked `superseded` and reported back to the
  handset that sent it. Nothing is refunded automatically — that is a person's
  decision and it is not one this system should make quietly.

  To confirm: should the second RM300 be refunded, credited against the same
  order, or treated as a deposit on the *next* category? And should the
  customer be told at the stall, which would need the handset to be online?
- **B5.** One customer, two properties: one lock or two?
- **B6.** Always flat RM300, or higher on large orders?
- ~~**B7.**~~ **ANSWERED — every product defers material to measurement.** At a
  fair the job is to lock the deposit, not to settle the specification.

  §4.1 previously said material "cannot be deferred past deposit" for products
  whose material moves the rate. This answer overrode that, and §4.1 now reads
  the same way. Seven variants have material-dependent rates:
  `zebra_blackout` (J/BL RM12 vs TBL RM15), `outdoor_zip_manual` and
  `outdoor_zip_motor` (1% RM55 vs 0% RM60), `fauxwood` (50mm RM27 vs 63mm RM29),
  `ultra_light_timber` (50mm RM26 vs 63mm RM30), `outdoor_roller_motor` (Somfy
  RM1,800 vs AOK RM1,000) and `vinyl_3mm` (supply-and-install vs supply-only).

  **A deferred material is quoted at the DEAREST option in its group.** That is
  forced, not chosen: §8.5 promises the final will be the same or lower, and
  quoting the cheaper material would make the final go *up*. The line says so on
  its face, and the drop when the customer picks the cheaper option is the
  promise being kept rather than a discount.

  At **final** pricing a missing material raises rather than guessing — nobody
  should be invoiced for a material they never chose.

## C. Operations
- **C1.** Orders per fair? Per month at the showroom?
- **C2.** How many staff, part-timers, and phones?
- **C3.** One branch or several?
- **C4.** Who books the measurement visit?
- **C5.** Which payment methods in the dropdown?
- **C6.** Does the terminal slip carry a reference staff can realistically type?
- **C9.** **Does the web dashboard need Chinese and Malay?** The handset is
  trilingual because §8 makes it one: a part-timer who reads only Malay has to
  be able to quote, and no string is ever hardcoded in a widget. The dashboard
  is built in English only so far, on the assumption that the office is a
  smaller and more consistent group than the fair staff.

  That is an assumption, not an answer. If whoever works the order board reads
  Chinese first, English-only is the same barrier §8 exists to remove — and
  retrofitting three languages across a dozen screens costs far more than
  starting with them. Worth asking before the dashboard grows.
- **C7.** May an order with nothing to measure skip the measurement steps?
  Every product defers material to measurement (B7), so in practice every order
  has a visit — but a supply-only flooring job might not. The pipeline currently
  refuses `confirmed → material_selected`, which is the conservative reading: a
  skipped step is a lie in the append-only history. Answering "yes, skip" is a
  one-line change to the transition table and a fixture; answering it wrongly
  puts jobs in the wrong column of the measurement schedule.
- **C10.** **What groups a measurement trip before the project library
  exists?** §11 Phase 5 says the queue is *grouped by project so one trip
  covers several units*, and `projects` / `unit_types` do not arrive until
  Phase 8. No address is captured anywhere either — an order carries a name,
  a phone and a delivery zone.

  So the queue groups by **customer**, keyed on the normalised phone exactly as
  a rate lock is (B9). One customer with three units is one trip, which is the
  case that exists today, and an order with no usable phone is its own group
  rather than pooled with every other phone-less order — pooling them would
  invent a trip that does not exist.

  What is worth asking is how the team actually plans a day: by area, by
  customer, or by whatever the installer says. If it is by area, the answer is
  a delivery-zone or postcode grouping and an address field, not the project
  library, and that is cheaper to add now than to retrofit.
- **C11.** **When does a balance actually fall due, and what is it aged
  from?** The outstanding-balances report ages every row from the **deposit**,
  because that is the only date the system knows: there is no invoice date, no
  payment terms and no delivery date in it. So nothing on that report is called
  *overdue* — it says "days since deposit" and lets the reader draw the
  conclusion.

  That is the conservative reading and it is almost certainly not how the shop
  thinks. If the balance is due on installation, an order sitting at
  `in_production` for ninety days is not late at all, and a report that implies
  it is will be ignored inside a month. If it is due on delivery, the system
  needs a delivery date it does not capture.

  Related: while a final price does not exist (Phase 6), a balance is computed
  from the **quotation**, which §8.5 makes an upper bound — the final will be
  the same or lower. Every row says which it is, and the report totals the two
  separately, because a book that mixed them would overstate what is
  collectable.
- `[BLOCKING P7]` **C12.** **Which pipeline step is "invoicing"?** §10.4 says
  an order over RM10,000 *"cannot reach invoicing status until buyer details
  exist"*, and there is no `invoicing` status: the pipeline is `confirmed →
  measurement_booked → measured → material_selected → in_production → ready
  → installed → closed`.

  The guard currently bites from **`material_selected`** — the first step
  after a final total exists. That is the conservative reading and it is
  deliberate: §10.2 says capture has to happen *while the customer is standing
  there*, and at that moment the measurer has only just left the house.
  Blocking later — at `ready`, at `installed`, at `closed` — means discovering
  the gap when the customer has no reason left to answer the phone, and the
  penalty is RM200 to RM20,000 **per** non-compliant invoice.

  The cost of being wrong this way is a job held in the office for a phone
  call. The cost of being wrong the other way is a fine. But if the shop
  actually invoices at installation, blocking production is friction with
  nothing behind it, and moving the guard is one line and a fixture.

  Cancelling is deliberately never blocked: it has nothing to do with
  invoicing, and refusing it would leave an over-threshold order trapped.
- `[BLOCKING P7]` **C13.** **Which buyer fields does MyInvois actually
  reject a submission for?** §10.3 lists the columns to capture but not which
  are mandatory, and only the accountant who files these knows.

  The system currently treats a buyer record as complete when it has a **name**,
  **one identifier** (a TIN, or an ID with its type — a number with no type
  cannot be filed) and a **postal address** (line 1, city, state, postcode).
  Line 2, country and MSIC are optional; country because every buyer here is
  Malaysian until one is not, MSIC because it is business-buyer only.

  That is the conservative reading: it asks for the minimum any invoice needs
  and errs toward asking for too much, because §10.2's penalty is for missing
  details rather than for spare ones. But asking for a field MyInvois does not
  want is friction at the exact moment a customer is being asked to hand over
  an IC number, and missing one it does want is a rejected submission weeks
  later when nobody remembers the order.

  Answering this changes one function on each engine and its fixtures.
- **C8.** Who may move an order along, and who may cancel one? The pipeline
  enforces *what* can happen, not *who* may do it — no role check is wired to it
  yet. A part-timer marking a job installed, or cancelling one, is the kind of
  thing that is obvious to the client and invisible to us.

## D. Documents
- `[BLOCKING P2]` **D1.** Two or three existing quote and order samples.
- **D2.** Required numbering format.
- **D3.** Quote validity period.

## E. Compliance
- `[BLOCKING P7]` **E1.** Sample SQL Account import template, and who runs it.
- `[BLOCKING P7]` **E2.** Is the RM10,000 "single transaction" the whole order or
  each payment separately? **Their accountant decides.**
- **E3.** Turnover band, confirming e-invoice phase.
- **E4.** Company registration number, TIN, MSIC code.

## F. Inventory (P9)
- **F1.** Is stock tracked today, or eyeballed?
- **F2.** Who owns recording movements? A **name**, not a department.

## G. Commercial
- **G1.** IP: licence, not assignment. Confirm before signing.
- **G2.** Will there ever be an in-house dev team, Java-shop by policy?

## Answered
- **Standard prices are the fair price plus 20% on curtains and 50% on blinds**,
  provisionally, until a real list arrives (A3). The date picks the list ✓
- **Prices become server-owned in Phase 3.** On-device editing is a Phase 2
  stand-in and turns read-only once the backend publishes ✓
- **The normal track is included in the curtain rate.** Every track and rod rate
  on the list is a special-track upgrade, chosen by the customer and never added
  automatically (§4.1) ✓
- **SQL Account remains the sole invoicing system.** This system tracks every
  order and hands the data over so the accounts can be done in one place; it
  issues nothing itself (§10) ✓
- **The MITC Aug 2026 fair price list is supplied and transcribed in full** —
  77 rows, two delivery zones, three product rules (A2a, A2b) ✓
- **Material is always chosen at measurement, never at the fair**, and a
  deferred material is quoted at the dearest option in its group (B7) ✓
- **The rate card is data and stays admin-editable.** One JSON file, no code
  change and no rebuild of anything but the asset ✓
- **Korea wallpaper: RM800 buys two rolls covering 280 sqft in total** (A14) ✓
- **All SPC rows share the 200 sqft minimum**, Herringbone included (A13) ✓
- **Decorative tape is included** in the printed timber blind rates (A13) ✓
- **Three languages: Chinese, English, Malay**, per user, default `zh`. Data
  labels are `{zh, en, ms}` maps, never parallel columns ✓
- **A quotation never shows less than RM300 per deposit category**, and the
  uplift is shown as its own labelled row, never folded into the lines ✓
- **The quote states plainly that the final will be the same or lower**, never
  higher. §8.5, binding ✓
- **Exactly 10ft is the LOWER band, RM46.** `band_max_tmm = 30481` (A1) ✓
- **On a quotation, billed quantity rounds UP to a whole unit**, every basis,
  once, after `min_qty` (A10) ✓
- **At final pricing, billed quantity is EXACT** — site-measured dimensions
  times the rate held at deposit, no round-up. The deposit locks the rate, not a
  quantity (A11) ✓
- **Rates always come from the published price list** and must be updatable
  without a code change or a deploy ✓
- **The deposit locks the promo rate only.** It does not bill a quantity — exact
  quantities come from the site measurement appointment afterwards ✓
- Day/night curtain = sheer + blackout, two layers on one window ✓
- Blinds and tracks ride the `curtain` RM300 deposit ✓
- RM300 covers unlimited windows within its category ✓
- Promo and lock are fair-only; showroom pays standard ✓
- ~~Promo is a percentage off one standard list~~ — **superseded by the supplied
  list.** The fair card carries the printed fair prices directly, and the
  standard card is *derived from it* by markup. Two published lists, and the date
  picks one (§3, A3, A3a). The discount percentage stays in the model, pinned on
  every lock and line, and is currently zero on both cards.
- No Tap to Pay. Record payments only, existing terminal stays ✓
- SQL Account is the sole e-invoice issuer of record ✓
- Backend is FastAPI ✓

---

# 14. ARCHITECTURE, BOUNDARIES, EXTENSIBILITY

Enough direction to stop this becoming a monolith. **Not a licence to build
abstractions nobody needs.** No microservices, no message bus, no framework
migration. One Flutter app, one FastAPI service, one Angular dashboard, one
Postgres — as CLAUDE.md says, that is the right shape for one developer
supporting one client.

What this section buys is that a future feature can be added **beside** what
exists rather than threaded through it.

## 14.1 Domains

Conceptually separate, whatever the folder layout:

auth & authorisation · customers · products & catalogue · pricing ·
quotations · orders · payments · measurements · materials · property library ·
documents · synchronisation · audit

A domain owns its rules. Another domain calls it rather than reimplementing it.

## 14.2 Four things that live in exactly one place

These are the ones that have already gone wrong, or would be expensive to
untangle:

| Rule | Home | Why one place |
|---|---|---|
| **Pricing** | `pricing/`, pure, on both sides, one shared fixture file | Two engines already disagree-check each other (§9.4). A third copy in a screen would not be checked by anything |
| **Order transitions** | `advanceOrder`, both sides, one fixture section | §6.6. A screen that decides its own transitions is a screen that skips a step nobody notices |
| **Authorisation** | One place per side | A permission checked in two files eventually disagrees with itself, and the disagreement favours whoever wrote the second one |
| **Unit parsing** | `core/`, separate from pricing | The engine takes canonical `_tmm` and nothing else (§5.1) |

## 14.3 Business logic does not live in the UI

A screen collects input, calls a rule, and renders what comes back.

The test: **could this rule be exercised with no UI at all?** For pricing, the
lifecycle, the threshold and the unit parser, the answer is yes today, and every
one of them has tests that run without a widget. Keep it that way — it is also
what makes the two engines checkable against one shared fixture file.

## 14.4 Reference data and transactions are different kinds of thing

| | Reference | Transaction |
|---|---|---|
| Examples | Rate cards, promos, product rules, delivery zones, materials, property library | Quotes, orders, payments, measurements, events |
| Written by | Admin, centrally | Anybody, on any handset, offline |
| Sync | Versioned, replaced wholesale, server wins | Idempotent push, client wins, server appends |
| Used by a transaction how | **Copied in, with its version recorded** | — |

**A transaction never dynamically references mutable reference data.** It
snapshots what it used. This is why an order line records its rule, band, version
and discount (§6.3), why a lock pins both version and percentage (§6.1), and why
a property-library dimension will be copied with its `source_version` (Phase 8).

Changing a price, a plan or a promo must never silently change what somebody was
already quoted or charged.

## 14.5 Generated content is never production truth

For the AI directions in §2.5 and Phase 8, one boundary:

```
customer image / uploaded plan
   -> storage
   -> AI service
   -> a PROPOSAL, with confidence
   -> human review
   -> approved record
```

A generated visualisation is a picture. An extracted dimension is a draft. **A
person's approval is what makes either real**, and nothing generated flows into
pricing, measurements, order lines or production paperwork without passing
through that approval. The AI service stays outside the pricing and order
domains entirely — it proposes to a review queue, it does not write to an order.

## 14.6 Extensibility principle

> Add a feature as a new capability in the domain that owns it, not by threading
> unrelated logic through an existing screen.

**Prefer:**
stable ids · versioned reference data · immutable transaction snapshots ·
one home per rule · auditable state changes · config over constants

**Avoid:**
a service that does everything · a screen that does everything · branching on a
product *name* rather than a stable key · a business constant compiled into the
app · a second copy of a pricing rule · a permission checked in two places · a
business rule that only exists inside a widget

**Stable identifiers, not display strings.** Pricing already matches on
`variant`, `material_key`, `layer` and `fulfilment`, and every label is a
`{zh, en, ms}` map. That is what lets a customer-facing catalogue (§2.5) layer
its own presentation on the same keys later, and what stops a renamed product
silently repricing.
