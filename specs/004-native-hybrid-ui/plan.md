# Implementation Plan: Milestone 3-E — Native Hybrid UI

**Branch**: `feat/editroom-core` | **Date**: 2026-11-28 | **Spec**: [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/004-native-hybrid-ui/spec.md)

## Technical Context
- **Frameworks**: `SwiftUI`, `AppKit`, `Foundation`
- **Persistence**: `UserDefaults` for panel layout & non-secret preferences (`PanelLayout.showAgentChat`, `ComfyConnectionPrefs`, `ChatProviderPrefs`); `AppSecrets.shared` (`KeychainStore`/`FileSecretStore`) strictly for credentials/tokens.
- **Verification**: `xcodebuild` Debug + `Editroom --extensions-test` (`E1–E7`) + `Editroom --hybrid-test` (`T1–T7`).
