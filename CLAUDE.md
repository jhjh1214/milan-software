# Milan Software

Soft furnishings order system for a Malaysian retailer (Melaka).
Curtains, blinds, SPC / vinyl / laminate flooring, wallpaper.

**Flutter** mobile app (quote, measure, deposit) · **Angular** web dashboard ·
**FastAPI** backend (sync, publishing, export).

Full detail in `SPEC.md`. This file is the context that must never be violated.

---

## Current state

**Phase 1 — Quotation Proof.** Flutter only, no server, no persistence.

Built and green: `Length`, `Money`, `Rational`, the unit parser, the soft
warnings, the pricing engine, the custom keypad, and the quote wizard in zh / en
/ ms. 204 tests; 100% coverage on `Length`, `Money` and `Rational`. Release APK
15.5MB against the 30MB target.

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
