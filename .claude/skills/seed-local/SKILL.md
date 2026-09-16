---
description: Bring up and seed the local Milan backend for testing (Docker db+api, an admin/staff/parttime user, both rate cards, a project/material/stock lot). Use when the user asks to test locally, start the local backend, or seed test data for the dashboard or mobile app.
---

The exact commands live in `deploy/README.md`'s "Local development"
section. Read it fresh each time rather than trusting a copy in this
file, since that section is the one source of truth this project keeps
updated and a second copy here would silently drift from it.

1. Read `deploy/README.md`'s "Local development" section.
2. Check whether `milan-db-1`/`milan-api-1` are already running and
   already seeded first (`docker compose ps` from `deploy/`, and a quick
   query for existing users) -- there is no reason to reseed a box that
   already has data, and Ollama/other local services this session has
   used before may already be up too.
3. If not already up, run the documented `docker compose -f
   docker-compose.yml -f docker-compose.dev.yml up -d --build db api`,
   then the seed sequence exactly as written in that section -- including
   the `MSYS_NO_PATHCONV=1` prefix on the CLI publish commands and the
   UTF-8 encoding notes for the curl-based seed script. Both are real,
   previously-hit traps on this Windows/Git-Bash setup, not optional
   flourishes to skip.
4. Confirm success with the verification query already in that doc
   (`select 'users' ... union all ...`) rather than assuming the seed
   commands worked.
5. Report what is now seeded and reachable (`http://localhost:8000` for
   the API, plus the seeded phone/PIN combinations) so the user can point
   the dashboard or a mobile build at it immediately.
