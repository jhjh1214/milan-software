---
description: Run all three of Milan's test suites (backend pytest, dashboard ng test, mobile flutter test) and report a consolidated pass/fail summary. Use when the user asks to run all tests, verify everything is green, or before reporting a multi-area change as complete.
---

Run all three, in order, regardless of whether an earlier one fails -- a
red backend suite tells you nothing about the dashboard or mobile suites,
so do not skip the rest because one went red.

1. Backend: `cd backend && python -m pytest -q`
2. Dashboard: `cd dashboard && npx ng test --watch=false`
3. Mobile: `cd mobile && flutter test`

Report one line per suite (pass count, or the first failure's name and
message) and a final overall verdict. If backend or dashboard files
changed, also mention that `check-backend` (ruff) and `dashboard/tools/
check-templates.mjs`/`check-pins.mjs` are worth running before a push --
`guard_git_push.py` (`.claude/hooks/`) already enforces both automatically
at push time, so this is a courtesy heads-up, not a requirement to repeat
here.
