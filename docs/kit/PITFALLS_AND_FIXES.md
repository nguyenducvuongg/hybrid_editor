# Pitfalls and Fixes — `hybrid_edit_vid` (v2)

Danh sách các lỗi tích hợp thực chiến đã chuyển thể sang kiến trúc **Rust + Slint + Live MCP + Whisper Metal + macOS Apple Silicon**.

> **Quy tắc bắt buộc (kết hợp skill `test-driven-development`):** Với mỗi pitfall liên quan đến milestone đang triển khai, hãy tuân thủ nghiêm ngặt vòng **Red -> Green -> Refactor**: viết bài kiểm thử hồi quy (regression test) trước, chạy chứng minh bài test **fail** (hoặc bắt được điều kiện biên), sau đó mới viết mã sửa tối thiểu để **pass**, rồi chạy `/ponytail-review` để giữ code sạch mà không làm mất test.

| Mã | Khu vực | Lỗi điển hình | Áp dụng cho `hybrid_edit_vid` |
| :--- | :--- | :--- | :--- |
| **P1** | Live MCP Bridge | Phiên MCP báo lỗi "stale revision" hoặc mất đồng bộ ngay sau khi Agent import media / cắt clip | Bắt buộc (M2) |
| **P2** | Render & Export | Sai màu nền/alpha giữa khung Preview Slint, ảnh `preview_timeline_strip` và video Export | Bắt buộc (M0, M1) |
| **P3** | Local Security | Nếu mở MCP qua HTTP cục bộ, máy chủ trả lời request có `Host` lạ (DNS rebinding) | Bắt buộc nếu bật HTTP transport (M2) |
| **P4** | State & Undo | Click chọn clip hoặc rê playhead làm kích hoạt autosave và xả rác lịch sử Undo | Bắt buộc (M1) |
| **P5** | Browser WebGL | Tràn WebGL context trên trình duyệt | **Đã loại bỏ** nhờ lõi Native Rust + Slint (vẫn quản lý GPU texture/buffer pool sạch trên Metal) |
| **P6** | Whisper A-roll | Whisper bịa lời thoại ("cảm ơn", "đăng ký kênh") ở khoảng lặng và cắt đứt câu ở biên cửa sổ | Sống còn cho v0.1 (M3) |
| **P7** | File System / macOS | Tên file phái sinh tiếng Việt (UTF-8 đa byte) quá 255 byte gây `ENAMETOOLONG` hoặc báo thành công ảo | Bắt buộc (M3, M4) |
| **P8** | Session Lock | Agent bị crash giữa phiên để lại khóa dự án (`concat.lock`) chặn vĩnh viễn client khác | Sống còn cho Live Mode (M1, M2) |
| **P9** | Build & Packaging | Chạy được ở chế độ Dev nhưng lỗi đường dẫn binary/model/dylib trên bản Release hoặc workspace khác | Bắt buộc (M0, M2, M4) |

---

## P1 · Phiên MCP bị "stale" hoặc mất đồng bộ sau khi Agent import media / thực thi lệnh

- **Triệu chứng:** Antigravity gọi tool import footage hoặc cắt clip thành công, nhưng ngay lệnh tiếp theo bị từ chối vì lệch project revision hoặc đọc phải trạng thái timeline cũ chưa có clip mới.
- **Nguyên nhân:** Lớp MCP Bridge trả kết quả tool về cho Agent trong khi Rust Core mới chỉ đưa sự kiện vào hàng đợi bất đồng bộ mà chưa thực sự commit xong trạng thái mới.
- **Hướng xử lý:** Thiết lập thứ tự đồng bộ chặt chẽ (strict ordering): lệnh từ MCP chỉ trả về `Ok(result, new_revision)` **sau khi** Command Bus đã commit thay đổi vào state lõi, phát sự kiện đồng bộ cho UI và hoàn tất flush trạng thái cần thiết. Không vá tạm bằng cách rút ngắn debounce.
- **Regression Test:** Chạy kịch bản MCP End-to-End thật (không mock bridge): tạo project -> import file -> đặt ngay lên timeline -> đọc lại trạng thái timeline -> cắt clip -> kiểm tra revision khớp 100%. Lặp lại **5 vòng liên tiếp** không rớt phiên.

