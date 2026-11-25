<p align="center">
  <img src="assets/concat-mark-dark.png" alt="Hybrid Editor mark" width="88" />
</p>

<h1 align="center">Hybrid Editor (<code>hybrid_edit_vid</code>)</h1>

<p align="center">
  <strong>Native AI-Hybrid Video Editor for macOS Apple Silicon</strong><br />
  <sub>Built on <a href="https://github.com/jub0t/Concat">Concat</a> (Rust + Slint + FFmpeg + Metal + CoreML + whisper.cpp)</sub>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL%20v3-0568FD?style=flat" alt="License: AGPL-3.0-or-later" /></a>
  <img src="https://img.shields.io/badge/Platform-macOS%20Apple%20Silicon%20(M4%20Pro)-212123?style=flat" alt="Platform: macOS Apple Silicon" />
  <img src="https://img.shields.io/badge/Stack-Rust%20%2B%20Slint%20%2B%20FFmpeg%20%2B%20Metal-18181b?style=flat" alt="Stack" />
</p>

<p align="center">
  <a href="#overview"><strong>🇬🇧 English</strong></a> · <a href="#tiếng-việt"><strong>🇻🇳 Tiếng Việt</strong></a>
</p>

---

## Overview

**Hybrid Editor (`hybrid_edit_vid`)** is a native desktop video editor combining direct human timeline manipulation in **Slint** with transactional AI agent workflows (**Antigravity 2.0** over a Live-Attach MCP Gateway and local Apple Silicon AI inference).

