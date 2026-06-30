#!/usr/bin/env bash
# Install MLX Parakeet STT venv for NativeVibe voice control.
set -euo pipefail

VENV="${NATIVEVIBE_PARAKEET_VENV:-$HOME/.nativevibe/parakeet-venv}"
MODEL="${PARAKEET_MODEL:-mlx-community/parakeet-tdt-0.6b-v3}"

echo "=== NativeVibe Parakeet setup ==="
echo "venv: $VENV"

if ! command -v ffmpeg >/dev/null; then
  echo "Installing ffmpeg via Homebrew..."
  brew install ffmpeg
fi

PYTHON=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null; then
    ver=$("$candidate" -c "import sys; print(sys.version_info[:2])" 2>/dev/null || echo "(0,0)")
    if "$candidate" -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
      PYTHON="$candidate"
      break
    fi
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "Need Python 3.10+ (brew install python@3.12)" >&2
  exit 1
fi
echo "python: $($PYTHON --version)"

if [[ ! -d "$VENV" ]]; then
  "$PYTHON" -m venv "$VENV"
fi

"$VENV/bin/pip" install -U pip wheel
"$VENV/bin/pip" install -U parakeet-mlx

echo "Probing parakeet-mlx import..."
"$VENV/bin/python" -c "from parakeet_mlx import from_pretrained; print('import ok')"

echo "Prefetching model weights ($MODEL) — first run may take a minute..."
"$VENV/bin/python" -c "
from parakeet_mlx import from_pretrained
from_pretrained('$MODEL')
print('model cached')
"

SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/parakeet-transcribe.py"
DEST="$HOME/.hermes/parakeet-transcribe.py"
mkdir -p "$(dirname "$DEST")"
cp "$SCRIPT_SRC" "$DEST"
chmod 755 "$DEST"

echo ""
echo "Parakeet ready."
echo "  python: $VENV/bin/python"
echo "  script: $DEST"
echo "  probe:  $DEST --probe"