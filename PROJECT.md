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
- Giao thức Unix Domain Socket (`chmod 600`) và cổng MCP `live-attach` + Semantic/Perception tools (`inspect_project_tree`, `inspect_timeline`, `preview_timeline_strip`, `begin_agent_turn` / `commit_agent_turn`) cùng nối `Studio`/`Host` vào `OpenProjects::claim_live` sẽ được triển khai ở **Milestone 2** (trên nhánh lưu trữ `archive/concat-m1` nếu quay lại lõi Concat).

---

## 5. Phase 0 — Chuyển lõi sang `Editroom` (`feat/editroom-core`)

### Quyết định lưu trữ & chuyển lõi (`2026-11-28`)
- **Lưu trữ lõi `Concat` (M0+M1):** Giữ nguyên `main` tại commit `3a14ce2c`, tạo nhánh `archive/concat-m1` và annotated tag `concat-m1-archive`, giữ nguyên thư mục `src/` để tham chiếu kiến trúc/thuật toán (đặc biệt `whisper.cpp` Metal + Silero VAD trong `concat-speech` và `LeaseManager` trong `concat-host`).
- **Lõi mới `editroom/`:** Nhập sạch mã nguồn [`robbietilton/Editroom`](https://github.com/robbietilton/Editroom) (commit `490a7aa`, remote `upstream-editroom`) vào `editroom/` trên nhánh mới `feat/editroom-core`.
- **Cấu hình build cục bộ (`editroom/Editroom.xcodeproj/project.pbxproj`):** Chuyển Debug & Release sang ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`, `ENABLE_HARDENED_RUNTIME = NO`, `PRODUCT_BUNDLE_IDENTIFIER = local.hybrideditvid.Editroom`).

### Bảng bổ sung Giấy phép cho lõi `Editroom`
| Thành phần | Nguồn / Phiên bản | Giấy phép | Ghi chú tuân thủ |
| :--- | :--- | :--- | :--- |
| **Editroom Core & UI** | `robbietilton/Editroom` (`490a7aa`) | `MIT` | Giữ nguyên `editroom/LICENSE` (Wonder Assembly LLC) |
| **Sparkle** | `sparkle-project/Sparkle` (`2.10.1`, SPM) | `MIT` | Quản lý auto-update macOS |
| **FFmpeg sidecar** | `editroom/Vendor/ffmpeg/ffmpeg` (`9.1`, `4.6 MB`) | `LGPL-2.1+` | Chạy như tiến trình phụ tách biệt (`Vendor/ffmpeg/README.md`) |

### Kiểm chứng Xcode & Phần cứng M4 Pro (`2026-11-28`)
- **Môi trường Xcode:** `Xcode 27.2` (`27B52`), `Apple Swift 6.4.2`, `macOS 27.3` (`26C5047e`), `Apple M4 Pro`.
- **Xcode MCP:** Đã mở & cấp quyền workspace `editroom/Editroom.xcodeproj` (`workspaceIdentifier: workspace-0IS78oauaq`, scheme `Editroom`, destination `My Mac`). *(Lưu ý: `BuildProject` MCP timeout ở 3 phút trong lần đầu tải Sparkle nên build đầy đủ thực hiện qua `xcodebuild` CLI.)*
- **Build Debug (`xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build`, `BypassSandbox: true`):** **`** BUILD SUCCEEDED **`** trong `640.72s` (cold build gồm resolve/compile `Sparkle 2.10.1` + SDK explicit modules).
- **Headless SelfTest (`Editroom --selftest /tmp/hybrid_edit_editroom_media /tmp/hybrid_edit_editroom_out`, `BypassSandbox: true`):** Exit code `0` (~25s) trên footage tổng hợp `sample_a.mp4` (`1920x1080 @ 30fps`) + `music.wav`:
  - **Passed:** `IMPORT OK` (`sample_a.mp4`, `music.wav`), `EXPORT OK` (`edit_h264.mp4`, `edit_hevc_4k_web.mp4`, `edit_noaudio.mp4`, `edit.wav`, `ramp.mp4`, `tone_0db/plus6/minus12.wav`), `UPSCALE OK` (`1080p→4K = 1.9 ms/frame` qua MetalFX), `SPEED GROUP OK`, `RAMP OK`, `STICKY OK`, `TRACKS OK`, `HISTORY OK`, `AI RESULT SHOW OK`, `SEARCH WORDS OK`, `LOCAL CAPTIONS OK`, `CAPTION UNDO OK`, `RIPPLE TRIM OK`, `ZOOM TOOL OK`.
  - **Skipped / Failed do thiếu bộ fixture test gốc của tác giả (`a_clip.mp4`, `c_clip.mp4`, `d_clip.mp4`, `e_clip.mp4`, `a_main.mp4`, `b_tone.wav`, `rot/*.mov`):** `RELINK SKIP`, `RELOAD SKIP`, `RELOAD ROTATED SKIP`, `IMPORT SHOWN FAIL`, `PROMISED FILES FAIL`, `REPLACED FILE FAIL`, `FOLDERS FAIL`. *(Lưu ý: khi chạy trong sandbox bị chặn `AVSampleBufferAudioRenderer` -> bắt buộc `BypassSandbox: true` cho audio/media runtime.)*
- **Xác minh `ffprobe` đầu ra:**
  - `edit_h264.mp4`: `h264`, `1280x720`, `30/1 fps`, `aac 48000Hz stereo`, `duration=4.500000`, `359,698 bytes`.
  - `edit_hevc_4k_web.mp4`: `hevc`, `3840x2160`, `30/1 fps`, `aac`, `duration=4.500000`, `1,360,703 bytes`.

### Lộ trình tiếp theo trên lõi `Editroom` (`feat/editroom-core`)
- **M1-E · Core Guardrails & Hybrid MCP (`I1`, `I2`, `I5`, `P1`, `P7`, `P8`):** ✅ Hoàn thành (`specs/002-editroom-guardrails-mcp/`, `62ff8c67`).
- **M2-E · Secrets, GitHub Skills, 3-Tier Plugins & Multi-Provider Chat Backend:** ✅ Hoàn thành (`specs/003-extensions-agent-backend/`, `63590a9a`).
- **M3-E · Native Hybrid UI:** ✅ Hoàn thành (`specs/004-native-hybrid-ui/`): Sidebar **Agent Chat** thu/mở (`⌘L`), tab **Skills**, **Plugins**, **Integrations** trong `SettingsView` + trình duyệt **Stock** nhanh trong `LibraryView`.
- **M4-E · ComfyUI Colab Tunnel & Stock APIs:** ✅ Hoàn thành (`specs/005-comfyui-stock-providers/`): `TunnelManager` (SSH/Tailscale/Cloudflare), `ComfyUIClient` (REST/WS + I2V + Workflows + Colab notebook), `PexelsProvider` & `PixabayProvider`, 4 MCP tools + live `StockLibraryView`.
- **M5-E · Smart A-Roll Tiếng Việt & Smart B-Roll 3 Tầng:** ✅ Hoàn thành (`specs/006-smart-aroll-broll/`): `AudioVAD` + `WhisperCPPProvider` (cơ chế chặn ảo giác 10s im lặng `P6`) + `BRollFTSIndex` (SQLite3 FTS5) + `LocalVLMVisionProvider`/`AppleVisionFallbackProvider` + thác 3 tầng: **1. B-Roll local → 2. Pexels/Pixabay → 3. ComfyUI Colab**.
- **M6-E · Hardening & 5-Round 4K E2E:** ✅ Hoàn thành (`specs/007-hardening-4k-e2e/`): Hardening Keychain/Plugin Env/Git Hooks/SSH Options/MCP Host & Origin, tối ưu Antigravity 2.0 live-attach (`DELETE /mcp` rollback/release) và benchmark E2E 5 vòng trên 4K `3840x2160` + xuất HEVC (`2.23s`).

---

## 6. Milestone 1-E — Editroom Guardrails, `AgentTurn`, `SessionLease` & Hybrid MCP (`2026-11-28`)

### Kiến trúc đã triển khai (`specs/002-editroom-guardrails-mcp/`)
- **Cô lập dữ liệu & Tên file an toàn APFS UTF-8 (`I4`, `I5`, `P7`):**
  - `editroom/Editroom/Model/AppStorage.swift` (`enum HybridStorage` tránh trùng `@AppStorage` của SwiftUI): hỗ trợ biến môi trường `HYBRID_EDIT_DATA_DIR`, mặc định `~/Library/Application Support/hybrid_edit_vid`.
  - Gắn toàn bộ 12 điểm lưu trữ/cache (`Reverser`, `Transcripts`, `SceneTagStore`, `ScrubCache`, `ScrubStrips`, `WaveformReader`, `FFmpeg`, `MediaAnalyzer`, `MediaNotes`, `MagicAgent`, `MediaDownload`, `EditorModel.recoveryURL` & `heldMediaFolder`).
  - `derivedCacheStem(for:maxPrefixBytes: 120)` băm `path|size|mtime|inode` bằng SHA-256 (16 hex) + cắt trên biên ký tự UTF-8 hợp lệ để tổng tên file hậu tố luôn `<= 200` UTF-8 bytes; ghi nguyên tử qua `writeAtomicVerified(_:to:posixPermissions:)`.
- **Single-Writer `SessionLease` & Hồi phục `SIGKILL` (`I2`, `P8`):**
  - `editroom/Editroom/MCP/SessionLease.swift` (`LeaseManager`, `SessionLease`, `RecoveredLease`): lưu lease dạng `0o600` trong `<HYBRID_EDIT_DATA_DIR>/leases/<sha256_16>.lease.json`, kiểm tra PID bằng `Darwin.kill(pid, 0)`, grace window `5_000...10_000` ms.
  - Khi lease hết hạn hoặc PID chết đang giữ `activeTurnId != nil`, engine tự rollback `AgentTurn` dở dang trước khi nhường quyền ghi cho client kế tiếp (bỏ qua pre-reclaim cho lifecycle tools để `session_attach` báo đúng `recovered_rolled_back_turn_id`).
- **Transactional `AgentTurn` & `revision` đơn điệu (`I1`, `P1`, `P4`):**
  - `editroom/Editroom/Model/AgentTurn.swift` & `EditorModel.swift`: thêm `@Published private(set) var revision: UInt64`, `activeAgentTurn`, `undoTurns`/`redoTurns`, `beginAgentTurn`, `commitAgentTurn`, `rollbackAgentTurn`. Các thao tác `ViewState` (`seek`, `selection`, `setView`, `skimming`) giữ nguyên `revision`, `undoStack` và `isDirty`.
- **Hybrid MCP Tools (`editroom/Editroom/MCP/MCPTools+Hybrid.swift`, `MCPServer.swift`, `MCPTools.swift`):**
  - Bổ sung 8 tools: `session_attach`, `session_heartbeat`, `session_release`, `begin_agent_turn`, `commit_agent_turn`, `rollback_agent_turn`, `apply_edl_patch` (`keep_ranges`, `delete_range`, `insert_overlay`), `preview_timeline_strip` (render bằng `CompositionBuilder` + `TimelineCompositor` & xuất JPEG grid kèm nhãn thời gian, `I3`/`P2`), cùng `"revision"` / `"active_turn_id"` trong `get_project`.

### Kiểm chứng thực nghiệm trên M4 Pro (`2026-11-28`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build` (`BypassSandbox: true`) | Build toàn bộ target `Editroom` (`Sparkle` + `HybridStorage` + MCP + Guardrails test runner) | **`** BUILD SUCCEEDED **`** (`exit 0`, ~16s incremental) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m1e_data .../Editroom --hybrid-test /tmp/hybrid_edit_m1e_out` (`BypassSandbox: true`) | Bộ 7 test tự động (`T1–T7` trong `HybridGuardrailsTest.swift`): cô lập thư mục + tên tiếng Việt dài (`141B`), `ViewState` 20 lần (`revision=0`), `AgentTurn` 3 edit = 1 Undo/Redo + Rollback, `SIGKILL` lease `0o600`, `apply_edl_patch keep_ranges` + Undo, `preview_timeline_strip` vs `Exporter` nền đen RGB < 12 (`P2`), live HTTP `403` spoofed `Host` (`P3`) + 5 vòng E2E `revision` (`port=47920`) | **7/7 PASSED** (`ALL 7 GUARDRAIL CHECKS PASSED`, `exit 0`, ~11s) |
| `graphify update .` | Cập nhật AST Knowledge Graph cho lõi `Editroom` | **39,251 nodes, 92,688 edges, 975 communities** |

---

## 7. Milestone 2-E — Secrets, GitHub Skills, 3-Tier Plugins & Agent Chat Backend (`2026-11-28`)

### Kiến trúc đã triển khai (`specs/003-extensions-agent-backend/`)
- **Secrets Store tách ly (`I5`):** [KeychainStore.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/KeychainStore.swift) (`KeychainStore` qua `Security.framework` cho runtime tương tác và `FileSecretStore` `0o600` trong `HYBRID_EDIT_DATA_DIR/secrets.json` khi test).
- **GitHub & Local `SKILL.md` Registry:** [SkillRegistry.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/SkillRegistry.swift) cài skill từ thư mục local hoặc GitHub URL (`owner/repo`, `/tree/<ref>/<subpath>`), ghim `commitSHA`, kiểm tra path-traversal/symlink (`SafePath`), phân tích YAML frontmatter và nạp `/slug` vào prompt agent.
- **3-Tier `PluginHost`:** [PluginHost.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/PluginHost.swift) nạp `plugin.json` (`schemaVersion == 1`):
  - **Tier A (MCP Sidecar):** `StdioMCPProcess` chạy off `@MainActor` (`I6`), mặc định `trustedForExecution = false` & `enabled = false` tới khi xác nhận tin cậy; xuất tool `plugin.<id>.<tool>` vào `MCPTools.call` và dừng sạch khi thoát app.
  - **Tier B (Asset Bundle):** Nạp `.cube` LUT (`list_looks`), ComfyUI workflow JSON templates và skill bundle.
- **Multi-Provider Chat Backend & 1-Click Antigravity:** [AgentProvider.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Agent/AgentProvider.swift), [ChatSessionStore.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Agent/ChatSessionStore.swift), [AgentConnect.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/MCP/AgentConnect.swift):
  - Hỗ trợ `OpenAICompatibleHTTPProvider` (OpenAI / Ollama / LM Studio), `GeminiHTTPProvider`, `CLIProcessAgentProvider` (`Claude CLI` / `Codex CLI`).
  - `ChatSessionStore` lưu lịch sử `ChatThread` theo từng dự án (`Chats/`), chạy mỗi lượt trong `LeaseManager` + `begin/commit/rollbackAgentTurn` (`I1`, `I2`), hỗ trợ `revertTurn` 1 chạm; bổ sung `.antigravity` trong `AgentConnect` & `SettingsView`.

### Kiểm chứng thực nghiệm trên M4 Pro (`2026-11-28`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build` (`BypassSandbox: true`) | Build toàn bộ target `Editroom` sau khi thêm `Extensions/`, `Agent/`, `ExtensionsTest` | **`** BUILD SUCCEEDED **`** (`exit 0`) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m2e_data .../Editroom --extensions-test /tmp/hybrid_edit_m2e_out` (`BypassSandbox: true`) | Bộ 6 test (`E1–E6`): `FileSecretStore` `0o600`, `SkillRegistry` local + GitHub pin + traversal guard, `PluginHost` Tier B `list_looks`, Tier A Python MCP sidecar trust gate + `stopAll()`, `ChatSessionStore` `AgentTurn` Undo/Rollback + Antigravity merge, `OpenAICompatibleHTTPProvider` loopback `NWListener` tool-calls | **6/6 PASSED** (`ALL 6 EXTENSION CHECKS PASSED`, `exit 0`, ~12s) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m1e_data .../Editroom --hybrid-test /tmp/hybrid_edit_m1e_out` (`BypassSandbox: true`) | Kiểm tra hồi quy toàn bộ guardrails M1-E (`T1–T7`) | **7/7 PASSED** (`ALL 7 GUARDRAIL CHECKS PASSED`, `exit 0`, ~10s) |

---

## 8. Milestone 3-E — Native Hybrid UI (`2026-11-28`)

### Kiến trúc UI đã triển khai (`specs/004-native-hybrid-ui/`)
- **Sidebar Agent Chat (`⌘L`):** [AgentChatPanel.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/AgentChatPanel.swift), [ContentView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/ContentView.swift), [Workspace.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Model/Workspace.swift), [EditroomApp.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/App/EditroomApp.swift) — khung chat nhiều lượt bên cạnh `InspectorView` (kèm nút `"Chat"` trên toolbar), chọn provider (`Gemini`, `Ollama`, `OpenAI-Compat`, `Claude Code`, `Codex`), chọn thread theo dự án, bật/tắt chip `/skill`, chèn nhanh `@playhead` / `@selected`, theo dõi tool calls và thẻ `AgentTurn` có nút **`Undo Turn`** đồng bộ `Cmd+Z`.
- **Settings Mở rộng (Skills, Plugins, Integrations):** [ExtensionsSettingsView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/ExtensionsSettingsView.swift), [SettingsView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/SettingsView.swift), [IntegrationPrefs.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/IntegrationPrefs.swift):
  - **Skills:** Cài từ GitHub URL hoặc thư mục local, xem trước nội dung `SKILL.md`, bật/tắt/xóa.
  - **Plugins:** Cài plugin Tier A/B, bắt buộc hộp thoại xác nhận **Trust & Enable** hiển thị lệnh thực thi trước khi bật MCP sidecar.
  - **Integrations:** Nhập API key an toàn vào `AppSecrets.shared` (AI Chat, Pexels, Pixabay) + cấu hình ComfyUI Google Colab Tunnel (`Cloudflare` / `Tailscale` / `SSH`) kèm nút **Test Connection** (`GET /system_stats`).
- **Stock Browser trong Library:** [StockLibraryView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/StockLibraryView.swift), [LibraryView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/LibraryView.swift) — nút chuyển nhanh `Media` / `Stock` ngay trên header thư viện.

### Kiểm chứng thực nghiệm trên M4 Pro (`2026-11-28`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build` (`BypassSandbox: true`) | Build toàn bộ target `Editroom` với các view SwiftUI mới | **`** BUILD SUCCEEDED **`** (`exit 0`, ~12s) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m3e_data .../Editroom --extensions-test /tmp/hybrid_edit_m3e_out` (`BypassSandbox: true`) | Bộ 7 test (`E1–E7`), gồm `E7` (`NSHostingView` layout smoke test 5 view + `ComfyConnectionPrefs`/`ChatProviderPrefs` round-trip) | **7/7 PASSED** (`ALL 7 EXTENSION CHECKS PASSED`, `exit 0`, ~10s) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m1e_data .../Editroom --hybrid-test /tmp/hybrid_edit_m1e_out` (`BypassSandbox: true`) | Hồi quy guardrails M1-E (`T1–T7`) | **7/7 PASSED** (`ALL 7 GUARDRAIL CHECKS PASSED`, `exit 0`, ~11s) |

---

## 9. Milestone 4-E — ComfyUI Colab Tunnel & Free Stock Media Providers (`2026-11-28`)

### Kiến trúc đã triển khai (`specs/005-comfyui-stock-providers/`)
- **Đường hầm Colab an toàn (`TunnelManager`):** [TunnelManager.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/ComfyUI/TunnelManager.swift) — hỗ trợ `.cloudflare`, `.tailscale`, `.ssh`; `parseSafeSSHArguments` chặn shell metacharacter (`; | & $ \` > <`), tiến trình con thu hồi sạch qua `TunnelManager.shared.stop()` khi thoát app (`EditroomApp.swift`).
- **ComfyUI Remote Generator (`ComfyUIClient`):** [ComfyUIClient.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/ComfyUI/ComfyUIClient.swift) — kiểm tra GPU/VRAM/checkpoints (`/system_stats`, `/object_info`), chụp frame trên timeline làm ảnh tham chiếu I2V (`POST /upload/image`), bind biến mẫu workflow JSON từ `ComfyWorkflows/` và Tier B plugin, theo dõi WebSocket + `/history`, lưu nguyên tử kèm `Sources.txt` và import trả `asset_id`.
- **Kho Stock Miễn Phí (`Pexels`, `Pixabay`) & UI:** [StockMediaClient.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/Stock/StockMediaClient.swift), [StockLibraryView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/StockLibraryView.swift) — tìm song song Pexels/Pixabay, dựng contact sheet JPEG đánh số, kiểm tra ảnh (`CGImageSource`) / video (`AVURLAsset`), ghi `Sources.txt` và hỗ trợ 1-click Import ngay trong `LibraryView > Stock`.
- **4 MCP Tools & Tài nguyên đi kèm:** [MCPTools+Hybrid.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/MCP/MCPTools+Hybrid.swift) (`comfy_status`, `comfy_generate`, `search_stock_media`, `import_stock_media`), Colab notebook [editroom_comfyui_colab.ipynb](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/assets/colab/editroom_comfyui_colab.ipynb) cùng 2 built-in skills ([comfy-broll-generator](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/assets/editor-skills/comfy-broll-generator/SKILL.md), [stock-media-finder](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/assets/editor-skills/stock-media-finder/SKILL.md)).

### Kiểm chứng thực nghiệm trên M4 Pro (`2026-11-28`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build` (`BypassSandbox: true`) | Build toàn bộ target `Editroom` sau khi thêm `Providers/` & `MediaProvidersTest` | **`** BUILD SUCCEEDED **`** (`exit 0`, ~10s) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m4e_data .../Editroom --media-providers-test /tmp/hybrid_edit_m4e_out` (`BypassSandbox: true`) | Bộ 6 test (`M1–M6` trong `MediaProvidersTest.swift`): SSH injection guard & kill child, ComfyUI mock HTTP + I2V upload + Undo, Pexels/Pixabay parallel search + JPEG contact sheet, stock download + `Sources.txt` + Undo, Colab `.ipynb` + 2 `SKILL.md`, `StockLibraryView` render smoke | **6/6 PASSED** (`ALL 6 MEDIA PROVIDER CHECKS PASSED`, `exit 0`, ~4s) |
| `--extensions-test` (`E1–E7`) + `--hybrid-test` (`T1–T7`) (`BypassSandbox: true`) | Kiểm tra hồi quy toàn bộ bộ kiểm thử M1-E -> M4-E | **7/7 + 7/7 PASSED** (`exit 0`, ~11s) |

---

## 10. Milestone 5-E — Smart A-Roll Tiếng Việt & Smart B-Roll 3 Tầng (`2026-11-28`)

### Kiến trúc đã triển khai (`specs/006-smart-aroll-broll/`)
- **Smart A-Roll Tiếng Việt & Chống Ảo Giác `P6` (`WhisperProvider` + `AudioVAD`):** [WhisperProvider.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/Speech/WhisperProvider.swift), [Transcripts.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Engine/Transcripts.swift) — giải mã 16kHz mono float32 PCM bằng `AVAssetReader` (không phụ thuộc `ffmpeg` ngoài), tính năng lượng từng khung 30ms (`dBFS`); nếu không có đoạn thoại nào vượt ngưỡng, hàm `transcribe` ngắt mạch sớm trả về `0` từ (đảm bảo **0 ảo giác** trên 10s im lặng tuyệt đối `P6`), lọc các câu rác của Whisper (`"Cảm ơn các bạn đã xem"`, `"Subscribe"`, tag `[...]`), xuất WAV 16-bit khi gọi `whisper-cli` và ghép vào `Transcripts.shared` với cơ chế lùi về Apple Speech.
- **Smart B-Roll Context Engine (`SQLite3 FTS5` + `Local VLM` / `Apple Vision`):** [BRollIndex.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/BRoll/BRollIndex.swift), [VisualIndexProvider.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/BRoll/VisualIndexProvider.swift) — lưu trữ bền vững tại `HybridStorage.subdir("BRollIndex")/broll_fts5.sqlite` (`I5`), lập chỉ mục song song chuỗi gốc & chuẩn hóa tiếng Việt (`đ -> d`, bỏ dấu) để tìm chính xác cả có dấu lẫn không dấu (`bm25`), trích keyframe và phân tích ngoài `@MainActor` (`I6`) qua `LocalVLMVisionProvider` (Ollama/LM Studio `/v1/chat/completions`) hoặc `AppleVisionFallbackProvider` (`VNClassifyImageRequest`).
- **4 MCP Tools, Settings & 2 Built-in Skills:** [MCPTools+Hybrid.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/MCP/MCPTools+Hybrid.swift) (`transcribe_aroll`, `index_broll_folder`, `search_broll`, `insert_broll_overlay` chia sẻ helper `insertOverlayClip` và đặt muted trên `V2`+ trong 1 `AgentTurn`), [ExtensionsSettingsView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/ExtensionsSettingsView.swift) (`SpeechPrefs` & `VLMIndexPrefs` tại [IntegrationPrefs.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/IntegrationPrefs.swift)), cùng 2 skills [aroll-rough-cut](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/assets/editor-skills/aroll-rough-cut/SKILL.md) và [smart-broll-inserter](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/assets/editor-skills/smart-broll-inserter/SKILL.md) thực thi thác tự động 3 tầng (**Local FTS5 -> Pexels/Pixabay Stock -> ComfyUI Colab**).

### Kiểm chứng thực nghiệm trên M4 Pro (`2026-11-28`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build` (`BypassSandbox: true`) | Build toàn bộ target `Editroom` với `Providers/Speech`, `Providers/BRoll` (`import SQLite3`), `MCPTools+Hybrid`, `SmartEditingTest` | **`** BUILD SUCCEEDED **`** (`exit 0`) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m5_smart_data .../Editroom --smart-editing-test /tmp/hybrid_edit_m5_smart_out` (`BypassSandbox: true`) | Bộ 6 test (`S1–S6` trong `SmartEditingTest.swift`): `P6` 10s im lặng (0 ảo giác), Whisper tiếng Việt + lọc khoảng lặng + `suggested_keep_ranges`, SQLite3 FTS5 có dấu/không dấu (`đ -> d`) & chống lỗi cú pháp query, Loopback Local VLM + `index_broll_folder`/`search_broll` (`fallback_tier=1/2`), `insert_broll_overlay` trên `V2` + 1-step Undo, cài & mở rộng prompt 2 skill M5-E | **6/6 PASSED** (`exit 0`) |
| `--media-providers-test` (`M1–M6`) + `--extensions-test` (`E1–E7`) + `--hybrid-test` (`T1–T7`) (`BypassSandbox: true`) | Kiểm tra hồi quy toàn bộ bộ kiểm thử từ M1-E đến M5-E | **6/6 + 7/7 + 7/7 PASSED** (`exit 0`, ~10s tổng 4 suite) |
| `graphify update .` | Cập nhật AST Knowledge Graph cho Milestone 5-E | **39,919 nodes, 94,692 edges, 993 communities** |

---

## 11. Milestone 6-E — Hardening & 5-Round 4K E2E Benchmark (`2026-11-28`)

### Bảo mật & Live-Attach đã triển khai (`specs/007-hardening-4k-e2e/`)
- **Keychain & Redaction ([KeychainStore.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/KeychainStore.swift)):** Giới hạn Keychain ở `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` và thêm `SecretRedactor` che toàn bộ token nhạy cảm (`geminiAPIKey`, `openAIAPIKey`, `pexelsAPIKey`, `pixabayAPIKey`, `comfyAuthToken`, `comfyCFClientId`, `comfyCFClientSecret` + regex `AIza...` / `sk-...` / `Bearer ...`).
- **Cách ly Plugin & Git Clone ([PluginHost.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/PluginHost.swift), [SkillRegistry.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/SkillRegistry.swift)):** Giới hạn env tiến trình con `StdioMCPProcess` chỉ nhận allowlist hệ thống (`PATH`, `HOME`, `TMPDIR`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `HYBRID_EDIT_DATA_DIR`), chặn manifest đòi khóa mật cốt lõi của app, từ chối control characters trong command; `GitRunner.safeCloneArguments` ép `-c core.hooksPath=/dev/null`, `-c core.fsmonitor=false` và `GIT_TERMINAL_PROMPT=0`.
- **Chặn SSH Option Injection & Bảo vệ Loopback MCP ([TunnelManager.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/ComfyUI/TunnelManager.swift), [MCPServer.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/MCP/MCPServer.swift), [AgentConnect.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/MCP/AgentConnect.swift)):** `TunnelManager` chặn `-F` và các `-o ProxyCommand/LocalCommand/PermitLocalCommand/...`; `MCPServer.isAllowedLocalHost` & `isAllowedOrigin` kiểm chặt IPv4/IPv6 `[::1]:port` chống spoof `Host`/`Origin`; `DELETE /mcp` tự rollback `AgentTurn` dở và giải phóng `SessionLease`; ghi `~/.gemini/antigravity/mcp_config.json` quyền `0o600` cùng hiển thị cursor `Antigravity`.

### Kiểm chứng thực nghiệm trên M4 Pro (`2026-11-28`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build` (`BypassSandbox: true`) | Build toàn bộ target `Editroom` sau hardening + [Hardening4KBenchmarkTest.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/App/Hardening4KBenchmarkTest.swift) | **`** BUILD SUCCEEDED **`** (`exit 0`) |
| `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m6_hard_data .../Editroom --hardening-4k-test /tmp/hybrid_edit_m6_hard_out` (`BypassSandbox: true`) | Bộ 6 test (`H1–H6`): `SecretRedactor` & `.room` zero-leak, Plugin env allowlist & chặn `gemini_api_key` + Git hook guard, SSH `-o`/`-F` & IPv6 `[::1]` MCP Host/Origin, `Antigravity 2.0` + `DELETE /mcp` cleanup, **5 vòng E2E 4K (`3840x2160 @ 30fps`)** + xuất **4K HEVC** + `ffprobe`, ngân sách schema `tools=61` (`39,429 bytes`) | **6/6 PASSED** (`rounds=502 ms`, `export_4k_hevc=2.23 s`, `rss=297.2 MB`, `exit 0`) |
| `--smart-editing-test` (`S1–S6`) + `--media-providers-test` (`M1–M6`) + `--extensions-test` (`E1–E7`) + `--hybrid-test` (`T1–T7`) (`BypassSandbox: true`) | Hồi quy toàn bộ 4 bộ kiểm thử M1-E → M5-E | **6/6 + 6/6 + 7/7 + 7/7 PASSED** (tổng **32/32 PASSED**) |
| `graphify update .` | Cập nhật AST Knowledge Graph sau cấu trúc sạch + M6-E | **4,538 nodes, 12,392 edges, 230 communities** |

---

## 12. Phase A (`v1.1`) — Sửa triệt để 10/10 lỗi Core Audit (`2026-11-28`)

### Các sửa lỗi & cải tiến cốt lõi (`specs/008-v11-core-audit-fixes/`)
- **`P0-1` (`ChatSessionStore.inAppTools` + `import_media` draft support):** Loại `hybridLifecycleTools` khỏi bộ tool gửi cho AI Chat in-app để tránh trùng `AgentTurn`/`SessionLease`, đồng thời gỡ rào `notInMagic()` ở `import_media` ([MCPTools.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/MCP/MCPTools.swift)) kèm `draft?.addAsset(asset)`.
- **`P0-2`, `P0-3`, `P1-3` (Multimodal Chat, Gemini Sanitizer & Safe JSON Errors):** [AgentProvider.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Agent/AgentProvider.swift) tách ảnh tool qua `AgentToolFormatting.parse` để chuyển `image_url` data URI (OpenAI-compatible) và `inlineData` (Gemini), thêm `GeminiHTTPProvider.sanitizeGeminiSchema`, thay string interpolation lỗi thành `AgentToolFormatting.jsonError` (có `SecretRedactor`), kiểm tra `Task.checkCancellation()`, và bổ sung lịch sử hội thoại + `MCPServer.endpoint` cho `CLIProcessAgentProvider`.
- **`P1-1` (Streaming, Stop/Cancel & Redaction):** [ChatSessionStore.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Agent/ChatSessionStore.swift) & [AgentChatPanel.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/AgentChatPanel.swift) thêm `streamingText`, nút **Stop** (`cancelActiveTurn()` rollback sạch turn/lease đang dở), và che lỗi qua `SecretRedactor.redact`.
- **`P1-2`, `P1-4`, `P1-5` (ComfyUI & Stock UI):** [ComfyUIClient.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/ComfyUI/ComfyUIClient.swift) tự nạp checkpoint thật từ `/object_info/CheckpointLoaderSimple`; [StockMediaClient.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/Stock/StockMediaClient.swift) loại bỏ force-cast `as!`; [StockLibraryView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/StockLibraryView.swift) bổ sung thumbnail `AsyncImage` và nút **Add V2** 1-click.
- **`P2-1`, `P2-2` (Built-in Skills Auto-Seeding & Swift 6 Concurrency):** [SkillRegistry.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Extensions/SkillRegistry.swift) & [ExtensionsSettingsView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/ExtensionsSettingsView.swift) tự nạp 4 built-in skills khi khởi động + nút `"Restore Built-in"`; xử lý cảnh báo Swift 6 trong `ChatSessionStore.swift`, `Meters.swift`, `AgentChatPanel.swift`, `MediaProvidersTest.swift`, `SmartEditingTest.swift`.

### Kiểm chứng thực nghiệm sau lần sửa cuối (`M4 Pro`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `--hardening-4k-test` | `H1–H6` + **`V1–V5`** (in-app tool filter & `import_media` draft, OpenAI/Gemini multimodal loopback & sanitizer, cancel rollback, ComfyUI checkpoint auto-bind, 4 built-in skills + Stock UI) | **11/11 PASSED** (`rounds=497 ms`, `export_4k_hevc=2.23 s`, `rss=212.8 MB`) |
| `--smart-editing-test` + `--media-providers-test` + `--extensions-test` + `--hybrid-test` | Hồi quy toàn bộ M1-E → M5-E | **6/6 + 6/6 + 7/7 + 7/7 PASSED** (tổng **37/37 PASSED**) |
| `graphify update .` | Cập nhật AST Knowledge Graph cho `v1.1` | **4,576 nodes, 12,530 edges, 218 communities** |

---

## 13. Phase B (`v1.2`) — Bộ tính năng Creator Tiếng Việt (`2026-11-28`)

### Tính năng cốt lõi đã triển khai (`specs/009-v12-vietnamese-creator-suite/`)
- **Phụ đề Karaoke Tiếng Việt theo từng từ (`CapCut` / `Karaoke Pill`):**
  - [Captions.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Model/Captions.swift), [CaptionRenderer.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Engine/CaptionRenderer.swift), [Transcripts.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Engine/Transcripts.swift), [InspectorView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/InspectorView.swift): bổ sung 5 preset (`classic`, `capcut_yellow`, `karaoke_pill`, `neon_box`, `minimal_clean`), `pillHighlight` (`NSLayoutManager` đo khung glyph bo tròn từng chữ), `activeScale` phóng chữ đang đọc (`1.0...1.25`), `uppercase` theo locale `vi_VN`, giới hạn `maxWordsPerLine` (`Auto, 2–6`), cùng MCP tool `generate_vietnamese_captions` chạy đồng bộ Preview/Export (`I3`, `P2`).
- **Auto-Ducking Nhạc Nền & Beat-Sync Rough Cut:**
  - [BeatSyncEngine.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Engine/BeatSyncEngine.swift), [MediaStore.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Engine/MediaStore.swift), [EditorModel.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Model/EditorModel.swift), [EditroomApp.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/App/EditroomApp.swift), [MCPTools+Hybrid.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/MCP/MCPTools+Hybrid.swift): thêm `auto_duck_bgm` (nạp sẵn waveform track thoại, gán `duckUnder`/`duckDB` qua ramp 50ms trong `CompositionBuilder` và hoàn tác 1 bước `Cmd+Z`), `Clip > Auto-Duck BGM Under Speech`, và `beat_sync_cuts` tận dụng `MediaAnalyzer.music` khớp điểm cắt B-roll/ảnh vào nhịp beat trong 1 `AgentTurn`.
- **Trình duyệt B-Roll trực quan & Skill Shorts Tiếng Việt:**
  - [BRollBrowserView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/BRollBrowserView.swift), [LibraryView.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/UI/LibraryView.swift), [BRollIndex.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/Providers/BRoll/BRollIndex.swift), [vietnamese-shorts-creator](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/assets/editor-skills/vietnamese-shorts-creator/SKILL.md): chuyển `LibraryView` sang 3 tab (`Media | B-Roll | Stock`), hiển thị thống kê SQLite FTS5, thumbnail keyframe bất đồng bộ, tìm kiếm tiếng Việt có/không dấu và nút **Add V2** 1 chạm tại playhead; nạp thêm built-in skill thứ 5 `vietnamese-shorts-creator`.

### Kiểm chứng thực nghiệm sau lần sửa cuối (`M4 Pro`)
| Kiểm tra | Phạm vi | Kết quả |
| :--- | :--- | :--- |
| `--creator-v12-test` ([CreatorFeaturesTest.swift](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/editroom/Editroom/App/CreatorFeaturesTest.swift)) | `C1–C6`: Karaoke pill & export MP4 parity (`diff=12,770,567`, `exportDiff=2,300,392`), `generate_vietnamese_captions` + Undo/Redo, `auto_duck_bgm` qua `AVAssetReaderAudioMixOutput` (`rmsSilence/rmsSpeech = 7.9x`), `beat_sync_cuts` & `MediaAnalyzer.music` (`119.8 BPM`), `BRollBrowserView` + 1-click `V2`, skill `vietnamese-shorts-creator` & `get_project` `duck_under` | **6/6 PASSED** (`ALL 6 CREATOR V1.2 CHECKS PASSED`, `exit 0`) |
| `--hardening-4k-test` | `H1–H6` + `V1–V5` (`tools=64`, `bytes=42,688`, `5 built-in skills`) | **11/11 PASSED** (`rounds=474 ms`, `export_4k_hevc=2.17 s`, `rss=295.6 MB`) |
| `--smart-editing-test` + `--media-providers-test` + `--extensions-test` + `--hybrid-test` | Hồi quy toàn bộ M1-E → M6-E + `v1.1` | **6/6 + 6/6 + 7/7 + 7/7 PASSED** (**43/43 checks across 6 suites**) |
