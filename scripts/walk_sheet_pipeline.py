#!/usr/bin/env python3
"""Generate and process quadruped Rocky walk sprite sheets.

Walk cycles use a different strategy than idle/mad frames:
  - Generate a full 2x5 sheet matching the quadruped Rocky reference
  - Slice, mirror for walk-right, pack into Pip/Assets frames

Usage:
  python scripts/walk_sheet_pipeline.py generate right
  python scripts/walk_sheet_pipeline.py process right
  python scripts/walk_sheet_pipeline.py all right
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from collections import deque
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MASCOT_DIR = ROOT / "mascot"
ASSETS_DIR = ROOT / "Pip" / "Assets"
SKIN_DIR = ROOT / "skins" / "rocky"
GEN_DIR = ROOT / "build" / "rocky-walk"
FRAME_SIZE = 640
PREFIX = "rocky"

WALK_PROMPT = (
    "Recreate this exact quadrupedal Rocky stone golem walk animation sprite sheet. "
    "Cracked beige-gray stone body, teal/cyan bands on shoulders and joints, "
    "one large glowing blue eye, hunched low posture with arms reaching toward the ground. "
    "Match the reference sheet's pose timing, frame layout, stone texture, and proportions. "
    "2 rows × 5 columns = 10 frames. Side profile facing RIGHT. "
    "Fully transparent background, no text, no labels, no watermarks. Game sprite sheet."
)

SHEETS = {
    "right": {
        "mascot": "all_right.png",
        "frames": ("walk-right-f", 10),
        "mirror": False,  # generated sheet already faces right
    },
    "left": {
        "mascot": "all_left.png",
        "frames": ("walk-left-f", 10),
        "mirror": True,   # flip right-facing sheet for walk-left
    },
}


def run_hf(args: list[str], timeout: int = 900) -> str:
    proc = subprocess.run(
        ["higgsfield", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "higgsfield failed")
    return proc.stdout.strip()


def parse_job(payload: str) -> dict:
    data = json.loads(payload)
    if isinstance(data, list):
        job_id = data[0] if isinstance(data[0], str) else data[0]["id"]
        out = run_hf(["generate", "get", job_id, "--json"], timeout=60)
        return json.loads(out)
    if data.get("status") == "completed":
        return data
    return wait_job(data["id"])


def wait_job(job_id: str, timeout_s: int = 900) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        out = run_hf(["generate", "get", job_id, "--json"], timeout=60)
        job = json.loads(out)
        if job.get("status") == "completed":
            return job
        if job.get("status") in {"failed", "cancelled", "error"}:
            raise RuntimeError(f"job failed: {job}")
        time.sleep(5)
    raise TimeoutError(f"job {job_id} timed out")


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def corner_bg_color(im: Image.Image) -> tuple[int, int, int]:
    rgb = im.convert("RGB")
    w, h = rgb.size
    points = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    samples = [rgb.getpixel(p) for p in points]
    rs = sorted(c[0] for c in samples)
    gs = sorted(c[1] for c in samples)
    bs = sorted(c[2] for c in samples)
    return (rs[len(rs) // 2], gs[len(gs) // 2], bs[len(bs) // 2])


def remove_bg_local(im: Image.Image, tolerance: int = 38) -> Image.Image:
    im = im.convert("RGBA")
    w, h = im.size
    bg = corner_bg_color(im)
    px = im.load()
    seen = [[False] * w for _ in range(h)]
    q: deque[tuple[int, int]] = deque()

    def matches(x: int, y: int) -> bool:
        r, g, b, a = px[x, y]
        if a < 8:
            return True
        return (
            abs(r - bg[0]) <= tolerance
            and abs(g - bg[1]) <= tolerance
            and abs(b - bg[2]) <= tolerance
        )

    for x in range(w):
        q.append((x, 0))
        q.append((x, h - 1))
    for y in range(h):
        q.append((0, y))
        q.append((w - 1, y))

    while q:
        x, y = q.popleft()
        if seen[y][x] or not matches(x, y):
            continue
        seen[y][x] = True
        px[x, y] = (px[x, y][0], px[x, y][1], px[x, y][2], 0)
        if x > 0:
            q.append((x - 1, y))
        if x + 1 < w:
            q.append((x + 1, y))
        if y > 0:
            q.append((x, y - 1))
        if y + 1 < h:
            q.append((x, y + 1))
    return im


def generate_sheet(side: str, force: bool = False) -> Path:
    spec = SHEETS[side]
    out = GEN_DIR / f"all_{side}-raw.png"
    if out.exists() and not force:
        print(f"[skip gen] {out}")
        return out

    ref = SKIN_DIR / "walk-reference.jpg"
    mascot = MASCOT_DIR / spec["mascot"]
    print(f"[gen] walk-{side} from reference …")
    out_hf = run_hf([
        "generate", "create", "nano_banana_2",
        "--prompt", WALK_PROMPT,
        "--image", str(ref),
        "--image", str(mascot),
        "--aspect_ratio", "21:9",
        "--resolution", "2k",
        "--wait",
        "--json",
    ])
    job = parse_job(out_hf)
    download(job["result_url"], out)
    print(f"[gen] -> {out}")
    return out


def slice_sheet(im: Image.Image, cols: int = 5, rows: int = 2) -> list[Image.Image]:
    w, h = im.size
    cw, ch = w // cols, h // rows
    frames = []
    for i in range(cols * rows):
        col, row = i % cols, i // cols
        frames.append(im.crop((col * cw, row * ch, (col + 1) * cw, (row + 1) * ch)))
    return frames


def pack_frame(frame: Image.Image, foot_frac: float = 0.92) -> Image.Image:
    frame = frame.convert("RGBA")
    bbox = frame.getbbox()
    canvas = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    if not bbox:
        return canvas
    cropped = frame.crop(bbox)
    foot_y = int(foot_frac * FRAME_SIZE)
    max_h = foot_y - 8
    max_w = FRAME_SIZE - 16
    scale = min(max_w / cropped.width, max_h / cropped.height, 1.6)
    nw = max(1, int(cropped.width * scale))
    nh = max(1, int(cropped.height * scale))
    resized = cropped.resize((nw, nh), Image.Resampling.LANCZOS)
    x = (FRAME_SIZE - nw) // 2
    y = foot_y - nh
    canvas.paste(resized, (x, y), resized)
    return canvas


def process_sheet(side: str) -> None:
    spec = SHEETS[side]
    raw_path = GEN_DIR / f"all_{side}-raw.png"
    if not raw_path.exists():
        raise FileNotFoundError(f"generate first: {raw_path}")

    mascot_path = MASCOT_DIR / spec["mascot"]
    target = Image.open(mascot_path)
    raw = Image.open(raw_path)
    if raw.mode == "RGBA" and raw.getchannel("A").getextrema()[0] < 250:
        im = raw
    else:
        im = remove_bg_local(raw)
    if im.size != target.size:
        im = im.resize(target.size, Image.Resampling.LANCZOS)

    out_sheet = GEN_DIR / f"all_{side}-processed.png"
    im.save(out_sheet)

    prefix, count = spec["frames"]
    frames = slice_sheet(im)
    preview_dir = GEN_DIR / "frames" / side
    preview_dir.mkdir(parents=True, exist_ok=True)

    for i, frame in enumerate(frames[:count]):
        if spec["mirror"]:
            frame = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        packed = pack_frame(frame)
        name = f"{PREFIX}-{prefix}{i}"
        packed.save(ASSETS_DIR / f"{name}.png")
        packed.save(preview_dir / f"{name}.png")
    print(f"[done] {count} walk-{side} frames -> {ASSETS_DIR}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["generate", "process", "all"])
    parser.add_argument("side", choices=["right", "left", "both"])
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    sides = ["right", "left"] if args.side == "both" else [args.side]
    for side in sides:
        if args.command in ("generate", "all"):
            generate_sheet(side, force=args.force)
        if args.command in ("process", "all"):
            process_sheet(side)


if __name__ == "__main__":
    main()