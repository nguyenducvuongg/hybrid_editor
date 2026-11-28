# Tasks — Phase C (`v1.3`): ComfyUI Studio & Smart Auto-Reframe (`010-v13-reframe-comfy-studio`)

**Status:** ✅ Complete & Verified (`48/48` checks across all 7 suites on Apple M4 Pro)

## Checklist

- [x] **S1.1 Dynamic Auto-Reframe Engine (`AutoReframeEngine.swift`):** Implemented `ReframeKeyframe`, smoothstep-interpolated `ReframePath` (`center(at:)` & Core Image Y-flipped `offset(at:canvas:output:)`), Apple Vision `VNDetectFaceRectanglesRequest` (`detectFaceCenter`), bidirectional EMA + deadband smoothing (`smooth`), and async timeline analyzer (`analyze(project:media:sampleIntervalSec:detector:)`).
- [x] **S1.2 Unified Preview & Export Compositor (`TimelineCompositor.swift`, `CompositionBuilder.swift`, `Exporter.swift`):** Added `reframePath` to `TimelineInstruction` and dynamic per-frame crop offset evaluation (`I3`, `P2`), plus `ExportSettings.autoReframe` async pre-analysis inside `Exporter.start`.
- [x] **S1.3 `ExportSheet` Auto-Reframe Toggle (`ExportSheet.swift`):** Added **Auto-Reframe (Face Tracking)** switch whenever cropping `16:9` sequences to `9:16`, `1:1`, or `4:5`.
- [x] **S1.4 Reframe MCP Support (`MCPTools.swift`, `MCPTools+Hybrid.swift`):** Added `analyze_reframe` (with optional cropped JPEG contact-sheet preview) and `auto_reframe` parameter on `export`.
- [x] **S2.1 ComfyUI Workflow Gallery & Realtime WebSocket Progress (`ComfyUIClient.swift`, `assets/comfy-workflows/*.json`):** Added 4 curated presets (`flux_schnell`, `flux_dev`, `wan21_i2v`, `stable_audio_sfx`) in Swift & JSON files on disk, `steps` placeholder binding, `ComfyUIClient.parseWebSocketEvent`, and `@MainActor ComfyProgressMonitor.shared`.
- [x] **S2.2 Studio UI (`AgentChatPanel.swift`, `ExtensionsSettingsView.swift`):** Added live WebSocket denoising progress bar in `AgentChatPanel` and **ComfyUI Workflow Gallery** cards with **Save JSON** export in `Settings > Integrations`.
- [x] **S3 Verification (`StudioV13Test.swift` `--studio-v13-test`):** Verified `5/5` (`R1–R5`) plus all `6` existing suites (`48/48` total) on Debug binary after final edit.
