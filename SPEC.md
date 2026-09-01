# Milan Software — Full Spec

Domain detail, data model, phases, open questions.
**Invariants, tech stack and build rules live in `CLAUDE.md`.** Read that first.

Section map:
| # | Section |
|---|---|
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

- **One standard price list.** The fair promo is a **discount percentage** on it,
  not a second list.
- **Promo and the 12-month lock are fair-only.** Showroom pays standard, no lock.
- Showroom orders still pin the price list version at order date, so a price rise
  between deposit and measurement does not reprice a confirmed order.

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
- Does not read floor plans automatically. See Phase 8.

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

### A curtain is at least two lines
Fabric per ft, **plus** track or rod per ft, separately:
`Doso RM9/ft, Meyer RM10/ft, Wooden Rod 28mm RM18/ft, Iron Rod 19/22/28mm
RM20/21/22/ft, Motor Track RM40/ft, S Track Day RM60/ft, S Track Night RM80/ft`.

The wizard adds the track line automatically. Never leave it to memory.

### Composite variants exist
`Wooden Rod With Sgp Pleat RM56/ft` is not RM18 plus something. It is its own
variant at its own rate. **Do not compute bundles from components.**

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

**This contradicts "customer picks fabric later, all same rate."** For these
products material is a price driver and cannot be deferred past deposit.

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

**Assumption pending confirmation:** `min_qty` applies at **both** stages. "Min
18 sqft" is printed on the price list as a commercial floor, not a rounding
artefact, so a site-measured 12 sqft roller blind still bills 18. Confirm before
Phase 6.

**`rawQty` must be exact rational arithmetic, not a float.** A foot is 304.8mm,
so ft→mm→sqft can never be exact in binary. A 12ft × 8ft blind that computes as
96.0000000001 sqft would ceil to 97 and overcharge by a whole sqft. Integer
numerator and denominator only; the divisions above are deferred, not evaluated.
The two engines must agree bit for bit — see §9.4.

## 4.4 Golden tests

Live in `shared/pricing-fixtures.json`, run by both Dart and Python suites.

All six below are `stage = estimate`. **Final-stage cases must be added before
Phase 6**, since that path rounds quantity differently and is currently untested.
Worked example for the fixture: a night curtain measured on site at 12ft 4in
(37592 tenths of a mm) bills `37592/3048 = 37/3 = 12.3333 ft × RM46 =
56733.33 sen → RM 567.33`, against RM 598.00 quoted at 13ft.

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

## 5.1 Do not guess unit from magnitude

Rejected design. `84` is a plausible inch drop and a plausible cm width. `180`
likewise. The ambiguous band 50–300 is where most real input lands. A wrong guess
produces a wrong price with no visible error.

## 5.2 What ships

- Per-field **default unit**, set by admin
- **Always-visible tappable unit chip** beside every dimension field
- **Suffix parsing** overrides the chip
- Magnitude used **only as a soft warning**, never as a decision

## 5.3 Parser

`Length? parseLength(String input, LengthUnit defaultUnit)` -> mm

| Input | mm | note |
|---|---|---|
| `84` | per chip | bare number |
| `84in` `84"` `84 inch` | 2134 | |
| `7ft` `7'` `7尺` | 2134 | |
| `7'6` `7'6"` `7ft6` `7ft 6in` `7尺6寸` | 2286 | **must work** — how the trade talks |
| `2400mm` | 2400 | |
| `2.4m` `2.4米` | 2400 | |
| `240cm` | 2400 | |
| `7.5ft` | 2286 | |
| `12'0` | 3658 | |
| empty | null | |
| `abc` `7''6` `-5` | null -> inline error | **never fall back to a guess** |

Round to nearest mm on parse. Chinese numerals not parsed — out of scope.

## 5.4 Soft warnings

Non-blocking, one-tap fix. Thresholds in config, not code.

| Condition | Message |
|---|---|
| >3000mm with chip on `in` | 2400 寸 = 61 米，是不是要打 mm？ + [改成 mm] |
| <300mm curtain drop | 高度只有 30cm，确认吗？ |
| Within `BAND_EDGE_WARN_TMM` (default 76mm ≈ 3in) of a band boundary | 刚刚超过 10 尺，请确认尺寸 + shows both prices |

The band-edge warning is the highest-value validation in the app. On a 12ft
curtain, `10ft 1in` vs `9ft 11in` is a RM144 swing.

## 5.5 Display

