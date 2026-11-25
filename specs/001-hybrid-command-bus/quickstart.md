# Quickstart Validation Guide: Milestone 1

## Prerequisites
- Rust `1.93.1` (`src/rust-toolchain.toml`), `ffmpeg` / `ffprobe` (VideoToolbox), `pkg-config`.
- Isolated temporary data directory (`HYBRID_EDIT_DATA_DIR` set to a temp path under `/tmp`).

## Validation Scenarios

1. **P4 · ViewState vs DocumentState Isolation:**
   - Run `cargo test -p concat-host --offline p4_view_state_does_not_write_or_pollute_undo` (and `concat-project` tests).
   - Verifies 20 clip selections + 20 playhead movements cause **0** undo entries and **0** disk writes; 1 timeline trim causes **1** undo entry and **1** save cycle.

2. **I1 · Transactional `AgentTurn` & 100-Step Hybrid Stress Test:**
   - Run `cargo test -p concat-project --offline agent_turn` and `cargo test -p concat-host --offline hybrid_100_ops`.
   - Verifies multi-command turn collapses to 1 Undo/Redo step, `rollback_agent_turn` leaves 0 partial mutations, and 100 interleaved manual/agent/undo/redo/accept/revert ops pass cleanly.

3. **I2 & P8 · Lease-Based Recoverable Lock & `kill -9` Crash Recovery:**
   - Run `cargo test -p concat-host --offline p8_crash_recovery` (including a real child-process `kill -9` test).
   - Verifies client A starts turn -> `kill -9` client A -> client B recovers ownership after grace period with pre-turn state intact, and reconnect within grace period preserves lease.

4. **I3 & P2 · Single Renderer Parity (Sub-16:9 Clip + Alpha PNG):**
   - Run `cargo test -p concat-export --offline p2_canvas_alpha_parity` + `ffprobe`/pixel verification on rendered MP4 & core preview frame.
   - Verifies uncovered canvas is solid black `[0, 0, 0, 255]` and transparent PNG alpha blends identically on preview and VideoToolbox MP4 export.

5. **Full M1 Build & Test Verification:**
   - `cd src && cargo test -p concat-project -p concat-host -p concat-api -p concat-export --offline`
   - `cd src && cargo build -p concat --profile quick --offline` (verifies Slint Hybrid Timeline UI compiles cleanly with zero errors).
