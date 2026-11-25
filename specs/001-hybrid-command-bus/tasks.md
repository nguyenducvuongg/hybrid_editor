# Tasks: Unified Command Bus, Transactional Agent Turn & Hybrid Timeline Foundation

**Input**: Design documents from `specs/001-hybrid-command-bus/`  
**Prerequisites**: [plan.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/001-hybrid-command-bus/plan.md), [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/001-hybrid-command-bus/spec.md), [data-model.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/001-hybrid-command-bus/data-model.md), [contracts/](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/001-hybrid-command-bus/contracts/)

**Tests**: Required per `test-driven-development` and Constitution `I1–I5` (`P2`, `P4`, `P8`). Every Pitfall / behavioral test MUST be written and observed FAILING (Red) before implementing the production code (Green).

## Phase 1: Setup & Data Isolation (`I5`)

- [x] T001 [P] Add `HYBRID_EDIT_DATA_DIR` regression test verifying isolated temp directory resolution and `~/Library/Application Support/hybrid_edit_vid` macOS default in `src/crates/concat-host/src/dirs.rs`
- [x] T002 Implement `HYBRID_EDIT_DATA_DIR` override and default `hybrid_edit_vid` identifier in `src/crates/concat-host/src/dirs.rs`

---

## Phase 2: Foundational — `SessionLease` & `StateDiffEvent` Primitives

- [x] T003 [P] Define `SessionLease` (`SessionLease.session_id`, `SessionLease.client_pid`, `SessionLease.grace_period_ms` clamped `5000..=10000`, `SessionLease.last_heartbeat_at_ms`, `SessionLease.active_turn_id` per `data-model.md`) contract types and failing unit tests (`P8`) in `src/crates/concat-host/src/lease.rs`
- [x] T004 Implement `LeaseManager` / `SessionLease` persistence (`HYBRID_EDIT_DATA_DIR/leases/`), PID liveness check, heartbeat renewal, and grace-period expiration in `src/crates/concat-host/src/lease.rs`

**Checkpoint**: Isolated `AppDirs` and `LeaseManager` ready for User Story phases.

---

## Phase 3: User Story 1 — Unified Undo/Redo & Transactional `AgentTurn` (Priority: P1) 🎯 MVP

**Goal**: Group N Agent commands into 1 Undo/Redo step sharing the unified history with manual edits (`I1`), with atomic `rollback_agent_turn` on error/cancel.

**Independent Test**: Run `cargo test -p concat-project --offline agent_turn` and `cargo test -p concat-host --offline hybrid_100_ops`.

### Tests (TDD Red) ⚠️

- [x] T005 [P] [US1] Write failing `AgentTurn` tests (multi-command batch -> 1 undo/redo step, rollback restores pre-turn snapshot with 0 residual edits, turn mismatch/double-begin errors, chronological interleave with manual edits) in `src/crates/concat-project/src/editor.rs`
- [x] T006 [P] [US1] Write failing 100-operation hybrid stress test (`StateDiffEvent.revision` monotonic, turn metadata preserved) in `src/crates/concat-host/src/session.rs`

### Implementation

- [x] T007 [US1] Add `AgentTurn` (`AgentTurn.turn_id`, `AgentTurn.summary`, `AgentTurn.baseline_revision`, `AgentTurn.affected_clip_ids` per `data-model.md`), `TurnMeta`, `TurnCommit`, and `TurnError` plus `begin_agent_turn`, `apply_in_turn`, `commit_agent_turn`, `rollback_agent_turn`, `top_undo_turn` in `src/crates/concat-project/src/editor.rs` and export in `src/crates/concat-project/src/lib.rs`
- [x] T008 [US1] Expose `Session::{begin_agent_turn, apply_in_turn, commit_agent_turn, rollback_agent_turn, revision, top_undo_turn}` and emit `StateDiffEvent` (`StateDiffEvent.revision`, `StateDiffEvent.source`, `StateDiffEvent.affected_clip_ids` per `data-model.md`) in `src/crates/concat-host/src/session.rs` and `src/crates/concat-host/src/lib.rs`

**Checkpoint**: US1 `AgentTurn` & `StateDiffEvent` pass all unit & 100-op hybrid tests.

---

## Phase 4: User Story 2 — ViewState Isolation from Document History & Disk Saves (`P4`) (Priority: P1)

**Goal**: Ensure 20 clip selections + 20 playhead movements cause 0 Undo steps and 0 disk writes (`P4`).

**Independent Test**: Run `cargo test -p concat-host --offline p4_view_state`.

### Tests (TDD Red) ⚠️

- [x] T009 [US2] Write failing `P4` regression test verifying 20 selection updates + 20 playhead movements produce `0` undo entries and `0` disk writes while 1 timeline trim produces `1` undo entry and `1` save cycle in `src/crates/concat-host/src/session.rs` (and `src/crates/concat/src/studio/edit.rs` unit harness)

### Implementation

- [x] T010 [US2] Audit and enforce strict separation between `ViewState` (`Studio::selection`, `playhead`, `accepted_turns`, `Session::revision` unchanged) and `DocumentState` (`after_change` / `schedule_autosave`) in `src/crates/concat/src/studio/edit.rs`, `src/crates/concat/src/studio/gestures.rs`, and `src/crates/concat-host/src/session.rs`

**Checkpoint**: `P4` regression test passes with 0 spurious writes/undos.

---

## Phase 5: User Story 3 — Live Multi-Client Access & Crash-Recoverable Lock (`I2`, `P8`) (Priority: P1)

**Goal**: Allow `Holder::Api` to attach live to a project held by `Holder::Window` behind serialized `SessionLease` single-writer ordering, and auto-recover + rollback uncommitted turns when a client crashes (`kill -9`).

