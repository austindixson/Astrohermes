#!/usr/bin/env python3
"""Rocky skin pipeline — per-frame restyle from Pip poses + style guide.

Restyles each Pip/Assets frame individually using the Rocky style guide
(skins/rocky/reference-sheet.png), Higgsfield nano_banana_2, background
remover, and local alpha cleanup. Preserves Pip pose/framing exactly.

Usage:
  python scripts/rocky_fix_pipeline.py archive
  python scripts/rocky_fix_pipeline.py clean-peek
  python scripts/rocky_fix_pipeline.py restyle walk-right-f0
  python scripts/rocky_fix_pipeline.py restyle-walk
  python scripts/rocky_fix_pipeline.py restyle-air
  python scripts/rocky_fix_pipeline.py restyle-all
  python scripts/rocky_fix_pipeline.py start          # archive + restyle all 122
  python scripts/rocky_fix_pipeline.py all --force
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
import urllib.request
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Pip" / "Assets"
ARCHIVE = ASSETS / "_archive" / "rocky-broken"
GEN = ROOT / "build" / "rocky-fix"
SKIN_DIR = ROOT / "skins" / "rocky"
STYLE_REF = SKIN_DIR / "reference-sheet.png"

RESTYLE_SUFFIX = (
    "Match the Rocky style guide reference EXACTLY — same weathered tan stone texture, "
    "dark mechanical joints, teal/cyan shoulder stripes, cel-shaded outlines, and line quality. "
    "Keep the EXACT pose, silhouette, limb positions, and framing of the source Pip sprite. "
    "Do NOT copy the five-legged body plan from the reference; only apply Rocky's surface "
    "materials and colors onto Pip's bipedal blob silhouette. "
    "Fully transparent background only — no white, gray, or checkerboard halos, "
    "especially under arms and between limbs. Single isolated game sprite, no text or labels."
)


def load_skin_config() -> dict:
    path = SKIN_DIR / "config.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text())

WALK_FRAMES = [f"walk-right-f{i}" for i in range(10)] + [f"walk-left-f{i}" for i in range(10)]
TURN_FRAMES = [f"turn-{i}" for i in range(6)]
OTHER_FRAMES = (
    [f"pickup-{i}" for i in range(12)]
    + [f"air-{i}" for i in range(12)]
    + [f"air-r-{i}" for i in range(12)]
    + [f"air-l-{i}" for i in range(12)]
    + [f"mad-{i}" for i in range(12)]
    + ["idle-right", "idle-left"]
    + [f"fall-{i}" for i in range(12)]
)
PEEK_FRAMES = [f"stable-{i}" for i in range(10)] + [f"pop-{i}" for i in range(12)]
AIR_FRAMES = (
    [f"air-{i}" for i in range(12)]
    + [f"air-r-{i}" for i in range(12)]
    + [f"air-l-{i}" for i in range(12)]
)
ALL_PIP = WALK_FRAMES + TURN_FRAMES + OTHER_FRAMES + PEEK_FRAMES


def corner_bg(im: Image.Image) -> tuple[int, int, int]:
    rgb = im.convert("RGB")
    w, h = rgb.size
    pts = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    s = [rgb.getpixel(p) for p in pts]
    return (sorted(c[0] for c in s)[2], sorted(c[1] for c in s)[2], sorted(c[2] for c in s)[2])


def _bg_mask(arr: np.ndarray, bg: tuple[int, int, int], tol: int = 55) -> np.ndarray:
    rgb = arr[:, :, :3].astype(np.int16)
    a = arr[:, :, 3]
    r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
    gray = (np.abs(r - g) <= 25) & (np.abs(g - b) <= 25)
    avg = (r + g + b) // 3
    checker = gray & (((avg >= 105) & (avg <= 175)) | ((avg >= 185) & (avg <= 255)))
    corner = (
        (np.abs(r - bg[0]) <= tol)
        & (np.abs(g - bg[1]) <= tol)
        & (np.abs(b - bg[2]) <= tol)
    )
    return checker | corner | (a < 8)


def _dilate(mask: np.ndarray, iterations: int = 1) -> np.ndarray:
    out = mask
    for _ in range(iterations):
        pad = np.pad(out, 1, mode="constant", constant_values=False)
        out = (
            pad[:-2, :-2] | pad[:-2, 1:-1] | pad[:-2, 2:]
            | pad[1:-1, :-2] | pad[1:-1, 1:-1] | pad[1:-1, 2:]
            | pad[2:, :-2] | pad[2:, 1:-1] | pad[2:, 2:]
        )
    return out


def _flood_from_edges(mask: np.ndarray) -> np.ndarray:
    h, w = mask.shape
    seen = np.zeros((h, w), dtype=bool)
    q: deque[tuple[int, int]] = deque()
    for x in range(w):
        q.append((x, 0))
        q.append((x, h - 1))
    for y in range(h):
        q.append((0, y))
        q.append((w - 1, y))
    while q:
        x, y = q.popleft()
        if seen[y, x] or not mask[y, x]:
            continue
        seen[y, x] = True
        if x:
            q.append((x - 1, y))
        if x + 1 < w:
            q.append((x + 1, y))
        if y:
            q.append((x, y - 1))
        if y + 1 < h:
            q.append((x, y + 1))
    return seen


def _to_image(arr: np.ndarray) -> Image.Image:
    out = arr.copy()
    a = out[:, :, 3]
    fringe = (a > 0) & (a < 30)
    bg_like = _bg_mask(out, corner_bg(Image.fromarray(out, "RGBA")))
    out[fringe | (bg_like & (a < 180))] = [0, 0, 0, 0]
    solid = a > 235
    out[solid, 3] = 255
    return Image.fromarray(out, "RGBA")


def flood_transparent(im: Image.Image, tol: int = 36) -> Image.Image:
    arr = np.array(im.convert("RGBA"))
    bg = corner_bg(im)
    mask = _bg_mask(arr, bg, tol) | (arr[:, :, 3] < 8)
    clear = _flood_from_edges(mask)
    arr[clear] = [0, 0, 0, 0]
    return Image.fromarray(arr, "RGBA")


def flood_interior(im: Image.Image) -> Image.Image:
    """Expand transparency into checkerboard/bg pockets (e.g. under arms)."""
    arr = np.array(im.convert("RGBA"))
    bg = corner_bg(im)
    for _ in range(5):
        transparent = arr[:, :, 3] < 20
        dilated = _dilate(transparent)
        bg_like = _bg_mask(arr, bg)
        fringe = (arr[:, :, 3] > 0) & (arr[:, :, 3] < 200)
        clear = dilated & (bg_like | fringe)
        arr[clear] = [0, 0, 0, 0]
    return Image.fromarray(arr, "RGBA")


def erode_halo(im: Image.Image) -> Image.Image:
    """Remove semi-transparent fringe and near-bg pixels hugging transparency."""
    arr = np.array(im.convert("RGBA"))
    bg = corner_bg(im)
    for _ in range(3):
        transparent = arr[:, :, 3] < 35
        dilated = _dilate(transparent)
        bg_like = _bg_mask(arr, bg)
        fringe = (arr[:, :, 3] > 0) & (arr[:, :, 3] < 50)
        weak = (arr[:, :, 3] < 230) & bg_like
        clear = dilated & (fringe | weak)
        arr[clear] = [0, 0, 0, 0]
    return _to_image(arr)


def fit_to_canvas(im: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Resize generated art to target canvas, preserving Pip framing."""
    if im.size == size:
        return im
    src = im.convert("RGBA")
    alpha = src.split()[3]
    bbox = alpha.getbbox()
    if not bbox:
        return Image.new("RGBA", size, (0, 0, 0, 0))
    cropped = src.crop(bbox)
    tw, th = size
    cw, ch = cropped.size
    scale = min(tw / cw, th / ch)
    nw, nh = max(1, int(cw * scale)), max(1, int(ch * scale))
    resized = cropped.resize((nw, nh), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    ox, oy = (tw - nw) // 2, (th - nh) // 2
    canvas.paste(resized, (ox, oy), resized)
    return canvas


def clean_frame(path: Path, out: Path | None = None, target_size: tuple[int, int] | None = None) -> Image.Image:
    im = Image.open(path)
    if target_size and im.size != target_size:
        im = fit_to_canvas(im, target_size)
    im = flood_transparent(im)
    im = flood_interior(im)
    im = erode_halo(im)
    im = flood_interior(im)
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        im.save(out)
    return im


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
            time.sleep(8 * (attempt + 1))
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
            raise RuntimeError(job)
        time.sleep(5)
    raise TimeoutError(job_id)


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def upload(path: Path) -> str:
    out = run_hf(["upload", "create", str(path), "--json"], timeout=120)
    return json.loads(out)["id"]


def parse_job_id(payload: str) -> str:
    data = json.loads(payload)
    if isinstance(data, list):
        return data[0] if isinstance(data[0], str) else data[0]["id"]
    return data["id"]


def remove_background_api(path: Path, out_path: Path, retries: int = 3) -> bool:
    """Higgsfield background remover. Returns False if all attempts fail."""
    last_err = ""
    for attempt in range(retries):
        try:
            media_id = upload(path)
            out = run_hf([
                "generate", "create", "image_background_remover",
                "--image", media_id,
                "--json",
            ], timeout=180)
            job = wait_job(parse_job_id(out), timeout_s=900)
            download(job["result_url"], out_path)
            return True
        except Exception as exc:
            last_err = str(exc)
            print(f"[bg-remove] attempt {attempt + 1}/{retries} failed: {last_err}")
            if attempt + 1 < retries:
                time.sleep(12 * (attempt + 1))
    print(f"[bg-remove] giving up, using local clean only: {last_err}")
    shutil.copy2(path, out_path)
    return False


def archive_rocky_assets() -> None:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest = ARCHIVE / stamp
    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    for path in sorted(ASSETS.glob("rocky-*.png")):
        shutil.copy2(path, dest / path.name)
        count += 1
    print(f"[archive] {count} frames -> {dest}")


def restyle_prompt() -> str:
    cfg = load_skin_config()
    style = cfg.get("style_prompt", "Rocky stone golem from Project Hail Mary.")
    return f"Restyle this Pip mascot sprite as Rocky. {style.strip()} {RESTYLE_SUFFIX}"


def restyle_pip_frame(pip_name: str, force: bool = False, skip_bg_api: bool = False) -> Path:
    src = ASSETS / f"{pip_name}.png"
    if not src.exists():
        raise FileNotFoundError(src)
    out = GEN / f"rocky-{pip_name}.png"
    if out.exists() and not force:
        print(f"[skip] {pip_name}")
        return out

    if not STYLE_REF.exists():
        raise FileNotFoundError(f"missing style guide: {STYLE_REF}")

    refs = [str(STYLE_REF)]
    # After idle-right exists, add it as a pose-matched style anchor
    anchor = ASSETS / "rocky-idle-right.png"
    if anchor.exists() and pip_name != "idle-right":
        refs.append(str(anchor))

    args = [
        "generate", "create", "nano_banana_2",
        "--prompt", restyle_prompt(),
        "--image", str(src),
        *sum([["--image", r] for r in refs], []),
        "--aspect_ratio", "1:1",
        "--resolution", "2k",
        "--wait",
        "--json",
    ]
    print(f"[restyle] {pip_name} …")
    job = parse_job(run_hf(args))
    raw = GEN / "raw" / f"rocky-{pip_name}.png"
    download(job["result_url"], raw)
    target = Image.open(src).size

    nobg = GEN / "nobg" / f"rocky-{pip_name}.png"
    if skip_bg_api:
        shutil.copy2(raw, nobg)
    else:
        print(f"[bg-remove] {pip_name} …")
        remove_background_api(raw, nobg)

    cleaned = clean_frame(nobg, target_size=target)
    cleaned.save(ASSETS / f"rocky-{pip_name}.png")
    cleaned.save(out)
    print(f"[done] rocky-{pip_name}")
    return out


def clean_peek() -> None:
    for name in PEEK_FRAMES:
        rocky = ASSETS / f"rocky-{name}.png"
        if not rocky.exists():
            print(f"[warn] missing {rocky}")
            continue
        clean_frame(rocky, GEN / "clean" / f"rocky-{name}.png")
        im = Image.open(GEN / "clean" / f"rocky-{name}.png")
        im.save(rocky)
        print(f"[clean] rocky-{name}")


def clean_all(force_resize: bool = False) -> None:
    """Clean alpha on every rocky-* asset (no API)."""
    for path in sorted(ASSETS.glob("rocky-*.png")):
        pip_name = path.stem.removeprefix("rocky-")
        pip_src = ASSETS / f"{pip_name}.png"
        target = Image.open(pip_src).size if pip_src.exists() else None
        if force_resize and target and path.stat().st_size > 0:
            clean_frame(path, GEN / "clean" / path.name, target_size=target)
        else:
            clean_frame(path, GEN / "clean" / path.name)
        im = Image.open(GEN / "clean" / path.name)
        im.save(path)
        print(f"[clean] {path.name}")


def restyle_walk(force: bool = False) -> None:
    for name in WALK_FRAMES:
        restyle_pip_frame(name, force=force)


def restyle_air(force: bool = False) -> None:
    for name in AIR_FRAMES:
        restyle_pip_frame(name, force=force)


def restyle_all_other(force: bool = False) -> None:
    for name in TURN_FRAMES + OTHER_FRAMES + PEEK_FRAMES:
        restyle_pip_frame(name, force=force)


def restyle_everything(force: bool = False) -> None:
    """Restyle all 122 frames from Pip sources + style guide."""
    restyle_pip_frame("idle-right", force=force)
    for name in ALL_PIP:
        if name == "idle-right":
            continue
        restyle_pip_frame(name, force=force)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "command",
        choices=[
            "archive", "clean-peek", "clean-all", "restyle",
            "restyle-walk", "restyle-air", "restyle-all", "start", "all",
        ],
    )
    parser.add_argument("frame", nargs="?", help="pip frame basename e.g. walk-right-f0")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--skip-bg-api", action="store_true", help="local clean only (no Higgsfield bg remover)")
    args = parser.parse_args()

    if args.command == "archive":
        archive_rocky_assets()
        return

    if args.command == "clean-peek":
        clean_peek()
        return

    if args.command == "clean-all":
        clean_all(force_resize=True)
        return

    if args.command == "restyle":
        if not args.frame:
            print("usage: restyle <pip-frame>", file=sys.stderr)
            sys.exit(1)
        restyle_pip_frame(args.frame, force=args.force, skip_bg_api=args.skip_bg_api)
        return

    if args.command == "start":
        archive_rocky_assets()
        restyle_everything(force=True)
        clean_all(force_resize=True)
        return

    if args.command in ("restyle-walk", "all"):
        restyle_walk(force=args.force)

    if args.command == "restyle-air":
        restyle_air(force=args.force)
        return

    if args.command in ("restyle-all", "all"):
        restyle_all_other(force=args.force)

    if args.command == "all":
        clean_all(force_resize=True)


if __name__ == "__main__":
    main()