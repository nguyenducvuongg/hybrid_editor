# Tasks: Phase A (`v1.1`) — Core Audit Fixes (`P0–P2`)

- [x] **T001** Create `specs/008-v11-core-audit-fixes/tasks.md`.
- [x] **T002 (`P0-1`)** Allow `import_media` inside active `AgentTurn` (`draft?.addAsset`) and filter `hybridLifecycleTools` from `ChatSessionStore.inAppTools`.
- [x] **T003 (`P0-2`)** Forward tool JPEG images cleanly via `inlineData` (Gemini) and `image_url` data URI follow-up messages (OpenAI-compatible) in `AgentProvider.swift`.
- [x] **T004 (`P0-3`)** Add `GeminiHTTPProvider.sanitizeGeminiSchema` before sending tool declarations to `:generateContent`.
- [x] **T005 (`P1-1`)** Add turn `Cancel/Stop` (`cancelActiveTurn`), live `streamingText`, and `SecretRedactor` scrubbing across `ChatSessionStore` & `AgentChatPanel`.
- [x] **T006 (`P1-2`)** Auto-bind `ComfyUIClient` built-in checkpoint from `/object_info/CheckpointLoaderSimple`.
- [x] **T007 (`P1-3`)** Replace raw JSON error string interpolation with `AgentToolFormatting.jsonError` and include recent thread history + `MCPServer.endpoint` in `CLIProcessAgentProvider`.
- [x] **T008 (`P1-4`, `P1-5`)** Remove unsafe `as!` cast in `StockMediaClient.swift`; add `AsyncImage` thumbnails & 1-click `Add V2` in `StockLibraryView.swift`.
- [x] **T009 (`P2-1`, `P2-2`)** Auto-seed 4 built-in skills in `SkillRegistry` + `"Restore Built-in"` button + startup seeding; clean up Swift 6 concurrency warnings in `ChatSessionStore.swift`, `Meters.swift`, `MediaProvidersTest.swift`, and `SmartEditingTest.swift`.
- [x] **T010** Add `V1–V5` regression checks in `Hardening4KBenchmarkTest.swift`, build, verify all 5 suites (`37/37`), update `PROJECT.md`, run `graphify update .`, and commit locally.
