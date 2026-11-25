# `hybrid_edit_vid` — Living Project Record

## 1. Tổng quan & Mục tiêu
- **Nền tảng gốc:** `jub0t/Concat` (`v0.2.12`, AGPL-3.0-or-later, Rust + Slint + FFmpeg + wgpu + ONNX Runtime + whisper.cpp).
- **Môi trường đích:** macOS Apple Silicon — **MacBook Pro M4 Pro** (`arm64`, 24 GiB Unified Memory, macOS `27.3`), VideoToolbox + Metal + CoreML.
- **Thư mục dữ liệu mặc định (`I5`):** `~/Library/Application Support/hybrid_edit_vid` (hoặc `HYBRID_EDIT_DATA_DIR`).
- **Tách biệt Skill (`I1–I6`):**
  - Dev-workflow skills: `~/.gemini/config/plugins/ponytail`, `~/.gemini/config/skills/` (4 skill chọn lọc của `addyosmani/agent-skills` + `graphify`), `.agents/skills/speckit-*`.
  - Runtime Video-Editing skills: `assets/editor-skills/` (trong repo) và `HYBRID_EDIT_DATA_DIR/skills/` (lúc chạy app).
- **Hiến pháp:** [`.specify/memory/constitution.md`](.specify/memory/constitution.md) (`v1.0.0`, ratified `2026-11-25`).

---

## 2. Phase 0 — Giải phẫu Mã nguồn `Concat` qua Graphify (`/graphify .`)

**Phạm vi đồ thị AST (`src/crates/`):** `21,063` nodes, `51,134` edges, `559` communities (`94% EXTRACTED`, `6% INFERRED`, `0% AMBIGUOUS`, `0` LLM tokens) tại `graphify-out/GRAPH_REPORT.md` và `graphify-out/graph.json` (đã thêm `graphify-out/` vào `.gitignore`).

### Q1 · Command Flow (UI Slint -> Core -> Disk & MCP -> Core)
- **Đường Slint UI:**
  - Kéo thả / thao tác liên tục được preview tạm trên bản sao `Studio::echo` (`src/crates/concat/src/studio/edit.rs::Studio::project`), không đụng vào `Session` trong khi đang kéo.
  - Khi nhả / xác nhận lệnh: `Studio::apply` / `Studio::apply_within` (`src/crates/concat/src/studio/edit.rs`) -> `concat_host::Session::apply` / `Session::apply_within` (`src/crates/concat-host/src/session.rs`) -> `concat_project::Editor::apply_within` (`src/crates/concat-project/src/editor.rs`) -> `concat_project::commands::apply` (`src/crates/concat-project/src/commands/mod.rs`) -> `Studio::after_change()` (cập nhật Slint UI và kích hoạt lưu).
  - Ghi xuống đĩa: `Session` tạo bản chụp `Project` (dùng `Arc` copy-on-write cho `Timeline` và `Clip`), lưu qua `projects::save` -> `concat_doc::save::save_document` (`src/crates/concat-doc/src/save.rs`): ghi `.saving-<pid>` -> `fcntl_fullfsync` (`F_FULLFSYNC` trên macOS) -> `holds` đọc lại đối chiếu byte -> hardlink/copy `.prev` -> `rename` nguyên tử -> `sync_all` thư mục.
- **Đường API / MCP hiện có:**
  - `concat-mcp` (`src/crates/concat-mcp/src/tools.rs`, `backend.rs`) -> `Backend::Window` (JSON-RPC tới `concat-server::Hub` tại `src/crates/concat-server/src/hub.rs`) hoặc `Backend::Headless` -> `concat_api::Api::dispatch` (`src/crates/concat-api/src/lib.rs`) -> `Session::apply`.

### Q2 · Ngăn xếp Undo/Redo & Mở rộng cho `AgentTurn`
- **Cấu trúc hiện tại trong `concat-project`:**
  - `concat_project::Editor` (`src/crates/concat-project/src/editor.rs`) giữ `undo: VecDeque<Snapshot>` (`before: Project`, `gesture: Option<String>`, giới hạn `UNDO_DEPTH = 200`) và `redo: Vec<Project>`.
  - `Editor::apply_within(Some(gesture), cmd)` gộp nhiều lệnh liên tiếp có cùng `gesture` vào một `Snapshot` duy nhất (`continues = last.gesture.as_deref() == Some(gesture)`). Các lệnh `command.is_view_state()` không đi vào ngăn xếp Undo.
  - Ngoài ra, `concat_doc::history::History<S, C, Sel, K>` (`src/crates/concat-doc/src/history.rs`) đã có mô hình `Step`, `Origin`, `planned_at: Revision`, `Coalesce { key, within }` (*"as long as a turn lasts for an assistant's"*), `Budget` (1000 steps / 256 MB) và tách view state (`Schema::carry_view`).
