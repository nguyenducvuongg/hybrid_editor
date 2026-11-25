# Constitution Seed — `hybrid_edit_vid` (v2)

> **Hướng dẫn cho Antigravity 2.0:** Tài liệu này là nội dung hạt giống để khởi tạo "Hiến pháp dự án" qua lệnh `/speckit-constitution` của GitHub Spec Kit. Mọi kế hoạch (`/speckit-plan`), đặc tả (`/speckit-specify`), đầu việc (`/speckit-tasks`) và mọi bước review code sau này đều phải tuân thủ tuyệt đối các điều khoản dưới đây. Nếu bất kỳ thay đổi nào có nguy cơ phá vỡ một Bất biến, Agent **phải dừng lại**, trình bày đánh đổi (trade-off) và chờ Product Owner duyệt.

---

## Phần I: 6 Bất biến Kiến trúc (The Six Architectural Invariants)

### I1 · Một cửa duy nhất cho mọi thay đổi (One Door for Every Change)
- Mọi thao tác làm thay đổi trạng thái dự án — từ kéo thả chuột/phím trên Slint, lệnh gọi MCP từ Antigravity, hay tác vụ từ Local LLM (Ollama/LM Studio) — **bắt buộc** phải đi qua một `EditorCore` / Command Bus duy nhất bằng Rust.
- Tuyệt đối không ghi trực tiếp vào cấu trúc dữ liệu dự án hay tệp dự án đi vòng qua Command Bus.
- Mọi chuỗi lệnh của Agent hỗ trợ gom nhóm giao dịch (`AgentTurn`) để nằm chung ngăn xếp Undo/Redo với thao tác thủ công của người dùng.

### I2 · External Agent chỉnh sửa trực tiếp trên Live Project
- Khi người dùng đang mở dự án trong ứng dụng `hybrid_edit_vid`, Antigravity kết nối qua MCP sẽ thao tác trên **chính phiên dự án đang mở đó** (Live-Attach Mode) thông qua cùng hệ thống Command Bus (I1).
- Mỗi thay đổi của Agent phát ra Event Stream để Hybrid Timeline Slint cập nhật ngay lập tức; người dùng có thể kéo thả, sửa tay hoặc Undo bất cứ lúc nào và Agent thấy ngay trạng thái mới nhất ở lượt gọi kế tiếp.
- Bảo đảm nhất quán ghi: **chỉ có một writer thực thi lệnh ghi tại một thời điểm** (serialized write lock), kèm cơ chế khóa tự phục hồi khi client chết đột ngột (P8).

### I3 · Preview và Export dùng chung một Renderer
- Khung hình hiển thị trên Viewport Slint, lưới ảnh trích xuất cho Agent kiểm tra thị giác (`preview_timeline_strip`) và khung hình xuất MP4/MOV cuối cùng phải đi qua cùng một đồ thị render và logic bố cục của lõi Concat.
- Mọi hiệu ứng, điểm cắt hoặc overlay mới bắt buộc được kiểm thử đồng thời trên cả đường preview lẫn đường export.

### I4 · Media phái sinh không bao giờ ghi đè tệp gốc
- Transcript (Whisper), bản đồ khoảng lặng (VAD), keyframe/chỉ mục B-roll, proxy video, hoặc tệp audio/video xử lý ở v0.2+ phải được lưu dưới dạng **artifact mới** liên kết tới media gốc qua mã định danh và mã băm phiên bản (revision + engine version).
- Người dùng luôn khôi phục hoặc đối chiếu về tệp nguồn nguyên bản được bất cứ lúc nào.

### I5 · Dữ liệu tách biệt hoàn toàn khỏi mã nguồn
- Toàn bộ dự án video, footage, cache, chỉ mục SQLite và trọng số model AI (Whisper, VAD, ONNX...) phải nằm trong **thư mục dữ liệu cấu hình ngoài repo code** (ví dụ `~/Library/Application Support/hybrid_edit_vid` hoặc `HYBRID_EDIT_DATA_DIR`).
- Build lại mã nguồn, chuyển nhánh Git hay chạy bộ test tuyệt đối không bao giờ chạm vào dữ liệu thực tế của người dùng.

