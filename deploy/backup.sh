#!/usr/bin/env bash
# Nightly backup, and a restore drill on the dump it just took.
#
# The drill is not optional decoration. An untested backup is a guess, and the
# way this fails is always the same: the dumps ran for a year, and the first
# person to try restoring one finds out it was empty, or truncated, or of a
# database that no longer matches the schema. So every night, the fresh dump is
# restored into a scratch database and queried. If that fails, the run fails
# loudly rather than reporting success.
#
# Install (as root on the VPS):
#   ln -s /opt/milan/deploy/backup.sh /etc/cron.daily/milan-backup
# or, preferring a timer you can inspect:
#   systemctl edit --force --full milan-backup.timer

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

set -a
# The directive has to sit directly above the source itself: shellcheck
# attaches it to the next command, and on a one-liner that was `set -a`.
# shellcheck source=/dev/null
. ./.env
set +a

BACKUP_DIR="${MILAN_BACKUP_DIR:-/var/backups/milan}"
KEEP_DAYS="${MILAN_BACKUP_KEEP_DAYS:-30}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="${BACKUP_DIR}/milan-${STAMP}.dump"

mkdir -p "$BACKUP_DIR"
# The dumps are the whole business. Nobody else on the box needs to read them.
chmod 700 "$BACKUP_DIR"

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

log "dumping ${POSTGRES_DB} to ${DUMP}"
# Custom format: compressed, and pg_restore can read it selectively. Written to
# a temporary name first so a run interrupted halfway cannot leave a
# half-written file that looks like a good backup.
docker compose exec -T db \
	pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges \
	>"${DUMP}.partial"
mv "${DUMP}.partial" "$DUMP"
chmod 600 "$DUMP"
log "wrote $(du -h "$DUMP" | cut -f1)"

# --- the drill ---------------------------------------------------------------
# Restore into a scratch database and check it actually contains the schema and
# the rows. Dropped afterwards whatever happens.
CHECK_DB="milan_restore_check_${STAMP}"
cleanup() {
	docker compose exec -T db \
		psql -U "$POSTGRES_USER" -d postgres -q \
		-c "DROP DATABASE IF EXISTS \"${CHECK_DB}\";" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "restore drill into ${CHECK_DB}"
docker compose exec -T db \
	psql -U "$POSTGRES_USER" -d postgres -q -c "CREATE DATABASE \"${CHECK_DB}\";"

docker compose exec -T db \
	pg_restore -U "$POSTGRES_USER" -d "$CHECK_DB" --no-owner --no-privileges \
	<"$DUMP"

# Three questions, each of which has a real failure behind it:
#   - is the schema at the migration head, or did the dump predate a migration?
#   - did the tables come back, or is this an empty database that restored
#     without error?
#   - do the rate cards survive? Losing those means no quote can be explained.
read -r VERSION TABLES CARDS <<<"$(
	docker compose exec -T db psql -U "$POSTGRES_USER" -d "$CHECK_DB" -tA -F' ' -c "
		SELECT
			(SELECT version_num FROM alembic_version),
			(SELECT count(*) FROM information_schema.tables
			  WHERE table_schema = 'public'),
			(SELECT count(*) FROM rate_cards);
	"
)"

log "restored: alembic=${VERSION} tables=${TABLES} rate_cards=${CARDS}"

if [ -z "${VERSION:-}" ]; then
	log "FAIL: restored database has no alembic_version row"
	exit 1
fi
# 5 application tables plus alembic_version.
if [ "${TABLES:-0}" -lt 6 ]; then
	log "FAIL: expected at least 6 tables, found ${TABLES}"
	exit 1
fi
if [ "${CARDS:-0}" -lt 1 ]; then
	log "FAIL: no rate cards in the restored database"
	exit 1
fi

# --- retention ---------------------------------------------------------------
# Only after the drill passed. Pruning first would let a run that produces a bad
# dump delete the last good one.
log "pruning dumps older than ${KEEP_DAYS} days"
find "$BACKUP_DIR" -name 'milan-*.dump' -mtime "+${KEEP_DAYS}" -print -delete
find "$BACKUP_DIR" -name '*.partial' -mtime +1 -print -delete

log "ok"