- **Điểm cần mở rộng ở M1:**
  - Cơ chế `gesture: Option<&str>` của `concat_project::Editor` chỉ gộp các lệnh liền kề và không có giao dịch rollback tường minh nếu một bước giữa lượt bị lỗi hoặc bị hủy (`AgentTurn`).
  - Cần bổ sung `begin_agent_turn(turn_id, summary)` / `commit_agent_turn` / `rollback_agent_turn` lưu snapshot trước turn, gom toàn bộ lệnh trong turn thành 1 mục Undo gắn metadata (`origin`, `turn_id`, `affected_clip_ids`) để Hybrid Timeline Slint highlight và `Revert Turn` / `Cmd+Z` hoàn tác trọn vẹn.

### Q3 · Cơ chế `concat.lock` / `editor-api` & Điểm chặn Live Mode
- **Cơ chế khóa liên tiến trình:**
  - `concat_host::lock::ProjectLock::acquire` (`src/crates/concat-host/src/lock.rs`) tạo tệp `concat.lock` trong thư mục project và giữ `flock` (`File::try_lock()`) kèm `pid\nrole\nstarted\n`.
- **Cơ chế đăng ký nội bộ (`OpenProjects`):**
  - `concat_api::OpenProjects` (`src/crates/concat-api/src/lib.rs`) giữ `BTreeMap<String, Claim>` theo đường dẫn project chuẩn hóa, phân chia `Holder::Window` vs `Holder::Api`.
  - Khi cửa sổ Slint mở project (`src/crates/concat/src/studio/project_files.rs`), nó gọi `open_projects.claim(&info.path, Holder::Window)`.
- **Điểm chặn cụ thể ngăn Live Mode:**
  - Mặc dù GUI có sẵn `Host.server: Option<concat_server::Server>` (`src/crates/concat/src/host.rs`) và `concat-mcp` (`src/crates/concat-mcp/src/backend.rs`) ưu tiên `Backend::Window`, hàm `OpenProjects::claim` đang **từ chối `Holder::Api` với lỗi `Refusal::Here(Holder::Window)`** ngay khi cửa sổ GUI đang mở project đó (xem ghi chú `"live mode", #337` trong `concat-mcp/src/backend.rs`).
  - Đồng thời `concat-server` dùng TCP (`SocketAddr`) + token thay vì Unix Domain Socket (`chmod 600`) và chưa có `SessionLease` heartbeat/grace-period rollback khi client MCP crash giữa chừng (P8).

### Q4 · Renderer Parity (Preview Slint vs Export FFmpeg — I3 & P2)
- **Phần dùng chung:**
  - Cả Monitor Preview (`Studio::preview_clips` tại `src/crates/concat/src/studio/monitor.rs` + `concat_host::preview::Monitor` tại `src/crates/concat-host/src/preview.rs`) và Export (`concat_host::export::request_for` tại `src/crates/concat-host/src/export.rs`) đều gọi `concat_export::flatten::flatten_timeline_in(...)` để trải timeline thành `Vec<ExportClip>`, dùng chung `VideoSettings` (`width`, `height`, `rate_num/den`, `color_space`, `canvas`) và composite trên `concat_render::WgpuCompositor` (trên macOS dùng chung Metal device/queue với cửa sổ qua `Monitor::off_thread()` / `sibling()`).
- **Điểm khác biệt / Rủi ro P2 cần khóa:**
  - `Studio::preview_clips` chèn thêm lớp chỉ hiển thị lúc preview (`self.audition` filter preview, `self.painting` `flat.highlighted = true`) lên bản sao `own`, đồng thời dùng `FrameSpec { proxy, nearest }` (chất lượng Quarter/Half/Full) và `self.echo` khi kéo chuột.
  - `preview_timeline_strip` ở M2 phải đi qua `concat_host::preview::Monitor` / `concat_export` (không đi qua lớp UI chrome của `Studio` và ép nền `canvas` đồng nhất với export) để bảo đảm I3 và P2.

---

## 3. Baseline Hardware, Toolchain & License Inventory

