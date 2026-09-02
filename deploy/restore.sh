#!/usr/bin/env bash
# Restore a dump over the live database. Destructive, and deliberately awkward.
#
#   ./restore.sh /var/backups/milan/milan-20260902T180000Z.dump
#
# Asks for the database name to be typed back before it does anything. The
# alternative -- a flag -- is a thing people paste from history at 2am.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

DUMP="${1:-}"
if [ -z "$DUMP" ] || [ ! -f "$DUMP" ]; then
	echo "usage: $0 /path/to/milan-<stamp>.dump" >&2
	exit 2
fi

# shellcheck source=/dev/null
set -a; . ./.env; set +a

echo "About to REPLACE database '${POSTGRES_DB}' with:"
echo "  ${DUMP}  ($(du -h "$DUMP" | cut -f1), $(date -r "$DUMP" -u +%Y-%m-%dT%H:%M:%SZ))"
echo
printf "Type the database name to confirm: "
read -r CONFIRM
if [ "$CONFIRM" != "$POSTGRES_DB" ]; then
	echo "Not confirmed. Nothing was changed." >&2
	exit 1
fi

# A dump of what is about to be destroyed. If the restore turns out to be of
# the wrong file, this is the only way back.
SAFETY="/tmp/milan-pre-restore-$(date -u +%Y%m%dT%H%M%SZ).dump"
echo "Dumping the current database to ${SAFETY} first."
docker compose exec -T db \
	pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges \
	>"$SAFETY"

echo "Stopping the API so nothing writes during the restore."
docker compose stop api

# Drop and recreate rather than --clean: --clean leaves behind anything the
# dump does not know about, which is exactly the state that makes a restore
# look like it worked.
docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -q -c \
	"SELECT pg_terminate_backend(pid) FROM pg_stat_activity
	  WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();"
docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -q -c \
	"DROP DATABASE \"${POSTGRES_DB}\";"
docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -q -c \
	"CREATE DATABASE \"${POSTGRES_DB}\";"

docker compose exec -T db \
	pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges \
	<"$DUMP"

echo "Starting the API. It runs 'alembic upgrade head' on boot, so a dump"
echo "older than the current code is migrated forward here."
docker compose up -d api

echo
echo "Restored. The pre-restore dump is at ${SAFETY} -- keep it until you are"
echo "satisfied, then delete it."
