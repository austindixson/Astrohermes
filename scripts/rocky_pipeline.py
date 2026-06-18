#!/usr/bin/env python3
"""DEPRECATED — sheet-to-sheet generation broke poses and baked in reference text.

Use scripts/restyle_pipeline.py instead (per-frame restyle from Pip/Assets).
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
REF_SHEET = ROOT / "Rocky" / "rocky-reference-sheet.png"
MASCOT_DIR = ROOT / "mascot"
GEN_DIR = ROOT / "build" / "rocky-gen"
SHEETS_DIR = ROOT / "rocky-assets"
ASSETS_DIR = ROOT / "Pip" / "Assets"
FRAME_SIZE = 640

PROMPT = (
    "Recreate this mascot sprite sheet with Rocky from Project Hail Mary. "
    "Use the character design reference sheet for Rocky's appearance: pentapedal rocky "
    "beige stone creature with teal accent stripes, cracked rock body, four jointed legs. "
    "Match the EXACT same pose layout, frame grid, spacing, and animation poses as the "
    "mascot sheet. Fully transparent background, PNG alpha channel, no background color, "
    "isolated sprites only. Game sprite sheet style."
)


@dataclass(frozen=True)
class SheetSpec:
    mascot_file: str
    frames: int
    cols: int
    rows: int
    aspect_ratio: str
    foot_frac: float
    frame_names: tuple[str, ...]


def frame_name(prefix: str, index: int) -> str:
    return f"{prefix}{index}"


SHEETS: dict[str, SheetSpec] = {
    "all_right": SheetSpec(
        "all_right.png", 10, 5, 2, "21:9", 0.88,
        tuple(frame_name("rocky-walk-right-f", i) for i in range(10)),
    ),
    "all_left": SheetSpec(
        "all_left.png", 10, 5, 2, "21:9", 0.88,
        tuple(frame_name("rocky-walk-left-f", i) for i in range(10)),
    ),
    "turn": SheetSpec(
        "turn.png", 6, 6, 1, "21:9", 0.88,
        tuple(frame_name("rocky-turn-", i) for i in range(6)),
    ),
    "pickup": SheetSpec(
        "pickup.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-pickup-", i) for i in range(12)),
    ),
    "in_air_stable": SheetSpec(
        "in_air_stable.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-air-", i) for i in range(12)),
    ),
    "in_air_right": SheetSpec(
        "in_air_right.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-air-r-", i) for i in range(12)),
    ),
    "in_air_left": SheetSpec(
        "in_air_left.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-air-l-", i) for i in range(12)),
    ),
    "mad": SheetSpec(
        "mad.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-mad-", i) for i in range(12)),
    ),
    "front": SheetSpec(
        "front.png", 1, 1, 1, "1:1", 0.88, ("rocky-idle-right",),
    ),
    "front_2": SheetSpec(
        "front_2.png", 1, 1, 1, "1:1", 0.88, ("rocky-idle-left",),
    ),
    "side_stable": SheetSpec(
        "side_stable.png", 10, 5, 2, "21:9", 0.88,
        tuple(frame_name("rocky-stable-", i) for i in range(10)),
    ),
    "side_pop": SheetSpec(
        "side_pop.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-pop-", i) for i in range(12)),
    ),
    "fall": SheetSpec(
        "fall.png", 12, 4, 3, "4:3", 0.88,
        tuple(frame_name("rocky-fall-", i) for i in range(12)),
    ),
}


def run_hf(args: list[str], timeout: int = 600, retries: int = 3) -> str:
    last_err = ""
    for attempt in range(retries):
        proc = subprocess.run(
            ["higgsfield", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if proc.returncode == 0:
            return proc.stdout.strip()
        last_err = proc.stderr.strip() or proc.stdout.strip() or "higgsfield failed"
        if "504" in last_err and attempt + 1 < retries:
            time.sleep(5 * (attempt + 1))
            continue
        break
    raise RuntimeError(last_err)


def upload(path: Path) -> str:
    out = run_hf(["upload", "create", str(path), "--json"], timeout=120)
    return json.loads(out)["id"]


def create_generation(ref_id: str, mascot_id: str, spec: SheetSpec) -> str:
    out = run_hf([
        "generate", "create", "nano_banana_2",
        "--prompt", PROMPT,
        "--image", ref_id,
        "--image", mascot_id,
        "--aspect_ratio", spec.aspect_ratio,
        "--resolution", "2k",
        "--json",
    ], timeout=120)
    return parse_job_id(out)


def wait_job(job_id: str, timeout_s: int = 900) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        out = run_hf(["generate", "get", job_id, "--json"], timeout=60)
        job = json.loads(out)
        status = job.get("status")
        if status == "completed":
            return job
        if status in {"failed", "cancelled", "error"}:
            raise RuntimeError(f"job {job_id} {status}")
        time.sleep(5)
    raise TimeoutError(f"job {job_id} timed out after {timeout_s}s")


def parse_job_id(payload: str) -> str:
    data = json.loads(payload)
    if isinstance(data, list):
        return data[0]
    return data["id"]


def remove_background(path: Path, out_path: Path) -> None:
    media_id = upload(path)
    out = run_hf([
        "generate", "create", "image_background_remover",
        "--image", media_id,
        "--json",
    ], timeout=120)
    job = wait_job(parse_job_id(out), timeout_s=600)
    download(job["result_url"], out_path)


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def corner_bg_color(im: Image.Image) -> tuple[int, int, int]:
    im = im.convert("RGB")
    w, h = im.size
    coords = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    colors = [im.getpixel(c)[:3] for c in coords]
    rs = sorted(c[0] for c in colors)
    gs = sorted(c[1] for c in colors)
    bs = sorted(c[2] for c in colors)
    mid = len(colors) // 2
    return (rs[mid], gs[mid], bs[mid])


def remove_bg_local(im: Image.Image, tolerance: int = 42) -> Image.Image:
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
        px[x, y] = (r := px[x, y][0], g := px[x, y][1], b := px[x, y][2], 0)
        if x > 0:
            q.append((x - 1, y))
        if x + 1 < w:
            q.append((x + 1, y))
        if y > 0:
            q.append((x, y - 1))
        if y + 1 < h:
            q.append((x, y + 1))

    return im


def ensure_rgba(path: Path, use_hf_bg: bool) -> Image.Image:
    transparent = path.with_name(f"{path.stem}-transparent.png")
    if transparent.exists():
        return Image.open(transparent)
    im = Image.open(path)
    if im.mode == "RGBA" and im.getchannel("A").getextrema()[0] < 250:
        return im
    if use_hf_bg:
        print(f"  removing background via higgsfield: {path.name}")
        remove_background(path, transparent)
        return Image.open(transparent)
    return remove_bg_local(im)


def resize_to_mascot_sheet(im: Image.Image, mascot_path: Path) -> Image.Image:
    target = Image.open(mascot_path)
    if im.size == target.size:
        return im
    return im.resize(target.size, Image.Resampling.LANCZOS)


def slice_frames(im: Image.Image, spec: SheetSpec) -> list[Image.Image]:
    w, h = im.size
    cell_w, cell_h = w // spec.cols, h // spec.rows
    frames: list[Image.Image] = []
    for i in range(spec.frames):
        col, row = i % spec.cols, i // spec.cols
        box = (col * cell_w, row * cell_h, (col + 1) * cell_w, (row + 1) * cell_h)
        frames.append(im.crop(box))
    return frames


def pack_frame(frame: Image.Image, foot_frac: float, size: int = FRAME_SIZE) -> Image.Image:
    frame = frame.convert("RGBA")
    bbox = frame.getbbox()
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if not bbox:
        return canvas

    cropped = frame.crop(bbox)
    foot_y = int(foot_frac * size)
    max_h = foot_y - 8
    max_w = size - 16
    scale = min(max_w / cropped.width, max_h / cropped.height, 1.5)
    new_w = max(1, int(cropped.width * scale))
    new_h = max(1, int(cropped.height * scale))
    resized = cropped.resize((new_w, new_h), Image.Resampling.LANCZOS)
    x = (size - new_w) // 2
    y = foot_y - new_h
    canvas.paste(resized, (x, y), resized)
    return canvas


def generate_sheet(name: str, spec: SheetSpec, ref_id: str | None = None) -> Path:
    raw_path = GEN_DIR / f"{name}-raw.png"
    if raw_path.exists():
        print(f"[skip gen] {name}: {raw_path}")
        return raw_path

    mascot_path = MASCOT_DIR / spec.mascot_file
    if ref_id is None:
        ref_id = upload(REF_SHEET)
    mascot_id = upload(mascot_path)
    print(f"[gen] {name} …")
    job_id = create_generation(ref_id, mascot_id, spec)
    job = wait_job(job_id)
    download(job["result_url"], raw_path)
    print(f"[gen] {name} -> {raw_path}")
    return raw_path


def process_sheet(
    name: str,
    spec: SheetSpec,
    use_hf_bg: bool,
    skip_gen: bool,
    ref_id: str | None = None,
) -> None:
    raw_path = GEN_DIR / f"{name}-raw.png"
    if not raw_path.exists() and not skip_gen:
        generate_sheet(name, spec, ref_id=ref_id)
    if not raw_path.exists():
        raise FileNotFoundError(f"missing generated sheet: {raw_path}")

    mascot_path = MASCOT_DIR / spec.mascot_file
    sheet_path = SHEETS_DIR / spec.mascot_file

    print(f"[process] {name}")
    im = ensure_rgba(raw_path, use_hf_bg=use_hf_bg)
    im = resize_to_mascot_sheet(im, mascot_path)
    SHEETS_DIR.mkdir(parents=True, exist_ok=True)
    im.save(sheet_path)

    frames = slice_frames(im, spec)
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    for frame, out_name in zip(frames, spec.frame_names, strict=True):
        packed = pack_frame(frame, spec.foot_frac)
        packed.save(ASSETS_DIR / f"{out_name}.png")
    print(f"[done] {name}: {len(frames)} frames -> {ASSETS_DIR}")


def cmd_generate(names: list[str], use_hf_bg: bool) -> None:
    ref_id = upload(REF_SHEET)
    failed: list[str] = []
    for name in names:
        try:
            process_sheet(name, SHEETS[name], use_hf_bg=use_hf_bg, skip_gen=False, ref_id=ref_id)
        except Exception as exc:
            print(f"[error] {name}: {exc}", file=sys.stderr)
            failed.append(name)
    if failed:
        raise RuntimeError(f"failed sheets: {', '.join(failed)}")


def cmd_process(names: list[str], use_hf_bg: bool) -> None:
    for name in names:
        process_sheet(name, SHEETS[name], use_hf_bg=use_hf_bg, skip_gen=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["generate", "process", "all"],
        help="generate: HF + process; process: existing raw PNGs; all: full pipeline",
    )
    parser.add_argument(
        "--sheet",
        action="append",
        dest="sheets",
        help="sheet key (default: all)",
    )
    parser.add_argument(
        "--hf-bg",
        action="store_true",
        help="use higgsfield background remover (slower, higher quality)",
    )
    args = parser.parse_args()
    names = args.sheets or list(SHEETS)
    use_hf_bg = args.hf_bg

    for name in names:
        if name not in SHEETS:
            print(f"unknown sheet: {name}", file=sys.stderr)
            sys.exit(1)

    if args.command == "generate":
        cmd_generate(names, use_hf_bg=use_hf_bg)
    elif args.command == "process":
        cmd_process(names, use_hf_bg=use_hf_bg)
    else:
        try:
            cmd_generate(names, use_hf_bg=use_hf_bg)
        except RuntimeError as exc:
            print(exc, file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
