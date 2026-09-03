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
| `backend/` | FastAPI server, the mirrored Python engine, migrations |
| `deploy/` | Compose stack, Caddy, backup and restore |

## Current state — Phases 1 to 3 complete

The app and the server both run. 479 mobile tests, 218 backend tests, all
green in CI, and the deploy stack has been brought up, backed up and
restored for real rather than only described.

**Working end to end:** quote a house in Chinese, English or Malay; the real
77-row MITC fair card driving every price; the custom keypad; special-track and
add-on upgrades charged on top; the delivery zone asked before the total;
customer details; local persistence so a force-quit costs nothing; and an
on-device PDF the customer can take away over WhatsApp with the phone in
airplane mode.

**Also working:** a photo per window, one tap from inside the line; and admin
price editing — export the list to Excel, change a number, import it back with a
diff preview showing exactly what moves before anything is applied.

**Still open in Phase 2, and only a stopwatch can settle them:** a six-window
house quoted in under four minutes, and an untrained person producing a correct
quote within thirty. Worth running before the client meeting.

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
flutter test          # 479 tests
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

```bash
cd backend
python -m venv .venv
.venv/Scripts/pip install -r requirements-dev.txt   # or bin/pip on Linux
python -m pytest -q   # 218 tests
python -m ruff check . && python -m ruff format --check .
```

Install the dev requirements into a venv rather than relying on whatever is
already on the machine. CI installs exactly that file, and a globally
installed ruff of a different version disagrees with it about formatting --
which makes a clean local run mean nothing.

`shared/pricing-fixtures.json` is the contract between the Dart engine and the
Python one. Both suites load it. A rule change means editing the fixture
first, then making both sides pass.

## CI and releases

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request, in four jobs: the Flutter suite, the Python suite, the shared files,
and the deploy stack. Beyond the two test suites it enforces

- 100% coverage on `Length`, `Money` and `Rational`, naming the uncovered
  lines when it fails;
- that all three languages are complete and the generated localisations are
  current;
- that the bundled rate card has not drifted from `shared/`, and that the
  standard list still matches what its generator produces;
- that nothing printable claims to be a tax invoice;
- that the compose stack comes up, the container migrates itself to the
  alembic head on boot, and `backup.sh` restores the dump it just took.

`.github/workflows/release.yml` is the delivery half. It runs only after CI
has gone green -- building a release off a red tree would put a wrong price
in front of a customer with a version number attached -- and publishes a
server image to GHCR plus split-per-ABI APKs. The image is booted, migrated
and probed before it is trusted, including that it still refuses an
anonymous pull; the APK build fails if arm64 exceeds the 30MB target.

Pushing a `v*` tag additionally attaches the APKs to a GitHub release.

Two traps this repo has already hit, both of the same shape: **the tool you
run locally must be the one CI runs.** A global ruff disagreed with the
pinned one about formatting, and Windows credits a `const` constructor with
coverage that Linux -- correctly -- does not.

## Legal constraint

Nothing this system prints may say "Tax Invoice" or "e-Invoice", or display a
UIN or validation QR. SQL Account is the sole issuer of record. See `SPEC.md`
§10 — this is a legal constraint, not a labelling preference.
