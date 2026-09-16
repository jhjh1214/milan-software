---
description: Run the backend's exact CI lint gate (ruff check and ruff format --check, both at the pinned version in backend/requirements-dev.txt) in an isolated venv. Use before pushing backend changes, or any time backend/*.py has been edited and you want to confirm it will pass CI's lint job.
---

CLAUDE.md documents this exact failure happening twice: a globally
installed ruff disagrees with the pinned version on formatting, so `ruff
check` passes locally while CI's `ruff format --check` fails on the same
push. Both must be checked, at the pinned version, not whatever ruff
happens to be on PATH.

1. Read the pinned version from the `ruff==` line in
   `backend/requirements-dev.txt`.
2. `.claude/hooks/guard_git_push.py` already maintains a cached venv at
   `.claude/hooks/.cache/ruff-venv` with that exact pin (rebuilt
   automatically if the pin ever changes) -- reuse it rather than
   building a second one:
   ```
   .claude/hooks/.cache/ruff-venv/Scripts/python.exe -m ruff check backend
   .claude/hooks/.cache/ruff-venv/Scripts/python.exe -m ruff format --check backend
   ```
   If that venv does not exist yet (first run), create one the same way
   the hook does: `python -m venv .claude/hooks/.cache/ruff-venv`, then
   `pip install ruff==<pin>` into it.
3. Report both results clearly, separately -- a pass on `check` says
   nothing about `format --check`. If `format --check` fails, mention
   that `ruff format backend` (no `--check`) fixes it in place, and offer
   to run it rather than fixing it by hand.
