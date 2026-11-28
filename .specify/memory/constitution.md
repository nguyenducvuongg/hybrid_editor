<!--
Sync Impact Report
- Version change: 1.0.0 -> 2.0.0 (Core pivot from jub0t/Concat to robbietilton/Editroom)
- Modified principles: Updated implementation stack references across I1-I3, M4 Pro Hardware Optimization, and Testing Discipline from Rust/Slint/wgpu (`src/`) to Swift/SwiftUI/AppKit/AVFoundation/CoreImage/Metal (`editroom/`), while preserving all 6 Architectural Invariants (I1-I6). Concat M0+M1 baseline remains archived on `archive/concat-m1` / tag `concat-m1-archive` / `src/`.
- Added sections: Editroom MIT + LGPL FFmpeg sidecar licensing & Xcode/Swift verification targets
- Removed sections: None
- Follow-up TODOs: Implement M1-E guardrails (`I5` HYBRID_EDIT_DATA_DIR override, `P7` UTF-8 safe cache names, external MCP `AgentTurn`/`SessionLease`/`apply_edl_patch`/`preview_timeline_strip`)
-->

# hybrid_edit_vid Constitution

## Core Principles

### I1. One Door for Every Change (Single Command Bus)
All state-mutating operations on a project — whether triggered by pointer/keyboard gestures in the SwiftUI/AppKit UI (`TimelineCanvas`, `InspectorView`), MCP tool calls from Antigravity 2.0 (`MCPServer` / `Editroom --mcp`), or local LLM/VLM integrations (Ollama / LM Studio / Apple Intelligence) — MUST pass through a single authoritative `EditorModel` / Command Bus (`mutate` / `MCPDraft` transactional boundary) in `editroom/Editroom/Model/EditorModel.swift`. Direct mutation of project data structures or `.room` project files bypassing the Command Bus is strictly prohibited. Agent command sequences MUST support transactional grouping (`AgentTurn` / `MCPDraft`) sharing the unified Undo/Redo stack with manual user edits, while UI-only `ViewState` (`TimelineViewState`, selection, playhead, skimming, scroll) MUST remain separated from `DocumentState` and Undo history (`P4`).

### I2. Live-Attach External Agent Collaboration
When the user has a project open in the `hybrid_edit_vid` native macOS application, external agents connecting via MCP (`http://127.0.0.1:47920/mcp` with Host/Origin allowlist guard `P3` or stdio bridge `Editroom --mcp`) MUST operate directly on that live open project session (Live-Attach Mode) via the unified Command Bus (`I1`), displaying live agent presence (`AgentPresence` / `MagicShow`) and supporting clean headless fallback when needed. Every committed Agent mutation MUST update the live timeline state deterministically before returning the new revision (`P1`), and the core engine MUST enforce strict serialized write locking (`one writer at a time`, commit-before-ack) paired with a lease-based recoverable lock (`P8`) so crashed clients cannot permanently block a session.

### I3. Single Renderer Parity (Preview, Visual QA & Export)
The `PreviewView` monitor viewport, the Agent visual feedback tools (`get_frame` / `preview_timeline_strip`), and final MP4/MOV/WAV export (`Exporter`) MUST traverse the exact same core `CompositionBuilder` and `TimelineCompositor` / `HDRTimelineCompositor` CoreImage+Metal pipeline (`editroom/Editroom/Engine/`). UI chrome (selection outlines, agent cursors, snap lines, playhead) MUST remain strictly in the AppKit/SwiftUI presentation layer and never leak into rendered/exported frames (`P2`). Every new effect, transition, caption style, or overlay MUST be tested on both preview and export paths.

