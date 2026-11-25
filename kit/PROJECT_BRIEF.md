# Project Brief: `hybrid_edit_vid`

## 1. Tầm nhìn sản phẩm
**`hybrid_edit_vid`** là nền tảng dựng phim **local-first, hybrid (Người + AI Agent cùng làm việc trực tiếp trên một timeline)** dành cho macOS Apple Silicon (tối ưu tối đa cho **MacBook Pro M4 Pro**), xây dựng để sử dụng **nội bộ, không mang tính thương mại**.

Sản phẩm kết hợp hai thế mạnh cốt lõi:
1. **Hiệu năng và độ chính xác Native của `jub0t/Concat` (Rust + Slint + FFmpeg + GPU Shaders + ONNX + whisper.cpp):** Xử lý mượt footage 4K/Log dung lượng lớn, preview và export dùng chung một engine, AI chạy offline không watermark, không phụ thuộc cloud.
2. **Trải nghiệm AI-Native và hệ thống Skill của `0xsline/OpenChatCut`:** Agent dựng phim theo quy trình chuyên nghiệp đóng gói trong `SKILL.md`, có vòng lặp tự kiểm tra thị giác trên timeline (`preview_timeline_strip`), thao tác live trước mắt người dùng và tích hợp chặt với **Antigravity 2.0** cùng **Local LLM/VLM (Ollama / LM Studio)**.

---

## 2. Các quyết định kiến trúc đã chốt (Locked Decisions)

| Hạng mục | Quyết định | Lý do & Định hướng thực thi |
| :--- | :--- | :--- |
| **Mã nguồn nền** | Fork/phát triển từ `jub0t/Concat` (AGPL-3.0) | Có sẵn lõi Rust mạnh, multi-track, keyframe, FFmpeg, GPU shaders, whisper-cpp, ONNX và nền tảng MCP/JSON-RPC/gRPC. Loại bỏ hoàn toàn React/Remotion/WebGL của OpenChatCut. |
| **Giao diện (UI Stack)** | **Phương án A: Giữ Slint của Concat** | Tận dụng viewport & timeline native mượt sẵn có. Tối ưu lại thành **Hybrid Timeline**: hỗ trợ kéo thả/cắt ghép thủ công tự nhiên, đồng thời hiển thị real-time thay đổi từ Agent, có vùng đánh dấu thao tác của Agent, nút Revert theo lượt (Agent Turn) và bảng trạng thái/chat gọn nhẹ. |
| **Bộ não AI & Agent** | **Ưu tiên Antigravity 2.0** + tùy chọn **Ollama / LM Studio** | Antigravity điều khiển trực tiếp qua **Live-Attach MCP Gateway** dùng chung bộ Video-Editing Skills. Kết nối thêm Ollama/LM Studio qua API cục bộ (OpenAI-compatible / Ollama API) để gán nhãn B-roll (VLM), tóm tắt transcript hoặc chạy tác vụ AI hoàn toàn offline. |
| **Phạm vi v0.1 (MVP)** | **(a) A-roll Rough Cut** + **(b) Smart B-roll Insertion** | Tập trung làm xuất sắc 2 bài toán tốn thời gian nhất khi dựng phim thực tế. |
| **Phạm vi v0.2+ (Backlog)** | Auto-caption động (word-level), transitions/text presets, lọc ồn giọng nói (RNNoise), tách nền (RVM), tách nhạc, tạo tài nguyên AI tạo sinh (ảnh/video/SFX/TTS) | Thiết kế kiến trúc lõi đủ sạch và mô-đun để cắm thêm ở các phiên bản sau mà không phải viết lại lõi. |
| **Phần cứng & HĐH** | **macOS Apple Silicon — MacBook Pro M4 Pro** | Bật tối đa VideoToolbox (hardware decode/encode/proxy), Metal (whisper.cpp & GPU shaders), CoreML (ONNX Runtime), tối ưu Unified Memory. Không làm Windows/Linux/Docker ở giai đoạn đầu. |
| **Pháp lý & Mục đích** | Nội bộ, phi thương mại (AGPL-3.0) | Chưa cần kiểm toán asset thương mại hay i18n đa ngôn ngữ ở v0.1, nhưng vẫn duy trì bảng theo dõi giấy phép cho dependency & model thêm mới. |

