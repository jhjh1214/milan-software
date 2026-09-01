# Milan Software

Soft furnishings order system for a Malaysian retailer (Melaka).
Curtains, blinds, SPC / vinyl / laminate flooring, wallpaper.

**Flutter** mobile app (quote, measure, deposit) · **Angular** web dashboard ·
**FastAPI** backend (sync, publishing, export).

Full detail in `SPEC.md`. This file is the context that must never be violated.

---

## Current state

**Phase 1 — Quotation Proof.** Flutter only, no server, no persistence.
Building `Length`, `Money`, the unit parser and rounding first.

**Blocked:** `SPEC.md` §13 **A1** (the 10ft band boundary) and **A2a** (the
curtain and blind rate rows).
**Do not build the pricing engine until those two are answered in writing.**

A3 and A4 were retagged `BLOCKING P2` — Phase 1 applies no discount, so promo
vs standard rates and the discount application order cannot block it. A10 is
answered: round up. Everything else in Phase 1 is unblocked.

---

## Non-negotiable invariants

**Lengths are integer millimetres.** Field naming `*_mm`. No `double` ever holds
a dimension. Convert at the UI boundary only. Never round-trip `mm → ft → mm`.

**Money is integer sen.** Field naming `*_sen`. RM46.00 is `4600`. `double` for
currency is forbidden. Python: `int` sen, `Decimal` at boundaries only, never
`float`.

**Two distinct roundings, never conflated.**
- *Quantity*: **always up, to a whole unit, once.** Every basis — ft, sqft, m,
  roll. There is no 19.99 sqft line. Applied after `min_qty`, never before.
  `MM_PER_FT` is 304.8, not an integer — compare in tenths of a mm. Test
  `3048 → 10` and `3049 → 11`.
- *Money*: round half-up to the nearest sen, **once**, at the line total. Never
  round intermediates.

**Quantity arithmetic is exact rational, never float.** A foot is 304.8mm, so
ft→mm→sqft cannot be exact in binary, and `96.0000000001` ceils to 97 and
overcharges by a whole sqft. Integer numerator over integer denominator; divide
last. This is what keeps the Dart and Python engines bit-identical.

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

1. **Never hardcode a price.** Rates come from data. Tests may use literals;
   nothing else may.
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

- Money columns end `_sen` and are `int`. Lengths end `_mm` and are `int`.
- Every table: `id uuid PK`, client-generated. Syncing tables carry `synced_at`.
- Timestamps `timestamptz`, stored UTC, displayed `Asia/Kuala_Lumpur`.
- Postgres enums server-side, Dart enums client-side, kept in step by a
  **generated** file, never by hand.
- Chinese and English throughout, switchable **per user**, not per device.
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
