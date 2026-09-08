# Milan Software

Soft furnishings order system for a Malaysian retailer in Melaka.
Curtains, blinds, SPC / vinyl / laminate flooring, wallpaper.

| Where | What |
|---|---|
| `CLAUDE.md` | Invariants and build rules. **Read first.** Never violated. |
| `SPEC.md` | Domain detail, data model, phases, open questions |
| `design-system/MASTER.md` | Visual and interaction decisions, and why |
| `shared/` | The Dart ↔ Python contract. One copy, both suites. |
| `mobile/` | Flutter app — quote, measure, deposit |
| `dashboard/` | Angular office dashboard |
| `backend/` | FastAPI server, the mirrored Python engine, migrations |
| `deploy/` | Compose stack, Caddy, backup and restore |
| `tool/` | Checkers and card generators run by CI |

---

## Current state

**Phases 1–6 complete. Phase 7 all but done** — only the SQL Account export
is left, and it is blocked on questions nobody has answered yet (§13 E1, E2,
C12, C13).

**853 Dart tests · 625 Python tests · 243 dashboard tests.** All green in CI,
which runs six staged jobs.

What works end to end today:

- **Quote a house** in Chinese, English or Malay on a phone with no signal,
  off the real 77-row MITC fair price list, and hand the customer a PDF.
- **Take a RM300 deposit** that locks the promo rate for that customer and
  category, and confirms the order.
- **Measure it later**, reprice at the card the deposit pinned, and share a
  revised order document showing both numbers side by side.
- **Run the office** from the dashboard: the order board, the measurement
  queue, one order in detail, four reports, publishing a price list, and
  managing who can sign in — now in **Chinese, English and Malay too**.

---

## Running it locally

You need Flutter 3.44, Python 3.12, Node 24, and Docker (only for the
Postgres the backend talks to).

### 1. The backend

```bash
cd backend
python -m venv .venv
.venv/Scripts/pip install -r requirements-dev.txt    # or bin/pip on Linux
```

It needs Postgres. The quickest one:

```bash
docker run -d --name milan-db -p 5432:5432 \
  -e POSTGRES_USER=milan -e POSTGRES_PASSWORD=milan -e POSTGRES_DB=milan \
  postgres:16
```

Then, from `backend/`:

```bash
# Point at the database you just started. The default host is `db`, which is
# the compose service name and does not resolve outside compose.
export DATABASE_URL=postgresql+psycopg://milan:milan@localhost:5432/milan

.venv/Scripts/alembic upgrade head
.venv/Scripts/uvicorn app.main:app --reload --port 8000
```

Check it: `curl http://localhost:8000/api/health` → `{"status":"ok"}`

### 2. Make yourself an admin, and load the price list

**There is no register endpoint and no default password.** Creating a user
needs shell access to the box, which is the bar it should have. The PIN is
never passed as an argument — it would land in shell history and in `ps`.

```bash
cd backend
.venv/Scripts/python -m app.cli users add \
    --name "Boss" --phone 0123456789 --role admin
# prompts: PIN:  →  4821
# prompts: PIN again:  →  4821

.venv/Scripts/python -m app.cli cards publish \
    ../shared/rate-card-fair-2026-08.json --list-id fair
```

Now you have credentials for **both** the handset and the dashboard — they
are the same account, so a leaver is deactivated once and is out of
everything:

| | |
|---|---|
| **Phone** | `0123456789` |
| **PIN** | `4821` |
| **Role** | `admin` |

Roles are `admin` (everything), `staff` (quotes, sees rates, cannot edit) and
`parttime` (quotes and deposits, **never sees a rate**). Add a part-timer to
see the difference:

```bash
.venv/Scripts/python -m app.cli users add \
    --name "Ah Meng" --phone 0111111111 --role parttime --language ms
```

`--language` defaults to `zh`, so an account made without it reads Chinese
everywhere — which is the product default, not an oversight.

Day to day, the same CLI does the rest:

```bash
.venv/Scripts/python -m app.cli users list
.venv/Scripts/python -m app.cli users pin --phone 0123456789
.venv/Scripts/python -m app.cli users deactivate --phone 0123456789
.venv/Scripts/python -m app.cli sessions list
.venv/Scripts/python -m app.cli sessions revoke <id> --reason "phone lost"
```

Sessions never expire (§12) — a token that expires does so mid-fair, with no
signal, holding a customer's deposit. **Revocation is the control instead**,
so `sessions revoke` is how a lost handset is dealt with.

