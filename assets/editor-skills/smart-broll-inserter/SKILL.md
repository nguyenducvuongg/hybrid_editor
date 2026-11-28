---
name: smart-broll-inserter
description: Chèn B-roll thông minh theo thác 3 tầng tự động (Local B-Roll FTS5 -> Free Stock Pexels/Pixabay -> ComfyUI Colab) vào V2+ trong 1 AgentTurn.
version: 1.0.0
tags:
  - broll
  - fts5
  - stock
  - comfyui
  - 3-tier
---

# Smart B-Roll Inserter (Thác Tự Động 3 Tầng)

Dùng skill này khi cần tìm và chèn B-roll minh họa đúng ngữ cảnh cho câu nói A-roll hoặc đoạn kịch bản.

## Thác 3 tầng bắt buộc (Fallback Ladder)

### Tầng 1 — Local B-Roll Context Engine (`search_broll`)
1. Gọi `search_broll(query: "<từ khóa ngữ cảnh tiếng Việt hoặc tiếng Anh>", limit: 6)`.
2. Nếu local index chưa có dữ liệu và người dùng cung cấp thư mục B-roll, chạy `index_broll_folder(folder_path: ...)` trước rồi `search_broll` lại.
3. Nếu tìm thấy hit phù hợp (`fallback_tier == 1` và mô tả khớp cảnh), dùng trực tiếp `asset_path` ở Tầng 1.

### Tầng 2 — Free Stock Media (`search_stock_media` -> `import_stock_media`)
1. Chỉ chuyển xuống Tầng 2 khi Tầng 1 trả về `fallback_tier == 2` (hoặc không có cảnh khớp).
2. Gọi `search_stock_media(query: "<English concise keywords>", kind: "videos", include_thumbnails: true)`.
3. Chọn `stock_id` đẹp nhất từ contact sheet và gọi `import_stock_media(stock_id: ...)`.

### Tầng 3 — Generative AI trên ComfyUI Colab (`comfy_status` -> `comfy_generate`)
1. Chỉ dùng Tầng 3 khi Tầng 1 & Tầng 2 không có cảnh đạt yêu cầu hoặc người dùng yêu cầu cảnh đặc biệt/stylized.
2. Kiểm tra `comfy_status` -> gọi `comfy_generate(kind: "video" | "image", prompt: "...")` (có thể truyền `reference_clip_id` cho I2V).

## Chèn lên Timeline (`I1`, `P2`)
1. Mở giao dịch: `begin_agent_turn(turn_id: ..., summary: "Insert B-roll overlays")`.
2. Gọi `insert_broll_overlay(asset_path: ... | asset_id: ..., timeline_start: ..., duration: ..., mute_audio: true)` để đặt B-roll lên track `V2`+ không át giọng A-roll.
3. Gọi `preview_timeline_strip` kiểm tra khung hình overlay trước khi gọi `commit_agent_turn`.
