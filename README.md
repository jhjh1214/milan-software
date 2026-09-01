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

## Current state — Phase 1 complete, Phase 2 in progress

Flutter only. No server yet.

**Working end to end:** quote a house in Chinese, English or Malay; the real
77-row MITC fair card driving every price; the custom keypad; special-track and
add-on upgrades charged on top; the delivery zone asked before the total;
customer details; local persistence so a force-quit costs nothing; and an
on-device PDF the customer can take away over WhatsApp with the phone in
airplane mode.

**Phase 2 still to do:** photo per window, and admin CSV import for the card.

**The real price list is in.** `shared/rate-card-fair-2026-08.json` carries the
MITC Mega Home Expo Aug 2026 fair list in full: 77 rows across curtains, blinds,
tracks and rods, flooring, wallpaper, add-ons and services, plus both delivery
zones and three product rules.

That file **is** the price list. Editing a rate there changes the app, with no
code change and no rebuild of anything but the asset. Nothing may put a rate
back into Dart.

**Material is chosen at measurement, not at the fair.** Seven variants have
material-dependent rates, and a deferred material is quoted at the **dearest**
option in its group — the only reading that keeps the promise that the final
price can only stay level or fall.

## Getting started

```bash
cd mobile
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift code
flutter test          # 239 tests
flutter run
```

`lib/data/database.g.dart` is generated, not committed. Run the generator after
a clone and after any change to `lib/data/database.dart`.

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
