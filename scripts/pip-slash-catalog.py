#!/usr/bin/env python3
"""Pip slash catalog + skill expansion for the onscreen composer.

Usage:
  pip-slash-catalog.py              # JSON catalog to stdout
  pip-slash-catalog.py expand MSG   # expand slash message for hermes chat -q
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

HERMES_AGENT = os.environ.get("HERMES_AGENT_HOME") or str(Path.home() / ".hermes" / "hermes-agent")
if HERMES_AGENT not in sys.path:
    sys.path.insert(0, HERMES_AGENT)

PIP_BUILTIN_NAMES = {
    "stop",
    "skills",
    "help",
    "commands",
    "model",
    "new",
    "reset",
    "compress",
    "status",
    "tools",
    "bundles",
    "agents",
    "background",
    "bg",
}


def build_catalog() -> dict:
    from agent.skill_commands import scan_skill_commands
    from hermes_cli.commands import COMMAND_REGISTRY

    builtins = []
    seen = set()
    for cmd in COMMAND_REGISTRY:
        names = {cmd.name, *(cmd.aliases or [])}
        if not names & PIP_BUILTIN_NAMES:
            continue
        key = f"/{cmd.name}"
        if key in seen:
            continue
        seen.add(key)
        builtins.append(
            {
                "command": key,
                "description": cmd.description,
                "category": cmd.category or "Commands",
                "kind": "command",
            }
        )

    skills = []
    for key, info in sorted(scan_skill_commands().items()):
        skills.append(
            {
                "command": key,
                "name": info.get("name", key.lstrip("/")),
                "description": (info.get("description") or "").strip(),
                "category": "Skills",
                "kind": "skill",
            }
        )

    return {"builtins": builtins, "skills": skills}


def expand_message(message: str) -> str:
    from agent.skill_commands import resolve_skill_command_key, build_skill_invocation_message

    trimmed = message.strip()
    if not trimmed.startswith("/"):
        return message

    parts = trimmed.split(maxsplit=1)
    command_token = parts[0]
    args = parts[1] if len(parts) > 1 else ""

    slug = command_token.lstrip("/")
    key = resolve_skill_command_key(slug)
    if not key:
        return message

    expanded = build_skill_invocation_message(key, user_instruction=args)
    if not expanded:
        return message
    return expanded


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "expand":
        raw = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()
        sys.stdout.write(expand_message(raw))
        return 0

    sys.stdout.write(json.dumps(build_catalog()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())