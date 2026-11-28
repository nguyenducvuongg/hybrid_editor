# Implementation Plan: Milestone 4-E — ComfyUI Colab Tunnel & Stock APIs

**Branch**: `feat/editroom-core` | **Date**: 2026-11-28 | **Spec**: [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/005-comfyui-stock-providers/spec.md)

## Technical Context
- **Modules**: `editroom/Editroom/Providers/ComfyUI/{TunnelManager.swift, ComfyUIClient.swift}`, `editroom/Editroom/Providers/Stock/StockMediaClient.swift`
- **Assets**: `assets/colab/editroom_comfyui_colab.ipynb`, `assets/editor-skills/{comfy-broll-generator,stock-media-finder}/SKILL.md`
- **MCP**: 4 new tools in `MCPTools+Hybrid.swift` (`comfy_status`, `comfy_generate`, `search_stock_media`, `import_stock_media`)
- **UI**: `StockLibraryView.swift` connected to `StockMediaManager.shared`
- **Verification**: `xcodebuild` Debug + `--media-providers-test` (`M1–M6`) + `--extensions-test` (`E1–E7`) + `--hybrid-test` (`T1–T7`)
