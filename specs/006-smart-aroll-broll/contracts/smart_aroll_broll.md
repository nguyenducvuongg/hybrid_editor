# Contracts: Milestone 5-E — Smart A-Roll & Smart B-Roll MCP Tools + Storage

## 1. MCP Tool Schemas (`MCPTools+Hybrid.swift`)

### `transcribe_aroll` (readOnly)
- **Inputs**:
  - `asset_id` (`string`, optional): Project asset UUID string.
  - `clip_id` (`string`, optional): Timeline clip UUID string (resolved to its asset).
  - `path` (`string`, optional): Direct local media file path.
  - `language` (`string`, optional, default `"vi"`): ISO language code passed to Whisper (`vi`, `en`, ...).
  - `min_silence_sec` (`number`, optional, default `0.7`): Gap threshold before splitting `suggested_keep_ranges`.
  - `pad_sec` (`number`, optional, default `0.1`): Breathing padding added around kept speech spans.
  - `vad_threshold_db` (`number`, optional): Override RMS dBFS threshold (default `-42.0`).
- **Response JSON**:
  - `provider`: `"whisper.cpp"` | `"vad-only"` | `"apple-speech"`
  - `language`: string
  - `duration`: number (seconds)
  - `vad_peak_db`: number
  - `speech_spans`: `[{"start": Double, "end": Double}]`
  - `word_count`: integer
  - `text`: string (joined words)
  - `words`: `[{"start": Double, "end": Double, "text": String}]`
  - `suggested_keep_ranges`: `[{"start": Double, "end": Double}]`

### `index_broll_folder` (non-mutating timeline / index write)
- **Inputs**:
  - `folder_path` (`string`, required): Local directory of B-roll videos/images.
  - `sample_interval_sec` (`number`, optional, default `4.0`): Frame sampling step for video assets.
  - `vlm_base_url` (`string`, optional): Override OpenAI-compatible VLM endpoint.
  - `vlm_model` (`string`, optional): Override VLM model ID.
  - `use_apple_vision` (`boolean`, optional, default `false`): Skip HTTP VLM and run Apple Vision offline directly.
- **Response JSON**:
  - `folder_path`: string
  - `indexed_files`: integer
  - `indexed_segments`: integer
  - `total_segments`: integer
  - `provider`: string

### `search_broll` (readOnly)
- **Inputs**:
  - `query` (`string`, required): Vietnamese (accented or unaccented) or English search query.
  - `limit` (`integer`, optional, default `6`, clamped `1...25`).
- **Response JSON**:
  - `query`: string
  - `count`: integer
  - `hits`: `[{"asset_path", "asset_name", "start_sec", "end_sec", "description", "tags", "mood", "score"}]`
  - `fallback_tier`: integer (`1` when hits > 0, `2` when empty)
  - `fallback_hint`: string instructing Tier 2 (`search_stock_media` / `import_stock_media`) -> Tier 3 (`comfy_generate`).

### `insert_broll_overlay` (mutating, guarded by `LeaseManager`)
- **Inputs**:
  - `asset_path` (`string`, optional): Local path to import if `asset_id` not already in project.
  - `asset_id` (`string`, optional): Existing project asset UUID.
  - `timeline_start` (`number`, optional, default `0`): Timeline placement time in seconds.
  - `source_start` (`number`, optional, default `0`): Source in-point in seconds.
  - `duration` (`number`, optional): Overlay duration in seconds.
  - `mute_audio` (`boolean`, optional, default `true`): Mutes B-roll audio track / omits audio overlay.
  - `track` (`string`, optional): Target video track name (defaults to first free overlay track `V2`+ or adds one).
  - `session_id` (`string`, optional): Held session lease ID.
- **Response JSON**:
  - `inserted_clip_ids`: `[string]`
  - `asset_id`: string
  - `track`: string
  - `timeline_start`: number
  - `duration`: number
  - `mute_audio`: boolean
  - `revision`: integer

## 2. SQLite3 FTS5 Schema (`BRollIndex`)
Location: `HybridStorage.subdir("BRollIndex")/broll_fts5.sqlite`
```sql
CREATE VIRTUAL TABLE IF NOT EXISTS broll_segments USING fts5(
    asset_path UNINDEXED,
    asset_name,
    start_sec UNINDEXED,
    end_sec UNINDEXED,
    description,
    tags,
    mood,
    normalized_text,
    tokenize='unicode61 remove_diacritics 0'
);
```
`normalized_text` stores `normalizeVietnamese(...)` (`đ`/`Đ` -> `d` + `.diacriticInsensitive` + `.caseInsensitive`) so Vietnamese queries match both with and without accents cleanly.
