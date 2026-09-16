#!/usr/bin/env python3
"""PreToolUse hook (Bash) -- blocks `git push` if it would send backend
Python that fails the pinned ruff check, or dashboard TypeScript that fails
its own template/pin checks.

Why this exists: this project's own CLAUDE.md documents the same mistake
happening twice -- "ruff was never run locally before, and it is what broke
CI" and, separately, two pushes in a row that passed `ruff check` but failed
CI on `ruff format --check`, because a newer globally-installed ruff
disagrees with the pinned 0.8.4 on formatting. This hook runs both, at the
exact pinned version read from backend/requirements-dev.txt, before the
push leaves the machine, so a red CI run for this specific reason cannot
happen again. It reuses a cached venv (`.claude/hooks/.cache/ruff-venv`)
rather than rebuilding one per push.

Never blocks anything this project has not already documented as a real,
repeated failure. If git plumbing itself fails (no upstream, detached
HEAD, git missing) this allows the push rather than becoming an obstacle
worse than the problem it exists to prevent.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import venv
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUFF_VENV = Path(__file__).resolve().parent / ".cache" / "ruff-venv"


def _allow() -> None:
    sys.exit(0)


def _deny(reason: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


def _run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
    )


def _changed_files(cwd: Path) -> list[str] | None:
    """Files in commits about to be pushed, or None if that cannot be
    determined (no upstream yet, detached HEAD, git missing) -- callers
    treat None as "nothing to check" rather than a reason to block."""
    upstream = _run(
        ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd
    )
    if upstream.returncode != 0:
        return None
    diff = _run(
        ["git", "diff", "--name-only", f"{upstream.stdout.strip()}..HEAD"], cwd
    )
    if diff.returncode != 0:
        return None
    return [line for line in diff.stdout.splitlines() if line]


def _ensure_ruff_venv() -> Path | None:
    """Creates the pinned-ruff venv once, reused on every later push. Returns
    the ruff pin string on success, or None if it could not be set up."""
    req_dev = PROJECT_ROOT / "backend" / "requirements-dev.txt"
    match = re.search(r"^ruff==(\S+)", req_dev.read_text(encoding="utf-8"), re.M)
    if match is None:
        return None
    pin = match.group(1)

    python_exe = RUFF_VENV / "Scripts" / "python.exe"
    if not python_exe.exists():
        venv.create(RUFF_VENV, with_pip=True)
    marker = RUFF_VENV / f".pin-{pin}"
    if not marker.exists():
        installed = subprocess.run(
            [str(python_exe), "-m", "pip", "install", "--quiet", f"ruff=={pin}"],
            capture_output=True,
            text=True,
            timeout=180,
        )
        if installed.returncode != 0:
            return None
        for old in RUFF_VENV.glob(".pin-*"):
            old.unlink()
        marker.touch()
    return python_exe


def main() -> None:
    try:
        _run_checks()
    except Exception as exc:  # noqa: BLE001 -- fail open: a bug in this
        # hook must never become a worse obstacle than the CI failure it
        # exists to prevent, so an unexpected error allows the push rather
        # than crashing with a traceback.
        print(f"guard_git_push.py: internal error, allowing push: {exc}", file=sys.stderr)
        sys.exit(0)


def _run_checks() -> None:
    payload = json.load(sys.stdin)
    if payload.get("tool_name") != "Bash":
        _allow()

    command = payload.get("tool_input", {}).get("command", "")
    if not re.search(r"\bgit\s+push\b", command):
        _allow()

    cwd = Path(payload.get("cwd", str(PROJECT_ROOT)))
    changed = _changed_files(cwd)
    if changed is None:
        _allow()

    backend_changed = any(re.match(r"backend/.*\.py$", f) for f in changed)
    dashboard_changed = any(
        re.match(r"dashboard/src/.*\.(ts|html)$", f) for f in changed
    )

    if backend_changed:
        python_exe = _ensure_ruff_venv()
        if python_exe is not None:
            backend_dir = PROJECT_ROOT / "backend"
            checked = _run([str(python_exe), "-m", "ruff", "check", "."], backend_dir)
            if checked.returncode != 0:
                _deny(
                    "git push blocked: `ruff check .` fails at the pinned "
                    "version.\n\n" + checked.stdout + checked.stderr
                )
            formatted = _run(
                [str(python_exe), "-m", "ruff", "format", "--check", "."],
                backend_dir,
            )
            if formatted.returncode != 0:
                _deny(
                    "git push blocked: `ruff format --check .` fails at the "
                    "pinned version (this is the specific check that broke "
                    "CI twice before -- `ruff check` alone can pass while "
                    "this fails).\n\n" + formatted.stdout + formatted.stderr
                )

    if dashboard_changed:
        dashboard_dir = PROJECT_ROOT / "dashboard"
        for tool in ("check-templates.mjs", "check-pins.mjs"):
            result = _run(["node", f"tools/{tool}"], dashboard_dir)
            if result.returncode != 0:
                _deny(
                    f"git push blocked: dashboard/tools/{tool} failed.\n\n"
                    + result.stdout
                    + result.stderr
                )

    _allow()


if __name__ == "__main__":
    main()
