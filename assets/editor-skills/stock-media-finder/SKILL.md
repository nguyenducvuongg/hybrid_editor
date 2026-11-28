---
name: stock-media-finder
description: Search Pexels and Pixabay for free B-roll photos and HD/4K videos matching timeline pacing, visually inspect candidates, and import chosen assets with attribution.
---

# Free Stock Media Finder (Pexels / Pixabay)

1. Inspect `get_project` first to determine the sequence aspect ratio (`landscape` vs `portrait` vs `square`) and gap duration to fill.
2. Call `search_stock_media` with targeted visual keywords, matching `orientation`, and `include_thumbnails: true` so you can visually verify framing before downloading full-resolution files.
3. Call `import_stock_media` with the chosen `stock_id`. Editroom downloads, verifies playable streams/images, logs attribution into `Sources.txt`, and returns `asset_id`.
4. Place the asset on `V2`+ using `apply_edl_patch` (`insert_overlay`, `mute_audio: true`) inside the active `AgentTurn`, then check via `preview_timeline_strip`.