### I4. Non-Destructive Derived Media Artifacts
All generated artifacts — word-level transcripts (Vietnamese/multilingual `whisper.cpp` Metal + Silero VAD and Apple `SpeechTranscriber`), scene/VLM semantic indexes, scrub caches, waveforms, reversed audio caches, playable `.mov` conversions, and v0.2+ processed stems/mattes — MUST be stored as new derived artifacts linked to original source media via content/file stamp hash (`path + size + mtime + inode + engine version`). Original source footage MUST NEVER be overwritten or modified, and artifact filenames MUST enforce UTF-8 byte-length safety on macOS APFS (`<= 180` bytes before suffix + hash, `P7`) with atomic `.tmp` -> `rename` writes.

### I5. Strict Data and Source Code Separation
All video projects, media footage, derived caches, SQLite semantic indexes, and AI model weights (`whisper.cpp`, Silero VAD, local VLM) MUST reside outside the source repository in a configurable external data directory (`~/Library/Application Support/hybrid_edit_vid` or `Editroom` data root on macOS by default, overridable via `HYBRID_EDIT_DATA_DIR` for isolated dev and test runs). Rebuilding code, switching Git branches, or running automated test suites MUST NEVER touch real user project data.

### I6. Off-Thread Serialized Heavy Execution
All CPU/GPU/memory-intensive jobs — VAD + `whisper.cpp` transcription, B-roll scene detection and VLM indexing, reverse audio/frame decoding, proxy/conversion via `Vendor/ffmpeg`, and 4K export — MUST execute on dedicated background queues/tasks (`Task.detached`, `DispatchQueue`) completely off the `@MainActor` UI event loop and MCP response blocking paths. Heavy AI/media jobs MUST respect Apple Silicon Unified Memory limits, providing explicit `progress` reporting, safe cancellation, and clear error propagation.

## Toolchain Precedence & Skill Separation

### Absolute Priority Hierarchy (No Conflicts)
All engineering sessions on `hybrid_edit_vid` MUST obey this strict precedence from highest to lowest:
1. **Tier 1 (Supreme) — This Constitution (`constitution.md`):** Architectural invariants I1–I6, quantitative verification discipline, security/safety rules, and M4 Pro hardware targets. No plugin or skill may override Tier 1.
2. **Tier 2 (Lifecycle Governance) — `github/spec-kit` (`/speckit-*`):** The sole workflow governing feature specifications (`specify -> clarify -> plan -> tasks -> implement`) and locking interface boundaries in `contracts/`. No parallel spec workflow is permitted.
3. **Tier 3 (Codebase Cartography) — `Graphify-Labs/graphify` (`/graphify .`):** Before deep-reading, modifying, or planning across the Swift/Metal codebase (`editroom/`) or archived Rust reference (`src/`), agents MUST query the Knowledge Graph (`graphify query`, `graphify path`, `graphify-out/GRAPH_REPORT.md`), distinguishing `EXTRACTED` (AST) vs `INFERRED` edges, and keep the graph updated after structural changes.
4. **Tier 4 (Execution Discipline & Anti-Bloat) — `ponytail` & 4 Selective Addy Osmani Skills:**
   - `interview-me`: Clarification Gate for ambiguous requirements or trade-offs.
   - `test-driven-development`: Mandatory Red -> Green -> Refactor loop for every Pitfall (`P1–P9`) and core state/media logic.
   - `ponytail` (`/ponytail-review`, `/ponytail-debt`): Post-implementation review to eliminate unnecessary abstractions and bloat; strictly FORBIDDEN from removing I1–I6 guards, `contracts/` schemas, input/security checks, or regression tests.
   - `code-review-and-quality`: Five-axis quality gate before closing any major milestone (`M1-E`–`M4-E`).
   - `context-engineering`: Token budget optimization for long sessions and compact MCP payloads (`get_project` / `inspect_project_context`).

