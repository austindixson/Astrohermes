#!/usr/bin/env python3
"""Generate alternative mascot skins from pose sheets + a character reference.

Usage:
  python scripts/skin_pipeline.py init circuit --display-name "Circuit"
  python scripts/skin_pipeline.py ref circuit "chrome robot mascot with LED belly star"
  python scripts/skin_pipeline.py generate circuit --sheet front
  python scripts/skin_pipeline.py generate circuit          # all sheets
  python scripts/skin_pipeline.py process circuit           # slice existing raw PNGs
  python scripts/skin_pipeline.py all circuit               # generate + process everything

Each skin lives under skins/<name>/ with config.json and reference-sheet.png.
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
FRAME_SIZE = 640

DEFAULT_PROMPT_SUFFIX = (
    "Match the EXACT same pose layout, frame grid, spacing, and animation poses as the "
    "mascot sheet. Fully transparent background, PNG alpha channel, no background color, "
    "isolated sprites only. Game sprite sheet style. Keep the same silhouette proportions "
    "as the original mascot."
)


@dataclass(frozen=True)
class SheetSpec:
    mascot_file: str
    frames: int
    cols: int
    rows: int
    aspect_ratio: str
    foot_frac: float


SHEET_LAYOUT: dict[str, SheetSpec] = {
    "all_right": SheetSpec("all_right.png", 10, 5, 2, "21:9", 0.88),
    "all_left": SheetSpec("all_left.png", 10, 5, 2, "21:9", 0.88),
    "turn": SheetSpec("turn.png", 6, 6, 1, "2:1", 0.88),
    "pickup": SheetSpec("pickup.png", 12, 4, 3, "4:3", 0.88),
    "in_air_stable": SheetSpec("in_air_stable.png", 12, 4, 3, "4:3", 0.88),
    "in_air_right": SheetSpec("in_air_right.png", 12, 4, 3, "4:3", 0.88),
    "in_air_left": SheetSpec("in_air_left.png", 12, 4, 3, "4:3", 0.88),
    "mad": SheetSpec("mad.png", 12, 4, 3, "4:3", 0.88),
    "front": SheetSpec("front.png", 1, 1, 1, "1:1", 0.88),
    "front_2": SheetSpec("front_2.png", 1, 1, 1, "1:1", 0.88),
    "side_stable": SheetSpec("side_stable.png", 10, 5, 2, "21:9", 0.88),
    "side_pop": SheetSpec("side_pop.png", 12, 4, 3, "4:3", 0.88),
    "fall": SheetSpec("fall.png", 12, 4, 3, "4:3", 0.88),
}

# Maps sheet keys to shipped frame name prefixes (matches MascotView.swift conventions).
FRAME_PREFIX: dict[str, str] = {
    "all_right": "walk-right-f",
    "all_left": "walk-left-f",
    "turn": "turn",
    "pickup": "pickup",
    "in_air_stable": "air",
    "in_air_right": "air-r",
    "in_air_left": "air-l",
    "mad": "mad",
    "front": "idle-right",
    "front_2": "idle-left",
    "side_stable": "stable",
    "side_pop": "pop",
    "fall": "fall",
}


@dataclass
class SkinConfig:
    name: str
    display_name: str
    asset_prefix: str
    prompt: str
    foot_frac: float = 0.88
    reference_sheet: str = "reference-sheet.png"

    @property
    def skin_dir(self) -> Path:
        return ROOT / "skins" / self.name

    @property
    def gen_dir(self) -> Path:
        return ROOT / "build" / f"{self.name}-gen"

    @property
    def sheets_dir(self) -> Path:
        return ROOT / "skins" / self.name / "sheets"

    @property
    def ref_path(self) -> Path:
        return self.skin_dir / self.reference_sheet

    def frame_names(self, sheet_key: str) -> tuple[str, ...]:
        spec = SHEET_LAYOUT[sheet_key]
        prefix = f"{self.asset_prefix}-{FRAME_PREFIX[sheet_key]}"
        if spec.frames == 1:
            return (prefix,)
        sep = "" if prefix.endswith("-") else "-"
        return tuple(f"{prefix}{sep}{i}" for i in range(spec.frames))

    def full_prompt(self) -> str:
        return f"{self.prompt.strip()} {DEFAULT_PROMPT_SUFFIX}"

    def save(self) -> None:
        self.skin_dir.mkdir(parents=True, exist_ok=True)
        path = self.skin_dir / "config.json"
        path.write_text(json.dumps({
            "name": self.name,
            "display_name": self.display_name,
            "asset_prefix": self.asset_prefix,
            "prompt": self.prompt,
            "foot_frac": self.foot_frac,
            "reference_sheet": self.reference_sheet,
        }, indent=2) + "\n")

    @classmethod
    def load(cls, name: str) -> SkinConfig:
        path = ROOT / "skins" / name / "config.json"
        if not path.exists():
            raise FileNotFoundError(f"skin not found: {path}\nRun: python scripts/skin_pipeline.py init {name}")
        data = json.loads(path.read_text())
        return cls(**data)


def run_hf(args: list[str], timeout: int = 600) -> str:
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


def upload(path: Path) -> str:
    out = run_hf(["upload", "create", str(path), "--json"], timeout=120)
    return json.loads(out)["id"]


def parse_job_id(payload: str) -> str:
    data = json.loads(payload)
    if isinstance(data, list):
        return data[0]
    return data["id"]


def wait_job(job_id: str, timeout_s: int = 900) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        out = run_hf(["generate", "get", job_id, "--json"], timeout=60)
        job = json.loads(out)
        status = job.get("status")
        if status == "completed":
            return job
        if status in {"failed", "cancelled", "error"}:
            raise RuntimeError(f"job {job_id} {status}: {job}")
        time.sleep(5)
    raise TimeoutError(f"job {job_id} timed out after {timeout_s}s")


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def create_generation(ref_id: str, mascot_id: str, spec: SheetSpec, prompt: str) -> str:
    out = run_hf([
        "generate", "create", "nano_banana_2",
        "--prompt", prompt,
        "--image", ref_id,
        "--image", mascot_id,
        "--aspect_ratio", spec.aspect_ratio,
        "--resolution", "2k",
        "--json",
    ], timeout=120)
    return parse_job_id(out)


def remove_background(path: Path, out_path: Path) -> None:
    media_id = upload(path)
    out = run_hf([
        "generate", "create", "image_background_remover",
        "--image", media_id,
        "--json",
    ], timeout=120)
    job = wait_job(parse_job_id(out), timeout_s=600)
    download(job["result_url"], out_path)


def corner_bg_color(im: Image.Image) -> tuple[int, int, int]:
    im = im.convert("RGB")
    w, h = im.size
    points = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    rs = sorted(p[0] for p in points)
    gs = sorted(p[1] for p in points)
    bs = sorted(p[2] for p in points)
    return (rs[len(rs) // 2], gs[len(gs) // 2], bs[len(bs) // 2])


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


def ensure_rgba(path: Path, use_hf_bg: bool) -> Image.Image:
    im = Image.open(path)
    if im.mode == "RGBA" and im.getchannel("A").getextrema()[0] < 250:
        return im
    if use_hf_bg:
        transparent = path.with_name(path.stem + "-transparent.png")
        if not transparent.exists():
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


def generate_sheet(skin: SkinConfig, sheet_key: str, ref_id: str | None = None) -> Path:
    spec = SHEET_LAYOUT[sheet_key]
    raw_path = skin.gen_dir / f"{sheet_key}-raw.png"
    if raw_path.exists():
        print(f"[skip gen] {sheet_key}: {raw_path}")
        return raw_path

    if not skin.ref_path.exists():
        raise FileNotFoundError(f"missing reference sheet: {skin.ref_path}")

    mascot_path = MASCOT_DIR / spec.mascot_file
    if ref_id is None:
        ref_id = upload(skin.ref_path)
    mascot_id = upload(mascot_path)
    print(f"[gen] {skin.name}/{sheet_key} …")
    job_id = create_generation(ref_id, mascot_id, spec, skin.full_prompt())
    job = wait_job(job_id)
    download(job["result_url"], raw_path)
    print(f"[gen] {sheet_key} -> {raw_path}")
    return raw_path


def process_sheet(
    skin: SkinConfig,
    sheet_key: str,
    use_hf_bg: bool,
    skip_gen: bool,
    ref_id: str | None = None,
) -> None:
    spec = SHEET_LAYOUT[sheet_key]
    raw_path = skin.gen_dir / f"{sheet_key}-raw.png"
    if not raw_path.exists() and not skip_gen:
        generate_sheet(skin, sheet_key, ref_id=ref_id)
    if not raw_path.exists():
        raise FileNotFoundError(f"missing generated sheet: {raw_path}")

    mascot_path = MASCOT_DIR / spec.mascot_file
    sheet_path = skin.sheets_dir / spec.mascot_file

    print(f"[process] {skin.name}/{sheet_key}")
    im = ensure_rgba(raw_path, use_hf_bg=use_hf_bg)
    im = resize_to_mascot_sheet(im, mascot_path)
    skin.sheets_dir.mkdir(parents=True, exist_ok=True)
    im.save(sheet_path)

    frames = slice_frames(im, spec)
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    names = skin.frame_names(sheet_key)
    foot = skin.foot_frac if sheet_key in {"front", "front_2"} else spec.foot_frac
    for frame, out_name in zip(frames, names, strict=True):
        packed = pack_frame(frame, foot)
        packed.save(ASSETS_DIR / f"{out_name}.png")
    print(f"[done] {sheet_key}: {len(frames)} frames")


def generate_reference(skin: SkinConfig, description: str) -> Path:
    """Generate a turnaround reference sheet from Pip's front pose + a text brief."""
    skin.skin_dir.mkdir(parents=True, exist_ok=True)
    out = skin.ref_path
    pip_front = MASCOT_DIR / "front.png"
    pip_id = upload(pip_front)

    ref_prompt = (
        f"Character design reference sheet for '{skin.display_name}', an alternative skin "
        f"of this mascot. {description.strip()} "
        "Create a professional turnaround reference sheet on a dark gray background with "
        "labeled sections: turnaround (front, 3/4, side, back), color palette swatches, "
        "idle pose, walk cycle keyframes, and decomposed body parts. "
        "Match the mascot's rounded blob silhouette, single antenna loop, back crest, "
        "belly star marking, and chibi proportions — but reinterpret them in the new theme. "
        "Clean game-art style, consistent lighting."
    )

    print(f"[ref] generating reference sheet for {skin.display_name} …")
    out_hf = run_hf([
        "generate", "create", "nano_banana_2",
        "--prompt", ref_prompt,
        "--image", pip_id,
        "--aspect_ratio", "16:9",
        "--resolution", "2k",
        "--wait",
        "--json",
    ], timeout=900)
    job = json.loads(out_hf)
    if isinstance(job, list):
        job = wait_job(job[0])
    elif job.get("status") != "completed":
        job = wait_job(job["id"])
    download(job["result_url"], out)
    print(f"[ref] saved {out}")
    return out


