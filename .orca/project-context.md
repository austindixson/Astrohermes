# Project context

> PNG · macOS · 5 layers

Xcode organized in 5 layers: Shell & View → Canvas System → Orchestrator → Agent Runtime → Utilities.

## Tech stack
**Languages:** PNG, Swift, Python, WEBP
**Platforms:** macOS

**Hierarchy** (presentation → core):
1. **Shell & View** — SwiftUI, AppKit · _OrcaCoderApp, Views, Chrome_
2. **Canvas System** — SwiftUI, Spatial layout · _InfiniteCanvasView, CanvasGridLayout_
3. **Orchestrator** — LLM tool loop, Command dispatch · _Orchestrator, BridgeOrchestratorPipeline_
4. **Agent Runtime** — PTY, CLI spawn · _AgentExecutor, PTYSession_
5. **Utilities** — Persistence, Git, File I/O · _PersistenceStore, GitIntegration_

## Stack hierarchy
- **Shell & View** — SwiftUI, AppKit · OrcaCoderApp, Views, Chrome
- **Canvas System** — SwiftUI, Spatial layout · InfiniteCanvasView, CanvasGridLayout
- **Orchestrator** — LLM tool loop, Command dispatch · Orchestrator, BridgeOrchestratorPipeline
- **Agent Runtime** — PTY, CLI spawn · AgentExecutor, PTYSession
- **Utilities** — Persistence, Git, File I/O · PersistenceStore, GitIntegration

## Infrastructure
- **Platforms:** macOS
- **Scripts:** `scripts/` test & automation harness

## User flow
1. **Launch** — welcome screen or resume last canvas
2. **Open project** — folder binds workspace; Orca scans stack + architecture
3. **Canvas** — spatial tiles: terminals, browser, plan, code, performance
4. **Command** — voice or text to orchestrator; triage → decompose or direct tools
5. **Agents** — parallel workers on canvas; lead synthesizes handoffs
6. **Ship** — git commit, preview in browser tile, iterate

_Workspace:_ `/Users/ghost/Desktop/Projects/pip-mascot`
_Analyzed:_ 2026-06-30T16:39:28Z