---

## 3. Sơ đồ kiến trúc mục tiêu (Target Architecture)

```text
+-------------------------------------------------------------------------+
|                    HYBRID WORKSPACE UI (Slint Native)                   |
|   [ Media Bin ]   [ Video Viewport & Hybrid Timeline ]   [ Agent HUD ]  |
|   - Hiển thị dấu vết Agent edits, Progress/Cancel, Accept / Revert Turn |
+---------------------------^-------------------------------^-------------+
                            | (State Diff Event Stream)     | (User / Local Chat)
                            v                               v
+---------------------------------------+   +-----------------------------+
|        CONCAT CORE ENGINE (Rust)      |   |  LOCAL AI & MEDIA INDEXER   |
|  - Single-Owner Live Session Store    |<--|  - VAD + whisper.cpp (Metal)|
|  - Unified Command Bus (I1)           |   |  - Scene Detect + Keyframes |
|  - Transactional Batch Undo (Turn)    |   |  - SQLite Semantic Index    |
|  - FFmpeg (VideoToolbox) + Shaders    |   |  - Ollama / LM Studio Client|
|  - Derived Artifacts Store (I4, I5)   |   |  - Serialized Heavy Queue I6|
+-------------------^-------------------+   +--------------^--------------+
                    |                                      |
                    | (Internal IPC: Unix Socket / gRPC)   |
                    v                                      |
+---------------------------------------+                  |
|    LIVE-ATTACH MCP GATEWAY (Bridge)   |<-----------------+
|  - Attach vào phiên UI đang mở (I2)   |
|  - Fallback Headless nếu app đóng     |
|  - Recoverable Lock (P8) & Sync (P1)  |
|  - Semantic & Perception Video Tools  |
+-------------------^-------------------+
                    | (stdio / localhost Streamable HTTP + Host Guard P3)
                    v
+---------------------------------------+
|     GOOGLE ANTIGRAVITY 2.0 (IDE/CLI)  |
|  - Đọc Runtime Skills (editor-skills) |
|  - Plan -> Cut/Insert -> Visual QA    |
+---------------------------------------+
```

---

## 4. Điểm khác biệt cốt lõi so với `jub0t/Concat` gốc

1. **Phá vỡ giới hạn `concat.lock` (Live Collaboration):** Chuyển từ khóa độc quyền sang **Single-Owner Engine + Multi-Client Live Session**: tiến trình GUI giữ quyền sở hữu engine và mở cổng IPC cục bộ cho MCP Gateway gắn thẳng vào phiên đang mở (còn khi GUI đóng, MCP fallback sang Headless).
2. **Transactional Batch Undo (Agent Turn):** Gói chuỗi lệnh cắt/chèn của Agent trong một lượt hội thoại vào một giao dịch hoàn tác duy nhất (`begin_agent_turn` -> các lệnh sửa -> `commit_agent_turn` / `rollback_agent_turn`) để người dùng nhấn `Cmd+Z` hoặc bấm Revert hoàn tác trọn vẹn 1 lượt.
3. **Semantic & Perception Tools:** Bổ sung tầng công cụ giúp Agent hiểu nội dung video thay vì cắt mù theo giây: tóm tắt ngữ cảnh timeline gọn token, word-level transcript, chỉ mục ngữ nghĩa B-roll và dải khung hình xem trước (`preview_timeline_strip`) để tự kiểm tra thị giác.
4. **Dữ liệu tách biệt & Non-destructive Artifacts:** Mọi file phái sinh (transcript JSON, silence map, keyframe thumbnails, SQLite index, proxy video) lưu ngoài thư mục code và không bao giờ ghi đè footage gốc.