def cmd_init(name: str, display_name: str | None, prefix: str | None) -> None:
    skin = SkinConfig(
        name=name,
        display_name=display_name or name.title(),
        asset_prefix=prefix or name,
        prompt=f"Recreate this mascot sprite sheet as {display_name or name.title()}.",
    )
    skin.save()
    print(f"Created skins/{name}/config.json")
    print(f"Next: python scripts/skin_pipeline.py ref {name} \"<character description>\"")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="scaffold a new skin config")
    p_init.add_argument("name")
    p_init.add_argument("--display-name")
    p_init.add_argument("--prefix", help="asset filename prefix (default: skin name)")

    p_ref = sub.add_parser("ref", help="generate reference sheet from description")
    p_ref.add_argument("name")
    p_ref.add_argument("description", nargs="+")

    for cmd in ("generate", "process", "all"):
        p = sub.add_parser(cmd)
        p.add_argument("name")
        p.add_argument("--sheet", action="append", dest="sheets")
        p.add_argument("--hf-bg", action="store_true", help="use higgsfield background remover")

    args = parser.parse_args()

    if args.command == "init":
        cmd_init(args.name, args.display_name, args.prefix)
        return

    skin = SkinConfig.load(args.name)

    if args.command == "ref":
        desc = " ".join(args.description)
        skin.prompt = (
            f"Recreate this mascot sprite sheet as {skin.display_name}. "
            f"{desc}"
        )
        skin.save()
        generate_reference(skin, desc)
        return

    names = args.sheets or list(SHEET_LAYOUT)
    use_hf_bg = getattr(args, "hf_bg", False)
    for sheet in names:
        if sheet not in SHEET_LAYOUT:
            print(f"unknown sheet: {sheet}", file=sys.stderr)
            sys.exit(1)

    if args.command == "process":
        for sheet in names:
            process_sheet(skin, sheet, use_hf_bg=use_hf_bg, skip_gen=True)
    else:
        ref_id = upload(skin.ref_path)
        for sheet in names:
            process_sheet(skin, sheet, use_hf_bg=use_hf_bg, skip_gen=False, ref_id=ref_id)


if __name__ == "__main__":
    main()