#!/bin/bash
# Full Rocky sprite regeneration from Pip poses + style guide.
set -euo pipefail
cd "$(dirname "$0")/.."
LOG=build/rocky-fix/batch-regen.log
mkdir -p build/rocky-fix
exec > >(tee -a "$LOG") 2>&1

echo "=== Rocky batch regen $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
python3 scripts/rocky_fix_pipeline.py archive
python3 scripts/rocky_fix_pipeline.py restyle-walk --force
python3 scripts/rocky_fix_pipeline.py restyle-air --force
python3 scripts/rocky_fix_pipeline.py restyle-all --force
python3 scripts/rocky_fix_pipeline.py clean-all
python3 scripts/verify_transparency.py
echo "=== Done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
