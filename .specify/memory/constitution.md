<!--
Sync Impact Report
- Version change: template -> 1.0.0 (initial ratification from kit/CONSTITUTION_SEED.md)
- Modified principles: Replaced template placeholders with I1-I6 Architectural Invariants
- Added sections: Toolchain Precedence, Apple Silicon M4 Pro Hardware Optimization, Skill Separation, Engineering & Testing Discipline, Governance
- Removed sections: Template placeholder comments
- Follow-up TODOs: None
-->

# hybrid_edit_vid Constitution

## Core Principles

### I1. One Door for Every Change (Single Command Bus)
All state-mutating operations on a project — whether triggered by pointer/keyboard gestures in the Slint UI, MCP tool calls from Antigravity 2.0, or local LLM/VLM integrations (Ollama / LM Studio) — MUST pass through a single Rust `EditorCore` / Command Bus (`concat-project` / `concat-host::Session`). Direct mutation of project data structures or project files bypassing the Command Bus is strictly prohibited. Agent command sequences MUST support transactional grouping (`AgentTurn`) sharing the unified Undo/Redo stack with manual user edits, while UI-only `ViewState` (selection, playhead, zoom, scroll) MUST remain separated from `DocumentState` and Undo history.

### I2. Live-Attach External Agent Collaboration
When the user has a project open in the `hybrid_edit_vid` native application, external agents connecting via MCP MUST operate directly on that live open project session (Live-Attach Mode) via the unified Command Bus (I1), falling back to Headless mode only when the GUI is closed. Every committed Agent mutation MUST emit a state-diff event stream for immediate Hybrid Timeline Slint updates, and the core engine MUST enforce strict serialized write locking (`one writer at a time`, commit-before-ack) paired with a lease-based recoverable lock so crashed clients cannot permanently block a session.

### I3. Single Renderer Parity (Preview, Visual QA & Export)
The Slint monitor viewport, the Agent visual feedback strip (`preview_timeline_strip`), and final MP4/MOV export MUST traverse the exact same core flattening and rendering graph (`concat-export` / `concat-render`). UI chrome (selection outlines, checkerboard transparency indicators, alignment guides) MUST remain strictly in the Slint presentation layer and never leak into rendered/exported frames. Every new effect, cut rule, or overlay MUST be tested on both preview and export paths.

### I4. Non-Destructive Derived Media Artifacts
All generated artifacts — Whisper word-level transcripts, Silero VAD silence maps, B-roll keyframes and semantic indexes, video proxies, and v0.2+ processed stems/mattes — MUST be stored as new derived artifacts linked to original source media via media ID and version hash (`revision + engine version`). Original source footage MUST NEVER be overwritten or modified, and artifact filenames MUST enforce UTF-8 byte-length safety on macOS APFS with atomic `.tmp` -> `rename` writes.

### I5. Strict Data and Source Code Separation
All video projects, media footage, derived caches, SQLite semantic indexes, and AI model weights (Whisper, Silero VAD, ONNX, local VLM) MUST reside outside the source repository in a configurable external data directory (`~/Library/Application Support/hybrid_edit_vid` on macOS by default, overridable via `HYBRID_EDIT_DATA_DIR`). Rebuilding code, switching Git branches, or running automated test suites MUST NEVER touch real user project data.

### I6. Off-Thread Serialized Heavy Execution
All CPU/GPU/memory-intensive jobs — VAD + `whisper.cpp` transcription, B-roll scene detection and VLM indexing, proxy generation, and 4K export — MUST execute on dedicated worker threads or child processes completely off the Slint UI event loop and IPC/MCP response threads. Heavy AI/media jobs MUST run through a serialized queue (respecting Unified Memory limits), providing explicit `progress` reporting, safe `cancel` handling, and clear error propagation.

## Toolchain Precedence & Skill Separation

