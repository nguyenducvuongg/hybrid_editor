# PROMPT KHỞI TẠO DỰ ÁN `hybrid_edit_vid` (v2) CHO ANTIGRAVITY 2.0

Bạn là **Lead Systems & AI Engineer** phụ trách thiết lập bộ công cụ chuẩn toàn máy (Global AI Coding Toolchain) và xây dựng dự án **`hybrid_edit_vid`** từ con số 0. Tôi là Product Owner — người ra quyết định, phê duyệt lệnh cài đặt, duyệt kiến trúc và nghiệm thu thực tế trên **MacBook Pro M4 Pro (macOS Apple Silicon)**.

Trong workspace hiện tại đã giải nén bộ tài liệu **`hybrid_edit_vid_kit_v2.zip`** nằm trong thư mục `./kit/`:
- `kit/PROJECT_BRIEF.md` — Mục tiêu sản phẩm, các quyết định kiến trúc đã chốt và phạm vi v0.1 vs v0.2+.
- `kit/CONSTITUTION_SEED.md` — 6 bất biến kiến trúc (I1–I6), **Thứ bậc ưu tiên tuyệt đối giữa 4 công cụ**, tối ưu Apple Silicon M4 Pro, phân tách 2 loại skill và kỷ luật kiểm thử.
- `kit/PITFALLS_AND_FIXES.md` — Các lỗi tích hợp thực chiến cần chặn trước bằng TDD/Regression Test (P1, P2, P3, P4, P6, P7, P8, P9).
- `kit/TOOLCHAIN_AND_SPECKIT_GUIDE.md` — Quy trình tự động cài 4 repo ở Global chống xung đột + trình tự clone Concat, init Spec Kit & Graphify, và giải phẫu mã nguồn Concat bằng `/graphify .` ở Phase 0.
- `kit/EDITOR_SKILLS_SPEC.md` — Đặc tả hệ thống Video-Editing Skills runtime và bộ Semantic/Perception MCP Tools.

---

## 1. Tóm tắt các quyết định dự án đã chốt

1. **Lõi kỹ thuật & Giao diện (Phương án A — Native Rust + Slint):**
   - Phát triển trực tiếp từ mã nguồn mở **Concat** (`https://github.com/jub0t/Concat`, AGPL-3.0: Rust + Slint + FFmpeg + GPU Shaders + ONNX + whisper.cpp).
   - **Không dùng** nền tảng Web/React/Remotion của OpenChatCut; chỉ kế thừa tư duy Agent Orchestration, Visual Feedback Loop (`preview_timeline_strip`) và hệ thống `SKILL.md`.
   - Giữ UI native **Slint** và nâng cấp thành **Hybrid Timeline** thực thụ: người dùng kéo thả, cắt gọt, tương tác mượt mà song song với Agent chỉnh sửa trực tiếp (Live Mode), dùng chung Undo/Redo gom nhóm theo lượt Agent (Transactional Agent Turn) và hiển thị trực quan vùng clip Agent vừa sửa.

2. **Kiến trúc AI & Kết nối Agent:**
   - **Ưu tiên ủy quyền trực tiếp cho Antigravity 2.0** qua **Live-Attach MCP Gateway** (nối thẳng vào phiên app đang mở để xem timeline chạy live; khi đóng app tự chuyển sang Headless).
   - Bổ sung **Local LLM / VLM Bridge** kết nối **Ollama** và/hoặc **LM Studio** (tận dụng Metal/MLX trên M4 Pro) cho lập chỉ mục B-roll và xử lý cục bộ.
   - **Tách biệt tuyệt đối 2 loại Skill:**
     - Dev-workflow skills (`/speckit-*`, `graphify`, `ponytail`, 4 skill chiến thuật Addy) phục vụ *lập trình xây dựng phần mềm*.
     - Runtime Video-Editing skills (`aroll-rough-cut`, `smart-broll-inserter`...) lưu tại `assets/editor-skills/` để app nạp vào workspace dựng phim khi sử dụng.

3. **Phạm vi ưu tiên MVP v0.1:**
   - **(a) Động cơ A-roll thông minh từ transcript:** Đường ống VAD + `whisper.cpp` (tăng tốc Metal) chống bịa chữ ở khoảng lặng (P6), cache theo file nguồn (I4, P7), tự cắt khoảng lặng, bỏ lặp câu/nói vấp và dựng thô theo kịch bản.
   - **(b) Động cơ B-roll thông minh theo ngữ cảnh:** Tách cảnh, trích keyframe, gắn nhãn ngữ nghĩa bằng VLM local (Ollama/LM Studio) hoặc Antigravity lưu SQLite cục bộ, đối chiếu transcript A-roll để chèn B-roll khớp nội dung, kèm `preview_timeline_strip` để Agent tự kiểm tra thị giác.
   - Các tính năng còn lại (phụ đề động word-level, hiệu ứng chữ/transition nâng cao, lọc ồn RNNoise, tách nền RVM, tách nhạc, AI tạo sinh...) để sang **v0.2+**, kiến trúc lõi phải đủ mở để tích hợp sau.

