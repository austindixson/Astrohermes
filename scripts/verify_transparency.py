#!/usr/bin/env python3
"""Verify Rocky sprite transparency — fail if frames have baked backgrounds."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Pip" / "Assets"

HALO_THRESHOLD = 500
MIN_TRANSPARENT_PCT = 60.0
PEEK_MIN_TRANSPARENT_PCT = 55.0
PEEK_PREFIXES = ("stable-", "pop-")


def halo_opaque_count(im: Image.Image) -> int:
    px = im.load()
    w, h = im.size
    count = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 180 and abs(r - g) < 25 and abs(g - b) < 25 and (r + g + b) // 3 > 170:
                count += 1
    return count


def transparent_pct(im: Image.Image) -> float:
    px = im.load()
    w, h = im.size
    total = w * h
    trans = sum(1 for y in range(h) for x in range(w) if px[x, y][3] == 0)
    return trans / total * 100.0


def check_frame(path: Path) -> tuple[bool, str]:
    im = Image.open(path).convert("RGBA")
    pip_name = path.stem.removeprefix("rocky-")
    halo = halo_opaque_count(im)
    trans = transparent_pct(im)

    is_peek = any(pip_name.startswith(p) for p in PEEK_PREFIXES)
    min_trans = PEEK_MIN_TRANSPARENT_PCT if is_peek else MIN_TRANSPARENT_PCT

    # Match or beat the Pip source frame transparency when available
    pip_src = ASSETS / f"{pip_name}.png"
    if pip_src.exists():
        pip_trans = transparent_pct(Image.open(pip_src).convert("RGBA"))
        min_trans = min(min_trans, pip_trans - 3.0)

    issues: list[str] = []
    if halo >= HALO_THRESHOLD:
        issues.append(f"halo_opaque={halo} (max {HALO_THRESHOLD - 1})")
    if trans < min_trans:
        issues.append(f"transparent={trans:.1f}% (min {min_trans:.1f}%)")

    if issues:
        return False, f"{path.name}: " + ", ".join(issues)
    return True, f"OK {path.name}: halo={halo} trans={trans:.1f}%"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frame", help="single frame e.g. rocky-walk-right-f0")
    parser.add_argument("--assets", type=Path, default=ASSETS)
    args = parser.parse_args()

    if args.frame:
        paths = [args.assets / (args.frame if args.frame.endswith(".png") else f"{args.frame}.png")]
    else:
        paths = sorted(args.assets.glob("rocky-*.png"))

    if not paths:
        print("no rocky frames found", file=sys.stderr)
        sys.exit(1)

    ok_count = 0
    failures: list[str] = []
    for path in paths:
        if not path.exists():
            failures.append(f"MISSING {path.name}")
            continue
        ok, msg = check_frame(path)
        print(msg)
        if ok:
            ok_count += 1
        else:
            failures.append(msg)

    print(f"\n{ok_count}/{len(paths)} passed")
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
