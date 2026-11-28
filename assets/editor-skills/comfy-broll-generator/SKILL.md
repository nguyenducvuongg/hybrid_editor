---
name: comfy-broll-generator
description: Generate custom B-roll images, videos (including Image-to-Video from timeline frames), or audio on a remote Google Colab ComfyUI server and insert them onto the timeline.
---

# ComfyUI B-Roll & Asset Generator

1. Call `comfy_status` first to verify Colab GPU connectivity, VRAM, and available workflow names or checkpoints.
2. Choose `kind` (`"image"`, `"video"`, or `"audio"`). When matching motion/continuity from the current cut, pass `reference_clip_id` and `reference_time` so Editroom captures the exact timeline frame and uploads it via `/upload/image` for Image-to-Video.
3. Call `comfy_generate` with descriptive visual prompts (`width`/`height` matching `get_project` sequence dimensions).
4. Insert the returned `asset_id` cleanly onto an overlay track (`V2`+ or `A2`+) with `apply_edl_patch` (`insert_overlay`) inside the active `AgentTurn`, then inspect visually via `preview_timeline_strip`.
