# Feature Specification: Milestone 1-E — Editroom Guardrails, Transactional External `AgentTurn`, `SessionLease` & Hybrid MCP Tools

**Feature Branch**: `feat/editroom-core`  
**Spec Directory**: `specs/002-editroom-guardrails-mcp`  
**Created**: 2026-11-28  
**Status**: Approved for Implementation  

**Input**: Port and lock all `hybrid_edit_vid` Core Architectural Invariants (`I1–I5`) and Pitfalls (`P1–P4`, `P7–P8`) onto the new `Editroom` Swift core (`editroom/`), establishing isolated external storage (`HYBRID_EDIT_DATA_DIR`), UTF-8 APFS-safe derived artifact naming, single-writer recoverable `SessionLease`, transactional external `AgentTurn` on `EditorModel` with monotonic `revision`, batch A-roll/B-roll editing (`apply_edl_patch`), and core-renderer contact-sheet inspection (`preview_timeline_strip`).

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Data Isolation & UTF-8 APFS-Safe Derived Artifacts (`I4`, `I5`, `P7`)
When running automated tests, development builds, or importing media with long Vietnamese filenames (multi-byte UTF-8 exceeding 255 bytes when suffixes are appended), all derived caches, recovery files, downloads, and leases write strictly inside `HYBRID_EDIT_DATA_DIR` (or `~/Library/Application Support/hybrid_edit_vid`), never touch the source repository or real user Application Support data, and never fail with `ENAMETOOLONG` or silent zero-byte writes.

**Acceptance Scenarios**:
1. **Given** `HYBRID_EDIT_DATA_DIR` is set to a temporary path, **When** any storage subsystem (`Reverser`, `Transcripts`, `SceneTags`, `ScrubCache`, `ScrubStrips`, `WaveformReader`, `FFmpeg`, `MediaAnalyzer`, `MediaNotes`, `MagicAgent`, `MediaDownload`, `Recovery`, `From Photos`, `LeaseManager`) resolves its folder, **Then** every path resides under `HYBRID_EDIT_DATA_DIR`.
2. **Given** a source media file whose Vietnamese accented name exceeds 130 characters (`> 260` UTF-8 bytes), **When** derived cache names are generated and written atomically, **Then** the final filename is `<= 200` UTF-8 bytes, splits cleanly on character boundaries without invalid UTF-8, and verifies existence + non-zero size before succeeding.

---

### User Story 2 - Unified `revision`, ViewState Isolation & External `AgentTurn` (`I1`, `P1`, `P4`)
When an external MCP client (Antigravity 2.0) opens a multi-step turn via `begin_agent_turn`, performs edits (`add_clip`, `split_clip`, `apply_edl_patch`, etc.), and calls `commit_agent_turn`, all edits land atomically onto the live `EditorModel` as **1** unified Undo/Redo entry sharing the stack with manual edits; meanwhile UI-only `ViewState` operations (`selection`, `playhead`, `zoom`, `scroll`, `skimming`) never increment `revision`, never push Undo entries, and never mark the document dirty.

**Acceptance Scenarios**:
1. **Given** an open `EditorModel`, **When** 20 selection/playhead/zoom/scroll changes occur, **Then** `revision` changes by `0`, `undoStack` count changes by `0`, and `isDirty` remains `false`.
2. **Given** an external MCP client runs `begin_agent_turn` -> 3 edits -> `commit_agent_turn`, **Then** `revision` increases by `1`, `canUndo` is `true`, 1 `model.undo()` reverts all 3 edits atomically, and 1 `model.redo()` reapplies all 3 edits.
3. **Given** an active `AgentTurn` with uncommitted edits, **When** `rollback_agent_turn` is called, **Then** `EditorModel` stays at the exact pre-turn baseline with `0` new Undo steps and unchanged `revision`.

---

### User Story 3 - Single-Writer `SessionLease` & `SIGKILL` Crash Recovery (`I2`, `P8`)
When external MCP clients collaborate on a live `EditorModel`, `LeaseManager` enforces single-writer ownership via `0o600` persisted lease files under `leases/`. If a client holding an uncommitted `AgentTurn` crashes abruptly (`SIGKILL`) or expires past the `5–10s` grace window, the engine automatically rolls back the incomplete turn and lets a subsequent client acquire control cleanly.

**Acceptance Scenarios**:
1. **Given** client A acquires a lease and opens an uncommitted `AgentTurn`, **When** client B attempts to acquire or mutate, **Then** client B is rejected with a busy-lease error.
2. **Given** client A dies (`kill -9`) mid-turn, **When** client B connects or mutates, **Then** `LeaseManager` detects dead PID, rolls back the uncommitted turn, reclaims the lease (`0o600`), and allows client B to proceed from the clean pre-turn `revision`.

---

### User Story 4 - Semantic Batch Editing (`apply_edl_patch`) & Core Visual QA (`preview_timeline_strip`) (`I3`, `P2`)
An Agent can submit a single `apply_edl_patch` call (`keep_ranges`, `delete_range`, `insert_overlay`) to rough-cut A-roll or insert B-roll overlays in 1 command, and inspect up to 12 rendered timeline frames via `preview_timeline_strip` routed through `CompositionBuilder` + `TimelineCompositor` matching final `Exporter` output (`P2`, zero UI chrome).

**Acceptance Scenarios**:
1. **Given** a 3-second A-roll clip on `V1`, **When** `apply_edl_patch` applies `keep_ranges` `[0.2, 1.0]` and `[1.8, 2.6]` with `ripple: true`, **Then** `V1` holds 2 contiguous clips covering `0.0...1.6s` and 1 Undo restores the original 3.0s clip.
2. **Given** a scaled-down clip and transparent PNG overlay on the timeline, **When** `preview_timeline_strip` and `Exporter` render the frame, **Then** empty margins render solid black (`RGB < 10`) with zero UI chrome leakage.

---

### User Story 5 - Live HTTP Security (`P3`) & 5-Round E2E Revision Consistency (`P1`)
`MCPServer` rejects non-loopback `Host` headers (`403 Forbidden`) and maintains strict `revision` synchronization across 5 consecutive live HTTP rounds (`begin_agent_turn` -> edits -> `commit_agent_turn` -> `get_project`).
