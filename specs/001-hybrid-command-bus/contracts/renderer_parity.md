# Contract: Single Renderer Parity & External Data Directory (`contracts/renderer_parity.md`)

**Status:** Locked for Milestone 1 (`I3`, `I5`, `P2`)

## 1. Canvas & Alpha Parity (`I3`, `P2`)
- **UI Chrome Isolation:** Checkerboard transparency indicators, clip selection borders, `agent_modified` outlines, playhead hairlines, and snap guides belong strictly to Slint (`src/crates/concat/ui/`).
- **Shared Core Render Graph:**
  - `concat_host::preview::Monitor` and `concat_host::export::request_for` / `concat_export::render_on` both consume `concat_export::flatten::flatten_timeline_in(...)` and `VideoSettings::canvas`.
  - For non-alpha exports (`.mp4` H.264/HEVC) and standard RGB preview verification, uncovered canvas pixels MUST composite over opaque black `[0, 0, 0, 255]` (via `concat_export::over_black` / `canvas`), and transparent PNG overlays MUST alpha-blend over that solid background with zero uninitialized/garbage pixels or checkerboard artifacts.
- **No Preview-Only Mutations:** Any preview-only audition/brush tint (`Studio::preview_clips` `own` list) MUST never be passed to `concat_host::export` or `concat_host::preview` core frame extraction (`Monitor::frame_image` / `preview_timeline_strip` in M2).

## 2. External Data Directory (`I5`)
- `concat_host::dirs::AppDirs::locate()` resolution order:
  1. If `HYBRID_EDIT_DATA_DIR` is set and non-empty (trimmed), return `AppDirs::under(Path::new(&val))` (must be absolute or resolved safely; never inside repo source during tests).
  2. Else if `portable_root()` exists beside binary, return `AppDirs::under(&portable)`.
  3. Else on `macos`, default `config` and `data` to `~/Library/Application Support/hybrid_edit_vid`.
- All leases, caches, projects created by default roots, and future SQLite/models MUST resolve through `AppDirs` (`I5`).
