// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 hybrid_edit_vid contributors

//! Lease-based recoverable lock for live multi-client sessions (`I2`, `P8`).

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Minimum allowed grace period in milliseconds (5s).
pub const MIN_GRACE_MS: u64 = 5_000;
/// Maximum allowed grace period in milliseconds (10s).
pub const MAX_GRACE_MS: u64 = 10_000;
/// Default grace period in milliseconds (8s).
pub const DEFAULT_GRACE_MS: u64 = 8_000;

/// Role of a lease holder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LeaseRole {
    /// Native desktop GUI window.
    Window,
    /// External agent attached live to the open session.
    LiveAgent,
    /// Headless agent operating when the GUI is closed.
    HeadlessAgent,
}

/// Persisted and in-memory write lease (`SessionLease`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionLease {
    /// Unique client session identifier.
    pub session_id: String,
    /// OS process ID of the holding client.
    pub client_pid: u32,
    /// Holder role.
    pub role: LeaseRole,
    /// Timestamp when acquired (Unix ms).
    pub acquired_at_ms: u64,
    /// Last heartbeat timestamp (Unix ms).
    pub last_heartbeat_at_ms: u64,
    /// Grace period duration in ms (clamped `5000..=10000`).
    pub grace_period_ms: u64,
    /// Active uncommitted `AgentTurn` identifier, if any.
    pub active_turn_id: Option<String>,
}

/// Information about a reclaimed expired/crashed lease.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveredLease {
    /// Expired session identifier.
    pub session_id: String,
    /// Dead or timed-out PID.
    pub client_pid: u32,
    /// Uncommitted turn ID that must be rolled back.
    pub uncommitted_turn_id: Option<String>,
}

/// Errors returned by `LeaseManager`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LeaseError {
    /// Another live client holds the write lease.
    Busy {
        /// Holding session ID.
        holder_session_id: String,
        /// Holding PID.
        client_pid: u32,
    },
    /// Operation referenced a session that does not hold the lease.
    NotOwner,
    /// Invalid lease arguments (e.g. empty session_id or zero PID).
    Invalid(String),
    /// Filesystem persistence error.
    Io(String),
}

