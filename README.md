# Pip 🐾

A cute, transparent desktop mascot for macOS that **walks along the bottom edge of your
screen** with a real walk cycle, and changes mood based on your **live Claude Code
usage** — pulled from your logged-in Claude session. No API key, no cloud account, no
billing, no third-party dependencies. Everything stays on your machine.

Pip's goal is to help you **maximize your 5-hour window without wasting quota at reset**.
He doesn't panic as the reset approaches — he gets antsy when you're *under*-using your
quota, and only worries when you're about to hit the cap.

---

## ⚡️ One-shot setup (recommended)

**Copy the block below and paste it into [Claude Code](https://claude.com/claude-code).**
It will clone, build, install, and launch Pip for you — and fix anything that goes wrong
along the way.

> ```
> Set up Pip, a macOS desktop mascot, on my Mac from
> https://github.com/TenzinDhonyoe/pip-mascot
>
> Do all of this for me, and troubleshoot anything that fails:
> 1. Clone the repo into ~/Developer (create it if needed) and cd into it.
> 2. Confirm I have full Xcode (not just the command-line tools). If `xcodebuild
>    -version` fails or points at CommandLineTools, tell me to install Xcode from the
>    Mac App Store, then run `sudo xcode-select -s /Applications/Xcode.app` and accept
>    the license with `sudo xcodebuild -license accept`.
> 3. Build the release app:
>    xcodebuild -project Pip.xcodeproj -scheme Pip -configuration Release \
>      -derivedDataPath build build
> 4. Copy build/Build/Products/Release/Pip.app to /Applications, replacing any old copy.
> 5. Remove the quarantine flag so Gatekeeper won't block it:
>    xattr -dr com.apple.quarantine /Applications/Pip.app
> 6. Launch it: open /Applications/Pip.app
> 7. Tell me to (a) click "Always Allow" if macOS shows a Keychain prompt — that's Pip
>    reading my Claude usage — and (b) make sure I'm logged into Claude Code so Pip has
>    data. Then confirm Pip is walking along the bottom of my screen with a 🐾 in my
>    menu bar.
> ```

That's it. Pip will be strolling at the bottom of your screen within a couple of minutes.

> **No Xcode installed?** Full Xcode is a large download. If you'd rather skip it, grab
> the prebuilt app from the [**Releases**](https://github.com/TenzinDhonyoe/pip-mascot/releases/latest)
> page (`Pip.app.zip`), unzip it, drag `Pip.app` to **Applications**, then in Terminal
> run `xattr -dr com.apple.quarantine /Applications/Pip.app` and double-click it.

---

## 🛠️ Manual setup

Requires **macOS 14 (Sonoma) or later** and **Xcode 15+** (Apple Silicon or Intel).

```sh
git clone https://github.com/TenzinDhonyoe/pip-mascot.git
cd pip-mascot
open Pip.xcodeproj          # then press ⌘R in Xcode
```

…or entirely from the command line:

```sh
xcodebuild -project Pip.xcodeproj -scheme Pip -configuration Release \
  -derivedDataPath build build
cp -R build/Build/Products/Release/Pip.app /Applications/
xattr -dr com.apple.quarantine /Applications/Pip.app   # let Gatekeeper run it
open /Applications/Pip.app
```

The app is ad-hoc signed ("Sign to Run Locally") — **no Apple Developer account, team,
or provisioning profile needed**. It's an agent app (`LSUIElement`): **no Dock icon, no
app menu**. You'll see Pip strolling at the bottom of your screen and a 🐾 item in the
menu bar.

### First-run checklist

1. **Log into Claude Code** (`claude` in any terminal) so Pip has usage data. Until then
   he just naps.
2. **Keychain prompt:** the first time Pip reads your usage, macOS asks for permission to
   read the "Claude Code-credentials" Keychain item. Click **Always Allow** — it won't
   ask again.
3. Optionally pick **Launch at Login** from the 🐾 menu so Pip comes back after a reboot.

---

## What you should see

- Pip strolls left↔right along the bottom edge of the screen at ~34 pt/s (tunable in
  `WalkEngine.swift` — `baseSpeed`), walking at ~1.8–3 footfalls/sec depending on mood
  (`Mood.strideHz`, decoupled from movement speed so step length varies by mood). The
  walk cycle alternates the two leg-swapped stride frames per direction and
  **synthesizes the in-betweens**: through the back quarter of each step the incoming
  frame crossfades in on top of the (still fully opaque) outgoing one, so the legs
  swing through instead of cutting — layered with a per-step bounce arc, contact
  squash / mid-swing stretch, and a continuous body rock.
- At a screen edge he squishes around to face you, swings through the turn, and heads
  back the other way.
- Every 7–18 s he pauses to idle: he turns to the camera (hand-on-chin pose) and
  breathes; antsy mood adds an impatient jiggle and a "!".
- He floats above other windows and **never steals focus**.

## The art

The character lives in real-alpha PNGs in `Pip/Assets/` — multiple stride frames per
walking direction with the legs swapped, so the walk cycle shows actual leg movement,
plus a front-facing idle pose per direction. The original source images are kept
untouched in `mascot/`; the shipped assets were produced from them by stripping the
baked-in checkerboard background (border flood-fill + halo erosion + edge feathering)
and downscaling. All *motion* on top (step bounce, footfall rock, squash-and-stretch)
and all mood *accessories* (sweat drop, z z z, "!", weekly aura, speech bubbles, badge)
are still drawn in code. Swapping the art means replacing the PNGs and, if their
proportions differ, adjusting the per-sprite `footFrac` values in `MascotView.swift`
(the fraction of the image height, from the top, where the feet rest — measured per
frame so the feet stay glued to the ground as the stride frames alternate). If the PNGs
are missing the renderer falls back to a simple drawn blob rather than an empty window.

## Moods (pace delta, not a countdown)

Every poll computes how far ahead/behind the "spend it evenly" line you are:

```
elapsedFrac = (now − windowStart) / 5h
paceDelta   = usedPct/100 − elapsedFrac
```

| Condition | Mood | Look & behavior |
|---|---|---|
| `paceDelta ≤ −0.25` | **ANTSY** | quota going to waste: walks 1.6×, impatient jiggle + "!" when idling, rare bubble "you've got quota to burn — use me!" |
| `−0.25 < paceDelta < 0.10` | **HAPPY** | on pace: calm stroll |
| `paceDelta ≥ 0.10` and `used < 90%` | **FOCUSED** | burning hot but fine: determined quick march |
| `used ≥ 90%` | **WORRIED** | lockout risk: nervous quick shuffle, animated sweat drop |
| no/stale data, or not logged in | **SLEEPY** | sits at the bottom, slumped, and dozes (floating z z z) |

Since the face is baked into the artwork, moods read through **gait, accessories, and
bubbles** rather than facial expressions.

The **weekly (7d) cap** is shown separately and subtly: past ~50% a soft aura glows
behind Pip, drifting from calm teal toward amber and then a warning red past ~80%.
Hover over Pip (or toggle *Show Usage Details*) for a tiny badge with both percentages
and reset countdowns.

## Where the data comes from

Two sources are merged, always preferring the freshest sample. A failed poll never
blanks the UI — the last good snapshot is kept until data ages out (3 h), at which
point Pip just gets sleepy. Malformed JSON, 4xx/5xx, no internet, expired token,
Claude Code never run: all degrade to SLEEPY, never a crash.

### 1. OAuth usage endpoint (primary, always on)

Every 30 s the app calls `GET https://api.anthropic.com/api/oauth/usage` with the
OAuth bearer token from your logged-in Claude Code session.

> ⚠️ **This endpoint is UNDOCUMENTED and unofficial.** It may change shape or
> disappear at any time. The app parses it defensively (probing several key names,
> accepting both epoch-seconds and ISO-8601 reset timestamps) and dumps the first
> successful raw response to `~/Library/Logs/Pip/usage-raw.json` so you can inspect
> the real schema yourself.

**Token source** (tried in order; nothing is ever written):

1. macOS login Keychain item **"Claude Code-credentials"**, read via
   `security find-generic-password -s "Claude Code-credentials" -w`, parsing the JSON
   for the nested access token (e.g. `claudeAiOauth.accessToken`, probed defensively).
   macOS may show a **Keychain permission prompt once** — click *Always Allow* and it
   won't ask again.
2. Fallback file `~/.claude/.credentials.json`, same nested parse.

If neither yields a token, Pip goes sleepy with the tooltip
*"log into Claude Code to wake me up"*.

### 2. Statusline bridge (secondary, official numbers)

Claude Code pipes a JSON payload — including a `rate_limits` object with
`five_hour`/`seven_day` `used_percentage` and `resets_at` (epoch seconds) — to any
configured statusline command. Pick **Install Statusline Bridge…** from Pip's menu to:

- write `~/.claude/pip-statusline.sh`, which appends each payload to
  `~/.claude/usage-mascot.json` (auto-trimmed so it never grows unbounded), and
- point `statusLine` in `~/.claude/settings.json` at it — **your settings.json is
  backed up first** (`settings.json.pip-backup`), and if you already had a statusline
  command it is chained so it keeps rendering.

Pip file-watches `usage-mascot.json` and uses it whenever it's fresher than the last
poll. This source only flows while Claude Code is actually running, which is exactly
when the numbers matter most.

## Menu

Right-click Pip — or use the 🐾 menu-bar item, which always works — for:

- live usage / pace / mood readout
- **Pause/Resume Walking**
- **Click-Through** (on by default; toggle off to drag Pip — drop him on any screen
  and he snaps to its bottom edge)
- **Pin to a Corner** (bottom-left / bottom-right / roam)
- **Show Usage Details** (persistent badge; hovering shows it too)
- **Refresh Usage Now**, **Install Statusline Bridge…**
- **Launch at Login** (`SMAppService`; works best once the app lives in /Applications)
- **Quit Pip**

## Decisions made for you (and how to change them)

- **Click-through is ON by default** per spec — which means right-clicking the mascot
  can't work until you turn it off. That's why the 🐾 **menu-bar item** exists: it's
  the always-reachable escape hatch (and the only deviation from "no chrome at all").
- **Window is 280×230 pt** with the ~140 pt character at the bottom center; the extra
  headroom is canvas for the speech bubble and hover badge. Edge collision uses the
  *character's* width, so his nose touches the screen edge, not the invisible window.
- **Speech bubbles are rare by design** (≥10 min apart, auto-dismiss in 8 s, click to
  dismiss when click-through is off) — a mascot that nags gets deleted.
- **Multi-monitor:** Pip walks the screen he's on and re-pins to whatever screen you
  drop him on. Dock/menu-bar changes re-pin automatically (he tracks `visibleFrame`
  every frame).
- **No sandbox / no hardened runtime**, because the app must run `security`, read
  `~/.claude`, and call the usage endpoint. Everything stays on your machine.
- **Percentages are assumed 0–100** from both sources (that's what both currently
  emit); values are clamped defensively.
- **CPU:** movement runs on a `CADisplayLink` capped at 60 fps; drawn poses are
  quantized and deduplicated, so SwiftUI only redraws ~10–15×/s while walking and
  almost never while idle.

## Renaming the mascot

One constant: `mascotName` in `Pip/Mood.swift`. It flows into the menu, logs
directory name, tooltips, and the generated bridge script. (The bundle/product name
stays "Pip" unless you also rename the target.)

Pip is an original little dino-blob (original artwork, in `mascot/`) — not derived
from anyone's logo or trademark.

## Project layout

```
Pip/
  main.swift               app bootstrap (no storyboard, no SwiftUI App lifecycle)
  AppDelegate.swift        wires store + poller + bridge + controller
  MascotController.swift   borderless non-activating NSPanel, display link, menus, drag
  WalkEngine.swift         CADisplayLink state machine: walk/turn/idle/sit/drag + pose
  MascotView.swift         SwiftUI Canvas — sprite rendering + procedural motion/accessories
  Assets/                  the real-alpha character sprites
  Mood.swift               mood enum, palette, mascotName
  UsageStore.swift         canonical model, freshest-sample merge, pace-delta moods
  OAuthUsagePoller.swift   30 s poller for the undocumented OAuth usage endpoint
  StatuslineBridge.swift   file-watcher + statusline script installer
  CredentialsProvider.swift  Keychain / credentials-file token extraction
  JSONProbe.swift          defensive JSON probing & epoch/ISO-8601 normalization
```

## Privacy

Pip never sends your usage anywhere. The only network call is to Anthropic's own usage
endpoint, with your own token, to read your own numbers. There is no analytics, no
telemetry, and no third-party code. Logs stay in `~/Library/Logs/Pip/`.

## License

MIT — see [LICENSE](LICENSE). The artwork in `mascot/` and `Pip/Assets/` is original and
shared under the same license.
