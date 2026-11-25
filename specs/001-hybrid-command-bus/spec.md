# Feature Specification: Unified Command Bus, Transactional Agent Turn & Hybrid Timeline Foundation

**Feature Branch**: `001-hybrid-command-bus`

**Created**: 2026-11-25

**Status**: Draft

**Input**: Milestone 1 of `hybrid_edit_vid` — Establish the single state-mutation gateway (`I1`), strict separation of view state from document history (`P4`), transactional multi-step Agent turns sharing the unified Undo/Redo stack (`I1`), live multi-client session ownership with crash-recoverable locking (`I2`, `P8`), Hybrid Timeline visual indicators and Accept/Revert controls, single-renderer canvas parity (`I3`, `P2`), and isolated external data storage (`I5`).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Unified Undo/Redo & Transactional Agent Turns (Priority: P1)

When an AI editing assistant performs a multi-step sequence of timeline edits (such as splitting a clip, trimming silence, and moving segments), the editor groups that entire turn into a single transactional unit so the user sees it as one coherent step and can undo or revert the entire turn with a single action (`Cmd+Z` or the Revert Turn control), while manual user edits share the exact same timeline and undo history.

**Why this priority**: Without a single mutation gateway and grouped Agent turns, multi-step AI edits scatter dozens of partial steps across the undo stack or collide with manual edits, making hybrid human-AI editing unusable.

**Independent Test**: Open a project with sample clips, run a manual edit, execute a multi-command Agent turn containing 5 timeline mutations, verify that a single undo/revert restores the exact state before the Agent turn, and verify that rolling back an interrupted turn leaves zero partial changes.

**Acceptance Scenarios**:

1. **Given** an open project with clips on the timeline, **When** an Agent opens a turn, performs 5 valid timeline edits, and commits the turn, **Then** the entire turn appears as exactly 1 step in the unified Undo history alongside manual edits.
2. **Given** a committed Agent turn on the undo stack, **When** the user triggers Undo or clicks Revert Turn, **Then** all 5 edits from that turn revert atomically to the exact pre-turn project state and Redo can reapply the entire turn as 1 step.
3. **Given** an active uncommitted Agent turn with 3 edits applied, **When** the turn is cancelled or a validation error triggers rollback, **Then** the project returns cleanly to the pre-turn state with 0 new Undo entries and 0 partial edits remaining.
4. **Given** a user performs a manual edit followed by an Agent turn followed by another manual edit, **When** the user undoes three times, **Then** each undo steps cleanly backward through manual edit 2, the entire Agent turn, and manual edit 1 in exact chronological order.

---

### User Story 2 - View State Isolation from Document History & Disk Saves (Priority: P1)

When a user clicks across clips, drags the playhead to scrub video, zooms, or scrolls the timeline, those view-only interactions happen instantaneously in memory without creating false Undo steps or triggering unnecessary project file writes, ensuring `Cmd+Z` always undoes actual timeline edits rather than selection changes.

**Why this priority**: Mixing selection or playhead movement into document history destroys the user's ability to undo an Agent turn after inspecting clips and causes constant redundant disk writes.

**Independent Test**: Load a project, perform 20 clip selection changes and 20 playhead movements, verify 0 new Undo entries and 0 project disk writes occur, then perform 1 clip trim and verify exactly 1 Undo entry and 1 save cycle occur.

**Acceptance Scenarios**:

1. **Given** an open project after a committed Agent turn, **When** the user clicks 20 different clips and moves the playhead 20 times, **Then** the Undo history retains the Agent turn as the very next undoable step and project storage receives 0 write operations.
2. **Given** an open project, **When** the user performs 1 clip split or trim after 20 selection/playhead changes, **Then** exactly 1 new Undo entry is created and the project persists cleanly.

---

### User Story 3 - Live Multi-Client Access & Crash-Recoverable Session Lock (Priority: P1)

When a project is open in the desktop editor window, an authorized local automation client can attach to that exact live session rather than being blocked by an exclusive file lock, and if an automation client crashes abruptly mid-turn, the editor automatically recovers the lock after a short grace period and rolls back any incomplete turn so a subsequent client can resume safely.

**Why this priority**: Exclusive locking prevents live human-AI collaboration on the open timeline, while unrecovered crash locks permanently wedge the project until manual intervention.

**Independent Test**: Open a project in live session mode, start an Agent turn from client A, terminate client A abruptly before commit, wait past the grace period, connect client B, and verify client B acquires write control cleanly with the pre-turn project state intact.

**Acceptance Scenarios**:

1. **Given** a project open in the desktop editor, **When** an authorized local automation client requests live attachment, **Then** it attaches to the active in-memory session with serialized single-writer ordering rather than opening a conflicting separate copy on disk.
2. **Given** client A holds an active write lease and is mid-turn, **When** client B attempts a write mutation before client A commits or expires, **Then** client B's write is rejected with a clear busy-lease error leaving the session consistent.
3. **Given** client A crashes unexpectedly while holding an active lease and an uncommitted turn, **When** client A stops sending heartbeats and the grace period (5–10 seconds) elapses, **Then** the engine automatically rolls back the uncommitted turn, releases the stale lease, and allows client B to acquire the session.
4. **Given** client A briefly loses connection but reconnects and heartbeats within the grace period, **When** client A resumes, **Then** it retains its valid lease without losing session ownership.

---

### User Story 3.5 / Story 4 - Hybrid Timeline Agent Feedback & Controls (Priority: P2)

On the Hybrid Timeline, the user can visually distinguish clips modified by the active or most recent Agent turn, see when an Agent turn is actively running (with progress and a cancel option), and click either **Accept** (dismissing the visual highlight while keeping the turn in the Undo stack) or **Revert Turn** (atomically undoing the turn).

**Why this priority**: Clear visual attribution and one-click Accept/Revert controls build user trust when an AI agent edits the timeline alongside the user.

**Independent Test**: Run a committed Agent turn that adds/modifies 2 clips, verify the Hybrid Timeline highlights those 2 clips and displays the turn controls; click Accept and verify the highlight clears while `Cmd+Z` still undoes the turn; repeat and click Revert Turn to verify immediate atomic revert.

**Acceptance Scenarios**:

1. **Given** an Agent turn is in progress, **When** the user views the workspace, **Then** an unobtrusive status indicator displays the turn summary, active state, and a Cancel control.
2. **Given** an Agent turn commits changes affecting specific clips, **When** the timeline updates, **Then** the affected clips display a distinct visual highlight and the workspace offers Accept and Revert Turn actions.
3. **Given** highlighted clips from a committed Agent turn, **When** the user clicks **Accept**, **Then** the visual highlight clears immediately while the turn remains intact as a single entry in the Undo stack (`Cmd+Z` still reverts it).
4. **Given** highlighted clips from a committed Agent turn, **When** the user clicks **Revert Turn**, **Then** the entire turn is undone in one step and the highlight clears.

---

### User Story 5 - Single Renderer Canvas Parity & Isolated External Data Directory (Priority: P2)

Preview frames and final exported videos share identical framing and background rendering without any editor selection outlines, checkerboard transparency grids, or alignment guides leaking into exported media, while all project files, caches, and runtime data reside in an isolated external application data folder separate from source code and automated test temporary folders.

**Why this priority**: Visual discrepancies between preview and export break editor trust, and mixing user media or test artifacts into the source tree risks data loss.

**Independent Test**: Render a project containing a clip smaller than the 16:9 canvas and a semi-transparent image overlay through both the core preview frame path and the export path, verifying uniform solid background fill and zero editor chrome leakage; verify all project/test artifacts write only inside the configured external data directory.

**Acceptance Scenarios**:

1. **Given** a timeline containing a scaled-down clip leaving empty canvas margins and a transparent-background overlay, **When** a frame is rendered for preview QA and exported to video, **Then** empty canvas regions match the configured background color (solid black by default) with zero checkerboard or UI selection chrome in the exported video.
2. **Given** the application or test suite starts with a configured external data directory override, **When** projects, locks, or caches are created, **Then** all artifacts are written strictly under that external directory and zero files are written inside the source repository.

---

### Edge Cases