impl std::fmt::Display for LeaseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LeaseError::Busy {
                holder_session_id,
                client_pid,
            } => write!(
                f,
                "session lease held by {holder_session_id} (pid {client_pid})"
            ),
            LeaseError::NotOwner => f.write_str("caller does not own the active session lease"),
            LeaseError::Invalid(msg) => f.write_str(msg),
            LeaseError::Io(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for LeaseError {}

/// Returns current Unix epoch time in milliseconds.
pub fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Coordinates single-writer `SessionLease` ownership with crash recovery (`P8`).
pub struct LeaseManager {
    lease_dir: PathBuf,
    lease_path: PathBuf,
    grace_period_ms: u64,
    current: Option<SessionLease>,
}

impl LeaseManager {
    /// Creates a lease manager persisting state under `lease_dir` for `project_key`.
    pub fn new(lease_dir: PathBuf, project_key: &str, grace_period: Duration) -> Self {
        let clamped_ms = (grace_period.as_millis() as u64).clamp(MIN_GRACE_MS, MAX_GRACE_MS);
        let mut hasher = Sha256::new();
        hasher.update(project_key.as_bytes());
        let digest = format!("{:x}", hasher.finalize());
        let lease_path = lease_dir.join(format!("{}.lease.json", &digest[..16]));
        let mut mgr = Self {
            lease_dir,
            lease_path,
            grace_period_ms: clamped_ms,
            current: None,
        };
        mgr.reload_from_disk();
        mgr
    }

    /// Path to the persisted lease metadata file.
    pub fn lease_path(&self) -> &Path {
        &self.lease_path
    }

    /// Acquires the write lease or reclaims an expired/dead lease.
    pub fn acquire(
        &mut self,
        session_id: &str,
        client_pid: u32,
        role: LeaseRole,
        now_ms: u64,
    ) -> Result<(SessionLease, Option<RecoveredLease>), LeaseError> {
        if session_id.trim().is_empty() {
            return Err(LeaseError::Invalid("session_id must not be empty".into()));
        }
        if client_pid == 0 {
            return Err(LeaseError::Invalid("client_pid must be > 0".into()));
        }
        self.reload_from_disk();
        let recovered = self.reclaim_if_expired(now_ms);

        if let Some(existing) = &self.current {
            if existing.session_id == session_id {
                let mut refreshed = existing.clone();
                refreshed.client_pid = client_pid;
                refreshed.last_heartbeat_at_ms = now_ms;
                self.persist(&refreshed)?;
                self.current = Some(refreshed.clone());
                return Ok((refreshed, recovered));
            }
            return Err(LeaseError::Busy {
                holder_session_id: existing.session_id.clone(),
                client_pid: existing.client_pid,
            });
        }

        let lease = SessionLease {
            session_id: session_id.to_owned(),
            client_pid,
            role,
            acquired_at_ms: now_ms,
            last_heartbeat_at_ms: now_ms,
            grace_period_ms: self.grace_period_ms,
            active_turn_id: None,
        };
        self.persist(&lease)?;
        self.current = Some(lease.clone());
        Ok((lease, recovered))
    }

    /// Refreshes heartbeat for `session_id` within grace period.
    pub fn heartbeat(
        &mut self,
        session_id: &str,
        client_pid: u32,
        now_ms: u64,
    ) -> Result<SessionLease, LeaseError> {
        self.reload_from_disk();
        let Some(existing) = self.current.as_mut() else {
            return Err(LeaseError::NotOwner);
        };
        if existing.session_id != session_id {
            return Err(LeaseError::Busy {
                holder_session_id: existing.session_id.clone(),
                client_pid: existing.client_pid,
            });
        }
        if is_expired(existing, now_ms) {
            self.clear_disk();
            self.current = None;
            return Err(LeaseError::NotOwner);
        }
        existing.client_pid = client_pid;
        existing.last_heartbeat_at_ms = now_ms;
        let updated = existing.clone();
        self.persist(&updated)?;
        Ok(updated)
    }

    /// Marks or clears an active uncommitted turn on the held lease.
    pub fn set_active_turn(
        &mut self,
        session_id: &str,
        turn_id: Option<String>,
        now_ms: u64,
    ) -> Result<(), LeaseError> {
        self.reload_from_disk();
        let Some(existing) = self.current.as_mut() else {
            return Err(LeaseError::NotOwner);
        };
        if existing.session_id != session_id {
            return Err(LeaseError::NotOwner);
        }
        existing.active_turn_id = turn_id;
        existing.last_heartbeat_at_ms = now_ms;
        let updated = existing.clone();
        self.persist(&updated)
    }

    /// Checks whether `session_id` is authorized to execute a write right now.
    pub fn check_writer(
        &mut self,
        session_id: Option<&str>,
        now_ms: u64,
    ) -> Result<Option<RecoveredLease>, LeaseError> {
        self.reload_from_disk();
        let recovered = self.reclaim_if_expired(now_ms);
        match (&self.current, session_id) {
            (None, _) => Ok(recovered),
            (Some(held), Some(caller)) if held.session_id == caller => Ok(recovered),
            (Some(held), _) => Err(LeaseError::Busy {
                holder_session_id: held.session_id.clone(),
                client_pid: held.client_pid,
            }),
        }
    }

    /// Releases the held lease cleanly.
    pub fn release(&mut self, session_id: &str) -> Result<(), LeaseError> {
        self.reload_from_disk();
        match &self.current {
            Some(existing) if existing.session_id == session_id => {
                self.current = None;
                self.clear_disk();
                Ok(())
            }
            Some(_) => Err(LeaseError::NotOwner),
            None => Ok(()),
        }
    }

    /// Reclaims any expired or dead-PID lease.
    pub fn reclaim_if_expired(&mut self, now_ms: u64) -> Option<RecoveredLease> {
        self.reload_from_disk();
        let existing = self.current.as_ref()?;
        if !is_expired(existing, now_ms) {
            return None;
        }
        let rec = RecoveredLease {
            session_id: existing.session_id.clone(),
            client_pid: existing.client_pid,
            uncommitted_turn_id: existing.active_turn_id.clone(),
        };
        self.current = None;
        self.clear_disk();
        Some(rec)
    }

    /// Returns the currently held lease, if any.
    pub fn current(&self) -> Option<&SessionLease> {
        self.current.as_ref()
    }

    fn reload_from_disk(&mut self) {
        if let Ok(bytes) = fs::read(&self.lease_path)
            && let Ok(parsed) = serde_json::from_slice::<SessionLease>(&bytes)
        {
            self.current = Some(parsed);
        } else if !self.lease_path.exists() {
            self.current = None;
        }
    }

    fn persist(&self, lease: &SessionLease) -> Result<(), LeaseError> {
        fs::create_dir_all(&self.lease_dir)
            .map_err(|e| LeaseError::Io(format!("create lease dir: {e}")))?;
        let tmp = self
            .lease_path
            .with_extension(format!("tmp-{}", std::process::id()));
        let bytes = serde_json::to_vec_pretty(lease)
            .map_err(|e| LeaseError::Io(format!("serialize lease: {e}")))?;

        let mut opts = OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut file = opts
            .open(&tmp)
            .map_err(|e| LeaseError::Io(format!("open lease tmp: {e}")))?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|e| LeaseError::Io(format!("write lease tmp: {e}")))?;
        fs::rename(&tmp, &self.lease_path)
            .map_err(|e| LeaseError::Io(format!("rename lease: {e}")))?;
        Ok(())
    }

    fn clear_disk(&self) {
        let _ = fs::remove_file(&self.lease_path);
    }
}

