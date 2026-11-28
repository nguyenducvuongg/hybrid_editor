# Feature Specification: Milestone 5-E — Smart A-Roll Tiếng Việt & Smart B-Roll 3 Tầng

**Feature Branch**: `feat/editroom-core`
**Created**: 2026-11-28
**Status**: Active
**Constitution**: v2.0.0 (`I1–I6`, `P1–P7`)

## User Scenarios & Testing

### User Story 1 — Vietnamese A-Roll Transcription & Silence Rough-Cut (Priority: P1)
As a Vietnamese video creator, I want Editroom to transcribe my spoken A-roll accurately in Vietnamese using Whisper (`whisper.cpp` Metal) pre-gated by Voice Activity Detection (VAD), so the agent can cut dead air via `apply_edl_patch` inside a single `AgentTurn` (`I1`) without hallucinating fake captions during silent gaps (`P6`).

**Acceptance Scenarios**:
1. **Given** a 10.0s pure silent audio/video file, **When** `AudioVAD` and `WhisperCPPProvider` process it (even with a Whisper binary that attempts to hallucinate `"Cảm ơn các bạn đã xem video"` on silence), **Then** `AudioVAD` returns zero speech spans and `WhisperCPPProvider` returns 0 words (`P6`).
2. **Given** a Vietnamese A-roll clip containing speech bursts separated by >0.7s dead air, **When** `transcribe_aroll` runs, **Then** UTF-8 Vietnamese diacritics are preserved, hallucinated phrases inside silence intervals are filtered out, and `suggested_keep_ranges` are returned in `"source"` coordinates ready for `apply_edl_patch(keep_ranges)`.
3. **Given** `Transcripts.shared` runs off `@MainActor` (`I6`), **When** Whisper is configured and preferred (`SpeechPrefs`), **Then** `Transcripts` uses `WhisperCPPProvider` first and falls back cleanly to Apple `SpeechReader` if Whisper is unavailable.

### User Story 2 — Smart B-Roll Context Engine & 3-Tier Automatic Fallback (Priority: P1)
As a creator with local B-roll footage, stock accounts (Pexels/Pixabay), and optional ComfyUI Colab, I want my local B-roll folder visually indexed into a persistent SQLite3 FTS5 database (via local VLM or Apple Vision fallback), so the agent automatically resolves every B-roll need through the 3-tier ladder: **Local B-Roll -> Free Stock -> ComfyUI Colab**.

**Acceptance Scenarios**:
1. **Given** a local B-roll folder containing videos/images, **When** `index_broll_folder` executes off `@MainActor`, **Then** frames are analyzed by `LocalVLMVisionProvider` (or `AppleVisionFallbackProvider` if VLM is offline) and persisted to `HybridStorage.subdir("BRollIndex")/broll_fts5.sqlite` (`I5`).
2. **Given** an indexed SQLite3 FTS5 database with Vietnamese & English descriptions, **When** `search_broll` is queried with accented (`"cà phê đường phố"`) or unaccented (`"ca phe duong pho"`) Vietnamese or special punctuation, **Then** matching segments return ranked by `bm25()` with `fallback_tier = 1`, while empty results return `fallback_tier = 2` instructing the agent to fall back to `search_stock_media` / `comfy_generate`.
3. **Given** a chosen B-roll asset path or `asset_id`, **When** `insert_broll_overlay` executes inside an active `AgentTurn`, **Then** it imports the media cleanly (visible to `MCPDraft`), places it muted on `V2`+ (`mute_audio: true`), increments `revision`, and reverts cleanly in 1 Undo step.

### User Story 3 — Built-in Agent Skills & Settings Visibility (Priority: P2)
As a user, I want two ready-to-use skills (`aroll-rough-cut` and `smart-broll-inserter`) plus non-secret Whisper/VLM settings exposed cleanly under Settings > Integrations.

## Requirements
- **FR-001**: `TranscriptionProvider` protocol + `AudioVAD` (`AVAssetReader` 16kHz mono float32 PCM energy/duration VAD) + `WhisperCPPProvider` (`whisper-cli` `-ojf` UTF-8 JSON parser + VAD overlap & hallucination filter).
- **FR-002**: Zero Whisper hallucinations on 10 seconds of pure silence (`P6`).
- **FR-003**: Persistent SQLite3 FTS5 store (`BRollFTSIndex`) with diacritic-preserving + Vietnamese ASCII-folded (`đ -> d`) dual-match indexing and query sanitization.
- **FR-004**: `VisualIndexProvider` (`LocalVLMVisionProvider` via OpenAI-compatible `/v1/chat/completions` vision API + `AppleVisionFallbackProvider` via `VNClassifyImageRequest`).
- **FR-005**: Four Hybrid MCP tools: `transcribe_aroll`, `index_broll_folder`, `search_broll`, and `insert_broll_overlay`.
- **FR-006**: Offline deterministic test suite `--smart-editing-test` (`S1–S6`).