Show entered value **and** billed value: `12尺 4寸 -> 按 13 尺计`.
Never show more precision than was entered.

---

# 6. ORDERS, DEPOSITS AND RATE LOCKS

## 6.1 The lock is on customer + category, not on the order

A single order can carry curtain lines at held promo rates and flooring lines at
standard price, if only one RM300 was paid.

```sql
category_locks
  id uuid PK
  customer_id
  category                enum(curtain, flooring, wallpaper)
  deposit_payment_id      uuid
  held_rate_card_version  int
  held_promo_id           uuid
  held_discount_pct       numeric(5,2)    -- denormalised; promos rows may change
  held_until              date            -- deposit date + 12 months
  status                  enum(active, expired, cancelled, refunded)
  UNIQUE(customer_id, category) WHERE status = 'active'
```

`family` and deposit category are **different fields**. Blinds and tracks have
their own rates but ride the curtain deposit. Keep the mapping in one function.

```python
def deposit_category(family):
    return {'curtain': 'curtain', 'blind': 'curtain', 'track': 'curtain',
            'flooring': 'flooring', 'wallpaper': 'wallpaper'}[family]

def price_basis_for(line, order):
    lock = active_lock(order.customer_id, deposit_category(line.family))
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
  id uuid PK
  order_no                  text          -- client-generated {branch}-{yymm}-{seq}
  customer_id
  channel                   enum(showroom, home_visit, fair, referral, phone)
  project_id, unit_type_id  uuid NULL
  pinned_rate_card_version  int
  delivery_zone_id          uuid NULL
  delivery_charge_sen       int DEFAULT 0
  status                    enum(confirmed, measurement_booked, measured,
                                 material_selected, in_production, ready,
                                 installed, closed, cancelled)
  estimate_total_sen        int
  final_total_sen           int NULL
  deposit_paid_sen, balance_due_sen
  has_unmeasured_lines      bool
  created_by, created_at, synced_at

order_lines
  id, order_id, sort_order
  family, variant, layer, material_key, fulfilment
  category_lock_id          uuid NULL     -- which lock priced this, null = none
  parent_line_id            uuid NULL     -- add-ons attach to their parent
  room, label
  est_width_tmm, est_height_tmm
  final_width_tmm, final_height_tmm         -- NULL until measured
  is_site_measured          bool DEFAULT false
  measured_by, measured_at
  billed_qty numeric, billed_unit text
  applied_rule_id, applied_band_label
  applied_rate_card_version int
  applied_discount_pct      numeric(5,2)
  standard_rate_sen         int           -- before discount, printed on the quote
  rate_sen, line_total_sen
  photo_ids                 uuid[]
  is_overridden             bool

order_events                              -- APPEND ONLY
  id, order_id, event, note, by_user, at, synced_at
```

**Estimate and final are both kept.** The variance report by salesperson tells
the boss who is guessing badly and needs retraining.

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

customers
  id uuid PK
  name, phone, email NULL
  tier            enum(standard, mvp) DEFAULT 'standard'
  -- buyer/compliance fields: see section 10
  created_by, created_at

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
CREATE INDEX ON orders (customer_id);
CREATE INDEX ON orders (channel, created_at);
CREATE INDEX ON order_lines (order_id, sort_order);
CREATE INDEX ON category_locks (held_until) WHERE status = 'active';
CREATE INDEX ON pricing_rules (rate_card_version, family, variant)
  WHERE superseded_at IS NULL;                    -- the hot lookup
CREATE UNIQUE INDEX ON category_locks (customer_id, category)
  WHERE status = 'active';
```

That last one is a **constraint**, not an optimisation. It stops a customer
accumulating two active curtain locks.

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
customers  -- additional columns
  tin                 text NULL
  id_type             enum(nric, brn, passport, army) NULL
  id_number           text NULL
  address_line1, address_line2, city, state, postcode, country
  msic_code           text NULL        -- business buyers only
  einvoice_requested  bool DEFAULT false
```

- Optional by default. Most walk-ins are General Public.
- **When the running total crosses the threshold, the wizard stops and requires
  buyer details.** Not a warning. A required step.
- Also required whenever the customer asks for an e-invoice, at any value.
- **Threshold lives in config, not code.** It will change.

## 10.4 The timing trap

The fair estimate is rough. The final after measurement is not. An order
estimated at RM8,500 settles at RM11,200.

Evaluate the threshold **twice**:
1. **At the fair, on the estimate** — prompt from **RM8,000**, not RM10,000, so
   borderline orders are captured while the customer is present.
