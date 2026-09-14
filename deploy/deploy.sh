#!/usr/bin/env bash
# Deploy a specific tagged release to this box.
#
#   ./deploy.sh v1.4.0
#
# Backs up first, checks out the tag (so the Caddyfile, this compose file and
# migrations/ on disk match what is about to run), pulls the API and web
# images release.yml already built and probed at that tag from GHCR --
# rather than rebuilding from source on a small VPS -- and brings the stack
# up on those pinned images. `docker-compose.prod.yml` is what makes that a
# pull instead of a build; see its own comment for why.
#
# Fails loud and leaves the previous images in place if the new ones do not
# come up healthy (SPEC.md's own "an untested backup is a guess" reasoning,
# applied to a deploy instead of a dump): there is no automatic rollback,
# because guessing that the previous tag is safe to silently reinstate is
# exactly the kind of guess this repo does not make about anything that
# matters. Roll back by running this script again with the previous tag.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

TAG="${1:-}"
if [ -z "$TAG" ]; then
	echo "usage: $0 <tag>   e.g. $0 v1.4.0" >&2
	exit 2
fi
# The workflow that calls this already validates the tag before it ever
# reaches a shell (.github/workflows/deploy.yml's own comment says why: a
# git tag may legally contain shell metacharacters). Checked again here
# rather than trusted, because this script is also meant to be run by hand,
# and its own $TAG feeds a git checkout and two image references below.
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
	echo "'$TAG' does not look like vX.Y.Z -- refusing to deploy it" >&2
	exit 2
fi

set -a
# The directive has to sit directly above the source itself: shellcheck
# attaches it to the next command, and on a one-liner that was `set -a`.
# shellcheck source=/dev/null
. ./.env
set +a

REPO="${MILAN_GHCR_REPOSITORY:?set MILAN_GHCR_REPOSITORY in .env, e.g. jhjh1214/milan-software}"

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

log "backing up before deploying ${TAG}"
./backup.sh

log "fetching and checking out ${TAG}"
git -C .. fetch --tags --quiet
git -C .. checkout --quiet "$TAG"

export MILAN_API_IMAGE="ghcr.io/${REPO}/api:${TAG}"
export MILAN_WEB_IMAGE="ghcr.io/${REPO}/web:${TAG}"

log "pulling ${MILAN_API_IMAGE}"
log "pulling ${MILAN_WEB_IMAGE}"
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull api caddy

log "starting the pinned images"
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# The API image carries its own HEALTHCHECK (backend/Dockerfile -- it hits
# /api/health from inside the container, which works whether or not the port
# is published to the host; on a real deploy it is not). Polling Docker's own
# verdict is more honest than this script re-deciding what "healthy" means.
log "waiting for the api container to report healthy"
ok=""
for _ in $(seq 1 60); do
	status="$(docker inspect --format='{{.State.Health.Status}}' milan-api-1 2>/dev/null || echo starting)"
	if [ "$status" = "healthy" ]; then
		ok=1
		break
	fi
	if [ "$status" = "unhealthy" ]; then
		break
	fi
	sleep 2
done

if [ -z "$ok" ]; then
	log "FAIL: milan-api-1 did not become healthy on ${TAG}"
	docker compose logs --tail=80 api caddy || true
	log "roll back with: $0 <previous-tag>"
	exit 1
fi

log "ok — ${TAG} is live"
