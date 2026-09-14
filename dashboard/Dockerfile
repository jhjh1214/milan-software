# The web front door: Caddy, with the dashboard baked into it.
#
# One image rather than a build step writing into a shared volume. A volume
# would mean the files on disk and the image that serves them could be
# different versions, and the way you would find out is somebody seeing a screen
# that no longer exists in the code.
#
# It also means the thing CI builds is the thing that runs, which is the same
# reasoning behind the API image booting and being probed before its tag is
# trusted.

FROM node:24-alpine AS build

WORKDIR /app

# The lockfile first, so a source change does not re-download the world.
COPY package.json package-lock.json ./
# `ci`, never `install`: it installs exactly the lockfile and fails when
# package.json and the lockfile disagree. Retries because PyPI's npm equivalent
# is occasionally slow rather than down, and a read timeout should not fail a
# build over nothing.
RUN npm ci --fetch-retries 5 --fetch-timeout 60000

COPY . .
RUN npm run build


FROM caddy:2-alpine

# Angular writes into dist/<project>/browser.
COPY --from=build /app/dist/dashboard/browser /srv

# Caddy's own config comes from the compose mount, so the two stay in one file
# rather than drifting between here and deploy/Caddyfile.

# A plain liveness check, deliberately not asking for a 2xx: a redirect off
# the ACME/plain-HTTP port 80 (the real site is on 443) is still Caddy
# answering, and `curl -f` only fails on 4xx/5xx or no response at all.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:80/ -o /dev/null || exit 1
