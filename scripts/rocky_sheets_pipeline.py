#!/usr/bin/env python3
"""Generate and process all Rocky sprite sheets (except walk — use walk_sheet_pipeline.py).

Ensures every output frame is RGBA with transparent corners.

Usage:
  python scripts/rocky_sheets_pipeline.py all
  python scripts/rocky_sheets_pipeline.py all --sheet mad
  python scripts/rocky_sheets_pipeline.py process --sheet turn
  python scripts/rocky_sheets_pipeline.py verify
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MASCOT_DIR = ROOT / "mascot"
ASSETS_DIR = ROOT / "Pip" / "Assets"
SKIN_DIR = ROOT / "skins" / "rocky"
GEN_DIR = ROOT / "build" / "rocky-sheets"
FRAME_SIZE = 640

ROCKY_STYLE = (
    "Rocky stone golem from Project Hail Mary. Cracked beige-gray stone plates, "
    "teal/cyan shoulder bands and joint accents, one large glowing blue eye. "
    "Hunched low quadrupedal posture with long arms, chunky segmented limbs, blocky feet. "
    "Match the EXACT pose layout, frame grid, spacing, and animation timing of the "
    "mascot sprite sheet. Fully transparent background, PNG alpha channel, no background "
    "color, no text, no labels, no watermarks. Isolated sprites only. Game sprite sheet."
)


@dataclass(frozen=True)
class SheetSpec:
    key: str
    mascot_file: str
    frames: int
    cols: int
    rows: int
    aspect_ratio: str
    foot_frac: float
    frame_names: tuple[str, ...]
    extra_prompt: str = ""


def frame_name(prefix: str, index: int) -> str:
    return f"{prefix}{index}"


SHEETS: dict[str, SheetSpec] = {
    "turn": SheetSpec(
        "turn", "turn.png", 6, 6, 1, "21:9", 0.88,
        tuple(frame_name("rocky-turn-", i) for i in range(6)),
        "Edge turnaround: EXACTLY 6 frames in ONE horizontal row, no second row. "
        "Rotate from right profile through front to left profile.",
    ),
    "pickup": SheetSpec(
        "pickup", "pickup.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-pickup-", i) for i in range(12)),
        "Pickup reaction: snatched, dangling, landing.",
    ),
    "in_air_stable": SheetSpec(
        "in_air_stable", "in_air_stable.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-air-", i) for i in range(12)),
        "Held aloft dangling poses.",
    ),
    "in_air_right": SheetSpec(
        "in_air_right", "in_air_right.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-air-r-", i) for i in range(12)),
        "Carried sideways facing right while held.",
    ),
    "in_air_left": SheetSpec(
        "in_air_left", "in_air_left.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-air-l-", i) for i in range(12)),
        "Carried sideways facing left while held.",
    ),
    "mad": SheetSpec(
        "mad", "mad.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-mad-", i) for i in range(12)),
        "Anger progression front-facing, 3 tiers of intensity.",
    ),
    "front": SheetSpec(
        "front", "front.png", 1, 1, 1, "1:1", 0.92,
        ("rocky-idle-right",),
        "ONE single front idle pose only — not a grid, not multiple characters. "
        "Facing slightly right, one hand near chin.",
    ),
    "front_2": SheetSpec(
        "front_2", "front_2.png", 1, 1, 1, "1:1", 0.92,
        ("rocky-idle-left",),
        "ONE single front idle pose only — not a grid. Facing slightly left.",
    ),
    "side_stable": SheetSpec(
        "side_stable", "side_stable.png", 10, 5, 2, "21:9", 0.90,
        tuple(frame_name("rocky-stable-", i) for i in range(10)),
        "Peeking from screen edge, half-body stable idle.",
    ),
    "side_pop": SheetSpec(
        "side_pop", "side_pop.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-pop-", i) for i in range(12)),
        "Emerging from edge hole, head to full body.",
    ),
    "fall": SheetSpec(
        "fall", "fall.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-fall-", i) for i in range(12)),
        "Dropped falling sequence with impact squash.",
    ),
}


def run_hf(args: list[str], timeout: int = 900, retries: int = 4) -> str:
    last = ""
    for attempt in range(retries):
        try:
            proc = subprocess.run(
                ["higgsfield", *args],
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            if proc.returncode == 0:
                return proc.stdout.strip()
            last = proc.stderr.strip() or proc.stdout.strip()
        except subprocess.TimeoutExpired:
            last = "timeout"
        if attempt + 1 < retries:
            time.sleep(10 * (attempt + 1))
    raise RuntimeError(last or "higgsfield failed")


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
            raise RuntimeError(f"job {job_id} failed: {job}")
        time.sleep(5)
    raise TimeoutError(f"job {job_id} timed out")


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def corner_bg_color(im: Image.Image) -> tuple[int, int, int]:
    rgb = im.convert("RGB")
    w, h = rgb.size
    pts = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    samples = [rgb.getpixel(p) for p in pts]
    return (
        sorted(s[0] for s in samples)[2],
        sorted(s[1] for s in samples)[2],
        sorted(s[2] for s in samples)[2],
    )


def flood_remove_bg(im: Image.Image, tolerance: int) -> Image.Image:
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
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < w and 0 <= ny < h:
                q.append((nx, ny))
    return im


def ensure_transparent(im: Image.Image) -> Image.Image:
    """Force clean RGBA with transparent corners."""
    if im.mode != "RGBA":
        im = im.convert("RGBA")

    corners = [
        im.getpixel((0, 0)),
        im.getpixel((im.width - 1, 0)),
        im.getpixel((0, im.height - 1)),
        im.getpixel((im.width - 1, im.height - 1)),
    ]
    if all(c[3] < 8 for c in corners):
        return im

    for tol in (32, 42, 55, 70):
        im = flood_remove_bg(im, tolerance=tol)
        corners = [
            im.getpixel((0, 0)),
            im.getpixel((im.width - 1, 0)),
            im.getpixel((0, im.height - 1)),
            im.getpixel((im.width - 1, im.height - 1)),
        ]
        if all(c[3] < 8 for c in corners):
            return im

    # Last resort: make any corner-colored pixels at edges transparent
    bg = corner_bg_color(im)
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            if x > 2 and x < w - 3 and y > 2 and y < h - 3:
                continue
            r, g, b, a = px[x, y]
            if a > 0 and (
                abs(r - bg[0]) <= 80
                and abs(g - bg[1]) <= 80
                and abs(b - bg[2]) <= 80
            ):
                px[x, y] = (r, g, b, 0)
    return im


def generate_sheet(spec: SheetSpec, force: bool = False) -> Path:
    raw = GEN_DIR / f"{spec.key}-raw.png"
    if raw.exists() and not force:
        print(f"[skip gen] {spec.key}")
        return raw

    refs = [
        SKIN_DIR / "walk-reference.jpg",
        SKIN_DIR / "reference-sheet.png",
        MASCOT_DIR / spec.mascot_file,
    ]
    for r in refs:
        if not r.exists():
            raise FileNotFoundError(r)

    prompt = f"{ROCKY_STYLE} {spec.extra_prompt}"
    print(f"[gen] {spec.key} …")
    out_hf = run_hf([
        "generate", "create", "nano_banana_2",
        "--prompt", prompt,
        "--image", str(refs[0]),
        "--image", str(refs[1]),
        "--image", str(refs[2]),
        "--aspect_ratio", spec.aspect_ratio,
        "--resolution", "2k",
        "--wait",
        "--json",
    ])
    job = parse_job(out_hf)
    download(job["result_url"], raw)
    print(f"[gen] {spec.key} -> {raw}")
    return raw


def extract_single_pose(im: Image.Image) -> Image.Image:
    """When the model returns a grid inside a 1x1 sheet, take the center cell."""
    w, h = im.size
    for cols, rows in ((3, 3), (2, 2), (4, 4)):
        cell_w, cell_h = w // cols, h // rows
        if cell_w < 80 or cell_h < 80:
            continue
        col, row = cols // 2, rows // 2
        return im.crop((col * cell_w, row * cell_h, (col + 1) * cell_w, (row + 1) * cell_h))
    return im


def slice_frames(im: Image.Image, spec: SheetSpec) -> list[Image.Image]:
    if spec.frames == 1:
        return [extract_single_pose(im)]

    w, h = im.size
    cw, ch = w // spec.cols, h // spec.rows
    frames: list[Image.Image] = []
    for i in range(spec.frames):
        col, row = i % spec.cols, i // spec.cols
        frames.append(im.crop((col * cw, row * ch, (col + 1) * cw, (row + 1) * ch)))
    return frames


def pack_frame(frame: Image.Image, foot_frac: float) -> Image.Image:
    frame = ensure_transparent(frame)
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
    return ensure_transparent(canvas)


def process_sheet(spec: SheetSpec) -> None:
    raw_path = GEN_DIR / f"{spec.key}-raw.png"
    if not raw_path.exists():
        raise FileNotFoundError(f"missing {raw_path}")

    mascot_path = MASCOT_DIR / spec.mascot_file
    target = Image.open(mascot_path)
    im = ensure_transparent(Image.open(raw_path))
    if im.size != target.size:
        im = im.resize(target.size, Image.Resampling.LANCZOS)

    processed = GEN_DIR / f"{spec.key}-processed.png"
    ensure_transparent(im).save(processed)

    frames = slice_frames(im, spec)
    preview = GEN_DIR / "frames" / spec.key
    preview.mkdir(parents=True, exist_ok=True)

    for frame, name in zip(frames, spec.frame_names, strict=True):
        packed = pack_frame(frame, spec.foot_frac)
        packed.save(ASSETS_DIR / f"{name}.png")
        packed.save(preview / f"{name}.png")
    print(f"[done] {spec.key}: {len(frames)} frames")


def verify_assets() -> bool:
    walk = [f"rocky-walk-right-f{i}" for i in range(10)] + [f"rocky-walk-left-f{i}" for i in range(10)]
    others = []
    for spec in SHEETS.values():
        others.extend(spec.frame_names)
    all_names = walk + others
    ok = True
    for name in all_names:
        p = ASSETS_DIR / f"{name}.png"
        if not p.exists():
            print(f"MISSING {name}")
            ok = False
            continue
        im = Image.open(p)
        if im.mode != "RGBA":
            print(f"BAD MODE {name}: {im.mode}")
            ok = False
        corners = [
            im.getpixel((0, 0)),
            im.getpixel((im.width - 1, 0)),
            im.getpixel((0, im.height - 1)),
            im.getpixel((im.width - 1, im.height - 1)),
        ]
        if any(c[3] > 10 for c in corners):
            print(f"NON-TRANSPARENT CORNERS {name}")
            ok = False
    print(f"verify: {len(all_names)} frames, {'OK' if ok else 'ISSUES FOUND'}")
    return ok


def reprocess_walk_transparency() -> None:
    """Re-pack walk frames ensuring transparent corners."""
    for side in ("right", "left"):
        preview = ROOT / "build" / "rocky-walk" / "frames" / side
        if not preview.exists():
            continue
        for p in sorted(preview.glob("rocky-walk-*.png")):
            im = ensure_transparent(Image.open(p))
            im.save(p)
            im.save(ASSETS_DIR / p.name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["generate", "process", "all", "verify"])
    parser.add_argument("--sheet", action="append", dest="sheets")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if args.command == "verify":
        ok = verify_assets()
        sys.exit(0 if ok else 1)

    names = args.sheets or list(SHEETS)
    for n in names:
        if n not in SHEETS:
            print(f"unknown sheet: {n}", file=sys.stderr)
            sys.exit(1)

    if args.command in ("generate", "all"):
        for n in names:
            generate_sheet(SHEETS[n], force=args.force)

    if args.command in ("process", "all"):
        for n in names:
            process_sheet(SHEETS[n])

    if args.command == "all":
        reprocess_walk_transparency()
        verify_assets()


if __name__ == "__main__":
    main()