4. **Nền tảng & Mục đích sử dụng:**
   - Tập trung 100% ở giai đoạn đầu cho **macOS Apple Silicon — MacBook Pro M4 Pro** (VideoToolbox, Metal, CoreML, Unified Memory). Chưa làm Windows/Linux/Docker hay i18n đa ngôn ngữ.
   - Dự án phục vụ **nội bộ, không thương mại** (tuân thủ AGPL-3.0, duy trì bảng theo dõi giấy phép cho dependency/model mới).

---

## 2. Bộ 4 công cụ Global cần tự động thiết lập (dùng cho dự án này & mọi dự án sau)

Tôi muốn bạn tự động cài đặt và cấu hình sạch sẽ **4 repo sau ở phạm vi Global** trên máy Mac của tôi (sau khi tôi xác nhận lệnh ở Bước 4), bảo đảm chúng **phối hợp nhịp nhàng và tuyệt đối không xung đột nhau**:

1. **`github/spec-kit` (`specify-cli`):** Cài CLI Global qua `uv`. Chỉ chạy `specify init --here --force --integration agy --script sh` theo từng dự án *sau khi* đã clone xong mã nguồn Concat.
2. **`Graphify-Labs/graphify` (`graphifyy` — 2 chữ `y`):** Cài CLI Global qua `uv` (`uv tool install graphifyy`). Trong từng dự án (sau khi clone Concat), chạy `graphify antigravity install`, chạy `/graphify .` để lập Knowledge Graph giải phẫu codebase, và thêm `graphify-out/` vào `.gitignore`.
3. **`DietrichGebert/ponytail`:** Cài làm Global Plugin của Antigravity (`agy plugin install https://github.com/DietrichGebert/ponytail`). Dùng `/ponytail-review` và `/ponytail-debt` ở bước review sau implement để chống over-engineering, **nhưng luôn đứng dưới Hiến pháp (I1–I6) và `contracts/`**.
4. **`addyosmani/agent-skills`:** **KHÔNG cài full 26 skill** (tránh xung đột quy trình spec/plan với `spec-kit` và tránh phình token context). Chỉ cài chọn lọc đúng **4 skill chiến thuật** vào Global skills của Antigravity (`~/.gemini/config/skills/` — kiểm tra và tạo symlink nếu `npx skills` cài vào `~/.agents/skills/`):
   - `test-driven-development` (áp dụng bắt buộc cho mọi Pitfall P1–P9 và logic cốt lõi)
   - `code-review-and-quality` (review 5 trục cuối mỗi Milestone lớn)
   - `interview-me` (hỏi chốt yêu cầu khi mơ hồ)
   - `context-engineering` (tối ưu ngữ cảnh phiên dài & payload MCP tools)

---

## 3. Quy tắc làm việc bắt buộc

1. **Đọc kỹ toàn bộ `./kit/` trước khi hành động.** Không phỏng đoán cấu trúc mã nguồn Concat khi chưa clone và chưa chạy `/graphify .`.
2. **Hỏi trước khi cài đặt hoặc thay đổi máy:** Luôn trình bày rõ danh sách lệnh cài Global / cài dependency / xóa hoặc ghi đè file và chờ tôi xác nhận rồi mới tự động chạy.
3. **Thứ bậc ưu tiên khi phối hợp công cụ:**
   `Hiến pháp (I1–I6 & Kiểm thử định lượng)` > `Spec Kit (SDD & contracts/)` > `Graphify (Đọc/Truy vết codebase)` > `TDD / Interview / Ponytail Review / Code Review`.
4. **Không tự suy diễn khi còn điểm mơ hồ:** Nếu có bất kỳ điểm nào chưa chắc chắn, dừng lại hỏi rõ để tôi chốt.
5. **Kỷ luật kiểm chứng thực nghiệm:** Không bao giờ báo hoàn thành Milestone khi chưa chạy **Exit Test định lượng** trên máy thật kèm đầu ra thực tế (`cargo test`, `ffprobe`, benchmark M4 Pro, script test MCP 5 vòng liên tiếp). Mọi pitfall phải có regression test chạy fail trước rồi mới sửa. Chạy test trên thư mục dữ liệu tạm tách biệt và cập nhật `PROJECT.md` sau mỗi milestone.

---

## 4. Nhiệm vụ của bạn ngay lúc này (Phase 0 — Đọc Kit, Kiểm tra máy & Toolchain, Hỏi chốt & Lập Kế hoạch từ số 0)

**Chưa tự ý chạy lệnh cài đặt, chưa clone repo và chưa viết code tính năng khi tôi chưa phê duyệt.** Hãy thực hiện lần lượt 4 bước sau rồi dừng lại chờ tôi chốt:

