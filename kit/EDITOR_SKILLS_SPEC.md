# Đặc tả Hệ thống Video-Editing Skills & Semantic MCP Tools

Tài liệu này định nghĩa tầng trí tuệ dựng phim runtime của `hybrid_edit_vid` — lấy cảm hứng từ Agent Workflow của OpenChatCut nhưng chạy trực tiếp trên lõi **Concat (Rust + Slint)** và tối ưu cho **Antigravity 2.0** + **Ollama / LM Studio**.

> **Lưu ý phân tách:** Các skill dựng phim dưới đây là **Runtime Editor Skills**, lưu tại `assets/editor-skills/` trong mã nguồn và `HYBRID_EDIT_DATA_DIR/skills/` khi chạy app — hoàn toàn tách biệt với Dev-Workflow Skills (`.agents/skills/` của Spec Kit và `~/.gemini/config/skills/` của Global dev tools).

---

## 1. Phân tầng MCP Tools (Từ Low-level đến Semantic & Perception)

### Nhóm 1 · Quản trị Phiên & Giao dịch (Session & Transaction Control — I1, I2, P8)
- `session_attach(project_path | active)` — Gắn vào cửa sổ app đang mở (Live Mode) hoặc khởi chạy Headless nếu app đóng; trả về `session_id`, `mode`, và `revision`.
- `session_heartbeat(session_id)` — Duy trì lease sống cho phiên.
- `begin_agent_turn(summary)` — Mở một giao dịch gom nhóm Undo (hiển thị trạng thái đang làm việc trên Hybrid Timeline Slint).
- `commit_agent_turn(turn_id)` — Chốt giao dịch thành 1 bước Undo duy nhất, đảm bảo đồng bộ revision mới nhất trước khi trả kết quả (P1).
- `rollback_agent_turn(turn_id)` — Hủy sạch toàn bộ thao tác trong lượt nếu Agent phát hiện lỗi hoặc người dùng bấm Hủy.

### Nhóm 2 · Nhận thức Ngữ cảnh & Thị giác (Perception & Context Tools — áp dụng `context-engineering`)
- `inspect_project_context(detail_level)` — Trả về bản tóm tắt timeline tiết kiệm token (danh sách track, clip kèm `clip_id`, vị trí timeline, `source_in`/`source_out`, và đoạn transcript tóm tắt).
- `preview_timeline_strip(timestamps[], width, grid_cols)` — Dùng chính renderer lõi (I3) để xuất nhanh lưới ảnh (contact sheet / filmstrip) tại các mốc thời gian Agent vừa cắt/chèn B-roll, in nhãn timestamp lên góc ảnh để Multimodal LLM (Antigravity hoặc VLM local) **tự nhìn kiểm tra lỗi thị giác** (lệch khung hình, hình đen, cắt ngang chuyển động).
- `get_job_status(job_id)` / `cancel_job(job_id)` — Theo dõi tiến trình và hủy các tác vụ nặng bất đồng bộ (I6), tránh timeout kết nối MCP.

### Nhóm 3 · Động cơ A-roll (MVP v0.1a — P6, P7)
- `transcribe_media(media_id, language, model)` — Chạy đường ống **VAD + whisper.cpp (Metal)**, lưu cache artifact an toàn byte-length (I4, P7), trả về word-level transcript và danh sách vùng im lặng.
- `detect_silence(media_id, threshold_db, min_duration_ms)` — Trả về danh sách khoảng lặng chính xác từ VAD/năng lượng âm thanh.
- `get_transcript(target_id, granularity)` — Lấy lời thoại theo từ (`word`) hoặc theo câu (`segment`) kèm mốc thời gian nguồn và mốc thời gian trên timeline.
- `apply_edl_patch(operations[])` — Cho phép Agent gửi **một danh sách cắt ghép tổng hợp (Edit Decision List)** trong 1 lần gọi (giữ các khoảng `[in, out]`, xóa đoạn vấp/im lặng, khép khoảng trống ripple-delete) thay vì gọi lẻ tẻ hàng chục lệnh `split`/`delete`.