### Absolute Priority Hierarchy (No Conflicts)
All engineering sessions on `hybrid_edit_vid` MUST obey this strict precedence from highest to lowest:
1. **Tier 1 (Supreme) — This Constitution (`constitution.md`):** Architectural invariants I1–I6, quantitative verification discipline, security/safety rules, and M4 Pro hardware targets. No plugin or skill may override Tier 1.
2. **Tier 2 (Lifecycle Governance) — `github/spec-kit` (`/speckit-*`):** The sole workflow governing feature specifications (`specify -> clarify -> plan -> tasks -> implement`) and locking interface boundaries in `contracts/`. No parallel spec workflow is permitted.
3. **Tier 3 (Codebase Cartography) — `Graphify-Labs/graphify` (`/graphify .`):** Before deep-reading, modifying, or planning across Concat's Rust/Slint crates, agents MUST query the Knowledge Graph (`graphify query`, `graphify path`, `graphify-out/GRAPH_REPORT.md`), distinguishing `EXTRACTED` (AST) vs `INFERRED` edges, and keep the graph updated after structural changes.
4. **Tier 4 (Execution Discipline & Anti-Bloat) — `ponytail` & 4 Selective Addy Osmani Skills:**
   - `interview-me`: Clarification Gate for ambiguous requirements or trade-offs.
   - `test-driven-development`: Mandatory Red -> Green -> Refactor loop for every Pitfall (`P1–P9`) and core state/media logic.
   - `ponytail` (`/ponytail-review`, `/ponytail-debt`): Post-implementation review to eliminate unnecessary abstractions and bloat; strictly FORBIDDEN from removing I1–I6 guards, `contracts/` schemas, input/security checks, or regression tests.
   - `code-review-and-quality`: Five-axis quality gate before closing any major milestone (`M0–M4`).
   - `context-engineering`: Token budget optimization for long sessions and compact MCP payloads (`inspect_project_context`).

### Strict Separation of Dev Skills vs Runtime Editor Skills
- **Dev-Workflow Skills:** Global (`~/.gemini/config/plugins/ponytail`, `~/.gemini/config/skills/` containing only the 4 selected Addy Osmani skills + `graphify`) and repository-level (`.agents/skills/speckit-*`, `.agents/rules/graphify.md`).
- **Runtime Video-Editing Skills:** Stored separately under `assets/editor-skills/<skill-name>/SKILL.md` in source and `HYBRID_EDIT_DATA_DIR/skills/` at runtime (`aroll-rough-cut`, `smart-broll-inserter`), loaded by the video-editing session and NEVER mixed into `.agents/skills/`.

## Apple Silicon Hardware Optimization (MacBook Pro M4 Pro)

1. **Native Hardware Acceleration First:**
   - Video decode, proxy creation, and encode MUST leverage **FFmpeg VideoToolbox** (`h264_videotoolbox`, `hevc_videotoolbox`, `prores_videotoolbox`).
   - Speech-to-text MUST execute `whisper.cpp` with the **Metal** backend (`GGML_METAL=ON`, default `large-v3-turbo` + Silero VAD).
   - ONNX models MUST target **CoreML Execution Provider** prior to CPU fallback.
   - Local LLM/VLM bridges (Ollama / LM Studio) MUST size defaults for 24 GB Unified Memory alongside Slint and VideoToolbox (7B–12B VLM, e.g., `qwen2.5vl:7b`), with Antigravity Multimodal supported as fallback.
2. **UI Responsiveness:** The Slint UI thread MUST NEVER block on disk I/O, synchronous frame decoding, or LLM HTTP requests.
3. **Quantitative M4 Pro Measurement:** Build times, `whisper.cpp` Metal RTF, Live-Attach MCP sync latency, and 4K VideoToolbox export throughput MUST be measured empirically on the target MacBook Pro M4 Pro and recorded in `PROJECT.md`.

## Engineering Workflow, Testing & Operations

1. **Approval Before Host Mutation:** Always present and obtain Product Owner approval before installing, uninstalling, deleting, or overwriting global tools or system dependencies.
2. **Empirical Exit Evidence Required:** No task or milestone may be declared complete without executing real verification commands (`cargo test`, `ffprobe`, M4 Pro benchmarks, 5-round E2E MCP loop) and reporting observed outputs.
3. **Two-Failures Stop Rule:** If the same bug recurs twice after attempted fixes, STOP immediately, formulate at least two root-cause hypotheses with verification steps for each, and consult the Product Owner.
4. **Isolated Test Environments:** Automated tests MUST use temporary isolated `HYBRID_EDIT_DATA_DIR` paths, dedicated Unix sockets/ports, and clean up spawned child processes by PID.
5. **Living Documentation & License Tracking:** Update `PROJECT.md` after every milestone (decisions, measured benchmarks, unverified gaps, next steps) and maintain a license inventory for `AGPL-3.0` (`jub0t/Concat`) and every newly added crate or AI model.

## Governance

This Constitution supersedes all other development workflows, plugins, and ad-hoc conventions. Any amendment proposing to relax or alter an Architectural Invariant (`I1–I6`) or testing requirement MUST be explicitly surfaced to the Product Owner with trade-off analysis, approved prior to implementation, and recorded via `/speckit-constitution` with a semantic version bump (`MAJOR` for breaking invariant changes, `MINOR` for expanded principles/sections, `PATCH` for clarifications).

**Version**: 1.0.0 | **Ratified**: 2026-11-25 | **Last Amended**: 2026-11-25
