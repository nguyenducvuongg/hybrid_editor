# Tasks — Phase B (`v1.2`): Vietnamese Creator Suite (`009-v12-vietnamese-creator-suite`)

**Status:** ✅ Complete & Verified (`43/43` checks across all 6 suites on Apple M4 Pro)

## Checklist

- [x] **F1.1 Caption Presets & Word-Chunking Model (`Captions.swift`):** Added `CaptionPreset` (`classic`, `capcut_yellow`, `karaoke_pill`, `neon_box`, `minimal_clean`), backwards-compatible `CaptionStyle` `Codable` properties (`pillHighlight`, `pillColor`, `uppercase`, `maxWordsPerLine`, `activeScale`), and `maxWordsPerLine`-aware `CaptionLayout.phrases`.
- [x] **F1.2 Karaoke Pill & Active Word Pop Renderer (`CaptionRenderer.swift`):** Extended unified `CaptionRenderer.draw` with `NSLayoutManager` glyph-rect rounded pill backdrop, `activeScale` pop font (`1.0...1.25`), `vi_VN` uppercase, and Vietnamese stacked-diacritic padding shared identically by viewer preview (`CompositionBuilder`) & export (`Exporter`, `P2`).
- [x] **F1.3 Transcript Cache & Locale Preservation (`Transcripts.swift`):** Added `storeTranscript(_:for:)` and preserved `vi` / `SpeechPrefs.whisperLanguage` transcripts across macOS UI locales.
- [x] **F1.4 Inspector Caption Style Controls (`InspectorView.swift`):** Added Preset picker menu, **Word pop** slider (`100–125%`), **Word pill** color/toggle row, **Uppercase** toggle, and **Words / line** (`Auto, 2–6`).
- [x] **F1.5 `generate_vietnamese_captions` MCP Tool (`MCPTools+Hybrid.swift`):** Added transactional `AgentTurn` caption generation supporting presets, `words` timing injection, AudioVAD + Whisper/Apple fallback, and `1-step Undo`.
- [x] **F2.1 On-Demand Waveform Loading & Menu Action (`MediaStore.swift`, `EditorModel.swift`, `EditroomApp.swift`):** Added `ensureWaveform(for:)`, `ensureWaveforms(for:trackID:)`, `EditorModel.autoDuckBGM(duckDB:)`, and menu item `Clip > Auto-Duck BGM Under Speech`.
- [x] **F2.2 `auto_duck_bgm` MCP Tool (`MCPTools+Hybrid.swift`, `MCPTools.swift`):** Ducks music track under dialogue track (`duckUnder` / `duckDB` with smooth 50ms linear ramps in `CompositionBuilder`) and exposes `duck_under`/`duck_db` in `get_project`.
- [x] **F2.3 Beat-Sync Engine & `beat_sync_cuts` MCP Tool (`BeatSyncEngine.swift`, `MCPTools+Hybrid.swift`):** Reuses `MediaAnalyzer.music` beat grid (or explicit BPM) to snap visual cut starts and durations onto musical beats atomically inside `AgentTurn`.
- [x] **F3.1 B-Roll Browser & 3-Tab Library (`BRollIndex.swift`, `BRollBrowserView.swift`, `LibraryView.swift`):** Added `listRecent(limit:)` & `stats()` on `BRollFTSIndex`, async off-main keyframe thumbnail cache `BRollThumbnailLoader`, folder indexing + live accented/unaccented Vietnamese FTS5 search + 1-click **Add V2** card in `LibraryView` (`Media | B-Roll | Stock`).
- [x] **F4 Built-in Workflow Skill (`assets/editor-skills/vietnamese-shorts-creator/SKILL.md`, `SkillRegistry.swift`):** Added `vietnamese-shorts-creator` as the 5th auto-seeded built-in skill (`Hardening4KBenchmarkTest` `V5` updated accordingly).
- [x] **F5 Verification Suite (`CreatorFeaturesTest.swift` `--creator-v12-test`):** All `6/6` checks (`C1–C6`) + all `5` existing suites (`37/37`) passed (`43/43` total) on Debug binary after final edit.