fn is_expired(lease: &SessionLease, now_ms: u64) -> bool {
    if !pid_is_alive(lease.client_pid) {
        return true;
    }
    now_ms.saturating_sub(lease.last_heartbeat_at_ms) >= lease.grace_period_ms
}

#[cfg(unix)]
fn pid_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    // Safety: signal 0 probes process existence without delivering a signal.
    let res = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if res == 0 {
        return true;
    }
    let err = std::io::Error::last_os_error();
    err.raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn pid_is_alive(pid: u32) -> bool {
    pid != 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn p8_lease_rejects_concurrent_writer_and_recovers_after_grace_period() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut mgr = LeaseManager::new(
            tmp.path().to_path_buf(),
            "proj-a",
            Duration::from_millis(6_000),
        );
        let pid = std::process::id();
        let (lease_a, rec) = mgr
            .acquire("agent-a", pid, LeaseRole::LiveAgent, 1_000)
            .expect("client A acquires");
        assert!(rec.is_none());
        assert_eq!(lease_a.grace_period_ms, 6_000);

        mgr.set_active_turn("agent-a", Some("turn-1".into()), 1_500)
            .expect("marks active turn");

        let busy = mgr
            .acquire("agent-b", pid, LeaseRole::LiveAgent, 4_000)
            .expect_err("B rejected while A live");
        assert!(matches!(busy, LeaseError::Busy { .. }));

        let renewed = mgr
            .heartbeat("agent-a", pid, 5_000)
            .expect("A renews within grace");
        assert_eq!(renewed.active_turn_id.as_deref(), Some("turn-1"));

        let (lease_b, recovered) = mgr
            .acquire("agent-b", pid, LeaseRole::LiveAgent, 11_500)
            .expect("B recovers expired lease");
        assert_eq!(lease_b.session_id, "agent-b");
        assert_eq!(
            recovered,
            Some(RecoveredLease {
                session_id: "agent-a".into(),
                client_pid: pid,
                uncommitted_turn_id: Some("turn-1".into()),
            })
        );
    }

    #[test]
    fn grace_period_is_clamped_to_five_to_ten_seconds() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let low = LeaseManager::new(tmp.path().to_path_buf(), "p1", Duration::from_secs(1));
        assert_eq!(low.grace_period_ms, 5_000);
        let high = LeaseManager::new(tmp.path().to_path_buf(), "p2", Duration::from_secs(30));
        assert_eq!(high.grace_period_ms, 10_000);
    }
}
