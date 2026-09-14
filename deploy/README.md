# Deploying

One VPS, Docker Compose, Caddy for TLS, a nightly dump that restores itself to
prove it works. CLAUDE.md: *one node, restorable in under an hour, is the right
shape for one developer supporting one client.*

## First boot

```sh
git clone <repo> /opt/milan
cd /opt/milan/deploy
cp .env.example .env
$EDITOR .env                 # domain, ACME email, a generated password
docker compose up -d --build
```

The API container runs `alembic upgrade head` before it serves, so there is no
separate migration step. Caddy gets a certificate on first request; the
domain's A record has to point here already or issuance fails.

Check it:

```sh
curl -fsS https://$MILAN_DOMAIN/api/health     # {"status":"ok"}
docker compose ps                              # all healthy
```

## The first admin

There is no register endpoint and no bootstrap password in the image. Creating a
user needs shell access to this box, which is the right bar for it.

```sh
docker compose exec api python -m app.cli users add \
    --name "Boss" --phone 0123456789 --role admin
```

It prompts for the PIN. **Never pass a PIN as an argument** — it would land in
shell history and in `ps` output for every process on the machine. In a script,
pipe it instead: `echo 4821 | docker compose exec -T api python -m app.cli ...`.

Roles are `admin` (everything), `staff` (quotes, sees rates, cannot edit) and
`parttime` (quotes and deposits, never sees a rate). `--role` defaults to
`parttime`.

Day to day:

```sh
docker compose exec api python -m app.cli users list
docker compose exec api python -m app.cli users pin --phone 0123456789
docker compose exec api python -m app.cli users deactivate --phone 0123456789
```

`deactivate` keeps the row — their quotes and payments still name them — and
revokes every live session they hold.

## Lost or stolen handsets

Sessions never expire. SPEC.md §12: a token that expires does so mid-fair, with
no signal, holding a customer's deposit. Revocation is the control instead.

```sh
docker compose exec api python -m app.cli sessions list
docker compose exec api python -m app.cli sessions revoke <id> --reason "phone lost"
```

The handset is signed out the next time it reaches the server. Until then it
keeps working offline, which is the trade this design makes on purpose.

## Publishing a rate card

Rate cards are data, never code (CLAUDE.md hard rule 1). A price change
publishes a *new version*; the old rows stay, marked superseded, so a quote
taken at the fair can still be explained months later. Versions only go up — a
re-used number would leave two different cards answering to one version.

Normally an admin publishes from the app or the dashboard. For the first card on
a new box, before anyone has an admin handset:

```sh
docker compose cp ../shared/rate-card-fair-2026-08.json api:/tmp/card.json
docker compose exec api python -m app.cli cards publish /tmp/card.json --list-id fair
```

## Local development

The same `db` and `api` services, minus Caddy, with `db` and `api` published
to the host instead of reachable only on the compose network. Caddy is left
out on purpose: it has nothing to serve locally (no real domain, no
certificate to get), and the dashboard's own dev server (`ng serve`,
already proxying `/api` to `http://localhost:8000` -- see
`dashboard/proxy.conf.json`) and Flutter's `flutter run` are the normal way
to work on either client day to day.

```sh
cd deploy
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build db api
curl -fsS http://localhost:8000/api/health     # {"status":"ok"}
```

`docker-compose.dev.yml` is a Compose *override*, not a replacement --
`docker-compose.yml` stays exactly what actually deploys, and nothing in the
override file is meant to ever run on the VPS.