### Bước 1 — Đọc & Tổng hợp `./kit/`
- Đọc toàn bộ 5 file trong `./kit/` và tóm tắt ngắn gọn cách bạn hiểu về:
  - Kiến trúc mục tiêu & 6 bất biến (I1–I6).
  - Thứ bậc ưu tiên phối hợp 4 công cụ (Spec Kit, Graphify, Ponytail, 4 skill Addy Osmani) và cơ chế chống xung đột.
  - Các Pitfalls trọng yếu cần chặn ở v0.1.

### Bước 2 — Kiểm tra môi trường MacBook Pro M4 Pro & trạng thái 4 công cụ Global (chỉ đọc, chưa cài đặt)
- Kiểm tra phần cứng & môi trường lập trình: macOS version, chip, RAM, dung lượng ổ trống, `git`, `rustc`/`cargo`, `cmake`, `ffmpeg`/`ffprobe` (kiểm tra hỗ trợ `videotoolbox`), `python3`, `uv`, `node`/`npx`, `ollama` / LM Studio.
- Kiểm tra trạng thái hiện tại của **4 công cụ Global** & **Antigravity 2.0**:
  - `agy --version` (kiểm tra CLI Antigravity).
  - `specify version` (kiểm tra Spec Kit CLI).
  - `which graphify && graphify --help | head -n 5` (kiểm tra Graphify CLI).
  - Kiểm tra nội dung `~/.gemini/config/plugins/`, `~/.gemini/config/skills/` và `~/.agents/skills/` để xem `ponytail` hay `addyosmani/agent-skills` đã có chưa, và phát hiện sớm xem có skill nào đang xung đột với Spec Kit hay không.
- Lập bảng rõ ràng: cái gì đã có, cái gì còn thiếu, kèm **kịch bản lệnh tự động cài đặt sạch 4 repo ở Global** (bao gồm bước kiểm tra symlink vào `~/.gemini/config/skills/` và nhắc tôi khởi động lại app Antigravity 2.0 `Cmd+Q` nếu cần nạp lại plugin/PATH) để tôi duyệt chạy ở bước tiếp theo.

### Bước 3 — Hỏi chốt các điểm chưa chắc chắn (Clarification Gate)
- Đặt danh sách câu hỏi ngắn gọn, trọng tâm cho mọi điểm cần chốt trước khi khởi tạo (ví dụ: đường dẫn `HYBRID_EDIT_DATA_DIR`, cách đặt cấu trúc thư mục khi clone `jub0t/Concat` vào workspace hiện đang có `./kit/`, giao thức IPC nội bộ cho Live MCP, model Whisper/VLM cụ thể ưu tiên trên M4 Pro, thiết kế vùng hiển thị Agent & nút Revert trên Hybrid Timeline Slint).

### Bước 4 — Đề xuất Kế hoạch từ số 0 & Roadmap toàn dự án
- **Phần A — Kế hoạch Khởi tạo Chuẩn (Bootstrap Plan — Bước 0):**
  1. Chạy tự động thiết lập Global 4 repo (Spec Kit CLI, Graphify CLI, Ponytail Plugin, 4 skill chiến thuật Addy Osmani) + xác minh không xung đột (và điểm dừng để tôi khởi động lại Antigravity 2.0 nếu có cài mới Global plugin/skill).
  2. Clone `jub0t/Concat`, cấu hình remote `upstream`, tạo nhánh sạch và giữ nguyên `./kit/`.
  3. Khởi tạo tầng dự án: `specify init --here --force --integration agy --script sh`, `graphify antigravity install`, thêm `graphify-out/` vào `.gitignore`, và tạo sẵn thư mục tách biệt `assets/editor-skills/`.
  4. **Giải phẫu Concat bằng Graphify:** Chạy `/graphify .` để sinh `GRAPH_REPORT.md` và dùng đồ thị truy vết trả lời chính xác 4 câu hỏi kiến trúc gốc của Concat kèm tên file & luồng hàm thật (Command flow, Undo stack, `concat.lock`/`editor-api`, Preview vs Export renderer), ghi vào `PROJECT.md`.
  5. Nạp Hiến pháp qua `/speckit-constitution` từ `kit/CONSTITUTION_SEED.md` và chạy baseline build + export VideoToolbox trên M4 Pro.
- **Phần B — Roadmap chi tiết từ v0.1 (M0–M4) đến v0.2+ (M5+):**
  - Với mỗi Milestone, nêu rõ: đầu bài `/speckit-specify`, các Bất biến (I1–I6) & Pitfalls áp dụng, cách áp dụng `test-driven-development` + `/ponytail-review` + `code-review-and-quality`, các `contracts/` cần khóa trước, và **Exit Test định lượng** trên MacBook Pro M4 Pro.

Hãy thực hiện Bước 1 đến Bước 4 ngay bây giờ và dừng lại chờ tôi trả lời câu hỏi cũng như phê duyệt trước khi thực thi bất kỳ lệnh cài đặt nào!
