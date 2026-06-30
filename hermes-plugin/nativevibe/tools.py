"""Hermes tool handlers for NativeVibe canvas control."""

from __future__ import annotations

import json
from typing import Any

try:
    from .bridge_client import NativeVibeBridgeError, send
except ImportError:
    from bridge_client import NativeVibeBridgeError, send

NATIVEVIBE_SCHEMA = {
    "type": "function",
    "function": {
        "name": "nativevibe",
        "description": (
            "Control the NativeVibe macOS IDE orchestrator — spawn windows, arrange dynamic "
            "grid layouts (studio: 2× Hermes + code terminal + browser/music), add/move tiles, "
            "send agent messages, write/read terminal I/O, list tiles, get action log, retrieve "
            "memory, and toggle voice. Requires NativeVibe.app running locally."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": [
                        "ping",
                        "spawn_window",
                        "close_window",
                        "add_tile",
                        "remove_tile",
                        "focus_tile",
                        "update_tile",
                        "set_tile_frame",
                        "set_canvas",
                        "apply_layout",
                        "send_agent_message",
                        "write_terminal",
                        "read_terminal",
                        "read_agent",
                        "get_state",
                        "list_tiles",
                        "get_actions",
                        "navigate_browser",
                        "memory_retrieve",
                        "voice_toggle",
                    ],
                    "description": "Bridge command to execute.",
                },
                "kind": {
                    "type": "string",
                    "enum": ["agent", "terminal", "browser", "markdown", "diagram", "note"],
                    "description": "Tile kind for add_tile.",
                },
                "preset": {
                    "type": "string",
                    "enum": ["studio", "dev_desk"],
                    "description": "Layout preset for apply_layout (studio = 2 Hermes + code + music browser).",
                },
                "x": {"type": "string", "description": "Canvas X for new tile or frame."},
                "y": {"type": "string", "description": "Canvas Y for new tile or frame."},
                "width": {"type": "string", "description": "Tile width for set_tile_frame."},
                "height": {"type": "string", "description": "Tile height for set_tile_frame."},
                "title": {"type": "string", "description": "Optional tile title."},
                "url": {"type": "string", "description": "Browser URL for add_tile, update_tile, or navigate_browser."},
                "workspace": {"type": "string", "description": "Working directory path for agent/terminal tiles."},
                "tile_id": {"type": "string", "description": "Target tile UUID."},
                "text": {"type": "string", "description": "Message or terminal input."},
                "query": {"type": "string", "description": "Memory retrieval query."},
                "limit": {"type": "string", "description": "Max actions for get_actions."},
                "max_chars": {"type": "string", "description": "Max chars for read_terminal."},
                "pan_x": {"type": "string"},
                "pan_y": {"type": "string"},
                "zoom": {"type": "string"},
                "background": {"type": "string", "description": "Canvas background preset (aurora, ember, ocean)."},
                "prefer_parakeet": {
                    "type": "boolean",
                    "description": "Use MLX Parakeet fast voice path when toggling voice.",
                },
            },
            "required": ["action"],
        },
    },
}


def _check_nativevibe_available(**_: Any) -> bool:
    return True


def _payload_from_args(args: dict[str, Any]) -> dict[str, str]:
    payload: dict[str, str] = {}
    for key in (
        "kind", "preset", "x", "y", "width", "height", "title", "url", "workspace",
        "tile_id", "text", "query", "limit", "max_chars",
        "pan_x", "pan_y", "zoom", "background",
    ):
        value = args.get(key)
        if value is not None and str(value).strip():
            payload[key] = str(value)
    if args.get("prefer_parakeet"):
        payload["prefer_parakeet"] = "1"
    return payload


def _handle_nativevibe(args: dict[str, Any], **_: Any) -> str:
    action = (args.get("action") or "").strip()
    if not action:
        return json.dumps({"ok": False, "error": "action is required"})

    command_map = {
        "ping": "ping",
        "spawn_window": "spawn_window",
        "close_window": "close_window",
        "add_tile": "add_tile",
        "remove_tile": "remove_tile",
        "focus_tile": "focus_tile",
        "update_tile": "update_tile",
        "set_tile_frame": "set_tile_frame",
        "set_canvas": "set_canvas",
        "apply_layout": "apply_layout",
        "send_agent_message": "send_agent_message",
        "write_terminal": "write_terminal",
        "read_terminal": "read_terminal",
        "read_agent": "read_agent",
        "get_state": "get_state",
        "list_tiles": "list_tiles",
        "get_actions": "get_actions",
        "navigate_browser": "navigate_browser",
        "memory_retrieve": "memory_retrieve",
        "voice_toggle": "voice_toggle",
    }
    bridge_command = command_map.get(action)
    if not bridge_command:
        return json.dumps({"ok": False, "error": f"unknown action: {action}"})

    if action == "add_tile" and not args.get("kind"):
        args["kind"] = "agent"
    if action == "apply_layout" and not args.get("preset"):
        args["preset"] = "studio"
    if action == "send_agent_message" and not args.get("text"):
        return json.dumps({"ok": False, "error": "text is required for send_agent_message"})
    if action == "write_terminal" and not args.get("text"):
        return json.dumps({"ok": False, "error": "text is required for write_terminal"})
    if action == "memory_retrieve" and not args.get("query"):
        return json.dumps({"ok": False, "error": "query is required for memory_retrieve"})
    if action in {"remove_tile", "focus_tile", "update_tile", "read_agent", "navigate_browser"} and not args.get("tile_id"):
        return json.dumps({"ok": False, "error": "tile_id is required"})
    if action == "navigate_browser" and not args.get("url"):
        return json.dumps({"ok": False, "error": "url is required for navigate_browser"})

    try:
        response = send(bridge_command, _payload_from_args(args))
    except NativeVibeBridgeError as exc:
        return json.dumps({"ok": False, "error": str(exc)})

    return json.dumps(response)