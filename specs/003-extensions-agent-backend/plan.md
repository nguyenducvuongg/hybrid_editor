# Implementation Plan: Milestone 2-E — Secrets, GitHub Skills, 3-Tier Plugins & Agent Chat Backend

**Branch**: `feat/editroom-core` | **Date**: 2026-11-28 | **Spec**: [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/003-extensions-agent-backend/spec.md)

## Technical Context
- **Language/SDK**: Swift 5 mode on Swift 6.4.2 (`Xcode 27.2`, macOS `27.3`, Apple Silicon M4 Pro)
- **Frameworks**: `Foundation`, `Security`, `Network`, `AppKit`
- **Target**: `editroom/Editroom.xcodeproj` (`PBXFileSystemSynchronizedRootGroup`)
- **Naming Rule**: Use `HybridStorage` (`AppStorage.swift`) everywhere; never introduce a top-level `AppStorage` type (shadows SwiftUI `@AppStorage`).
- **Verification**:
  - `xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug -derivedDataPath /tmp/hybrid_edit_editroom_dd build`
  - `HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_m2e_data .../Editroom --extensions-test /tmp/hybrid_edit_m2e_out` (`E1–E6` PASS)
  - Regression check: `Editroom --hybrid-test /tmp/hybrid_edit_m1e_out` (`T1–T7` PASS)

## Constitution & Architecture Check
- **I1 (Single Command Bus & AgentTurn):** `ChatSessionStore.send` wraps every chat turn in `beginAgentTurn` -> `commitAgentTurn` / `rollbackAgentTurn`; failures roll back atomically without advancing `revision`.
- **I2 (Single-Writer Lease):** `ChatSessionStore.send` acquires `SessionLease` on `model.leaseManager` (`"in-app-chat"`) and releases in `defer`.
- **I4 & I5 (Isolation & Safe Storage):** Secrets in Keychain (or `0o600` `secrets.json` inside `HYBRID_EDIT_DATA_DIR` during tests), Skills under `HybridStorage.subdir("Skills")`, Plugins under `HybridStorage.subdir("Plugins")`, Chats under `HybridStorage.subdir("Chats")`.
- **I6 (Off-MainThread Execution):** Git clone subprocesses (`GitRunner`), stdio MCP child processes (`StdioMCPProcess`), and HTTP/CLI AI provider loops (`AgentProvider`) execute off `@MainActor`.