### Toolchain đã kiểm chứng trên MacBook Pro M4 Pro
- **OS / CPU / RAM:** macOS `27.3` (`26C5047e`), `Apple M4 Pro` (`arm64`), `24 GiB` Unified Memory, trống `238 GiB` / `460 GiB`.
- **Công cụ toàn máy:** `specify-cli 1.4.5.dev0`, `graphifyy 0.9.120`, `ponytail 5.3.3`, 4 skill chọn lọc `addyosmani/agent-skills`, `rustc 1.93.1` (pinned `src/rust-toolchain.toml`) & `rustc 1.100.0` (stable), `pkgconf 3.0.11`, `cmake 4.5.1`, `ffmpeg 9.1` (`h264_videotoolbox`, `hevc_videotoolbox`, `prores_videotoolbox`).

### Baseline M0 (Build & Export VideoToolbox — Đã đo trên M4 Pro, `2026-11-25`)
- **Build `concat-cli` (`dev` profile, có tải `ort-sys` CoreML):** `2m 37s` (`2m 37.65s` total).
- **Build `concat-mcp` (`dev` profile, offline):** `29.75s`.
- **Build `concat` Slint GUI (`quick` profile, có tải prebuilt Skia Metal/GL):** `4m 03s`.
- **Render & Export 5 giây (`concat-cli render`, 150 frames `1920x1080 @ 30fps`, `Apple M4 Pro` Metal GPU compositor + fade-in + `h264_videotoolbox`):** `20.626s` (`debug` build).
- **Xác minh `ffprobe` đầu ra:** `codec_name=h264`, `width=1920`, `height=1080`, `r_frame_rate=30/1`, `nb_frames=150`, `duration=5.000000`, `size=5118880`, `bit_rate=8190208`.
- **VideoToolbox Unit Test (`cargo test -p concat-media --offline videotoolbox`):** `test hardware::tests::videotoolbox_decodes_h264_and_not_jpeg ... ok` (`1 passed; 0 failed`).
- **Phần chưa kiểm chứng ở M0:** Chưa chạy toàn bộ suite `cargo nextest run --workspace` (chưa cài `cargo-nextest`) và chưa mở cửa sổ GUI Slint trực tiếp từ phiên dòng lệnh; sẽ kiểm tra ở M1/M2.
- **Bước tiếp theo:** Bắt đầu **Milestone 1** (`/speckit-specify` -> `/speckit-plan` -> `contracts/` -> TDD Red/Green) cho Unified Command Bus, `AgentTurn` Transactional Undo, Lease-based Recoverable Lock, và Hybrid Timeline Slint.

### Bảng theo dõi Giấy phép (License Inventory)
| Thành phần | Nguồn / Phiên bản | Giấy phép | Ghi chú tuân thủ |
| :--- | :--- | :--- | :--- |
| **Concat Core & UI** | `jub0t/Concat` (`v0.2.12`) | `AGPL-3.0-or-later` | Giữ nguyên `LICENSE`, `LICENSING.md`, `THIRD_PARTY_NOTICES.md`, `docs/README.concat.md`; dự án nội bộ phi thương mại |
| **Slint** | `1.18.1` (patched) | `GPL-3.0` (open-source) / Royalty-free | Tương thích dùng nội bộ AGPL-3.0 |
| **FFmpeg** | System Homebrew `9.1` (dev) / `scripts/ffmpeg-macos.sh` `8.1` (LGPL release) | `GPL` (Homebrew local) / `LGPL-2.1+` (release bundle) | Dùng `VideoToolbox` & `AudioToolbox` phần cứng macOS; bản phát hành tuân thủ LGPL |
| **whisper.cpp (`whisper-rs-sys`)** | `0.15.0` (patched) | `MIT` | Tăng tốc Metal trên Apple Silicon |
| **ONNX Runtime (`ort`)** | `2.0.0-rc.13` | `MIT` | CoreML Execution Provider trên macOS |
| **`png` (dev-dependency)** | `0.17` (`concat-export` test-only) | `MIT OR Apache-2.0` | Tạo ảnh RGBA có kênh alpha cho bài test đối chứng renderer `P2` |

---

## 4. Milestone 1 (`001-hybrid-command-bus`) — Unified Command Bus, Transactional `AgentTurn`, Lease & Hybrid Timeline

