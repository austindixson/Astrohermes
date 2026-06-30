#!/usr/bin/env python3
"""NativeVibe CLI companion — bidirectional control for Hermes / MCP.

Examples:
  nativevibe-bridge.py ping
  nativevibe-bridge.py spawn
  nativevibe-bridge.py tile add agent --x 200 --y 160 --workspace ~/Desktop/pip-mascot
  nativevibe-bridge.py agent send "refactor the canvas store"
  nativevibe-bridge.py terminal write "ls -la"
  nativevibe-bridge.py memory retrieve "Hermes gateway"
  nativevibe-bridge.py voice toggle
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PLUGIN_DIR = Path.home() / ".hermes" / "plugins" / "nativevibe"
REPO_PLUGIN = Path(__file__).resolve().parent.parent / "hermes-plugin" / "nativevibe"
for candidate in (PLUGIN_DIR, REPO_PLUGIN):
    if candidate.exists():
        sys.path.insert(0, str(candidate))
        break

from bridge_client import NativeVibeBridgeError, send  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="NativeVibe bridge CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")
    sub.add_parser("spawn")
    sub.add_parser("close")
    sub.add_parser("state")
    sub.add_parser("actions")
    layout = sub.add_parser("layout")
    layout.add_argument("preset", choices=["studio", "dev_desk"], nargs="?", default="studio")
    layout.add_argument("--workspace")

    tile = sub.add_parser("tile")
    tile_sub = tile.add_subparsers(dest="tile_cmd", required=True)
    add = tile_sub.add_parser("add")
    add.add_argument("kind", choices=["agent", "terminal", "browser", "markdown", "diagram", "note"])
    add.add_argument("--x", default="120")
    add.add_argument("--y", default="120")
    add.add_argument("--title")
    add.add_argument("--workspace")
    add.add_argument("--url")
    rm = tile_sub.add_parser("remove")
    rm.add_argument("tile_id")
    focus = tile_sub.add_parser("focus")
    focus.add_argument("tile_id")
    upd = tile_sub.add_parser("update")
    upd.add_argument("tile_id")
    upd.add_argument("--title")
    upd.add_argument("--workspace")

    agent = sub.add_parser("agent")
    agent_sub = agent.add_subparsers(dest="agent_cmd", required=True)
    send_msg = agent_sub.add_parser("send")
    send_msg.add_argument("text")
    send_msg.add_argument("--tile-id")

    term = sub.add_parser("terminal")
    term_sub = term.add_subparsers(dest="term_cmd", required=True)
    write = term_sub.add_parser("write")
    write.add_argument("text")
    write.add_argument("--tile-id")
    read = term_sub.add_parser("read")
    read.add_argument("--tile-id")
    read.add_argument("--max-chars", default="8000")

    mem = sub.add_parser("memory")
    mem_sub = mem.add_subparsers(dest="mem_cmd", required=True)
    retrieve = mem_sub.add_parser("retrieve")
    retrieve.add_argument("query")

    voice = sub.add_parser("voice")
    voice_sub = voice.add_subparsers(dest="voice_cmd", required=True)
    voice_sub.add_parser("toggle")
    voice_sub.add_parser("parakeet")

    args = parser.parse_args()

    try:
        if args.cmd == "ping":
            resp = send("ping")
        elif args.cmd == "state":
            resp = send("get_state")
        elif args.cmd == "actions":
            resp = send("get_actions")
        elif args.cmd == "layout":
            payload = {"preset": args.preset}
            if args.workspace:
                payload["workspace"] = str(Path(args.workspace).expanduser())
            resp = send("apply_layout", payload)
        elif args.cmd == "spawn":
            resp = send("spawn_window")
        elif args.cmd == "close":
            resp = send("close_window")
        elif args.cmd == "tile" and args.tile_cmd == "add":
            payload = {"kind": args.kind, "x": args.x, "y": args.y}
            if args.title:
                payload["title"] = args.title
            if args.workspace:
                payload["workspace"] = str(Path(args.workspace).expanduser())
            if getattr(args, "url", None):
                payload["url"] = args.url
            resp = send("add_tile", payload)
        elif args.cmd == "tile" and args.tile_cmd == "remove":
            resp = send("remove_tile", {"tile_id": args.tile_id})
        elif args.cmd == "tile" and args.tile_cmd == "focus":
            resp = send("focus_tile", {"tile_id": args.tile_id})
        elif args.cmd == "tile" and args.tile_cmd == "update":
            payload = {"tile_id": args.tile_id}
            if args.title:
                payload["title"] = args.title
            if args.workspace:
                payload["workspace"] = str(Path(args.workspace).expanduser())
            resp = send("update_tile", payload)
        elif args.cmd == "agent" and args.agent_cmd == "send":
            payload = {"text": args.text}
            if args.tile_id:
                payload["tile_id"] = args.tile_id
            resp = send("send_agent_message", payload)
        elif args.cmd == "terminal" and args.term_cmd == "write":
            payload = {"text": args.text}
            if args.tile_id:
                payload["tile_id"] = args.tile_id
            resp = send("write_terminal", payload)
        elif args.cmd == "terminal" and args.term_cmd == "read":
            payload = {"max_chars": args.max_chars}
            if args.tile_id:
                payload["tile_id"] = args.tile_id
            resp = send("read_terminal", payload)
        elif args.cmd == "memory" and args.mem_cmd == "retrieve":
            resp = send("memory_retrieve", {"query": args.query})
        elif args.cmd == "voice" and args.voice_cmd == "toggle":
            resp = send("voice_toggle")
        elif args.cmd == "voice" and args.voice_cmd == "parakeet":
            resp = send("voice_toggle", {"prefer_parakeet": "1"})
        else:
            parser.error("unknown command")
            return 2

        print(json.dumps(resp, indent=2))
        return 0 if resp.get("ok") else 1
    except NativeVibeBridgeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())