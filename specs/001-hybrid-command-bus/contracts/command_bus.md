# Contract: Unified Command Bus & `AgentTurn` (`contracts/command_bus.md`)

**Status:** Locked for Milestone 1 (`I1`, `P4`)

## 1. Command Gateway Boundary
Every mutation to `Project` MUST traverse:
- `concat_project::Editor::{apply, apply_within, begin_agent_turn, commit_agent_turn, rollback_agent_turn, undo, redo}`
- Wrapped by `concat_host::Session` / `LiveSession` (`src/crates/concat-host/src/session.rs`), which enforces `SessionLease` write authorization before mutating `Editor` and returns updated `(EditorView, StateDiffEvent)`.

## 2. `AgentTurn` API Contract
```rust
pub struct TurnCommit {
    pub turn_id: String,
    pub summary: String,
    pub revision: u64,
    pub affected_clip_ids: Vec<String>,
    pub pushed_undo_step: bool,
}

pub enum TurnError {
    AlreadyActive { active_turn_id: String },
    NotActive,
    TurnMismatch { expected: String, actual: String },
    CommandFailed(CommandError),
}
```
- **Atomicity:**
  - `begin_agent_turn(turn_id, summary)` fails with `TurnError::AlreadyActive` if another turn is open.
  - While a turn is open, `apply_in_turn(turn_id, cmd)` mutates the draft `Project` inside `Editor`; view-state commands (`cmd.is_view_state()`) are rejected inside an agent turn or ignored without touching undo.
  - `commit_agent_turn(turn_id)` finalizes the draft into **at most 1** Undo `Snapshot` (with `TurnMeta`), clears `redo`, increments `revision` if project changed, and returns `TurnCommit`.
  - `rollback_agent_turn(turn_id)` discards all draft changes, restores `baseline_project`, keeps `IdMint` intact, and increments **0** undo steps.

## 3. `ViewState` vs `DocumentState` Invariant (`P4`)
- Operations modifying `selection`, `playhead`, `zoom`, `scroll`, or `dismissed_turn_ids` MUST NOT:
  - call `Editor::apply` with a document-mutating command,
  - push onto `Editor::undo` or clear `Editor::redo`,
  - increment `Session::revision`,
  - mark `dirty = true` or invoke `schedule_autosave()` / `save_document()`.
- `Studio::accept_agent_turn()` clears `highlighted_clip_ids` and records `turn_id` in `dismissed_turn_ids` (UI `ViewState` only), leaving `Editor::undo` unchanged so `Cmd+Z` still reverts the turn.
- `Studio::revert_agent_turn()` checks whether the top of `Editor::undo` matches the highlighted `turn_id`:
  - if yes, calls `Studio::undo()` (atomically reverting the turn in 1 step and clearing highlights);
  - if newer manual edits sit above it on the Undo stack, refuses silent discard and displays a clear non-destructive notice telling the user newer manual edits exist above the Agent turn.
