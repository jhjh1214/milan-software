#!/usr/bin/env python3
"""PreToolUse hook (Bash and PowerShell) -- blocks writing to a tracked
.md/.dart/.arb/.yml/.yaml file through shell redirection instead of the
Write/Edit tool.

Why this exists: this project's own CLAUDE.md documents two separate,
repeated encoding failures from exactly this pattern --

  "Never write a .dart, .arb or .md file through Set-Content/Out-File if
  it contains a section sign or Chinese -- it writes ANSI or adds a BOM."

  "Never write a workflow file -- or anything with \\r, \\n or \\\\ in it --
  through a bash heredoc feeding a Python string: the escapes are
  interpreted twice and a literal carriage return lands in the file."

Both really are the same mistake: a shell redirect or a *-Content cmdlet
does not give the same UTF-8-no-BOM, no-double-escaping guarantee the
Write/Edit tools do. This blocks the pattern before it happens rather than
after, and says which tool to use instead.

Scratchpad and other temp-directory writes are exempt -- those files are
never git-tracked and do not need this guarantee.

Checks only the part of the command *outside* quoted strings, so a command
that merely mentions `> file.md` inside a quoted argument (piping test
JSON to a script, printing an example) is not read as a real redirect.
The trade-off, accepted deliberately: a genuine redirect whose own target
is quoted (`echo x > "file.md"`) is missed too, since the target's quotes
get stripped along with it. Real usage almost never quotes a plain
filename with no spaces, so this favours not blocking innocuous commands
over catching that rarer case -- found by this hook blocking its own
first test run.
"""

from __future__ import annotations

import json
import re
import sys

SENSITIVE_EXT = r"(?:md|dart|arb|ya?ml)"

BASH_PATTERNS = [
    re.compile(rf">>?\s*['\"]?\S+\.{SENSITIVE_EXT}['\"]?\b", re.IGNORECASE),
    re.compile(rf"\btee\s+.*\.{SENSITIVE_EXT}\b", re.IGNORECASE),
]
POWERSHELL_PATTERNS = [
    re.compile(
        rf"\b(Set-Content|Out-File|Add-Content)\b[^|;]*\.{SENSITIVE_EXT}\b",
        re.IGNORECASE,
    ),
]

EXEMPT_SUBSTRINGS = ("AppData\\Local\\Temp", "AppData/Local/Temp", "scratchpad")

_QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")


def _outside_quotes(command: str) -> str:
    """Only what is *outside* single/double quotes -- so a command that
    merely mentions `> file.md` inside a quoted string (piping test JSON to
    a script, printing an example, quoting another command) is not read the
    same as an actual, unquoted shell redirect. Found the hard way: this
    hook's own first version blocked a plain `echo "..."` whose quoted text
    happened to contain the substring `> notes.md`."""
    return _QUOTED.sub(" ", command)


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


def main() -> None:
    payload = json.load(sys.stdin)
    tool_name = payload.get("tool_name")
    if tool_name not in ("Bash", "PowerShell"):
        _allow()

    command = payload.get("tool_input", {}).get("command", "")
    if not command:
        _allow()
    if any(marker in command for marker in EXEMPT_SUBSTRINGS):
        _allow()

    patterns = BASH_PATTERNS if tool_name == "Bash" else POWERSHELL_PATTERNS
    unquoted = _outside_quotes(command)
    if any(p.search(unquoted) for p in patterns):
        _deny(
            "Blocked: this looks like it writes a .md/.dart/.arb/.yml/.yaml "
            "file through shell redirection or a *-Content cmdlet rather "
            "than the Write or Edit tool. CLAUDE.md documents two separate "
            "real incidents from exactly this: PowerShell's Set-Content/"
            "Out-File writing ANSI or adding a BOM to a file with non-ASCII "
            "content, and a bash heredoc double-escaping \\r/\\n into a "
            "workflow file and breaking CI. Use the Write or Edit tool for "
            "this file instead -- both write UTF-8 correctly."
        )

    _allow()


if __name__ == "__main__":
    main()
