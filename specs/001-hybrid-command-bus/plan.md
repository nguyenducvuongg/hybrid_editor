# Implementation Plan: Milestone 1 — Unified Command Bus, Transactional Agent Turn & Hybrid Timeline Foundation

**Branch**: `001-hybrid-command-bus` | **Date**: 2026-11-25 | **Spec**: [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/001-hybrid-command-bus/spec.md)
**Input**: Feature specification from `specs/001-hybrid-command-bus/spec.md`

## Summary

Milestone 1 builds the core collaborative foundation on top of `jub0t/Concat`'s Rust + Slint engine:
1. **Unified Command Bus & `AgentTurn` (`concat-project`, `concat-host`):** Group multi-step Agent edits into a single transactional Undo/Redo entry (`begin/commit/rollback_agent_turn`) alongside manual edits (`I1`), strictly isolating `ViewState` from `DocumentState` and autosave (`P4`).
2. **Recoverable `SessionLease` & Live-Attach Coordinator (`concat-host`, `concat-api`):** Replace the `Holder::Window` vs `Holder::Api` refusal with serialized single-writer `LiveSession` coordination and a PID/heartbeat lease lock (`5–10s` grace period) that auto-rolls back uncommitted turns on client crash (`I2`, `P8`).
3. **Hybrid Timeline Slint UI (`concat`):** Highlight Agent-modified clips via `ClipData.agent_modified`, add an Agent Turn HUD (`Progress / Cancel / Accept / Revert Turn`) where `Accept` clears only visual highlights (`Cmd+Z` preserved), and publish live `StateDiffEvent` updates.
4. **Renderer Parity & External Data Isolation (`concat-export`, `concat-host`):** Enforce `HYBRID_EDIT_DATA_DIR` / `~/Library/Application Support/hybrid_edit_vid` (`I5`) and verify pixel-exact background/alpha parity between core preview and VideoToolbox export (`I3`, `P2`).

## Technical Context

**Language/Version**: Rust `1.93.1` (edition 2024, pinned in `src/rust-toolchain.toml`), Slint `1.18.1` (Skia Metal/winit)  
**Primary Dependencies**: `concat-core`, `concat-project`, `concat-host`, `concat-api`, `concat-export`, `concat-render` (`wgpu 30`), `serde` / `serde_json`, `slint`  
**Storage**: Atomic `Document` JSON (`concat-doc::save`), lease metadata in `HYBRID_EDIT_DATA_DIR/leases/` (outside repo)  
**Testing**: `cargo test` (TDD Red -> Green -> Refactor), real child-process `kill -9` P8 harness, `ffmpeg`/`ffprobe` P2 pixel parity check  
**Target Platform**: macOS Apple Silicon (MacBook Pro M4 Pro, VideoToolbox + Metal)  
**Project Type**: Native desktop application + Rust workspace (`src/crates/*`)  
**Performance Goals**: UI thread never blocked by disk I/O or lock waits; `ViewState` operations (`selection`, `playhead`) = 0 disk writes; Slint publish stays under 16ms frame budget  
**Constraints**: Must obey `I1–I6`, zero `concat` test regressions, `missing_docs = "warn"` workspace lint, no over-engineering (`ponytail`)  
**Scale/Scope**: Single-user + local AI agent on 1 live open project at a time (`UNDO_DEPTH = 200`, `AgentTurn` arbitrary command batch)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I1 (One Door for Every Change):** PASS — All manual & Agent edits go through `concat_project::Editor` & `concat_host::Session`; `AgentTurn` shares the single `undo` stack; `ViewState` is excluded.
- **I2 (Live-Attach Collaboration):** PASS — `OpenProjects` + `LiveSession` allow `Holder::Api` to share the open window session under `SessionLease` single-writer serialization (`P8`).
- **I3 (Single Renderer Parity):** PASS — Preview & Export share `flatten_timeline_in` + `WgpuCompositor`; UI highlights live solely in Slint `ClipData`.
- **I4 (Non-Destructive Derived Media):** N/A in M1 (no source media modification; project saves keep `.prev` atomic swap).
- **I5 (Data Separation):** PASS — `AppDirs::locate()` honors `HYBRID_EDIT_DATA_DIR` and defaults to `~/Library/Application Support/hybrid_edit_vid`.
- **I6 (Off-Thread Heavy Jobs):** PASS — Existing `spawn_save` / worker lanes remain off UI thread; M1 adds zero blocking I/O on Slint main loop.

*Post-design re-check:* All 3 `contracts/` files (`command_bus.md`, `session_lease.md`, `renderer_parity.md`) uphold `I1–I6` without exceptions.

## Project Structure

### Documentation (this feature)

```text
specs/001-hybrid-command-bus/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── checklists/
│   └── requirements.md
└── contracts/
    ├── command_bus.md
    ├── session_lease.md
    └── renderer_parity.md
```

### Source Code (affected Concat crates)

```text
src/crates/
├── concat-project/src/
│   ├── editor.rs           # Add AgentTurn, TurnMeta, begin/apply_in_turn/commit/rollback
│   └── lib.rs              # Re-export AgentTurn types
├── concat-host/src/
│   ├── dirs.rs             # HYBRID_EDIT_DATA_DIR override & ~/Library/Application Support/hybrid_edit_vid
│   ├── lease.rs            # NEW: SessionLease, LeaseGuard, PID liveness & grace-period recovery (P8)
│   ├── session.rs          # StateDiffEvent, LiveSession wrapper, turn & view-state separation (P4)
│   └── lib.rs              # Export lease module & StateDiffEvent
├── concat-api/src/
│   └── lib.rs              # Live-Attach coordination in OpenProjects + turn/lease tests
├── concat-export/src/
│   └── lib.rs              # P2 canvas/alpha parity regression test (preview vs VideoToolbox export)
└── concat/
    ├── src/studio/
    │   ├── edit.rs         # Turn HUD actions (cancel/accept/revert_agent_turn), P4 regression tests
    │   ├── publish.rs      # Publish ClipData.agent_modified & AgentTurn HUD properties
    │   └── project_files.rs # Integrate LiveSession / lease on open/close
    ├── src/studio.rs       # ViewState fields for active/dismissed AgentTurn highlights
    ├── src/lib.rs          # Wire Slint callbacks (accept-agent-turn, revert-agent-turn, cancel-agent-turn)
    └── ui/
        ├── editor.slint    # Agent Turn HUD properties & callbacks
        └── timeline/
            ├── model.slint # ClipData.agent-modified field
            ├── lanes.slint # Visual highlight for agent-modified clips
            └── tray.slint  # Compact Agent Turn HUD (Progress/Cancel, Accept/Revert Turn)
```

## Complexity Tracking

No Constitution violations or extra crates introduced. All changes stay inside Concat's existing 4 crates (`concat-project`, `concat-host`, `concat-api`, `concat`) plus 1 focused `lease.rs` module.
