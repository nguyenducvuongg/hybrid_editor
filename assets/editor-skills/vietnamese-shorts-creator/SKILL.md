---
name: vietnamese-shorts-creator
description: Dựng video Reels/Shorts/TikTok tiếng Việt trọn quy trình: cắt thô A-roll VAD, phụ đề karaoke từng từ CapCut, chèn B-roll 3 tầng theo nhịp beat, và auto-ducking nhạc nền trong 1 AgentTurn.
---

# Vietnamese Shorts & Reels Creator

Quy trình chuẩn cho Creator tiếng Việt trên Editroom Core (bảo toàn 1-Step Undo qua `AgentTurn` & `preview_timeline_strip`):

1. **Cài khung dọc & kiểm tra timeline**:
   - Gọi `get_project` xem resolution/tracks/clips; nếu cần Reels/TikTok `9:16`, gọi `set_sequence(width: 1080, height: 1920, fps: 30)`.
2. **A-roll Rough Cut chống ảo giác khoảng lặng (`P6`)**:
   - Gọi `transcribe_aroll(language: "vi", min_silence_sec: 0.7, pad_sec: 0.1)` để nhận `words` và `suggested_keep_ranges`.
   - Cắt khoảng lặng bằng `apply_edl_patch(keep_ranges, coord: "source", ripple: true)`.
3. **Phụ đề Karaoke Tiếng Việt từng từ (`CapCut` / `Karaoke Pill`)**:
   - Gọi `generate_vietnamese_captions(preset: "karaoke_pill", max_words: 4)` (hoặc `capcut_yellow` / `neon_box`) để tạo track phụ đề bám khít timestamp từng chữ tiếng Việt và render đồng nhất giữa preview & export (`P2`).
4. **Chèn B-Roll 3 Tầng & Cắt Nhịp Beat (`beat_sync_cuts`)**:
   - Tìm B-roll địa phương qua `search_broll(query: "<ngữ cảnh không dấu hoặc có dấu>")` -> Fallback `search_stock_media` -> Fallback `comfy_generate`.
   - Chèn muted lên `V2` qua `insert_broll_overlay(mute_audio: true)`. Nếu cắt loạt ảnh/B-roll theo nhạc, gọi `beat_sync_cuts(beats_per_cut: 2)`.
5. **Auto-Ducking Nhạc Nền Dưới Giọng Nói**:
   - Gọi `auto_duck_bgm(bgm_track: "A2", voice_track: "A1", duck_db: -14)` để tự động giảm âm nhạc nền mượt mà (ramp 50ms) mỗi khi có giọng nói.
6. **Kiểm tra trực quan (`I3`, `P2`)**:
   - Gọi `preview_timeline_strip(timestamps: [...])` kiểm tra khung hình & chữ phụ đề trước khi `commit_agent_turn`.
