# Milan Software

Soft furnishings order system for a Malaysian retailer in Melaka.
Curtains, blinds, SPC / vinyl / laminate flooring, wallpaper.

| Where | What |
|---|---|
| `CLAUDE.md` | Invariants and build rules. **Read first.** Never violated. |
| `SPEC.md` | Domain detail, data model, phases, open questions |
| `design-system/MASTER.md` | Visual and interaction decisions, and why |
| `shared/` | The Dart ↔ Python contract. One copy, both suites. |
| `mobile/` | Flutter app |

## Current state — Phase 1, Quotation Proof

Flutter only. No server, no persistence between launches.

**Working:** `Length`, `Money`, exact rational arithmetic, the unit parser,
the pricing engine, the custom keypad, and the quote wizard in three languages.

**Blocked on `SPEC.md` §13 A2a** — the real curtain and blind rate rows. Until
they arrive, `shared/rate-card-seed.json` is built only from numbers already
published in the spec and is flagged `"provisional": true`, which the app
displays as a red banner.

> **Do not quote a real customer from the seed card.**

Replacing it must not require a code change. That is the test of whether
"never hardcode a price" was actually obeyed.

## Getting started

```bash
cd mobile
flutter pub get
flutter test          # 192 tests
flutter run
```

## The things most likely to be got wrong

Each of these has already been wrong once, in the spec or in the code, and each
now has a test naming it.

**Lengths are tenths of a millimetre, not millimetres.** A foot is 304.8mm.
Storing whole millimetres turned `12ft` into 3658mm, back into 12.0013ft, and up
to 13ft — quoting RM598 where RM552 was owed. In tenths every unit is an exact
integer and the round-trip disappears.

**The 10ft band edge is `30481`, not `30480`.** The maximum is exclusive, so
exactly 10ft must sit below it. One off-by-one is RM144 on a 12ft curtain.

**Money rounds half-up, once, at the line total.** Never on an intermediate.

**The two pricing stages round quantity differently, on purpose.** A quotation
rounds up to whole units; final pricing after site measurement is exact. So the
estimate is always ≥ the final, which is why every quote must carry the
reference-price disclaimer.

**Height selects the band. Height never multiplies.** For `per_ft_width` only
width is charged.

**A missing band raises, it never falls back to the cheapest rate.** A silent
fallback is a confident wrong price.

## Testing

```bash
cd mobile
flutter test --coverage
flutter analyze --fatal-infos --fatal-warnings
dart format --output=none --set-exit-if-changed lib test
```

`shared/pricing-fixtures.json` is the contract between the Dart engine and the
Python one that arrives in Phase 3. A rule change means editing the fixture
first, then making both sides pass.

CI additionally enforces 100% coverage on `Length`, `Money` and `Rational`,
that all three languages are complete, that the bundled rate card has not
drifted from `shared/`, and that nothing printed claims to be a tax invoice.

## Legal constraint

Nothing this system prints may say "Tax Invoice" or "e-Invoice", or display a
UIN or validation QR. SQL Account is the sole issuer of record. See `SPEC.md`
§10 — this is a legal constraint, not a labelling preference.
