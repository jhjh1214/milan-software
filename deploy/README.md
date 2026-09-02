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

## Publishing a rate card

Rate cards are data, never code (CLAUDE.md hard rule 1). A price change
publishes a *new version*; the old rows stay, marked superseded, so a quote
taken at the fair can still be explained months later.

```sh
docker compose exec -T api python -c "
from app.db import session_scope
from app.services.ingest import publish_card
import json, sys
payload = json.load(open('/srv/card.json'))
with session_scope() as s:
    publish_card(s, list_id='fair', payload=payload)
"
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

## Not yet verified

These files have never been run. There is no Docker daemon on the development
machine, so `docker compose config` has validated the syntax and nothing has
validated the behaviour. Before this is relied on: bring the stack up on a
throwaway host, take a backup, and run `restore.sh` against it.
