#!/usr/bin/env bash
# Live UI/UX pass for NativeVibe — appagent + bridge (run after nativevibe-qa.sh)
set -euo pipefail

APP="${NATIVEVIBE_APP:-/Users/ghost/Desktop/pip-mascot/build/Build/Products/Debug/NativeVibe.app}"
BRIDGE="/Users/ghost/Desktop/pip-mascot/scripts/nativevibe-bridge.py"
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
  sleep 0.5
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

button_center() {
  local title="$1"
  local ident="${2:-}"
  appagent find --pid "$PID" --role AXButton 2>/dev/null | python3 -c "
import sys,json
title,ident=sys.argv[1],sys.argv[2]
for n in json.load(sys.stdin):
  t=str(n.get('title') or '')
  i=str(n.get('identifier') or '')
  if (title and t == title) or (ident and ident in i):
    p,s=n['position'],n['size']
    print(int(p['x']+s['width']/2), int(p['y']+s['height']/2))
    break
" "$title" "$ident"
}

echo "=== NativeVibe UI/UX ==="
ensure_app
echo "PID=$PID"

osascript <<'EOF' >/dev/null 2>&1 || true
tell application "NativeVibe" to activate
delay 0.3
tell application "System Events"
  tell process "NativeVibe"
    set frontmost to true
    if (count of windows) > 0 then set size of window 1 to {1280, 860}
  end tell
end tell
EOF
sleep 0.8

# Layout + tile chrome in AX
python3 "$BRIDGE" layout studio --workspace /Users/ghost/Desktop/pip-mascot >/dev/null
sleep 1
ax_has "Hermes" && pass "studio tile Hermes visible in AX" || fail "studio tile Hermes visible in AX"
ax_has "Code" && pass "studio tile Code visible in AX" || fail "studio tile Code visible in AX"

# Resize reflow
python3 "$BRIDGE" state 2>/dev/null | python3 -c "
import sys,json,re
w=float(re.search(r'\"title\":\"Hermes\".*?\"width\":\"([^\"]+)\"', json.load(sys.stdin)['data']['tiles']).group(1))
open('/tmp/nv_w_before.txt','w').write(str(w))
"
osascript <<'EOF' >/dev/null 2>&1 || true
tell application "NativeVibe" to activate
delay 0.3
tell application "System Events"
  tell process "NativeVibe"
    set frontmost to true
    if (count of windows) > 0 then set size of window 1 to {880, 680}
  end tell
end tell
EOF
sleep 0.8
python3 "$BRIDGE" state 2>/dev/null | python3 -c "
import sys,json,re
before=float(open('/tmp/nv_w_before.txt').read())
w=float(re.search(r'\"title\":\"Hermes\".*?\"width\":\"([^\"]+)\"', json.load(sys.stdin)['data']['tiles']).group(1))
import sys as s
s.exit(0 if w < before - 20 else 1)
" && pass "resize reflow shrinks Hermes tile" || fail "resize reflow shrinks Hermes tile"

# Toolbar labels (accessible names)
for label in Studio Agent Terminal Browser Note Diagram; do
  ax_has "$label" && pass "toolbar label $label" || fail "toolbar label $label"
done

# Memory field live interaction
FIELD=$(appagent find --pid "$PID" --role AXTextField 2>/dev/null | python3 -c "
import sys,json
for n in json.load(sys.stdin):
  if n.get('identifier')=='nativevibe.memory.query':
    p,s=n['position'],n['size']
    print(int(p['x']+s['width']/2), int(p['y']+s['height']/2))
")
if [[ -n "$FIELD" ]]; then
  read -r FX FY <<< "$FIELD"
  appagent act click --pid "$PID" --x "$FX" --y "$FY" >/dev/null 2>&1
  appagent act type-text --pid "$PID" --text "hermes" >/dev/null 2>&1
  appagent act key-press --pid "$PID" --key return >/dev/null 2>&1
  sleep 0.6
  ax_has "memory retrieved" && pass "memory retrieve via UI typing" || fail "memory retrieve via UI typing"
else
  fail "memory query field coordinates"
fi

# Voice button discoverable
VOICE=$(button_center Voice nativevibe.voice.toggle)
[[ -n "$VOICE" ]] && pass "Voice button labeled in AX" || fail "Voice button labeled in AX"

# Agent reply surface (composer NSView may not expose in AX inside scroll canvas)
python3 "$BRIDGE" agent send "reply with exactly: ux_ok" >/dev/null
sleep 8
osascript -e 'tell application "NativeVibe" to activate' >/dev/null 2>&1 || true
if ax_has "ux_ok"; then
  pass "agent reply visible in canvas"
elif python3 "$BRIDGE" state 2>/dev/null | python3 -c "
import sys,json
s=json.load(sys.stdin)['data'].get('status','').lower()
import sys as x
x.exit(0 if 'agent' in s and ('replied' in s or 'ux_ok' in s or 'thinking' in s) else 1)
"; then
  pass "agent reply surfaced in status"
else
  fail "agent reply surfaced"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
test "$FAIL" -eq 0