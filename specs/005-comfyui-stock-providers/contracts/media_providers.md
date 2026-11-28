# Contract: ComfyUI Colab Tunnel & Free Stock Media Providers

**Status:** Locked for Milestone 4-E

## 1. `TunnelManager` (`editroom/Editroom/Providers/ComfyUI/TunnelManager.swift`)
- Supports `.cloudflare`, `.tailscale`, and `.ssh`.
- `parseSafeSSHArguments(_:)`: rejects shell metacharacters, supports `ssh` (`/usr/bin/ssh`) and `cloudflared`.
- `stop()` terminates managed child process (`SIGTERM` + `300ms` wait + `SIGKILL` fallback), wired into `AppDelegate.applicationWillTerminate`.

## 2. `ComfyUIClient` (`editroom/Editroom/Providers/ComfyUI/ComfyUIClient.swift`)
- Auth headers read from `AppSecrets.shared` (`comfyAuthToken`, `comfyCFClientId`, `comfyCFClientSecret`).
- Supports `ComfyMediaKind` (`.image`, `.video`, `.audio`), built-in default workflow templates, `HybridStorage.subdir("ComfyWorkflows")`, and `PluginHost.shared.activeComfyWorkflowPaths()`.
- `generate(...)`: optional `uploadImage` I2V -> `POST /prompt` -> concurrent WebSocket (`/ws?clientId=`) + `GET /history/<id>` polling -> `GET /view` -> `HybridStorage.writeAtomicVerified` -> `Sources.txt` provenance.

## 3. `StockMediaClient` (`editroom/Editroom/Providers/Stock/StockMediaClient.swift`)
- Providers: `PexelsProvider` (`/v1/search`, `/videos/search`) & `PixabayProvider` (`/api/`, `/api/videos/`), injectable `baseURL` for testing.
- `StockMediaManager`: searches enabled providers concurrently, renders numbered JPEG contact sheets, verifies downloaded assets (`CGImageSource` / `AVURLAsset`), writes `Sources.txt` attribution.

## 4. MCP Tools (`editroom/Editroom/MCP/MCPTools+Hybrid.swift`)
- `comfy_status` (readOnly)
- `comfy_generate` (mutating; supports `reference_clip_id` + `reference_time` I2V frame capture)
- `search_stock_media` (readOnly; supports `include_thumbnails: true`)
- `import_stock_media` (mutating; imports verified file into `EditorModel`)