### I6 · Tác vụ nặng chạy ngoài luồng chính và chạy tuần tự
- Mọi tác vụ tốn CPU/GPU/RAM (Whisper + VAD, tách cảnh & VLM lập chỉ mục B-roll, tạo proxy, render export 4K) phải chạy trên worker thread hoặc child process tách biệt khỏi luồng UI Slint và luồng phản hồi IPC/MCP.
- Tác vụ nặng chạy qua hàng đợi **tuần tự (một heavy job tại một thời điểm hoặc giới hạn rõ ràng phù hợp Unified Memory)**, bắt buộc có báo cáo tiến trình (`progress`), hủy an toàn (`cancel`) và thông báo lỗi tường minh.

---

## Phần II: Thứ bậc Ưu tiên của 4 Công cụ Phát triển (Toolchain Precedence)

Để 4 công cụ (`spec-kit`, `graphify`, `ponytail`, 4 skill chọn lọc của `addyosmani/agent-skills`) hỗ trợ nhau tối đa mà **không bao giờ xung đột**, mọi phiên làm việc của Antigravity 2.0 phải tuân thủ thứ bậc ưu tiên từ cao xuống thấp sau:

1. **Cấp 1 (Tối thượng) — Hiến pháp dự án (`constitution.md`):**
   - 6 Bất biến (I1–I6), kỷ luật kiểm thử định lượng, quy chuẩn an toàn/bảo mật và tối ưu M4 Pro. Không một skill hay plugin nào được phép ghi đè.
2. **Cấp 2 (Xương sống quản trị) — `github/spec-kit` (`/speckit-*`):**
   - Là cơ chế **duy nhất** quản lý vòng đời thiết kế tính năng lớn (`specify -> clarify -> plan -> tasks -> implement`) và khóa cứng ranh giới giao tiếp trong `contracts/`.
   - Không chạy song song quy trình spec của bên thứ ba.
3. **Cấp 3 (Bản đồ & Truy vết mã nguồn) — `Graphify-Labs/graphify` (`/graphify .`):**
   - Trước khi đọc sâu, sửa đổi hoặc lập kế hoạch trên codebase Rust/Slint của Concat, **ưu tiên truy vấn Knowledge Graph (`graphify-out/GRAPH_REPORT.md`, `graphify query`, `graphify path`)** thay vì `grep` mò mẫm tốn token.
   - Phân biệt rõ quan hệ `EXTRACTED` (từ AST thật) và `INFERRED`; cập nhật lại graph sau các thay đổi cấu trúc lớn.
4. **Cấp 4 (Kỷ luật thực thi, TDD & Chống phình code) — `ponytail` & 4 skill chiến thuật `addyosmani`:**
   - **`interview-me`:** Sử dụng ở bước Clarification Gate khi yêu cầu hoặc đánh đổi kỹ thuật còn mơ hồ (hỏi từng điểm sắc gọn).
   - **`test-driven-development`:** Áp dụng bắt buộc theo vòng **Red -> Green -> Refactor** cho mọi Pitfall trong `kit/PITFALLS_AND_FIXES.md` và mọi logic cốt lõi (Command Bus, Recoverable Lock, VAD/Whisper stitching, EDL patch, path byte-limit).
   - **`ponytail` (`/ponytail-review`, `/ponytail-debt`):** Gọi ở bước **review sau implement** để dọn abstraction thừa, struct/trait vẽ vời và code dài dòng không cần thiết. **Ranh giới đỏ:** `ponytail` tuyệt đối không được cắt bỏ 6 Bất biến (I1–I6), các schema trong `contracts/`, bước kiểm tra đầu vào, xử lý lỗi biên, hay các bài regression test.
   - **`code-review-and-quality`:** Chạy kiểm duyệt chất lượng 5 trục trước khi đóng/merge mỗi Milestone lớn (M0–M4).
   - **`context-engineering`:** Áp dụng khi phiên chat dài hoặc khi thiết kế cấu trúc trả về của MCP tools (`inspect_project_context`) để tối ưu ngân sách token.

