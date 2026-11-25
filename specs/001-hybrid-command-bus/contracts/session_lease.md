# Contract: Lease-Based Recoverable Lock & Live Session (`contracts/session_lease.md`)

**Status:** Locked for Milestone 1 (`I2`, `P8`)

## 1. Live-Attach Ownership (`OpenProjects` Evolution)
- `OpenProjects` (`src/crates/concat-api/src/lib.rs`) MUST distinguish:
  - **Window + Live Agent Coexistence:** When `Holder::Window` holds a project open, `Holder::Api` attaching in Live Mode does NOT receive `Refusal::Here(Holder::Window)`. Instead, `Api` routes write requests through the shared `LiveSessionHandle` (`Arc<Mutex<LiveSession>>`) owned by the process, serializing writes behind `SessionLease`.
  - **Cross-Process Fallback / Recovery:** `concat_host::lock::ProjectLock` continues to protect against two separate OS processes writing the same project folder concurrently, while `SessionLease` governs active automation writers and crash recovery inside/across sessions.

## 2. `SessionLease` Operations
```rust
pub struct LeaseConfig {
    pub grace_period: Duration, // MUST be clamped within 5s..=10s in production; configurable for fast tests
}

pub trait LeaseGuard {
    fn acquire(&mut self, session_id: &str, client_pid: u32, role: LeaseRole, now_ms: u64) -> Result<SessionLease, LeaseError>;
    fn heartbeat(&mut self, session_id: &str, client_pid: u32, now_ms: u64) -> Result<SessionLease, LeaseError>;
    fn release(&mut self, session_id: &str) -> Result<(), LeaseError>;
    fn check_writer(&mut self, session_id: Option<&str>, now_ms: u64) -> Result<(), LeaseError>;
    fn reclaim_expired(&mut self, now_ms: u64) -> Option<RecoveredLease>;
}
```

## 3. Crash Recovery Semantics (`P8`)
- If client A (`session_id = A`, `client_pid = P_A`) dies (`kill -9`, so OS PID `P_A` is no longer alive) OR misses heartbeats for `>= grace_period`:
  1. `reclaim_expired` marks lease `A` expired.
  2. If `A` held `active_turn_id = Some(turn_id)`, the coordinator invokes `rollback_agent_turn(turn_id)` BEFORE releasing the write slot.
  3. Client B (`session_id = B`, `client_pid = P_B`) acquires the lease cleanly and sees `revision` equal to the pre-turn state.
- If client A reconnects and calls `heartbeat(A, P_A, now)` **before** `grace_period` elapses, lease `A` stays valid and `active_turn_id` is preserved.
- Lease metadata persisted to disk (for cross-process recovery) MUST live under `HYBRID_EDIT_DATA_DIR/leases/` (via `AppDirs`, `I5`), using atomic write + `chmod 600` on Unix.
