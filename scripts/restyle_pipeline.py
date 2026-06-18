#!/usr/bin/env python3
"""Restyle Pip sprites frame-by-frame — preserves pose, fixes sheet-to-sheet failures.

The old rocky_pipeline regenerated whole sprite sheets from a reference turnaround.
That broke poses, baked in reference-sheet text, and changed the silhouette.

This pipeline instead restyles each shipped Pip/Assets frame individually:
  source frame (exact pose) + optional style ref → restyled frame (same pose)

Usage:
  python scripts/restyle_pipeline.py init mossy --display-name "Mossy"
  python scripts/restyle_pipeline.py test mossy idle-right
  python scripts/restyle_pipeline.py all mossy
  python scripts/restyle_pipeline.py all mossy --frames walk-right-f0,walk-right-f1
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS_DIR = ROOT / "Pip" / "Assets"
ARCHIVE_DIR = ASSETS_DIR / "_archive"

RESTYLE_SUFFIX = (
    "Keep the EXACT same pose, silhouette, proportions, limb positions, framing, "
    "and camera angle as the source sprite. Apply only the new surface appearance "
    "from the style reference — do NOT change the bipedal blob body plan. "
    "Do not add text, labels, watermarks, title cards, or backgrounds. "
    "Output a single isolated game sprite on a fully transparent background "
    "with clean alpha edges."
)

# All shipped Pip frame basenames (excludes rocky/archive).
SOURCE_FRAMES: tuple[str, ...] = (
    *(f"walk-right-f{i}" for i in range(10)),
    *(f"walk-left-f{i}" for i in range(10)),
    *(f"turn-{i}" for i in range(6)),
    *(f"pickup-{i}" for i in range(12)),
    *(f"air-{i}" for i in range(12)),
    *(f"air-r-{i}" for i in range(12)),
    *(f"air-l-{i}" for i in range(12)),
    *(f"mad-{i}" for i in range(12)),
    "idle-right", "idle-left",
    *(f"stable-{i}" for i in range(10)),
    *(f"pop-{i}" for i in range(12)),
    *(f"fall-{i}" for i in range(12)),
)


@dataclass
class SkinConfig:
    name: str
    display_name: str
    asset_prefix: str
    style_prompt: str
    style_ref: str | None = None

    @property
    def skin_dir(self) -> Path:
        return ROOT / "skins" / self.name

    @property
    def gen_dir(self) -> Path:
        return ROOT / "build" / f"{self.name}-restyle"

    def save(self) -> None:
        self.skin_dir.mkdir(parents=True, exist_ok=True)
        (self.skin_dir / "config.json").write_text(json.dumps({
            "name": self.name,
            "display_name": self.display_name,
            "asset_prefix": self.asset_prefix,
            "style_prompt": self.style_prompt,
            "style_ref": self.style_ref,
            "mode": "restyle",
        }, indent=2) + "\n")

    @classmethod
    def load(cls, name: str) -> SkinConfig:
        path = ROOT / "skins" / name / "config.json"
        if not path.exists():
            raise FileNotFoundError(f"skin not found: {path}")
        data = json.loads(path.read_text())
        style_ref = data.get("style_ref") or data.get("reference_sheet")
        return cls(
            name=data["name"],
            display_name=data["display_name"],
            asset_prefix=data["asset_prefix"],
            style_prompt=data.get("style_prompt") or data.get("prompt", ""),
            style_ref=style_ref,
        )

    def out_name(self, source: str) -> str:
        return f"{self.asset_prefix}-{source}"

    def full_prompt(self, source: str) -> str:
        return (
            f"Restyle this game sprite as {self.display_name}. "
            f"{self.style_prompt.strip()} {RESTYLE_SUFFIX}"
        )


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


def parse_job(payload: str) -> dict:
    data = json.loads(payload)
    if isinstance(data, list):
        job_id = data[0] if isinstance(data[0], str) else data[0]["id"]
        out = run_hf(["generate", "get", job_id, "--json"], timeout=60)
        return json.loads(out)
    if data.get("status") == "completed":
        return data
    if "result_url" in data:
        return data
    return wait_job(data["id"])


def wait_job(job_id: str, timeout_s: int = 600) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        out = run_hf(["generate", "get", job_id, "--json"], timeout=60)
        job = json.loads(out)
        if job.get("status") == "completed":
            return job
        if job.get("status") in {"failed", "cancelled", "error"}:
            raise RuntimeError(f"job {job_id} failed: {job}")
        time.sleep(4)
    raise TimeoutError(f"job {job_id} timed out")


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def restyle_frame(skin: SkinConfig, source: str, force: bool = False) -> Path:
    src_path = ASSETS_DIR / f"{source}.png"
    if not src_path.exists():
        raise FileNotFoundError(f"missing source frame: {src_path}")

    out_path = skin.gen_dir / f"{source}.png"
    if out_path.exists() and not force:
        print(f"[skip] {source}")
        return out_path

    args = [
        "generate", "create", "nano_banana_2",
        "--prompt", skin.full_prompt(source),
        "--image", str(src_path),
        "--aspect_ratio", "1:1",
        "--resolution", "2k",
        "--wait",
        "--json",
    ]
    if skin.style_ref:
        ref = skin.skin_dir / skin.style_ref
        if ref.exists():
            args.extend(["--image", str(ref)])

    print(f"[restyle] {skin.name}/{source} …")
    job = parse_job(run_hf(args, timeout=900))
    download(job["result_url"], out_path)
    print(f"[done] {source} -> {out_path}")
    return out_path


def install_frames(skin: SkinConfig, sources: list[str]) -> None:
    for source in sources:
        gen = skin.gen_dir / f"{source}.png"
        if not gen.exists():
            raise FileNotFoundError(f"generate first: {gen}")
        dest = ASSETS_DIR / f"{skin.out_name(source)}.png"
        shutil.copy2(gen, dest)
    print(f"[install] {len(sources)} frames -> {ASSETS_DIR}")


def cmd_init(name: str, display: str | None, prefix: str | None, prompt: str | None) -> None:
    skin = SkinConfig(
        name=name,
        display_name=display or name.title(),
        asset_prefix=prefix or name,
        style_prompt=prompt or f"A themed reskin of {display or name.title()}.",
    )
    skin.save()
    print(f"Created skins/{name}/config.json")
    print(f"Test: python scripts/restyle_pipeline.py test {name} idle-right")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init")
    p_init.add_argument("name")
    p_init.add_argument("--display-name")
    p_init.add_argument("--prefix")
    p_init.add_argument("--prompt", help="style description (colors, materials, theme)")

    for cmd in ("test", "generate", "install", "all"):
        p = sub.add_parser(cmd)
        p.add_argument("name")
        p.add_argument("frame", nargs="?", help="single frame for test")
        p.add_argument("--frames", help="comma-separated frame basenames")
        p.add_argument("--force", action="store_true")

    args = parser.parse_args()

    if args.command == "init":
        cmd_init(args.name, args.display_name, args.prefix, args.prompt)
        return

    skin = SkinConfig.load(args.name)
    if args.frames:
        frames = [f.strip() for f in args.frames.split(",") if f.strip()]
    elif args.frame:
        frames = [args.frame]
    elif args.command == "test":
        frames = ["idle-right"]
    else:
        frames = list(SOURCE_FRAMES)

    for f in frames:
        if f not in SOURCE_FRAMES:
            print(f"unknown frame: {f}", file=sys.stderr)
            sys.exit(1)

    if args.command in ("test", "generate", "all"):
        for f in frames:
            restyle_frame(skin, f, force=args.force)

    if args.command in ("install", "all"):
        install_frames(skin, frames)


if __name__ == "__main__":
    main()