// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 hybrid_edit_vid contributors

//! Real OS `kill -9` (`SIGKILL`) regression test for Lease-based Recoverable Lock (`P8`).

use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use concat_host::lease::{LeaseManager, LeaseRole, now_unix_ms};
use concat_host::session::{LiveSession, Session};
use concat_host::projects;
use concat_project::Command as EditCommand;

#[test]
fn p8_crash_recovery_after_sigkill_mid_turn() {
    if std::env::var("P8_CHILD_ROLE").as_deref() == Ok("crash_holder") {
        let lease_dir = PathBuf::from(std::env::var("P8_LEASE_DIR").expect("lease dir"));
        let project_key = std::env::var("P8_PROJECT_KEY").expect("project key");
        let mut mgr = LeaseManager::new(lease_dir, &project_key, Duration::from_secs(6));
        mgr.acquire("crashed-agent", std::process::id(), LeaseRole::LiveAgent, now_unix_ms())
            .expect("child acquires lease");
        mgr.set_active_turn("crashed-agent", Some("turn-crash".into()), now_unix_ms())
            .expect("child starts turn");
        println!("READY");
        std::thread::sleep(Duration::from_secs(60));
        return;
    }

    let scratch = tempfile::tempdir().expect("scratch");
    let lease_dir = scratch.path().join("leases");
    let proj_root = scratch.path().join("projects");
    std::fs::create_dir_all(&proj_root).expect("proj root");

    let info = projects::create(
        &proj_root.to_string_lossy(),
        "P8Crash",
        1920,
        1080,
        30,
        1,
        [0, 0, 0, 255],
    )
    .expect("create project");
    let session = Session::open_info(&info).expect("open session");
    let mut live = LiveSession::new(session, lease_dir.clone(), Duration::from_secs(6));

    // Start an uncommitted turn on the live session, matching what client 1 held.
    live.session(); // verify readable
    let exe = std::env::current_exe().expect("current test exe");
    let mut child = Command::new(exe)
        .arg("--exact")
        .arg("p8_crash_recovery_after_sigkill_mid_turn")
        .arg("--nocapture")
        .env("P8_CHILD_ROLE", "crash_holder")
        .env("P8_LEASE_DIR", &lease_dir)
        .env("P8_PROJECT_KEY", &info.path)
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn child holder");

    let stdout = child.stdout.take().expect("child stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line).expect("read child stdout");
        assert!(n > 0, "child exited before signaling READY");
        if line.trim() == "READY" {
            break;
        }
    }

    // Client 2 cannot acquire while child process is alive within grace period.
    let busy = live.acquire_lease("client-2", std::process::id(), LeaseRole::LiveAgent, now_unix_ms());
    assert!(busy.is_err(), "live child must hold exclusive write lease");

    // Simulate uncommitted turn in engine state before abrupt SIGKILL of client 1.
    // Reconstruct state by letting child's turn id be active on session too:
    let mut inner = Session::open_info(&info).expect("open");
    let pre_tracks = inner.project().active().tracks.len();
    inner.begin_agent_turn("turn-crash", "Crashed turn").expect("begin");
    inner
        .apply_in_turn(
            "turn-crash",
            EditCommand::AddTrack { bottom: false },
        )
        .expect("uncommitted edit");
    assert_eq!(inner.project().active().tracks.len(), pre_tracks + 1);

    let mut live_with_turn = LiveSession::new(inner, lease_dir.clone(), Duration::from_secs(6));

    // Kill client 1 abruptly with SIGKILL (kill -9).
    child.kill().expect("SIGKILL child");
    let _ = child.wait();

    // Client 2 immediately recovers dead PID lease and rolls back uncommitted turn!
    let (lease_2, recovered) = live_with_turn
        .acquire_lease("client-2", std::process::id(), LeaseRole::LiveAgent, now_unix_ms())
        .expect("client 2 recovers after SIGKILL");
    assert_eq!(lease_2.session_id, "client-2");
    assert!(recovered.is_some());
    assert_eq!(
        live_with_turn.session().project().active().tracks.len(),
        pre_tracks,
        "uncommitted turn must be rolled back cleanly"
    );
    assert!(live_with_turn.session().active_turn_id().is_none());
}