### 3. The dashboard

```bash
cd dashboard
npm ci
npm start          # http://localhost:4200
```

`proxy.conf.json` forwards `/api` to `localhost:8000`, so the backend above
has to be running. In production Caddy serves both from one host, which is
why the app calls `/api` on its own origin.

Sign in with `0123456789` / `4821`.

The dashboard opens in **Chinese** — that is the default (§13 C9). The three
buttons at the top of the sign-in screen switch it, each labelled in its own
language. Once you sign in, your account's own language wins.

### 4. The mobile app

```bash
cd mobile
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift code
flutter run
```

`lib/data/database.g.dart` is generated, not committed. Run the generator
after a clone and after any change to `lib/data/database.dart`.

The app ships with the fair card bundled, so **it quotes before it has ever
seen the server**. Sign in once to pull the office's card and to be able to
sync; after that it works with the phone in airplane mode.

---

## Testing it by hand

### The one thing that will confuse you first

**Fair rates only apply between 28 and 31 August 2026.** That is the MITC
promo window on the card, and fair mode is bounded by it so the app cannot
quote promo rates after the fair ends. Outside those dates you get the
standard list (fair prices plus 20% on curtains, 50% on blinds) and **no
deposit prompt**, because §6.1 says only a *fair* deposit opens a rate lock.

To see the fair behaviour, set the device or emulator clock to **29 August
2026** before you start.

### A full walk-through

1. **Sign in** on the handset with `0123456789` / `4821`.
2. **Turn fair mode on.** It is the switch in the banner at the top of the
   quote screen ("At a fair" / 在展销会). The banner beside it says which list
   is in force — *Fair prices MITC-2026-08* or *Standard prices (not a
   fair)* — so you can always see which one you are quoting on.
3. **New quote → add a window.** Room → *Curtains* → *Night Curtain (Dimout)*
   → width `12'`, drop `9'`. It quotes **RM 552.00** — golden row 1.
   - Type `12' 4"` instead and it bills 13ft (**RM 598**): a quotation rounds
     every quantity up. That is the asymmetry the whole product is built on.
   - Type exactly `10'` for the drop and it stays in the *lower* band at
     RM46/ft. `10' 1"` jumps to RM58. That fencepost is RM144 on this window.
4. **The upgrade step.** A curtain is offered tracks and rods; a floor is not.
   Tick *Motor* and watch **Motor Track appear with it** — RM40 a foot on the
   curtain's width, because a motor with no track drives nothing. Untick the
   motor and the track goes too.
5. **Add an outdoor roller blind.** The stainless steel side guide is added
   for you, locked, saying *required for this product*. It is RM400 and it is
   what the blind runs in.
6. **Add a floor.** Note it asks for width and **length**, not height — a
   floor lies flat. The upgrade step offers *dismantle old SPC* and *self
   levelling*, billed on the same square footage you just typed.
7. **Finish the quote.** The deposit prompt asks for RM300 for each category
   on the quote. Take one and the promo rate is held for twelve months.
8. **Share the PDF.** Turn airplane mode on first — it is generated on the
   device. Every page carries the reference-price promise: *after site
   measurement the price will be the same or lower, never higher.*
9. **On the dashboard**, the order appears on the board, sorted by how soon
   its rate hold runs out. Open it to see why every line costs what it does.
10. **Measure it.** Back on the handset, open the order and record the real
    tape. The final prices at the card the deposit pinned, not today's, and
    the variance is visible before the measurer leaves the house.

### Things worth trying to break

- **Quote over RM10,000** and try to advance the order past *material
  chosen*. It refuses until buyer details exist (§10.2 — a legal
  requirement, and the penalty is RM200–20,000 per invoice). The refusal
  opens the form that fixes it.
- **Sign in as the part-timer** (`0111111111`). No rate, cost or margin is
  visible anywhere. They pick a product; the system picks the rate.
- **Pull the network out mid-quote**, force-quit the app, reopen it. The
  quote is still there — every mutation lands in SQLite before the UI says
  it worked.
- **Publish a price list** from the dashboard. It shows exactly what moves
  before anything is committed, and the publish button does not exist until
  a preview has been seen.

---

## The things most likely to be got wrong

Each has already been wrong once, in the spec or in the code, and each now
has a test naming it.