### Nhóm 4 · Động cơ B-roll Thông minh (MVP v0.1b)
- `index_broll_folder(folder_path, vlm_provider)` — Quét thư mục footage B-roll: chạy tách cảnh (`scene_detect`), trích keyframe đại diện, gửi qua **VLM local (Ollama / LM Studio)** hoặc Antigravity mô tả nội dung/góc máy/ánh sáng/cảm xúc, lưu vào **SQLite Semantic Index** trong `HYBRID_EDIT_DATA_DIR`.
- `search_broll(query, duration_min_ms, orientation, top_k)` — Tìm các đoạn B-roll phù hợp nhất với đoạn thoại A-roll (kết hợp FTS5 / từ khóa và semantic matching).
- `insert_broll_overlay(broll_media_id, source_in, source_out, timeline_start, track_index, mute_audio, fit_mode)` — Chèn B-roll lên track phủ (V2+) khớp nhịp nói A-roll, tự động tắt âm thanh B-roll mặc định và căn khung hình chuẩn.

---

## 2. Chuẩn Định dạng Runtime Video-Editing Skill (`SKILL.md`)

Mọi skill dựng phim lưu trong `assets/editor-skills/<skill-slug>/SKILL.md` theo cấu trúc YAML frontmatter + Markdown:

```markdown
---
name: aroll-rough-cut
version: 0.1.0
description: Quy trình dựng thô A-roll từ transcript — xóa khoảng lặng, bỏ lặp câu/nói vấp và giữ nhịp nói tự nhiên.
required_tools:
  - begin_agent_turn
  - transcribe_media
  - detect_silence
  - get_transcript
  - apply_edl_patch
  - preview_timeline_strip
  - commit_agent_turn
---

# Quy trình thực thi (Workflow)
1. Gọi `inspect_project_context` để nắm cấu trúc track A-roll hiện tại.
2. Đảm bảo toàn bộ clip A-roll đã có word-level transcript qua `transcribe_media` (đã qua lọc VAD).
3. Phân tích transcript để lập kế hoạch cắt (Edit Plan):
   - Xác định khoảng lặng dài hơn ngưỡng cấu hình (mặc định > 450ms), chừa đệm thở (padding 80–120ms) để tiếng không bị cụt.
   - Đánh dấu các câu nói vấp, lặp ý (giữ lần nói trôi chảy sau cùng).
   - Nếu người dùng cung cấp kịch bản mục tiêu, đối chiếu sắp xếp theo cấu trúc kịch bản.
4. Trình bày ngắn gọn bản tóm tắt kế hoạch cắt (tổng thời lượng trước/sau) nếu cắt > 30% footage, hoặc thực thi trực tiếp theo yêu cầu.
5. Mở `begin_agent_turn`, áp dụng hàng loạt bằng `apply_edl_patch`, kiểm tra các điểm nối bằng `preview_timeline_strip` rồi gọi `commit_agent_turn`.
```

### Danh sách 2 Skill cốt lõi cho v0.1
1. **`assets/editor-skills/aroll-rough-cut/SKILL.md`**: Dựng thô A-roll, cắt khoảng lặng giữ nhịp thở tự nhiên, loại bỏ nói vấp/lặp câu, hỗ trợ dựng theo kịch bản hoặc dàn ý người dùng đưa.
2. **`assets/editor-skills/smart-broll-inserter/SKILL.md`**: Đọc transcript A-roll sau khi dựng thô, phân đoạn ý chính (beat sheet), truy vấn `search_broll`, đề xuất & chèn B-roll phủ lên track V2 với nguyên tắc tránh lặp clip, thời lượng shot hợp lý (2–5 giây), kiểm tra khung hình bằng `preview_timeline_strip` trước khi chốt `commit_agent_turn`.

---

## 3. Chiến lược kết hợp Antigravity 2.0 + Ollama / LM Studio

| Tác vụ AI | Engine ưu tiên | Engine dự phòng / Tùy chọn |
| :--- | :--- | :--- |
| Lập kế hoạch dựng phim, hiểu kịch bản dài, điều phối tool đa bước | **Antigravity 2.0** (qua Live MCP) | Local LLM qua Ollama / LM Studio (Qwen/Llama/Gemma reasoning models) |
| Chuyển giọng nói thành văn bản (Word-level STT) | **Local `whisper.cpp` (Metal)** + Silero VAD | Không dùng cloud ở v0.1 |
| Phân tích & gắn nhãn hàng loạt ảnh keyframe kho B-roll | **Local VLM qua Ollama / LM Studio** (tiết kiệm token & riêng tư 100%) | Antigravity Multimodal (khi không bật Ollama/LM Studio) |
| Kiểm tra thị giác (`preview_timeline_strip`) | **Antigravity 2.0** (Multimodal) | Local VLM qua Ollama / LM Studio |
