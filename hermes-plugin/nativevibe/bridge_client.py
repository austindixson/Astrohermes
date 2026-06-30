"""NativeVibe bridge client — direct inbox/outbox IPC (no shell scripts)."""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path

BRIDGE = Path.home() / ".nativevibe" / "bridge"
INBOX = BRIDGE / "inbox"
OUTBOX = BRIDGE / "outbox"
DEFAULT_TIMEOUT = 8.0


class NativeVibeBridgeError(Exception):
    pass


def send(command: str, payload: dict[str, str] | None = None, timeout: float = DEFAULT_TIMEOUT) -> dict:
    INBOX.mkdir(parents=True, exist_ok=True)
    OUTBOX.mkdir(parents=True, exist_ok=True)
    req_id = uuid.uuid4().hex
    req = {"id": req_id, "command": command, "payload": payload or {}}
    (INBOX / f"{req_id}.json").write_text(json.dumps(req), encoding="utf-8")

    outbox_path = OUTBOX / f"{req_id}.json"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if outbox_path.exists():
            try:
                return json.loads(outbox_path.read_text(encoding="utf-8"))
            finally:
                outbox_path.unlink(missing_ok=True)
        time.sleep(0.1)

    raise NativeVibeBridgeError(
        f"No response after {timeout}s — start Pip or NativeVibe.app (bridge must be running)."
    )