---

## P2 · Lệch nền / Alpha giữa Preview, `preview_timeline_strip` và Export (I3)

- **Triệu chứng:** Khung xem trước hoặc ảnh chụp kiểm tra thị giác cho Agent hiển thị nền caro/trong suốt khác với file video xuất ra, hoặc vùng khoảng trống bị rác pixel.
- **Nguyên nhân:** Cấu hình nền canvas ở viewport bị trộn vào đồ thị render xuất video, hoặc `preview_timeline_strip` đi qua pipeline render khác pipeline export.
- **Hướng xử lý:** Mọi chỉ báo UI (checkerboard, khung chọn, đường gióng) chỉ thuộc lớp UI chrome của Slint; Export luôn lấp khoảng trống bằng màu đen đồng nhất (trừ khi xuất định dạng có kênh alpha); `preview_timeline_strip` gọi trực tiếp renderer lõi (I3).
- **Regression Test:** Xuất một clip không phủ kín khung 16:9 + một ảnh PNG trong suốt; kiểm tra pixel vùng viền đen và đối chiếu ảnh `preview_timeline_strip` với khung hình trích bằng `ffmpeg` từ video xuất ra.

---

## P3 · Bảo mật cổng giao tiếp cục bộ (DNS Rebinding & Local Access)

- **Triệu chứng:** Nếu MCP Gateway hỗ trợ Streamable HTTP cục bộ, trang web độc hại trên trình duyệt có thể lợi dụng DNS rebinding gửi request `Host: evil.example` vào cổng localhost để điều khiển app.
- **Hướng xử lý:** Ưu tiên giao tiếp nội bộ giữa `hybrid-edit-mcp` (`stdio`) và GUI bằng **Unix Domain Socket** (`chmod 600`). Nếu mở thêm Streamable HTTP: bắt buộc bind `127.0.0.1`, đặt **Host Allowlist Middleware** đầu tiên (chỉ chấp nhận `localhost`, `127.0.0.1`, `[::1]`, trả `403` cho mọi `Host` khác) và kiểm tra bearer token cục bộ.
- **Regression Test:** Request mang `Host: evil.example` tới endpoint nội bộ -> trả về `403`; request hợp lệ kèm token -> trả về `200`.

---

## P4 · Click chọn clip / rê playhead gây ghi đĩa liên tục và làm hỏng lịch sử Undo

- **Triệu chứng:** Bấm qua lại 20 clip trên Hybrid Timeline tạo ra 20 lần ghi file project và 20 mục Undo giả, làm mất khả năng `Cmd+Z` quay lại lượt Agent vừa dựng.
- **Hướng xử lý:** Tách bạch tuyệt đối `DocumentState` (đi qua Command Bus & Undo Stack) khỏi `ViewState` (selected clips, playhead, zoom, scroll — chỉ nằm trong bộ nhớ UI).
- **Regression Test:** 20 thao tác chọn clip + 20 lần di chuyển playhead tạo **0 lần ghi đĩa và 0 Undo entry**; 1 thao tác cắt/kéo clip tạo **đúng 1 Undo entry và 1 chu kỳ lưu**.

---

## P6 · Whisper bịa lời thoại ở đoạn im lặng và lệch timestamp trên footage dài (Sống còn cho A-roll)

- **Triệu chứng:** Whisper sinh câu ảo ("Cảm ơn các bạn đã xem", "Đăng ký kênh") đè lên khoảng lặng hoặc cắt đứt câu ở biên cửa sổ 30 giây.
- **Hướng xử lý:**
  1. Chuẩn hóa âm thanh nguồn về 16kHz mono WAV/PCM qua FFmpeg wrapper thống nhất.
  2. Đặt **VAD (Silero VAD)** phía trước để tách thành các speech chunk kết thúc tại khoảng lặng tự nhiên.
  3. Chạy `whisper.cpp` (backend **Metal** trên M4 Pro) riêng cho từng chunk, lấy word-level timestamp rồi dịch ngược về mốc thời gian gốc của file nguồn.
  4. Lọc bỏ text rơi ra ngoài vùng VAD hoặc khớp hallucination outro độ tin cậy thấp.
  5. **Cache theo file nguồn** (hash file + phiên bản model + cấu hình VAD); cắt/trim clip trên timeline tự động cắt lát transcript theo `[source_in, source_out]` mà không trộn từ giữa 2 clip.
