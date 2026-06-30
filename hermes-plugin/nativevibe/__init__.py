"""NativeVibe Hermes plugin — agents control the macOS IDE canvas via bridge IPC."""

from __future__ import annotations

from .tools import (
    NATIVEVIBE_SCHEMA,
    _check_nativevibe_available,
    _handle_nativevibe,
)


def register(ctx) -> None:
    ctx.register_tool(
        name="nativevibe",
        toolset="nativevibe",
        schema=NATIVEVIBE_SCHEMA,
        handler=_handle_nativevibe,
        check_fn=_check_nativevibe_available,
        emoji="🖥️",
    )