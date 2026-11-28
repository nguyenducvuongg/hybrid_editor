---
name: aroll-rough-cut
description: Cắt dựng thô A-roll tiếng Việt với Whisper Metal + VAD lọc khoảng lặng, giữ câu nói tự nhiên trong 1 AgentTurn có thể Undo.
version: 1.0.0
tags:
  - aroll
  - vietnamese
  - whisper
  - vad
  - rough-cut
---

# A-Roll Rough-Cut (Tiếng Việt + VAD Guard)

Dùng skill này khi người dùng muốn nghe băng tiếng Việt, bỏ khoảng lặng (`dead air`), hoặc cắt rough-cut một clip A-roll.

## Quy trình chuẩn (`I1`, `I4`, `P6`)

1. **Xác định clip A-roll mục tiêu**:
   - Gọi `get_project` để lấy `clip_id` (hoặc `asset_id` / đường dẫn file) trên `V1`.
2. **Transcribe với VAD pre-gate**:
   - Gọi `transcribe_aroll` (`language: "vi"`, `min_silence_sec: 0.7`, `pad_sec: 0.12`).
   - Kiểm tra `speech_spans`, `words` và `suggested_keep_ranges`. Nếu clip hoàn toàn im lặng, `speech_spans` rỗng — không tự bịa lời thoại hoặc cắt nhầm (`P6`).
3. **Loại bỏ câu vấp / khoảng lặng theo ý người dùng**:
   - Lọc lại các đoạn từ `suggested_keep_ranges` (hoặc giữ theo dải thời gian của câu muốn giữ).
   - Mở giao dịch: `begin_agent_turn(turn_id: ..., summary: "Rough-cut A-roll tiếng Việt")`.
   - Áp dụng 1 lệnh duy nhất: `apply_edl_patch` với operation `{ "op": "keep_ranges", "clip_id": ..., "coord": "source", "ripple": true, "ranges": [...] }`.
4. **Kiểm tra thị giác trước khi chốt (`P2`)**:
   - Gọi `preview_timeline_strip` ở các điểm nối (`timestamps`) để xác nhận không bị nhảy hình/cắt cụt.
   - Đóng giao dịch: `commit_agent_turn` để gộp toàn bộ thành 1 bước Undo (`⌘Z`).