**`api` is reachable from the whole LAN, on purpose and not risk-free.** A
phone testing this needs a direct route that does not go through Caddy
(see the override file's own comment for why), which means anyone else on
the same Wi-Fi can reach it too -- unauthenticated until they hit a real
login check, but still. Fine on a home or office network; do not run this
on a fair's own public Wi-Fi or any network you do not otherwise trust.
`db` is bound to loopback only, since nothing legitimate needs it from
anywhere but this machine.

Seed it the same way a fresh box gets its first admin, then add a couple more
accounts and enough data to exercise the newer phases (Inventory, the
Property Library) rather than just sign-in:

```sh
# The first admin, per "The first admin" above.
echo 4821 | docker compose exec -T api python -m app.cli users add \
    --name "Boss" --phone 0123456789 --role admin

# A staff and a part-timer account -- hard rule 8 means what a part-timer
# can and cannot see is worth testing as its own signed-in role, not
# inferred from the admin account.
echo 4821 | docker compose exec -T api python -m app.cli users add \
    --name "Staff Sam" --phone 0123456780 --role staff
echo 4821 | docker compose exec -T api python -m app.cli users add \
    --name "Part-timer Amy" --phone 0123456781 --role parttime

# Both rate cards -- a fresh box otherwise has neither list, and
# "compare fair against standard" is not testable with only one of them.
docker compose cp ../shared/rate-card-fair-2026-08.json api:/tmp/fair.json
docker compose cp ../shared/rate-card-standard.json api:/tmp/standard.json
MSYS_NO_PATHCONV=1 docker compose exec api python -m app.cli cards publish /tmp/fair.json --list-id fair
MSYS_NO_PATHCONV=1 docker compose exec api python -m app.cli cards publish /tmp/standard.json --list-id standard
```

`MSYS_NO_PATHCONV=1` is a Git Bash thing, not a Milan one: without it, Git
Bash rewrites `/tmp/fair.json` into a Windows path before `docker compose`
ever sees it, and the container reports a file that does not exist.

The CLI has nothing for materials, projects, or stock -- Phase 8 and 9 were
both built API-first, with no CLI to match `users`/`cards`. Seed those
through the real endpoints instead, signed in as the admin just created:

```sh
TOKEN=$(curl -fsS -X POST http://localhost:8000/api/auth/login \
    -H "Content-Type: application/json" \
    -d '{"phone":"0123456789","pin":"4821","device_id":"seed","device_label":"seed"}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

curl -fsS -X POST http://localhost:8000/api/projects \
    -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
    -d '{"name":"Taman Harmoni","developer":"ABC Sdn Bhd","area":"Ayer Keroh, Melaka"}'

curl -fsS -X POST http://localhost:8000/api/materials \
    -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
    -d '{"family":"flooring","variant_compat":["spc_4mm_1mm"],"code":"SPC-OAK-4MM","names":{"zh":"四毫米SPC地板","en":"4mm SPC flooring","ms":"Lantai SPC 4mm"},"uom":"box","coverage_per_unit":"18","reorder_level":"20"}'
# -> note the material's own "id" from the response, then:
curl -fsS -X POST http://localhost:8000/api/stock/receive \
    -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
    -d '{"material_id":"<id from above>","lot_ref":"DYE-2609-01","qty":"40","cost_sen":8500,"location":"Warehouse A"}'
```

**Pointing the mobile app at this.** `ServerConfig.parse` (the "change
server" field in the app's own settings screen) refuses anything that is
not `https`, on purpose -- a PIN and a non-expiring token cross this
connection, and a fair's wifi is a stranger's wifi (`mobile/lib/sync/
server_config.dart`). That check does not apply to the compile-time
default, so pointing a local debug build at this box is a build flag,
never a runtime setting:

```sh
cd mobile
# Android emulator: 10.0.2.2 is the special alias for the host machine.
flutter run --dart-define=MILAN_API_URL=http://10.0.2.2:8000
# A physical phone on the same Wi-Fi as this machine: use this machine's
# own LAN IP instead of 10.0.2.2 (ipconfig / ip addr), e.g.
flutter run --dart-define=MILAN_API_URL=http://192.168.1.23:8000
```

Tear it down the same way as anything else here, keeping the seeded data
between sessions (the `db-data` volume is untouched by `down` alone):

```sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml down
```

## Backups

`backup.sh` dumps, then **restores the dump it just took** into a scratch
database and queries it. A dump that restores empty, or that predates a
migration, fails the run instead of being reported as a success.

```sh
ln -s /opt/milan/deploy/backup.sh /etc/cron.daily/milan-backup
```

Dumps land in `/var/backups/milan` (override with `MILAN_BACKUP_DIR`), mode
`600`, kept 30 days (`MILAN_BACKUP_KEEP_DAYS`). Pruning happens only after the
drill passes, so a bad run cannot delete the last good dump.

**They are on the same disk as the database.** That covers the failure that
actually happens — a bad migration, a wrong `DELETE`, a corrupted table — and
not the one that ends the business, which is losing the host. Copy them off:

```sh
rclone sync /var/backups/milan remote:milan-backups   # or scp, or restic
```

## Restoring

```sh
./restore.sh /var/backups/milan/milan-20260902T180000Z.dump
```

Types-the-name-to-confirm, dumps the current database to `/tmp` first, stops
the API, drops and recreates rather than `--clean`, restores, and brings the
API back — which migrates the dump forward if it is older than the code.

## Upgrading

```sh
cd /opt/milan && git pull && cd deploy && docker compose up -d --build
```

There is one replica, so `alembic upgrade head` on boot cannot race itself.
Take a backup first; the restore path above is the rollback.

## What is deliberately not here

- **No Kubernetes, no microservices, no separate migration job.** One node.
- **Postgres publishes no port.** It is reachable on the compose network only;
  a published 5432 on a VPS gets found.
- **The API publishes no port.** Caddy is the only way in, so TLS cannot be
  bypassed.
- **No secrets in the repo.** `.env` is gitignored; `.env.example` is the
  template.

## Verified

Run for real on 3 Sep 2026 against Postgres 16, end to end:

- `docker compose up -d --build db api` — the API migrated to `0003` on boot
  and reported healthy without a separate migration step.
- `users add` created the first admin; `cards publish` loaded the 77-row fair
  card.
- Over HTTP: an unauthenticated pull was refused **401**, sign-in worked, the
  bundle returned 77 rules, a repeat pull sent no payload, and a payment pushed
  twice produced **one** row with the **same** receipt number `R2608-0001`.
- `backup.sh` dumped, restored into a scratch database and reported
  `alembic=0003 tables=11 rate_cards=1`. With `rate_cards` emptied it failed
  with `FAIL: no rate cards in the restored database` — the drill has teeth.
- `restore.sh` put a dump back over the live database; the card, the admin and
  the payment with its receipt all returned, and the API came back healthy.

Caddy is the one piece still unexercised: starting it would chase a real
certificate for a domain that does not resolve.

### A note about shells on Windows

`backup.sh` and `restore.sh` call `docker compose`, so run them from a shell
where that works. On the VPS that is any shell. On a Windows development
machine use **Git Bash** — WSL's bash cannot see Docker unless WSL integration
is switched on in Docker Desktop, and PowerShell's `|` does not deliver stdin
into `docker compose exec`, which is what the CLI reads a PIN from.