### Strict Separation of Dev Skills vs Runtime Editor Skills
- **Dev-Workflow Skills:** Global (`~/.gemini/config/plugins/ponytail`, `~/.gemini/config/skills/` containing only the 4 selected Addy Osmani skills + `graphify`) and repository-level (`.agents/skills/speckit-*`, `.agents/rules/graphify.md`).
- **Runtime Video-Editing Skills:** Stored separately under `assets/editor-skills/<skill-name>/SKILL.md` in source and `HYBRID_EDIT_DATA_DIR/skills/` at runtime (`aroll-rough-cut`, `smart-broll-inserter`), loaded by the video-editing session and NEVER mixed into `.agents/skills/`.

## Apple Silicon Hardware Optimization (MacBook Pro M4 Pro)

1. **Native Hardware Acceleration First:**
   - Video decode, compositing, scaling, and encode MUST leverage **AVFoundation / VideoToolbox** (`h264`, `hevc` 10-bit HLG), **CoreImage Metal (`MTLDevice`)**, and **MetalFX (`MTLFXSpatialScaler`)**.
   - Speech-to-text for Vietnamese and multilingual footage MUST execute `whisper.cpp` with the **Metal** backend (`GGML_METAL=ON`, default `large-v3-turbo` + Silero VAD), alongside Apple `SpeechTranscriber` where supported.
   - Computer vision & local semantic indexing MUST leverage **Apple Vision / Neural Engine (`ANE`)** and local VLM bridges (**Ollama / LM Studio** or Apple `FoundationModels` / MLX) sized for 24 GB Unified Memory alongside 4K compositing (7B–12B VLM, e.g., `qwen2.5vl:7b`), with Antigravity Multimodal supported as fallback.
2. **UI Responsiveness:** `@MainActor` and `TimelineCanvas` MUST NEVER block on disk I/O, synchronous frame decoding, or LLM HTTP requests.
3. **Quantitative M4 Pro Measurement:** `xcodebuild` timings, `Editroom --selftest` results, `whisper.cpp` Metal RTF, Live-Attach MCP sync latency, and 4K VideoToolbox export throughput MUST be measured empirically on the target MacBook Pro M4 Pro and recorded in `PROJECT.md`.

## Engineering Workflow, Testing & Operations

1. **Approval Before Host Mutation:** Always present and obtain Product Owner approval before installing, uninstalling, deleting, or overwriting global tools or system dependencies.
2. **Empirical Exit Evidence Required:** No task or milestone may be declared complete without executing real verification commands (`xcodebuild`, `xcodebuild test` / `XCTest`, `Editroom --selftest`, `ffprobe`, M4 Pro benchmarks, 5-round E2E MCP loop) and reporting observed outputs honestly (including exact scope and any skipped/failed sub-checks).
3. **Two-Failures Stop Rule:** If the same bug recurs twice after attempted fixes, STOP immediately, formulate at least two root-cause hypotheses with verification steps for each, and consult the Product Owner.
4. **Isolated Test Environments:** Automated tests MUST use temporary isolated `HYBRID_EDIT_DATA_DIR` paths, dedicated ports/sockets, and clean up spawned child processes by PID.
5. **Living Documentation & License Tracking:** Update `PROJECT.md` after every milestone (decisions, measured benchmarks, unverified gaps, next steps) and maintain a license inventory covering `Editroom` (`MIT`), `Sparkle` (`MIT`), `Vendor/ffmpeg` (`LGPL-2.1+`), archived `jub0t/Concat` (`AGPL-3.0-or-later`), and every newly added dependency or AI model.

## Governance

This Constitution supersedes all other development workflows, plugins, and ad-hoc conventions. Any amendment proposing to relax or alter an Architectural Invariant (`I1–I6`) or testing requirement MUST be explicitly surfaced to the Product Owner with trade-off analysis, approved prior to implementation, and recorded via `/speckit-constitution` with a semantic version bump (`MAJOR` for breaking invariant changes, `MINOR` for expanded principles/sections, `PATCH` for clarifications).

**Version**: 2.0.0 | **Ratified**: 2026-11-25 | **Last Amended**: 2026-11-28
