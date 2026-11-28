# Tasks: Milestone 5-E — Smart A-Roll Tiếng Việt & Smart B-Roll 3 Tầng

## Phase 1: Specs & Built-in Editor Skills
- [x] **T001** Create `specs/006-smart-aroll-broll/{spec.md, plan.md, contracts/smart_aroll_broll.md, tasks.md}`.
- [x] **T002** Author `assets/editor-skills/aroll-rough-cut/SKILL.md` and `assets/editor-skills/smart-broll-inserter/SKILL.md`.

## Phase 2: Smart A-Roll Vietnamese & VAD Guard (`I4`, `I6`, `P6`)
- [x] **T003** Add `SpeechPrefs` and `VLMIndexPrefs` to `editroom/Editroom/Extensions/IntegrationPrefs.swift`.
- [x] **T004** Implement `AudioVAD`, `TranscriptionProvider`, `WhisperCPPProvider`, hallucination filtering, and keep-range suggestion in `editroom/Editroom/Providers/Speech/WhisperProvider.swift`.
- [x] **T005** Integrate `WhisperCPPProvider` into `editroom/Editroom/Engine/Transcripts.swift` with graceful fallback to Apple Speech.

## Phase 3: Smart B-Roll Context Engine (SQLite3 FTS5 + VLM/Vision)
- [x] **T006** Implement `BRollFTSIndex` (`libsqlite3` FTS5 + Vietnamese diacritic normalization + query escaping + `bm25` ranking) in `editroom/Editroom/Providers/BRoll/BRollIndex.swift`.
- [x] **T007** Implement `VisualIndexProvider`, `LocalVLMVisionProvider`, `AppleVisionFallbackProvider`, and `BRollIndexer` in `editroom/Editroom/Providers/BRoll/VisualIndexProvider.swift`.

## Phase 4: MCP Tools & Settings UI
- [x] **T008** Add `transcribe_aroll`, `index_broll_folder`, `search_broll`, and `insert_broll_overlay` to `editroom/Editroom/MCP/MCPTools+Hybrid.swift`.
- [x] **T009** Add Speech (Whisper Metal) & Local VLM settings section to `editroom/Editroom/UI/ExtensionsSettingsView.swift`.
- [x] **T010** Register `SmartEditingTest.runIfRequested()` in `editroom/Editroom/App/EditroomApp.swift`.

## Phase 5: Verification, Docs & Commit
- [x] **T011** Implement `--smart-editing-test` (`S1–S6`) in `editroom/Editroom/App/SmartEditingTest.swift`.
- [x] **T012** Build Debug, run `--smart-editing-test`, `--media-providers-test`, `--extensions-test`, `--hybrid-test`, update `PROJECT.md`, run `graphify update .`, and commit locally.