- What happens when a user triggers a manual edit on the timeline while an Agent turn is actively open? The single-writer lock rejects or queues conflicting concurrent writes cleanly so neither manual nor Agent state corrupts the other, or requires the active turn to commit/cancel before manual document mutation proceeds.
- What happens when `Cmd+Z` is pressed after an Agent turn was accepted? Because Accept only clears visual attribution, `Cmd+Z` cleanly reverts the entire accepted turn.
- What happens when a subsequent manual edit occurs after a committed Agent turn and the user clicks Revert Turn? Revert Turn safely handles whether the turn is the latest undo step (direct undo) or warns/disables if newer manual edits sit on top of it so later user work is never silently discarded.
- What happens when a project has an unclosed legacy exclusive lock file left on disk from an older crash? Stale dead-process locks are recovered automatically without manual file deletion.
- What happens when the external data directory path does not yet exist on disk? The system creates it securely on startup with private user permissions.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST route every project-mutating operation (manual UI edits, automation requests, and future local AI edits) through a single authoritative command gateway.
- **FR-002**: System MUST separate transient view state (clip selection, playhead position, timeline zoom, scroll offsets, UI highlights) from persistent document state and the Undo/Redo history.
- **FR-003**: System MUST support transactional Agent turns (`begin`, `commit`, `rollback`) that group any number of consecutive turn edits into a single entry on the unified Undo/Redo stack shared with manual edits.
- **FR-004**: System MUST enforce strict serialized write ownership (`one writer at a time`) so manual edits and automation clients never concurrently mutate the same project state.
- **FR-005**: System MUST allow authorized local automation clients to attach to a project currently open in the desktop editor window rather than blocking them with an exclusive file lock.
- **FR-006**: System MUST protect live sessions with a lease-based recoverable lock tracking session identity, client process identity, heartbeat timestamp, and turn state, automatically rolling back uncommitted turns and releasing the lock after a 5–10 second heartbeat grace period if the client terminates abnormally.
- **FR-007**: System MUST allow a temporarily disconnected client to retain its active lease if it reconnects and refreshes its heartbeat before the grace period expires.
- **FR-008**: System MUST publish state-change events containing the current revision and affected clip identifiers whenever a command or turn commits, undoes, redoes, or rolls back so the workspace updates live.
- **FR-009**: The workspace timeline MUST visually highlight clips added or modified by the active/latest Agent turn, display active turn progress with a Cancel option, and provide Accept and Revert Turn actions.
- **FR-010**: Clicking Accept MUST dismiss the visual Agent highlight without removing the turn from the Undo stack; clicking Revert Turn MUST atomically undo the turn when it is at the top of the undo stack (or cleanly undo back safely without silently discarding subsequent user edits).
- **FR-011**: Preview rendering and final video export MUST use the same core composition graph and background fill rules, keeping selection boxes, guides, and checkerboard indicators strictly in the UI presentation layer.
- **FR-012**: System MUST store all projects, locks, runtime caches, and session metadata inside the standard macOS application support data directory by default, honoring an explicit data-directory override for isolated testing without touching source files.

### Key Entities

- **Command**: An atomic, deterministic project state mutation or read-only view update routed through the unified command gateway.
- **AgentTurn**: A transactional editing batch identified by a unique turn ID, summary label, owning lease ID, pre-turn baseline snapshot, and the set of affected clip identifiers.
- **SessionLease**: A recoverable write lock associating an active project session with a client session ID, process ID, heartbeat timestamp, grace-period duration, and active turn state.
- **ViewState**: In-memory UI state (selection, playhead, zoom, scroll, dismissed/active turn highlights) excluded from Undo history and disk saves.
- **StateDiffEvent**: A revision-stamped notification emitted upon committed mutations, undos, redos, or lease recoveries to synchronize the live UI.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Executing 20 clip selection changes and 20 playhead movements produces **0** Undo entries and **0** project file writes, while executing 1 timeline trim produces **1** Undo entry and **1** save cycle.
- **SC-002**: An Agent turn containing 5 or more timeline edits collapses into **1** unified Undo/Redo step, and an aborted or failed turn leaves **0** residual clip mutations.
- **SC-003**: After forcibly terminating an active automation client mid-turn, a second client automatically recovers session ownership and sees the clean pre-turn state within **10 seconds** without manual lock cleanup.
- **SC-004**: Exporting a timeline with empty canvas regions and transparent overlays produces **100%** pixel-consistent background fill matching the core preview frame, with **0** editor UI indicators present in exported video frames.
- **SC-005**: Running 100 consecutive hybrid operations (alternating manual timeline edits, multi-command Agent turns, Accept, Revert Turn, and Undo/Redo) completes with **0** state corruptions or panics, and all test artifacts remain confined to the isolated temporary data directory.

## Assumptions

- Default external data directory on macOS is `~/Library/Application Support/hybrid_edit_vid`, overridable via `HYBRID_EDIT_DATA_DIR`.
- If a user performs new manual edits on top of an already-committed Agent turn before clicking Accept/Revert, the **Revert Turn** button either prompts/disables with clear explanation rather than silently discarding the user's newer manual edits, while `Cmd+Z` steps back chronologically as standard.
- External MCP transport wiring (`hybrid-edit-mcp` binary and Unix Domain Socket listener) is delivered in Milestone 2; Milestone 1 delivers and verifies the core Session/Command Bus, `AgentTurn`, `SessionLease`, Hybrid Timeline Slint UI, and in-process/automated integration tests ready for M2 attachment.