**Lengths are tenths of a millimetre, not millimetres.** A foot is 304.8mm.
Storing whole millimetres turned `12ft` into 3658mm, back into 12.0013ft, and
up to 13ft — quoting RM598 where RM552 was owed. In tenths every accepted
unit is an exact integer and the round-trip disappears.

**The 10ft band edge is `30481`, not `30480`.** The maximum is exclusive, so
exactly 10ft must sit below it. One off-by-one is RM144 on a 12ft curtain.

**Money rounds half-up, once, at the line total.** Never on an intermediate.

**The two pricing stages round quantity differently, on purpose.** A
quotation rounds up to whole units; final pricing after site measurement is
exact. So the estimate is always ≥ the final, which is why every quote must
carry the reference-price disclaimer.

**Height selects the band. Height never multiplies.** For `per_ft_width`
only width is charged.

**A missing band raises, it never falls back to the cheapest rate.** A silent
fallback is a confident wrong price.

**An add-on takes its parent's deposit category.** A motor has none of its
own. Applying a curtain lock to a flooring line is the expensive bug in this
design, so a parentless add-on raises rather than guessing.

---

## Testing

```bash
cd mobile
flutter test                                              # 853 tests
flutter analyze --fatal-infos --fatal-warnings
dart format --output=none --set-exit-if-changed lib test
```

```bash
cd backend
.venv/Scripts/python -m pytest -q                         # 625 tests
.venv/Scripts/python -m ruff check .
.venv/Scripts/python -m ruff format --check .
```

```bash
cd dashboard
npm test            # 243 tests
npm run build
node tools/check-pins.mjs
node tools/check-templates.mjs
```

```bash
python tool/check_labelling.py --self-test    # the checker still checks
python tool/check_labelling.py                # nothing claims to be a tax doc
```

**Install the dev requirements into a venv rather than relying on whatever is
on the machine.** CI installs exactly `requirements-dev.txt`, and a globally
installed ruff of a different version disagrees with it about formatting —
which makes a clean local run mean nothing. This has broken CI once already.

`shared/pricing-fixtures.json` is the contract between the Dart engine and
the Python one. Both suites load it, and CI fails a section only one of them
reads. A rule change means editing the fixture first, then making both sides
pass.

---

## CI and releases

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request, in **six staged jobs**:

```
shared  ->  lint  ->  backend   ->  mobile
                      dashboard     deploy
```

Nothing downstream starts until its gate is green. A ruff error used to sit
behind a four-and-a-half-minute Flutter run, a Postgres container and a
Docker stack, all burnt before anybody learned a lambda argument was called
`l`.

Beyond the suites it enforces:

- 100% coverage on `Length`, `Money` and `Rational`, naming the uncovered
  lines when it fails;
- that all three languages are complete and the generated localisations are
  current;
- that the bundled rate card has not drifted from `shared/`, and that the
  standard list still matches what its generator produces;
- that every fixture section is loaded by **both** suites;
- that no schema version arrives without a captured Drift snapshot;
- the document labelling audit — every ARB value, the handset source, every
  dashboard template and the card's own labels, in all three languages, plus
  anything that shows a UIN or renders a QR;
- that no Angular template binds a directive its component never imported
  (`(ngSubmit)` without FormsModule renders fine and does nothing);
- that the compose stack comes up, the container migrates itself to the
  alembic head on boot, and `backup.sh` restores the dump it just took.

`.github/workflows/release.yml` runs only after CI is green — building a
release off a red tree would put a wrong price in front of a customer with a
version number attached — and publishes API and web images to GHCR plus
split-per-ABI APKs. Images are booted, migrated and probed before their tags
are trusted. Pushing a `v*` tag attaches the APKs to a GitHub release.

**The tool you run locally must be the one CI runs.** This repo has hit that
twice: a global ruff disagreed with the pinned one about formatting, and
Windows credits a `const` constructor with coverage that Linux — correctly —
does not.

---

## Legal constraint

Nothing this system prints may say "Tax Invoice" or "e-Invoice", or display a
UIN or validation QR. **SQL Account is the sole issuer of record.** See
`SPEC.md` §10 — this is a legal constraint, not a labelling preference, and
two systems issuing for one sale produce two validated UINs and a 72-hour
cancellation problem.

`tool/check_labelling.py` enforces it across every surface, in all three
languages; `tool/check_pdf_text.py` renders the real documents and reads the
text back, because a PDF stores glyph indices and grepping the bytes would
pass either way.