### Thành phần đã triển khai (`specs/001-hybrid-command-bus/`)
- **Data Isolation (`I5`)**: `src/crates/concat-host/src/dirs.rs` hỗ trợ `HYBRID_EDIT_DATA_DIR`, đặt `IDENTIFIER = "hybrid_edit_vid"` (`~/Library/Application Support/hybrid_edit_vid`), thêm `AppDirs::leases()`.
- **Transactional `AgentTurn` (`I1`)**: `src/crates/concat-project/src/editor.rs` bổ sung `begin_agent_turn`, `apply_in_turn`, `commit_agent_turn`, `rollback_agent_turn`, `top_undo_turn`, `revision()`, `touched_clip_ids()`, gom N lệnh Agent thành 1 Undo/Redo duy nhất chung ngăn xếp với sửa thủ công.
- **Session & `StateDiffEvent` (`I1`, `P4`)**: `src/crates/concat-host/src/session.rs` tách biệt `ViewState` (`Command::is_view_state()`, `Studio::selection`, `playhead`, `AgentTurnHudState`) khỏi `DocumentState`/`revision`/autosave, đồng thời xây dựng `LiveSession` phát `StateDiffEvent`.
- **Lease-Based Recoverable Lock (`I2`, `P8`)**: `src/crates/concat-host/src/lease.rs` cài `LeaseManager` / `SessionLease` (grace `5000..=10000 ms`, tệp `0o600` dưới `leases/`, `libc::kill(pid, 0)` kiểm tra PID sống) và `LiveSession` tự `rollback_agent_turn` khi client giữ lease bị `SIGKILL`.
- **Live-Attach Sharing (`I2`)**: `src/crates/concat-api/src/lib.rs` mở rộng `OpenProjects` (`claim_live`, `live_session`) và `Api::live_sessions` để `Holder::Api` đọc/ghi tuần tự trên cùng `LiveSession` với cửa sổ GUI (tích hợp UDS Live-Attach Gateway trong `Host`/`Studio` thực hiện ở **Milestone 2**).
- **Hybrid Timeline Slint UI (`I1`, `I3`)**: `src/crates/concat/ui/timeline/{model,lanes,tray}.slint`, `ui/editor.slint` và `src/crates/concat/src/{studio.rs,studio/edit.rs,studio/publish.rs,lib.rs}` thêm highlight clip `agent-modified` (viền + badge `AI`), HUD tiến trình/duyệt lượt Agent (`Cancel`, `Accept`, `Revert Turn`) và `Accept` chỉ xóa highlight UI mà giữ nguyên Undo `Cmd+Z`.

### Kết quả kiểm chứng M1 sau lần sửa cuối (MacBook Pro M4 Pro)
| Kiểm tra | Phạm vi | Kết quả thực tế |
| :--- | :--- | :--- |
| `concat-project` (`--offline`) | `265` lib tests (gồm `agent_turn_groups_multiple_edits_into_single_undo_redo_and_supports_rollback`) + `4` `mutations.rs` | **269 passed, 0 failed** |
| `concat-host` (`--test p8_crash_recovery --offline`) | Crash recovery thật bằng `child.kill()` (`SIGKILL`) giữa `AgentTurn` | **1 passed, 0 failed** |
| `concat-host` (`--lib --offline`, `BypassSandbox: true` cho VideoToolbox/loopback) | Toàn bộ unit test host (gồm `dirs`, `lease`, `session::p4_view_state`, `hybrid_100_ops`) | **198 passed, 0 failed, 4 ignored** (4 test ignore sẵn của upstream) |
| `concat-api` (`--offline`, `BypassSandbox: true` cho GPU/export) | Toàn bộ 35 unit test API (gồm `live_attach_shares_window_session_and_serializes_writes`) | **35 passed, 0 failed** |
| `concat` (`--lib --offline hybrid_hud`) | `AgentTurnHudState` `Accept` giữ `Cmd+Z` + `Revert Turn` chặn xóa nhầm edit mới | **2 passed, 0 failed** (253 filtered out) |
| `concat-export` (`--test p2_canvas_parity --offline`, `BypassSandbox: true` cho VideoToolbox) | `preview_frame` vs `h264_videotoolbox` `.mp4` với clip `<16:9` + PNG alpha trong suốt | **1 passed, 0 failed** (`0.73s`) |
| `cargo clippy --all-targets --offline -- -D warnings` | `concat-project`, `concat-host`, `concat-api`, `concat-export` | **0 warnings, 0 errors** (`44.07s`) |
| `cargo build -p concat --profile quick --offline` | Toàn bộ ứng dụng Slint + UI HUD | **Thành công, 0 lỗi** (`1m 32s`) |
| `graphify update .` | Cập nhật AST Knowledge Graph tại root | **17,451 nodes, 33,921 edges, 2,492 communities** |

### Ghi chú / Bước tiếp theo (M2)
- Giao thức Unix Domain Socket (`chmod 600`) và cổng MCP `live-attach` + Semantic/Perception tools (`inspect_project_tree`, `inspect_timeline`, `preview_timeline_strip`, `begin_agent_turn` / `commit_agent_turn`) cùng nối `Studio`/`Host` vào `OpenProjects::claim_live` sẽ được triển khai ở **Milestone 2**.
