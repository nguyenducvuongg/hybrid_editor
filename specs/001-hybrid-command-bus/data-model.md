# Data Model: Milestone 1 — Unified Command Bus & Hybrid Session

## Entities

### 1. `AgentTurn` (`concat_project::editor::AgentTurn`)
Represents an active or committed transactional batch of commands from an AI agent.
- `AgentTurn.turn_id`: `String` (non-empty, unique monotonic or UUID-formatted identifier, max 64 bytes)
- `AgentTurn.summary`: `String` (human-readable label for HUD and Undo menu, 1..=160 chars)
- `AgentTurn.lease_id`: `Option<String>` (owning `SessionLease.session_id` when driven by an external client)
- `AgentTurn.baseline_revision`: `u64` (document revision when turn opened)
- `AgentTurn.baseline_project`: `Project` (immutable `Arc`-shared snapshot before turn began)
- `AgentTurn.command_count`: `usize` (number of commands successfully applied inside this turn)
- `AgentTurn.affected_clip_ids`: `Vec<String>` (deduplicated clip IDs added or modified relative to `baseline_project`)
- `AgentTurn.status`: `TurnStatus` (`Active | Committed | RolledBack`)

**Validation & Transition Rules:**
- Only **one** `AgentTurn` may be `Active` on an `Editor` at any instant (`Active` -> `Committed` or `RolledBack`).
- `commit_agent_turn(turn_id)` MUST fail with `TurnError::Mismatch` if `turn_id` does not match the currently active turn.
- On `commit_agent_turn`, if `affected_clip_ids` is empty and project state equals `baseline_project`, no Undo entry is pushed; otherwise **exactly 1** Undo `Snapshot` is pushed with `TurnMeta` and `redo` is cleared.
- On `rollback_agent_turn`, `project` is restored to `baseline_project` while `IdMint` stays monotonic (`I1`).

### 2. `TurnMeta` (`concat_project::editor::TurnMeta`)
Metadata attached to an Undo `Snapshot` created by a committed `AgentTurn`.
- `TurnMeta.turn_id`: `String`
- `TurnMeta.summary`: `String`
- `TurnMeta.affected_clip_ids`: `Vec<String>`
- `TurnMeta.revision`: `u64` (revision after commit)

### 3. `SessionLease` (`concat_host::lease::SessionLease`)
Recoverable write lease guarding live multi-client access (`I2`, `P8`).
- `SessionLease.session_id`: `String` (non-empty UUID/unique client session identifier)
- `SessionLease.client_pid`: `u32` (OS process ID of the lease holder, > 0)
- `SessionLease.role`: `LeaseRole` (`Window | LiveAgent | HeadlessAgent`)
- `SessionLease.acquired_at_ms`: `u64` (Unix epoch milliseconds)
- `SessionLease.last_heartbeat_at_ms`: `u64` (Unix epoch milliseconds)
- `SessionLease.grace_period_ms`: `u64` (bounded `5000..=10000`, default `8000`)
- `SessionLease.active_turn_id`: `Option<String>` (non-null while an uncommitted `AgentTurn` is open)

**Validation & Transition Rules:**
- Acquire succeeds if no lease exists, OR existing lease's `client_pid` is dead, OR `now_ms - last_heartbeat_at_ms >= grace_period_ms`.
- If an expired/dead lease had `active_turn_id: Some(tid)`, lease recovery MUST atomically trigger `rollback_agent_turn(tid)` before granting ownership to the new client.
- Heartbeat / reclaim with matching `session_id` within `grace_period_ms` refreshes `last_heartbeat_at_ms` and preserves `active_turn_id`.
- A non-holder client attempting write mutation while a live lease is active MUST be rejected with `LeaseError::Busy { holder_session_id, client_pid }`.

### 4. `StateDiffEvent` (`concat_host::session::StateDiffEvent`)
Emitted synchronously upon commit, undo, redo, or rollback (`I1`, `I2`).
- `StateDiffEvent.revision`: `u64` (monotonically increasing project revision)
- `StateDiffEvent.source`: `MutationSource` (`Manual | AgentTurn { turn_id, summary } | Undo | Redo | LeaseRollback { turn_id }`)
- `StateDiffEvent.affected_clip_ids`: `Vec<String>`
- `StateDiffEvent.can_undo`: `bool`
- `StateDiffEvent.can_redo`: `bool`

### 5. `ViewState` (UI-only, non-serialized in `Undo` — `P4`)
- `Studio.selection`: `Vec<String>`
- `Studio.playhead`: `f32`
- `Studio.lanes` (zoom, scroll, snap, locked lanes)
- `Studio.active_agent_turn`: `Option<AgentTurnHudState>` (`turn_id`, `summary`, `in_progress: bool`, `highlighted_clip_ids: HashSet<String>`, `dismissed_turn_ids: HashSet<String>`)
- `Studio.revision`: `u64` (only increments on `DocumentState` mutations, NEVER on `ViewState` changes)
