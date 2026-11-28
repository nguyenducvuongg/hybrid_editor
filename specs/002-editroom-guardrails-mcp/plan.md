# Implementation Plan: Milestone 1-E — Editroom Guardrails & Hybrid MCP Control

**Branch**: `feat/editroom-core` | **Date**: 2026-11-28 | **Spec**: [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/002-editroom-guardrails-mcp/spec.md)

## Technical Context
- **Language/SDK**: Swift 5 mode on Swift 6.4.2 (`Xcode 27.2`, macOS `27.3` Apple Silicon M4 Pro)
- **Frameworks**: `Foundation`, `CryptoKit`, `AppKit`, `AVFoundation`, `CoreImage`, `Network`
- **Target**: `editroom/Editroom.xcodeproj` (`PBXFileSystemSynchronizedRootGroup` auto-includes new Swift files under `editroom/Editroom/`)
- **Verification**: `xcodebuild` Debug build + headless `Editroom --hybrid-test <outDir>` executing 7 deterministic empirical tests (`T1–T7`) + `graphify update .`

## Constitution Check
- **I1 (Single Command Bus & AgentTurn):** Enforced via `EditorModel.mutate`, `ActiveAgentTurn` + `MCPDraft`, and `undoTurns` parallel stack.
- **I2 (Live-Attach & Lease):** Enforced via `LeaseManager` (`0o600`, PID check, `5–10s` grace, auto-rollback on recovery) + `MCPServer` loopback guard.
- **I3 (Single Renderer Parity):** `preview_timeline_strip` renders strictly via `CompositionBuilder.build` + `AVAssetImageGenerator` (`TimelineCompositor`).
- **I4 & I5 (Derived Artifacts & Data Isolation):** `AppStorage` honors `HYBRID_EDIT_DATA_DIR`, defaults to `~/Library/Application Support/hybrid_edit_vid`, and caps prefix UTF-8 bytes at `<= 120` + SHA-256 (`P7`).
- **I6 (Off-Thread Execution):** `AppStorage` & `LeaseManager` are `nonisolated`; `preview_timeline_strip` decodes asynchronously off `@MainActor` blocking paths where `AVAssetImageGenerator` runs.