2. **At final pricing** — if crossed, the order **cannot reach invoicing status**
   until buyer details exist. Enforce in the state machine, not the UI.

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
| 8 | Project Library | — | Stage 2 |
| 9 | Inventory | — | Stage 2 |

Maintenance ladder (starts at Phase 3 — nothing to host before then):
RM150 (P2) → RM450 (P3–4) → RM750 (P5) → RM950 (P6–7). 12-month minimum.

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
- Automatic track line prompt when a curtain is added
- Photo per window
- Local persistence via Drift, survives force-quit
- Customer record
- Quote PDF generated **on device**, shareable offline, bilingual
- Rate card imported from admin-prepared CSV

**Acceptance**
- [ ] Quote survives force-quit, reopens at the exact window
- [ ] A curtain line prompts for its track; skipping requires a deliberate tap
- [ ] Herringbone SPC without self levelling is blocked with a clear message
- [ ] ZIP blind over 20ft width is blocked
- [ ] Wallpaper rounds up to whole BOGO pairs
- [ ] Delivery charge appears before the customer sees a total, never after
- [ ] Quote PDF reaches WhatsApp with the phone in airplane mode
- [ ] Every line prints entered size, billed size, band applied, rate
- [ ] **Six-window house quoted in under 4 minutes, stopwatch-timed**
- [ ] **Untrained person produces a correct quote within 30 minutes**

The PDF is slower than it looks. Budget the full 40 hours — layout, Chinese font
embedding and page breaks all take longer than expected.

---

## PHASE 3 — Backend and Sync
**143h · 4 weeks · FastAPI + Postgres**

First phase with running costs, so maintenance billing starts here.

**In**
- FastAPI, Postgres, Alembic
- Python pricing engine mirroring Dart, sharing `shared/pricing-fixtures.json`
- Auth: users, roles, offline-tolerant sessions
- `GET /api/bundle` versioned gzipped pull
- Outbox push, idempotent on client UUID
- Server-side re-pricing with discrepancy logging
- Rate card publishing as a versioned set
- "Fair mode" pre-download
- Docker Compose deploy, nightly backup, **tested restore**

**Acceptance**
- [ ] Same fixtures pass in both Dart and Python suites, in CI
- [ ] Quote offline for one hour, restore network, everything lands **once**
- [ ] Double-submit the same outbox row: no duplicate created
- [ ] Publish a rate change; every device picks it up on next connect
- [ ] Token killed mid-fair simulation: app keeps working offline
- [ ] Database restored from backup into a scratch container successfully

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

**Acceptance**
- [ ] Two category deposits recorded offline; both receipts resolve after sync
- [ ] A flooring line on a curtain-only lock prices at **standard**, not promo
- [ ] Adding flooring with no flooring lock triggers the prompt every time
- [ ] Declined category deposits appear in a report
- [ ] Changing the promo % afterwards does not move a locked order's price
- [ ] An override made offline appears in the audit log naming the admin
- [ ] Cash-up totals reconcile per user per day

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

**Acceptance**
- [ ] Publishing shows exactly which products move and by how much before commit
- [ ] Order board loads 500 orders without pagination lag
- [ ] Every filter state is reachable by URL
- [ ] Deactivating a user requires typing their name

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

**Acceptance**
- [ ] A measured order reprices at the old card even after two rate publishes
- [ ] Variance visible to the measurer before they leave the house
- [ ] An order crossing RM10,000 cannot advance without buyer details
- [ ] Works fully offline in a house with no signal

---

## PHASE 7 — SQL Account and e-Invoice Compliance
**60h · 2 weeks**

Read section 10 in full first. Those legal constraints are not optional.

**In**
- Buyer detail capture: TIN, ID type and number, address, MSIC
- **RM10,000 threshold gate**, prompting from RM8,000, enforced at estimate and
  final pricing
- Config-driven threshold
- SQL Account export behind an adapter interface
- Export screen in the dashboard, date-ranged, re-export option
- Document labelling audit

**Out**
**No MyInvois integration. No LHDN submission. No certificate handling.**

**Acceptance**
- [ ] An order crossing the threshold cannot reach invoicing without buyer details
- [ ] Export imports into SQL Account without manual correction
- [ ] Re-exporting the same range does not create duplicates
- [ ] No printed document uses "Tax Invoice" or "e-Invoice", or displays anything
      resembling a UIN or validation QR
- [ ] Threshold change is a config edit, not a deployment