**Independent Test**: Run `cargo test -p concat-api --offline live_attach` and `cargo test -p concat-host --offline p8_crash_recovery`.

### Tests (TDD Red) ⚠️

- [x] T011 [P] [US3] Write failing `LiveSession` & `OpenProjects` live-attach tests (Window + API attach on same open project, busy-writer rejection when another lease is active, serialized commit ordering) in `src/crates/concat-api/src/lib.rs`
- [x] T012 [P] [US3] Write failing `P8` real child-process crash recovery test (`kill -9` child holding lease + uncommitted turn -> parent/second client reclaims after grace period with pre-turn state intact; reconnect within grace preserves ownership) in `src/crates/concat-host/tests/p8_crash_recovery.rs`

### Implementation

- [x] T013 [US3] Implement `LiveSession` coordinator (integrating `Session` + `LeaseManager` + `rollback_agent_turn` on lease expiry/dead PID) in `src/crates/concat-host/src/session.rs`
- [x] T014 [US3] Update `OpenProjects` in `src/crates/concat-api/src/lib.rs` to permit live attachment alongside `Holder::Window` via shared `LiveSession` handle instead of `Refusal::Here(Holder::Window)` *(Note: GUI `studio/project_files.rs` + `host.rs` wire-up with Unix Domain Socket MCP Gateway lands in M2)*

**Checkpoint**: Live-attach and real `kill -9` crash recovery pass cleanly.

---

## Phase 6: User Story 4 — Hybrid Timeline Agent Feedback & Controls (Priority: P2)

**Goal**: Display Agent-modified clip highlights, active turn progress/Cancel, and `Accept` / `Revert Turn` actions in the native Slint Hybrid Timeline without leaking highlights into undo (`Accept`) or exported video (`I3`).

**Independent Test**: `cargo build -p concat --profile quick --offline` + Studio unit tests for `accept_agent_turn` (clears highlight, keeps Undo step) and `revert_agent_turn` (undoes 1 turn, warns if newer manual edits sit above it).

### Tests (TDD Red) ⚠️

- [x] T015 [US4] Write failing `Studio` tests for `accept_agent_turn` (clears `agent_highlight_clips`, preserves `can_undo` and `Cmd+Z` revert) and `revert_agent_turn` (undoes top turn atomically; refuses silent discard when newer manual edits exist) in `src/crates/concat/src/studio/edit.rs`

### Implementation

- [x] T016 [P] [US4] Add `agent-modified: bool` to `ClipData` and visual highlight border/badge to `src/crates/concat/ui/timeline/model.slint` and `src/crates/concat/ui/timeline/lanes.slint`
- [x] T017 [P] [US4] Add Agent Turn HUD state properties & callbacks (`agent-turn-active`, `agent-turn-summary`, `agent-turn-can-act`, `accept-agent-turn`, `revert-agent-turn`, `cancel-agent-turn`) in `src/crates/concat/ui/editor.slint` and compact HUD bar in `src/crates/concat/ui/timeline/tray.slint`
- [x] T018 [US4] Wire `Studio` (`src/crates/concat/src/studio.rs`, `edit.rs`, `publish.rs`) and `src/crates/concat/src/lib.rs` callbacks to publish `agent_modified` clip highlights, HUD state, and handle Accept/Revert/Cancel actions

**Checkpoint**: Slint GUI compiles cleanly (`quick` profile) and Studio Agent Turn HUD unit tests pass.

---

## Phase 7: User Story 5 — Single Renderer Canvas Parity (`I3`, `P2`) (Priority: P2)

**Goal**: Prove core preview frame rendering and VideoToolbox MP4 export share identical framing and solid black background fill on sub-16:9 clips and alpha-transparent PNG overlays (`P2`).

**Independent Test**: Run `cargo test -p concat-export --offline p2_canvas_alpha_parity`.

### Tests (TDD Red) & Verification

- [x] T019 [US5] Write `P2` regression test rendering a sub-16:9 clip + transparent PNG overlay through both core preview frame path (`concat_export::preview` / `Monitor`) and `concat_export::render_on` VideoToolbox `.mp4`, verifying solid black `[0, 0, 0, 255]` margin pixels and matching `ffmpeg`-extracted frame pixels in `src/crates/concat-export/tests/p2_canvas_parity.rs`
- [x] T020 [US5] Fix any canvas/alpha discrepancy discovered (or confirm shared `over_black` / `flatten_timeline_in` invariant) in `src/crates/concat-export/src/lib.rs` and `src/crates/concat-host/src/preview.rs`

---

## Phase 8: Polish, Review & Milestone 1 Acceptance

- [x] T021 Run `/ponytail-review` across modified crates (`concat-project`, `concat-host`, `concat-api`, `concat-export`, `concat`) without touching `I1–I6`, `contracts/`, or regression tests
- [x] T022 Run `code-review-and-quality` + `/speckit-analyze` consistency check + `graphify update .`
- [x] T023 Run full M1 Exit Test suite (`cargo test` across affected crates + `cargo clippy` + `cargo build -p concat --profile quick --offline`) and record quantitative results in `PROJECT.md`

## Dependencies & Execution Order

- **Phase 1–2** (`dirs.rs`, `lease.rs`) block Phase 5 (`LiveSession` / `OpenProjects`).
- **Phase 3** (`AgentTurn` in `concat-project` + `Session`) blocks Phase 5 (`rollback_agent_turn` on lease recovery) and Phase 6 (Slint HUD).
- **Phase 4** (`P4`) and **Phase 7** (`P2`) can run in parallel once Phase 2 completes.
- Within every phase: **TDD Red test task MUST run and fail before its corresponding implementation task**.
