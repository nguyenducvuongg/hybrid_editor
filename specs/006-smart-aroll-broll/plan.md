# Implementation Plan: Milestone 5-E — Smart A-Roll Tiếng Việt & Smart B-Roll 3 Tầng

**Branch**: `feat/editroom-core` | **Spec**: [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/006-smart-aroll-broll/spec.md)

## Technical Context
- **Host Language / Frameworks**: Swift 6 / macOS (`AVFoundation`, `Vision`, `SQLite3`, `AppKit`, `SwiftUI`), compiled cleanly under `editroom/Editroom.xcodeproj` (`PBXFileSystemSynchronizedRootGroup`).
- **Persistence (`I5`, `P7`)**: All runtime data stays under `HybridStorage.subdir("BRollIndex")` (`broll_fts5.sqlite`) and `HybridStorage.subdir("Transcripts")`, plus `UserDefaults` for non-secret `SpeechPrefs` & `VLMIndexPrefs`.
- **Main-Thread Protection (`I6`)**: `AVAssetReader` PCM decoding, WAV export, `whisper-cli` execution, `AVAssetImageGenerator`, HTTP calls to local VLM, and SQLite indexing execute off `@MainActor`.

## Architecture Overview

```
editroom/Editroom/
├── Providers/
│   ├── Speech/
│   │   └── WhisperProvider.swift      # AudioVAD (16kHz PCM), WhisperCPPProvider, hallucination filter
│   └── BRoll/
│       ├── BRollIndex.swift           # SQLite3 FTS5 + Vietnamese diacritic normalization + bm25 search
│       └── VisualIndexProvider.swift  # LocalVLMVisionProvider, AppleVisionFallbackProvider, BRollIndexer
├── Engine/
│   └── Transcripts.swift              # Prefer WhisperCPPProvider when configured, fallback to Apple SpeechReader
├── Extensions/
│   └── IntegrationPrefs.swift         # SpeechPrefs + VLMIndexPrefs
├── MCP/
│   └── MCPTools+Hybrid.swift          # transcribe_aroll, index_broll_folder, search_broll, insert_broll_overlay
├── UI/
│   └── ExtensionsSettingsView.swift   # Whisper Metal & Local VLM settings card
└── App/
    ├── EditroomApp.swift              # Hook SmartEditingTest.runIfRequested()
    └── SmartEditingTest.swift         # Offline deterministic S1–S6 suite (--smart-editing-test)

assets/editor-skills/
├── aroll-rough-cut/SKILL.md           # A-roll Vietnamese rough-cut workflow
└── smart-broll-inserter/SKILL.md      # 3-tier B-roll automatic fallback workflow
```

## Verification Plan
1. `xcodebuild` Debug build with `CODE_SIGN_IDENTITY=-`.
2. `--smart-editing-test` (`S1–S6` passing inside isolated `HYBRID_EDIT_DATA_DIR`).
3. Zero regressions across `--media-providers-test` (`6/6`), `--extensions-test` (`7/7`), and `--hybrid-test` (`7/7`).