**Blocked on** a sample SQL Account import template, and the accountant's ruling
on E2.

---

## PHASE 8 — Project Library and Floor Plans
**Stage 2 · quoted after Phase 5 has run live two months**

**Manage this expectation before selling it.** "Upload a floor plan, get an
instant quotation" is not something to promise. Developer plans usually do not
dimension windows, scale is inconsistent, and extraction fails **silently** — a
wrongly scaled plan produces a confident wrong number.

**What actually works:** admin uploads the plan per unit type, **calibrates scale
once** by tapping two points on a known dimension, then taps each window entering
real dimensions from the developer's schedule. Digitised once per unit type,
reused for every customer in that project. Slow for customer one, very fast from
customer two.

```sql
projects      id, name, developer, area, version int, updated_at
unit_types    id, project_id, name, floor_count
openings      id, unit_type_id, label, room, floor,
              nominal_w_tmm, nominal_h_tmm, sort_order
rooms         id, unit_type_id, name, nominal_area_mm2, skirting_run_tmm, floor
floor_plans   id, unit_type_id, file_ref, scale_tmm_per_px, uploaded_by
```

**Instantiate, never reference.** Copy values into the order line. Editing a
project later must not mutate an issued order.

Any plan-sourced line is `is_site_measured = false` and prints
`参考尺寸，未现场丈量`. **Never let a plan-derived dimension reach production
without a site measurement.** Enforce in the state machine.

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
- `[BLOCKING P2]` **A3.** Are RM46 / RM58 the **promo** rates? If so, is the
  standard list supplied directly or derived from these?
  *Retagged from P1: Phase 1 seeds the printed numbers and applies no discount,
  so the answer changes labelling in Phase 2, not the Phase 1 engine.*
- `[BLOCKING P2]` **A4.** Is the discount applied to the **unit rate** (discount
  → round → multiply) or the **line total** (multiply → discount → round)?
  Differs by sen per line and real money across a house.
  *Retagged from P1: Phase 1 builds no discount and no golden case exercises one.*
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
- `[BLOCKING P6]` **A11a.** Follow-on: does `min_qty` still apply at the final
  stage? A site-measured 12 sqft roller against a printed "Min 18sqft" — 18 or
  12? Assumed **18** (a commercial floor, not a rounding artefact) and written
  into §4.3 as an assumption. Confirm before Phase 6.
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
- **A15.** **Do the banded tracks and rods band on the curtain's height?**
  S-track, multi-track and the rod-with-pleat and rod-with-eyelet composites all
  print two prices under the same 10ft header as the curtains. Implemented as a
  height band on the line's own height, which for a track line is the curtain
  drop. Plain rods and the Doso/Meyer tracks are unbanded, as printed.

## B. Deposits and locks
- `[BLOCKING P4]` **B1.** Curtain RM300 paid at a fair, customer returns six
  months later wanting flooring. Does the second RM300 buy **promo** or
  **standard**?
- `[BLOCKING P4]` **B2.** 12 months elapse, house still not ready. Extend,
  reprice, or case by case?
- **B3.** Cancel after deposit: forfeit, partial, or credit?
- `[BLOCKING P4]` **B4.** Final lands under RM300: refund or credit? Partly
  pre-empted — a **quotation** now floors at RM300 per category (§4.3), so the
  customer is never quoted less than they deposit. But a quote of RM300 that
  measures down to RM240 still lands here, because final pricing is exact and has
  no floor. Refund the RM60, credit it, or keep it?
- **B8.** Is the RM300 quotation floor **per deposit category** or per order?
  Implemented per category, since RM300 buys one category. Phase 1 carries only
  curtain and blind lines, which share one category, so the two readings are
  identical there. **The distinction becomes real in Phase 2** when flooring
  arrives: curtain RM250 + flooring RM200 quotes as RM600 under per-category and
  RM450 under per-order.
- **B5.** One customer, two properties: one lock or two?
- **B6.** Always flat RM300, or higher on large orders?
- ~~**B7.**~~ **ANSWERED — every product defers material to measurement.** At a
  fair the job is to lock the deposit, not to settle the specification.

  This overrides the note in §4.1 that material "cannot be deferred past
  deposit" for products whose material moves the rate. Seven variants do:
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
- Promo is a percentage off one standard list ✓
- No Tap to Pay. Record payments only, existing terminal stays ✓
- SQL Account is the sole e-invoice issuer of record ✓
- Backend is FastAPI ✓
