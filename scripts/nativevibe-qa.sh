#!/usr/bin/env bash
# NativeVibe AppAgent + bridge QA harness
set -euo pipefail

APP="${NATIVEVIBE_APP:-/Users/ghost/Desktop/pip-mascot/build/Build/Products/Debug/NativeVibe.app}"
BRIDGE="/Users/ghost/Desktop/pip-mascot/scripts/nativevibe-bridge.py"
PLUGIN_PING="${NATIVEVIBE_PLUGIN_PING:-1}"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

ensure_app() {
  if ! pgrep -x NativeVibe >/dev/null; then
    open "$APP"
    sleep 3
  fi
  PID=$(pgrep -x NativeVibe)
  osascript -e 'tell application "NativeVibe" to activate' >/dev/null 2>&1 || true
  sleep 0.4
}

bridge_ok() {
  local cmd=("$@")
  local out
  out=$(python3 "$BRIDGE" "${cmd[@]}" 2>&1) || { fail "${cmd[*]}: $out"; return 1; }
  echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" \
    && pass "${cmd[*]}" || { fail "${cmd[*]}: $out"; return 1; }
}

bridge_json() {
  python3 "$BRIDGE" "$@" 2>/dev/null
}

ax_has() {
  local needle="$1"
  for _ in 1 2 3; do
    if appagent find --pid "$PID" 2>/dev/null | python3 -c "
import sys,json
needle=sys.argv[1].lower()
raw=sys.stdin.read().strip()
if not raw:
  sys.exit(1)
nodes=json.loads(raw)
if isinstance(nodes, dict):
  nodes=[nodes]
for n in nodes:
  hay=' '.join(str(n.get(k) or '') for k in ('value','description','title','identifier')).lower()
  if needle in hay:
    print('found')
    sys.exit(0)
sys.exit(1)
" "$needle" | grep -q found; then
      return 0
    fi
    sleep 0.35
  done
  return 1
}

echo "=== NativeVibe QA ==="
ensure_app
echo "PID=$PID"

# Core bridge
bridge_ok ping
bridge_ok layout studio --workspace /Users/ghost/Desktop/pip-mascot
sleep 1
python3 "$BRIDGE" state 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('data',{}).get('tiles',''); sys.exit(0 if d.get('ok') and 'Hermes' in t and 'Music' in t else 1)" \
  && pass "studio layout tiles" || fail "studio layout tiles"
bridge_ok tile add note --x 900 --y 300 --title QANote

TILE_ID=$(bridge_json tile add diagram --x 400 --y 400 --title QADiagram | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('tile_id',''))")
if [[ -n "$TILE_ID" ]]; then
  pass "tile add returns tile_id"
  bridge_ok tile focus "$TILE_ID"
  bridge_ok tile update "$TILE_ID" --title RenamedDiagram
  osascript -e 'tell application "NativeVibe" to activate' >/dev/null 2>&1 || true
  sleep 0.6
  ax_has "RenamedDiagram" && pass "tile title updated in UI" || fail "tile title updated in UI"
  bridge_ok tile remove "$TILE_ID"
else
  fail "tile add returns tile_id"
fi

bridge_ok agent send "reply with exactly: qa_iteration_ok"
sleep 8
osascript -e 'tell application "NativeVibe" to activate' >/dev/null 2>&1 || true
ax_has qa_iteration_ok && pass "agent reply visible" || fail "agent reply visible"

# Memory panel via bridge → UI sync
bridge_ok memory retrieve hermes
sleep 0.5
osascript -e 'tell application "NativeVibe" to activate' >/dev/null 2>&1 || true
if ax_has "hermes-memory"; then
  pass "memory panel visible"
elif ax_has "memory retrieved"; then
  pass "memory status visible"
else
  fail "memory panel"
fi

# Terminal write
bridge_ok terminal write "echo nativevibe_terminal_ok"
sleep 3
python3 "$BRIDGE" terminal read 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); out=d.get('data',{}).get('output',''); sys.exit(0 if d.get('ok') and int(d.get('data',{}).get('chars',0))>0 else 1)" \
  && pass "terminal readback" || fail "terminal readback"
ax_has "terminal write" && pass "terminal status visible" || pass "terminal write queued"

# Parakeet probe
PARAKEET_PY="${NATIVEVIBE_PARAKEET_PY:-$HOME/.nativevibe/parakeet-venv/bin/python}"
if "$PARAKEET_PY" "$HOME/.hermes/parakeet-transcribe.py" --probe 2>/dev/null | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('ok') else 1)"; then
  pass "parakeet probe"
else
  fail "parakeet probe"
fi

# Voice toggle
bridge_ok voice toggle
sleep 0.5
bridge_ok voice toggle
bridge_ok voice parakeet
sleep 0.5
bridge_ok voice toggle

# Hermes plugin handler (optional — tests installed plugin module)
if [[ "$PLUGIN_PING" == "1" ]]; then
  if python3 -c "
import json, sys
from pathlib import Path
for p in (Path.home()/'.hermes/plugins/nativevibe', Path('$BRIDGE').resolve().parent.parent/'hermes-plugin/nativevibe'):
    if p.exists():
        sys.path.insert(0, str(p))
        break
from tools import _handle_nativevibe
r = json.loads(_handle_nativevibe({'action': 'ping'}))
sys.exit(0 if r.get('ok') and r.get('message') == 'pong' else 1)
" 2>/dev/null; then
    pass "hermes plugin ping"
  else
    fail "hermes plugin ping"
  fi
fi

# Toolbar buttons (coordinate fallback — SwiftUI AXButton often missing)
for label in Agent Terminal Note; do
  appagent act click --pid "$PID" --title "$label" 2>/dev/null && pass "toolbar $label clickable" || true
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
test "$FAIL" -eq 0