- **Regression Test:** Dùng file ghi âm thật (tiếng Việt/Anh) có chèn 10 giây im lặng ở giữa và 10 giây im lặng ở cuối: khẳng định **0 từ nào xuất hiện trong vùng im lặng**, đo tốc độ xử lý thực tế trên M4 Pro và độ lệch timestamp.

---

## P7 · Tên tệp phái sinh quá dài (`ENAMETOOLONG`) và báo thành công ảo

- **Triệu chứng:** Tên footage tiếng Việt dài có dấu (UTF-8 2–3 byte/ký tự) ghép thêm hậu tố cache vượt quá giới hạn **255 byte** của APFS macOS, gây lỗi âm thầm nhưng job vẫn báo "xong".
- **Hướng xử lý:** Viết một hàm đặt tên duy nhất (`derived_artifact_path`) đếm theo **UTF-8 byte length**; nếu vượt ngưỡng an toàn (> 180 byte), rút gọn thành tiền tố cắt đúng biên UTF-8 + mã băm SHA-256 ngắn. Ghi nguyên tử qua tệp tạm `.tmp` rồi `rename`, và chỉ báo `Succeeded` sau khi xác nhận tệp đầu ra tồn tại và kích thước > 0 byte.
- **Regression Test:** Chạy pipeline tạo artifact trên tệp mẫu có tên tiếng Việt dài > 120 ký tự có dấu (vượt 255 byte khi gắn hậu tố): lần 1 tạo tệp khác rỗng, lần 2 đạt **cache hit** tức thì.

---

## P8 · Agent bị crash để lại khóa dự án (`Lock`) chặn vĩnh viễn phiên làm việc

- **Triệu chứng:** Antigravity hoặc script MCP bị `SIGKILL` giữa chừng làm kẹt khóa dự án vĩnh viễn.
- **Hướng xử lý:** Thay `concat.lock` bằng **Lease-based Recoverable Lock** trên Live Session của Rust Core: gắn `session_id`, `client_pid`, `last_heartbeat_at` và trạng thái transaction; nếu tiến trình chủ đã chết và hết thời gian gia hạn yên lặng (grace period 5–10 giây) không còn lệnh ghi dở, tự rollback transaction chưa commit và cho client mới tiếp quản an toàn. Chủ cũ nối lại trong grace period vẫn giữ nguyên phiên.
- **Regression Test:** Mở phiên MCP -> bắt đầu 1 agent turn -> giết đột ngột client (`kill -9`) -> kết nối client thứ 2 -> xác nhận sau cơ chế phục hồi, client thứ 2 tiếp quản thành công và dự án nguyên vẹn.

---

## P9 · Chạy được ở chế độ Dev nhưng lỗi khi chạy Binary Release hoặc Workspace khác

- **Triệu chứng:** `cargo run` trong thư mục dev chạy tốt nhưng khi Antigravity gọi binary release (`hybrid-edit-mcp`) từ `cwd` khác với `$PATH` tối giản thì không tìm thấy `ffmpeg`, thiếu `.dylib` hoặc lạc đường dẫn `assets/editor-skills/`.
- **Hướng xử lý:** Mọi lệnh `ffmpeg`/`ffprobe` đi qua một **Media Tool Wrapper duy nhất** (ưu tiên cấu hình/bundled -> `/opt/homebrew/bin` -> `$PATH`, có timeout & giới hạn log); dùng đường dẫn tuyệt đối chuẩn hóa cho `assets/editor-skills/` và `HYBRID_EDIT_DATA_DIR`; kiểm tra liên kết thư viện bằng `otool -L` trên macOS.
- **Regression Test:** Chạy binary release `hybrid-edit-mcp` từ `/tmp/clean_cwd` với `$PATH` tối giản mô phỏng Antigravity subprocess và hoàn thành chu trình import -> transcribe -> export.