---

## Phần III: Nguyên tắc Tối ưu Phần cứng Apple Silicon (MacBook Pro M4 Pro)

1. **Ưu tiên tăng tốc phần cứng gốc macOS:**
   - Giải mã, tạo proxy và mã hóa video qua **FFmpeg VideoToolbox** (`h264_videotoolbox`, `hevc_videotoolbox`, `prores_videotoolbox`).
   - Chạy `whisper.cpp` với backend **Metal** (`GGML_METAL=ON`).
   - Chạy mô hình ONNX (khi cần) qua **CoreML Execution Provider** trước khi fallback CPU.
   - Kết nối **Ollama / LM Studio** tận dụng tăng tốc GPU Metal / MLX trên M4 Pro.
2. **Bảo vệ độ mượt giao diện Slint:** Luồng UI không bao giờ bị chặn bởi I/O đĩa, decode khung hình đồng bộ hay request mạng tới LLM.
3. **Đo đạc định lượng trên M4 Pro:** Mọi chỉ số hiệu năng (thời gian build, tốc độ transcribe, độ trễ đồng bộ MCP lên Timeline, tốc độ export 4K) phải được đo thực tế trên máy đích và ghi vào `PROJECT.md`.

---

## Phần IV: Phân tách Tuyệt đối 2 Loại Skill

- **Dev-Workflow Skills (phục vụ lập trình xây dựng phần mềm):**
  - Global: `~/.gemini/config/plugins/` (`ponytail`) và `~/.gemini/config/skills/` (4 skill chọn lọc của `addyosmani`).
  - Workspace repo: `.agents/skills/` (`/speckit-*`) và rule Graphify trong `.agents/`.
- **Runtime Video-Editing Skills (phục vụ dựng phim khi dùng app):**
  - Lưu trữ trong mã nguồn tại `assets/editor-skills/<skill-name>/SKILL.md` (không trộn vào `.agents/skills/` của repo code).
  - App nạp bộ skill này (cùng skill tùy biến trong `HYBRID_EDIT_DATA_DIR/skills/`) vào phiên dựng phim thực tế.

---

## Phần V: Kỷ luật Làm việc, Kiểm thử và Vận hành

1. **Hỏi trước khi tác động hệ thống:** Luôn đề xuất và chờ Product Owner duyệt trước khi cài đặt, gỡ cài đặt, xóa hoặc ghi đè công cụ/dữ liệu trên máy.
2. **Bằng chứng thực thi là bắt buộc:** Không tuyên bố hoàn thành task/milestone nếu chưa chạy lệnh kiểm thử thực tế và xuất log đo đạc (`cargo test`, `ffprobe`, kết quả benchmark, script MCP 5 vòng liên tiếp).
3. **Quy tắc "Hai lần thất bại thì dừng":** Nếu cùng một lỗi lặp lại 2 lần sau khi sửa, dừng ngay, viết ra ít nhất 2 giả thuyết gốc rễ kèm cách kiểm chứng từng giả thuyết rồi hỏi Product Owner.
4. **Cách ly tuyệt đối môi trường Test:** Mọi bài test tự động phải dùng `HYBRID_EDIT_DATA_DIR` tạm thời riêng, cổng/socket riêng và dọn tiến trình theo PID sau khi chạy.
5. **Ghi chép sống (`PROJECT.md` + Bảng giấy phép):** Cập nhật `PROJECT.md` sau mỗi milestone (quyết định & lý do, kết quả đã đo kiểm, phần chưa kiểm chứng, bước tiếp theo) và ghi nhận giấy phép mọi crate/model AI mới thêm.
