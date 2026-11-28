# Contract: Editroom Guardrails, `SessionLease`, `AgentTurn` & Hybrid MCP Tools

**Status:** Locked for Milestone 1-E (`I1–I5`, `P1–P4`, `P7–P8`)

---

## 1. `HybridStorage` (`editroom/Editroom/Model/AppStorage.swift`)
- Named `enum HybridStorage` (avoiding collision with SwiftUI `@AppStorage`).
- **Environment Override (`I5`):** `HYBRID_EDIT_DATA_DIR` (non-empty trimmed path).
  - Default when unset: `~/Library/Application Support/hybrid_edit_vid`.
- **Subdirectories:** `Reversed`, `Transcripts`, `Scenes`, `Scrub`, `Waveforms`, `Converted`, `Analysis`, `Notes`, `Magic`, `Downloaded Music`, `Recovery`, `From Photos`, `leases`.
- **UTF-8 Safe Derived Naming (`P7`):**
  - `derivedCacheStem(for: URL, maxPrefixBytes: Int = 120) -> String`:
    - Stamp: `path|size|mtime|inode` hashed with `SHA256` -> 16 lowercase hex chars.
    - Prefix truncated at valid Swift `Character` boundaries so `prefix.utf8.count <= maxPrefixBytes`.
    - Total filename with suffix (`-v2.json`, `.scrub709`, etc.) guaranteed `<= 200` UTF-8 bytes (< APFS 255-byte limit).
- **Atomic Verified Write:** `writeAtomicVerified(_:to:posixPermissions:)` writes `.tmp-<uuid>` -> sets mode (`0o600` for leases) -> atomic replace/move -> verifies file exists with exact byte length.

---

## 2. `SessionLease` & `LeaseManager` (`editroom/Editroom/MCP/SessionLease.swift`)
- **Grace Period Clamping (`P8`):** `5_000...10_000` ms (`default = 8_000` ms).
- **Persistence:** `<HYBRID_EDIT_DATA_DIR>/leases/<sha256_16(projectKey)>.lease.json` (`0o600`).
- **Liveness:** `Darwin.kill(pid, 0)` (`true` iff `res == 0 || errno == EPERM`, `false` for `pid <= 0`).
- **Operations:** `acquire`, `heartbeat`, `setActiveTurn`, `checkWriter`, `release`, `reclaimIfExpired`.
- **Crash Recovery:** Any expired or dead-PID lease holding `activeTurnId != nil` triggers `EditorModel.rollbackAnyActiveAgentTurn()` BEFORE releasing/re-acquiring the write slot.

---

## 3. `EditorModel` `AgentTurn` & `revision` (`editroom/Editroom/Model/AgentTurn.swift`, `EditorModel.swift`)
- `revision: UInt64` increments **only** on committed `Project` mutations (`mutate`, `amendLastStep`, `commitLive`, `commitAgentTurn`, `undo`, `redo`). Selection, playhead, skimming, and zoom/scroll MUST leave `revision`, `undoStack`, and `isDirty` untouched (`P4`).
- **Methods:**
  - `beginAgentTurn(turnId: String, summary: String, sessionId: String?) throws`
  - `commitAgentTurn(turnId: String) throws -> TurnCommit` (pushes `baselineProject` once onto `undoStack` with `TurnMeta`, assigns `project = draft.project`, increments `revision`, clears `redoStack`/`redoTurns`, calls `didChange()`)
  - `rollbackAgentTurn(turnId: String) throws -> UInt64` (discards active turn without touching `undoStack` or `revision`)
  - `rollbackAnyActiveAgentTurn() -> String?`

---

## 4. New & Extended MCP Tools (`editroom/Editroom/MCP/MCPTools+Hybrid.swift`)

| Tool | Required Args | Optional Args | Semantics |
| :--- | :--- | :--- | :--- |
| `session_attach` | — | `session_id`, `client_pid`, `grace_ms` | Acquires or refreshes single-writer lease (`reclaimIfExpired` + auto-rollback first); returns `session_id`, `revision`, `active_turn_id`. |
| `session_heartbeat` | `session_id` | `client_pid` | Refreshes lease heartbeat within grace window. |
| `session_release` | `session_id` | — | Releases lease (rolling back any uncommitted turn owned by `session_id`). |
| `begin_agent_turn` | `turn_id`, `summary` | `session_id` | Acquires/validates lease, opens transactional `ActiveAgentTurn` on `EditorModel`, records `activeTurnId` on lease. |
| `commit_agent_turn` | `turn_id` | `session_id` | Commits active `AgentTurn` into 1 Undo step, clears `activeTurnId` on lease, returns `TurnCommit` (`revision`, `affected_clip_ids`, `pushed_undo_step`). |
| `rollback_agent_turn` | `turn_id` | `session_id` | Discards active turn cleanly, clears `activeTurnId` on lease, returns `revision`. |
| `apply_edl_patch` | `operations` | `session_id` | Atomic batch EDL operations: `keep_ranges` (`clip_id`, `ranges: [{start, end}]`, `coord?: "timeline"\|"source"`, `ripple?: Bool`), `delete_range` (`clip_id`, `start`, `end`, `ripple?: Bool`), `insert_overlay` (`asset_id`, `timeline_start`, `source_start?`, `duration?`, `track?`, `mute_audio?`). |
| `preview_timeline_strip` | `timestamps` | `width`, `grid_cols`, `output` | Renders up to 12 frames through `CompositionBuilder` + `TimelineCompositor` (`I3`/`P2`), draws timestamp labels in a JPEG grid, optionally saves via `writeAtomicVerified`, returns image + metadata. |
| `get_project` *(extended)* | — | — | Now includes `"revision": UInt64` and optional `"active_turn_id": String` at top level (`P1`). |
