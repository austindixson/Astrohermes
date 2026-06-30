#!/usr/bin/env python3
"""MLX Parakeet local STT for NativeVibe.

Records via ffmpeg (optional) or transcribes a WAV from Swift AVAudioRecorder.
Uses parakeet-mlx (NVIDIA Parakeet on Apple Silicon).

Usage:
  parakeet-transcribe.py --probe
  parakeet-transcribe.py --duration 5
  parakeet-transcribe.py --file /path/to/audio.wav
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_MODEL = os.environ.get("PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")


def venv_python() -> Path | None:
    home = Path.home()
    candidates = [
        home / ".nativevibe/parakeet-venv/bin/python",
        Path(__file__).resolve().parent / "parakeet-venv/bin/python",
    ]
    for path in candidates:
        if path.is_file():
            return path
    return None


def record_wav(seconds: float, sample_rate: int = 16_000) -> Path:
    ffmpeg = os.environ.get("FFMPEG", "ffmpeg")
    out = Path(tempfile.mkstemp(suffix=".wav")[1])
    # macOS default input; allow override for multi-mic setups.
    device = os.environ.get("PARAKEET_MIC_DEVICE", ":0")
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "avfoundation",
        "-i",
        device,
        "-t",
        str(seconds),
        "-ar",
        str(sample_rate),
        "-ac",
        "1",
        str(out),
    ]
    subprocess.run(cmd, check=True)
    return out


def transcribe_parakeet(path: Path, model_id: str = DEFAULT_MODEL) -> str:
    from parakeet_mlx import from_pretrained

    model = from_pretrained(model_id)
    result = model.transcribe(str(path))
    text = (getattr(result, "text", None) or "").strip()
    if not text:
        raise RuntimeError("empty parakeet transcript")
    return text


def probe() -> dict:
    issues: list[str] = []
    if not shutil_which("ffmpeg"):
        issues.append("ffmpeg not found")
    try:
        from parakeet_mlx import from_pretrained  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        issues.append(f"parakeet_mlx import failed: {exc}")
    return {
        "ok": len(issues) == 0,
        "engine": "parakeet-mlx",
        "model": DEFAULT_MODEL,
        "python": sys.executable,
        "issues": issues,
    }


def shutil_which(cmd: str) -> str | None:
    from shutil import which

    return which(cmd)


def emit(payload: dict, code: int = 0) -> int:
    stream = sys.stdout if payload.get("ok") else sys.stderr
    print(json.dumps(payload), file=stream, flush=True)
    return code


def reexec_with_venv_if_needed() -> None:
    try:
        import parakeet_mlx  # noqa: F401
        return
    except ImportError:
        pass
    vpy = venv_python()
    if vpy and Path(sys.executable).resolve() != vpy.resolve():
        os.execv(str(vpy), [str(vpy), *sys.argv])


def main() -> int:
    reexec_with_venv_if_needed()
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", action="store_true", help="Check deps without transcribing")
    parser.add_argument("--duration", type=float, default=5.0)
    parser.add_argument("--file")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    args = parser.parse_args()

    if args.probe:
        return emit(probe(), 0 if probe()["ok"] else 1)

    audio_path: Path | None = Path(args.file).expanduser() if args.file else None
    temp: Path | None = None
    try:
        if audio_path is None:
            temp = record_wav(args.duration)
            audio_path = temp
        if not audio_path.exists() or audio_path.stat().st_size < 128:
            return emit({"ok": False, "error": "no audio captured", "engine": "parakeet-mlx"}, 1)
        text = transcribe_parakeet(audio_path, model_id=args.model)
        return emit({"ok": True, "text": text, "engine": "parakeet-mlx", "model": args.model})
    except Exception as exc:  # noqa: BLE001
        return emit({"ok": False, "error": str(exc), "engine": "parakeet-mlx"}, 1)
    finally:
        if temp and temp.exists():
            temp.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())