Instead of wrapping a browser timeline, `hybrid_edit_vid` builds directly on [jub0t/Concat](https://github.com/jub0t/Concat) (`v0.2.12`, `AGPL-3.0-or-later`) while preserving full upstream compatibility, native VideoToolbox hardware encode/decode, Metal GPU compositing, and atomic project persistence.

### Core Architectural Invariants (`I1–I6`)

| Invariant | Principle |
| :--- | :--- |
| **I1 · Unified Command Bus & Transactional `AgentTurn`** | Every timeline edit—manual UI or AI Agent—passes through `concat_project::Editor`. An `AgentTurn` groups $N$ agent commands into a single atomic `Undo`/`Redo` step (`Cmd+Z`) with pre-turn rollback and clean `ViewState` separation (`P4`). |
| **I2 · Live-Attach & Recoverable Leases** | External agents can attach live to an open window session behind single-writer `SessionLease` serialization (`HYBRID_EDIT_DATA_DIR/leases/`, `5–10s` grace, PID check, automatic uncommitted turn rollback on `SIGKILL`, `P8`). |
| **I3 · Single Renderer Parity** | Preview frames, agent visual feedback strips, and VideoToolbox `.mp4` exports share the same compositor/canvas rules (`P2`) without leaking UI selection or agent-highlight overlays into exported frames. |
| **I4 · Local AI Cache & Skill Separation** | Dev-workflow skills stay cleanly separated from runtime editing skills (`assets/editor-skills/`). Media intelligence (transcripts, VAD segments, scene indices) is cached per content hash/stream signature. |
| **I5 · Data Isolation** | Application data defaults to `~/Library/Application Support/hybrid_edit_vid` and is cleanly overridable via `HYBRID_EDIT_DATA_DIR` for isolated builds and tests. |
| **I6 · Quantitative Hardware Verification** | Every milestone is verified against real builds, `cargo test`, `cargo clippy`, `ffprobe`, and Apple Silicon benchmarks before acceptance. |

---

## Repository Structure

```text
hybrid_editor/
├── README.md                        # Project overview, architecture, build & test guide (EN / VI)
├── PROJECT.md                       # Living engineering log, Graphify anatomy & M4 Pro benchmarks
├── LICENSE / LICENSING.md           # AGPL-3.0-or-later & third-party licensing terms
├── THIRD_PARTY_NOTICES.md           # Upstream and dependency attributions
├── src/                             # Rust workspace (Cargo.toml, crates/*, Slint UI, patches/*)
│   ├── crates/concat-project/       # Document model, commands, unified Editor & AgentTurn undo stack
│   ├── crates/concat-host/          # Session lifecycle, AppDirs (I5), LeaseManager (P8), LiveSession
│   ├── crates/concat-api/           # JSON-RPC API, OpenProjects live-attach sharing
│   ├── crates/concat-export/        # Shared preview/export flattening & VideoToolbox pipeline
│   ├── crates/concat-media/         # FFmpeg 9.1 + VideoToolbox/AudioToolbox decode & encode
│   ├── crates/concat-render/        # wgpu/Metal GPU compositor
│   ├── crates/concat-mcp/           # Built-in MCP server
│   └── crates/concat/               # Native Slint GUI + Hybrid Timeline HUD
├── assets/
│   └── editor-skills/               # Runtime video-editing skills (separate from dev-workflow skills)
├── kit/                             # Antigravity Starter Kit v2 docs & bootstrap prompt
│   ├── README.md
│   ├── ANTIGRAVITY_BOOTSTRAP_PROMPT.md
│   ├── PROJECT_BRIEF.md
│   ├── CONSTITUTION_SEED.md
│   ├── PITFALLS_AND_FIXES.md
│   ├── TOOLCHAIN_AND_SPECKIT_GUIDE.md
│   └── EDITOR_SKILLS_SPEC.md
├── specs/                           # Spec Kit specifications, plans, contracts & task checklists
│   └── 001-hybrid-command-bus/
├── docs/                            # Upstream Concat docs & archived upstream README (README.concat.md)
├── scripts/                         # Build, locale check & FFmpeg packaging helpers
├── models/                          # Model manifests & runtime metadata
├── android-native/                  # Upstream mobile target sources
└── .specify/ & .agents/             # Project Constitution, Spec Kit templates & Graphify rules
```

---

## Roadmap & Current Status

- [x] **Milestone 0 — Toolchain, Constitution & Baseline:** Ratified [constitution.md](.specify/memory/constitution.md), Graphify AST baseline, and verified VideoToolbox/Metal export on Apple M4 Pro.
- [x] **Milestone 1 — Unified Command Bus, `AgentTurn`, Recoverable Leases & Hybrid Timeline HUD** ([specs/001-hybrid-command-bus](specs/001-hybrid-command-bus/spec.md)):
  - `Editor` transactional `AgentTurn` (`begin_agent_turn`, `apply_in_turn`, `commit_agent_turn`, `rollback_agent_turn`) grouped into 1 Undo/Redo entry.
  - `LeaseManager` (`0o600` persisted lease, `5–10s` grace, PID liveness, real `SIGKILL` crash-recovery test `p8_crash_recovery`).
  - `ViewState` vs `DocumentState` isolation (`P4`) and `OpenProjects::claim_live` + `Api::live_sessions` serialized multi-client access.
  - Native Slint Hybrid Timeline highlights (`ClipData.agent-modified`, `AI` badge) and HUD (`Cancel`, `Accept`, `Revert Turn` — where `Accept` clears highlights while preserving `Cmd+Z` undo).
  - Single-renderer alpha/canvas parity (`p2_canvas_parity`) between `preview_frame` and `h264_videotoolbox` `.mp4`.
- [ ] **Milestone 2 — Live-Attach UDS MCP Gateway & Perception Tools:** Unix Domain Socket (`chmod 600`) live attach from `Studio`/`Host`, `inspect_project_tree`, `inspect_timeline`, and visual `preview_timeline_strip`.
- [ ] **Milestone 3 — Smart A-Roll Engine:** Silero VAD + `whisper.cpp` (Metal, `large-v3-turbo`), anti-hallucination gating (`P6`), file-hash caching (`P7`), and `aroll-rough-cut` skill.
- [ ] **Milestone 4 — Smart B-Roll Context Engine:** Scene cut detection + keyframe extraction + SQLite semantic index (local VLM / Antigravity fallback) + `smart-broll-inserter` skill.
- [ ] **Milestone 5 — End-to-End Integration, Context Budget & Hardening:** Full 5-round autonomous edit + manual hybrid verification on 4K/1080p footage.

See [PROJECT.md](PROJECT.md) for detailed test outputs, Graphify anatomy notes, and the dependency license inventory.

---

## Build & Test (macOS Apple Silicon)

### Prerequisites

- **macOS Apple Silicon** (tested on MacBook Pro M4 Pro, macOS `27.3`, `24 GiB` Unified Memory)
- **Rust toolchain** pinned by [src/rust-toolchain.toml](src/rust-toolchain.toml) (`rustc 1.93.1`)
- **FFmpeg**, **CMake**, **pkg-config** (`brew install ffmpeg cmake pkg-config`)

### Build the Native Slint App

```bash
cd src
HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_dev cargo build -p concat --profile quick
```

### Run Milestone 1 Verification Tests

```bash
cd src
export HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_test

cargo test -p concat-project --offline
cargo test -p concat-host --offline --test p8_crash_recovery
cargo test -p concat-host --offline --lib
cargo test -p concat-api --offline
cargo test -p concat-export --offline --test p2_canvas_parity
cargo clippy -p concat-project -p concat-host -p concat-api -p concat-export --all-targets --offline -- -D warnings
```

---

## License & Upstream Attribution

This project is licensed under **AGPL-3.0-or-later** ([LICENSE](LICENSE)) and is built directly upon [jub0t/Concat](https://github.com/jub0t/Concat) (`v0.2.12`). All upstream copyright notices, license files ([LICENSING.md](LICENSING.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)), and the original Concat README ([docs/README.concat.md](docs/README.concat.md)) are preserved in full.

---

<a id="tiếng-việt"></a>

## Tiếng Việt

### Tổng quan

**Hybrid Editor (`hybrid_edit_vid`)** là trình dựng phim desktop native kết hợp thao tác timeline trực tiếp của người dùng trên giao diện **Slint** với luồng chỉnh sửa giao dịch của AI Agent (**Antigravity 2.0** qua Live-Attach MCP Gateway và suy luận AI cục bộ trên Apple Silicon).

Dự án phát triển trực tiếp từ mã nguồn mở [jub0t/Concat](https://github.com/jub0t/Concat) (`v0.2.12`, `AGPL-3.0-or-later`), giữ nguyên khả năng tương thích upstream, giải mã/mã hóa phần cứng **VideoToolbox**, dựng hình GPU **Metal**, và cơ chế lưu dự án nguyên tử.

### 6 Bất biến Kiến trúc (`I1–I6`)

| Bất biến | Nguyên tắc cốt lõi |
| :--- | :--- |
| **I1 · Command Bus thống nhất & `AgentTurn` giao dịch** | Mọi thao tác timeline (thủ công hay AI Agent) đều đi qua `concat_project::Editor`. Một `AgentTurn` gom $N$ lệnh thành đúng 1 bước `Undo`/`Redo` (`Cmd+Z`), hỗ trợ `rollback` về trạng thái trước lượt và tách bạch `ViewState` (`P4`). |
| **I2 · Live-Attach & Khóa phục hồi theo Lease** | Agent gắn trực tiếp vào phiên cửa sổ đang mở thông qua cơ chế khóa ghi đơn luồng `SessionLease` (`HYBRID_EDIT_DATA_DIR/leases/`, grace `5–10s`, kiểm tra PID sống, tự rollback lượt chưa commit nếu tiến trình chết đột ngột `SIGKILL`, `P8`). |
| **I3 · Đồng nhất một bộ Renderer** | Khung xem trước, dải kiểm tra thị giác cho Agent và file xuất `.mp4` VideoToolbox dùng chung quy tắc compositor/canvas (`P2`), không làm lọt highlight UI hay khung chọn vào video xuất. |
| **I4 · Cache AI cục bộ & Tách biệt 2 loại Skill** | Skill lập trình (dev-workflow) tách biệt hoàn toàn khỏi runtime editing skills (`assets/editor-skills/`). Dữ liệu phân tích media (transcript, đoạn VAD, chỉ mục cảnh) được cache theo hash nội dung/luồng nguồn. |
| **I5 · Cô lập thư mục dữ liệu** | Dữ liệu ứng dụng mặc định nằm tại `~/Library/Application Support/hybrid_edit_vid` và cho phép ghi đè qua biến môi trường `HYBRID_EDIT_DATA_DIR` khi chạy thử nghiệm/test cô lập. |
| **I6 · Kiểm chứng định lượng trên phần cứng thật** | Mỗi milestone chỉ được nghiệm thu sau khi chạy thực tế trên MacBook Pro M4 Pro (`cargo test`, `cargo clippy`, `ffprobe`, benchmark phần cứng). |

### Cấu trúc Thư mục

- [`src/`](src/) — Workspace Rust & Slint (`concat-project`, `concat-host`, `concat-api`, `concat-export`, `concat-media`, `concat-render`, `concat-mcp`, `concat`).
- [`assets/editor-skills/`](assets/editor-skills/) — Bộ skill dựng phim runtime nạp cho Agent khi biên tập video.
- [`kit/`](kit/) — Toàn bộ bộ tài liệu khởi tạo v2 (`kit/README.md`, `kit/ANTIGRAVITY_BOOTSTRAP_PROMPT.md`, `PROJECT_BRIEF.md`, `CONSTITUTION_SEED.md`, `PITFALLS_AND_FIXES.md`, `TOOLCHAIN_AND_SPECKIT_GUIDE.md`, `EDITOR_SKILLS_SPEC.md`).
- [`specs/`](specs/) — Đặc tả Spec Kit, kế hoạch, hợp đồng kỹ thuật (`contracts/`) và danh sách tác vụ theo từng milestone.
- [`docs/`](docs/) — Tài liệu gốc của Concat và bản lưu README gốc tại [`docs/README.concat.md`](docs/README.concat.md).
- [`PROJECT.md`](PROJECT.md) — Nhật ký kỹ thuật sống, kết quả giải phẫu Graphify và số liệu đo đạc M4 Pro.

### Lộ trình & Trạng thái hiện tại

- [x] **Milestone 0 — Toolchain, Hiến pháp & Baseline:** Chốt [constitution.md](.specify/memory/constitution.md), giải phẫu Graphify và kiểm chứng build + export VideoToolbox/Metal trên Apple M4 Pro.
- [x] **Milestone 1 — Unified Command Bus, `AgentTurn`, Recoverable Lease & Hybrid Timeline HUD** ([specs/001-hybrid-command-bus](specs/001-hybrid-command-bus/spec.md)):
  - Hỗ trợ `AgentTurn` giao dịch trên `Editor` gom nhiều lệnh thành 1 bước Undo/Redo.
  - `LeaseManager` (`0o600`, grace `5–10s`, kiểm tra PID) và bài test crash recovery `SIGKILL` thật (`p8_crash_recovery`).
  - Tách biệt `ViewState` vs `DocumentState` (`P4`) và chia sẻ `LiveSession` qua `OpenProjects::claim_live` / `Api::live_sessions`.
  - Giao diện Hybrid Timeline native Slint có viền/badge `AI` (`ClipData.agent-modified`) và thanh HUD (`Cancel`, `Accept`, `Revert Turn` — bấm `Accept` chỉ xóa highlight, giữ nguyên Undo `Cmd+Z`).
  - Kiểm chứng đồng nhất nền đen & alpha giữa `preview_frame` và `h264_videotoolbox` `.mp4` (`p2_canvas_parity`).
- [ ] **Milestone 2 — Cổng MCP Live-Attach qua UDS & Perception Tools:** Unix Domain Socket (`chmod 600`) nối thẳng từ `Studio`/`Host`, `inspect_project_tree`, `inspect_timeline`, và `preview_timeline_strip`.
- [ ] **Milestone 3 — Động cơ A-Roll thông minh:** Silero VAD + `whisper.cpp` (Metal, `large-v3-turbo`), chống bịa chữ khoảng lặng (`P6`), cache theo file nguồn (`P7`), và skill `aroll-rough-cut`.
- [ ] **Milestone 4 — Động cơ B-Roll theo ngữ cảnh:** Tách cảnh, trích keyframe, chỉ mục ngữ nghĩa SQLite (VLM local / Antigravity fallback) và skill `smart-broll-inserter`.
- [ ] **Milestone 5 — Tích hợp toàn trình, tối ưu ngữ cảnh & kiểm thử 5 vòng liên tiếp** trên footage 4K/1080p.

### Build & Chạy Kiểm thử (macOS Apple Silicon)

**Yêu cầu:** macOS Apple Silicon (đã kiểm thử trên MacBook Pro M4 Pro, macOS `27.3`, `24 GiB` Unified Memory), Rust toolchain theo [`src/rust-toolchain.toml`](src/rust-toolchain.toml) (`rustc 1.93.1`), `ffmpeg`, `cmake`, `pkg-config`.

```bash
cd src
HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_dev cargo build -p concat --profile quick
```

Chạy bộ test nghiệm thu Milestone 1:

```bash
cd src
export HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_test

cargo test -p concat-project --offline
cargo test -p concat-host --offline --test p8_crash_recovery
cargo test -p concat-host --offline --lib
cargo test -p concat-api --offline
cargo test -p concat-export --offline --test p2_canvas_parity
cargo clippy -p concat-project -p concat-host -p concat-api -p concat-export --all-targets --offline -- -D warnings
```

### Giấy phép & Ghi công

Dự án phát hành theo giấy phép **AGPL-3.0-or-later** ([LICENSE](LICENSE)), phát triển trực tiếp từ [jub0t/Concat](https://github.com/jub0t/Concat) (`v0.2.12`). Toàn bộ thông báo bản quyền và tệp pháp lý gốc ([LICENSING.md](LICENSING.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [docs/README.concat.md](docs/README.concat.md)) được giữ nguyên vẹn.
