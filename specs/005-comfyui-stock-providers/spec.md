# Feature Specification: Milestone 4-E — ComfyUI Colab Tunnel & Free Stock Media Providers

**Feature Branch**: `feat/editroom-core`  
**Spec Directory**: `specs/005-comfyui-stock-providers`  
**Created**: 2026-11-28  
**Status**: Approved for Implementation  

**Input**: Enable Editroom's agent chat and external MCP clients to generate images, videos, and audio via remote ComfyUI running on Google Colab (over Cloudflare Tunnel, Tailscale, or SSH Tunnel) including Image-to-Video reference uploads from timeline frames, and to search/preview/import free stock media from Pexels and Pixabay APIs inside transactional `AgentTurn`s (`I1–I6`, `P7`).

---

## User Scenarios & Testing

### User Story 1 - Safe ComfyUI Colab Tunnels (`TunnelManager`)
Users configure `.cloudflare`, `.tailscale`, or `.ssh` in Settings > Integrations. SSH tunnel commands reject shell injection (`;`, `|`, `&`, `$`, `` ` ``), spawn cleanly off `@MainActor`, and tear down cleanly when Editroom exits (`applicationWillTerminate`).

### User Story 2 - Remote Image/Video/Audio Generation & I2V (`ComfyUIClient`)
Agents inspect Colab GPU/VRAM & workflow availability (`comfy_status`), optionally capture a frame from a timeline clip as PNG and upload it via `POST /upload/image`, run template substitution cleanly (`{{prompt}}`, `{{seed}}`, `{{width}}`, `{{height}}`, `{{frames}}`, `{{input_image}}`), monitor WebSocket + history completion without locking the timeline, save generated media atomically (`HybridStorage.writeAtomicVerified`) with `Sources.txt` provenance, and auto-import returning `asset_id`.

### User Story 3 - Free Stock Search & Import (`Pexels`, `Pixabay`, `StockLibraryView`)
Agents (`search_stock_media` / `import_stock_media`) and editors (in `LibraryView > Stock`) search Pexels & Pixabay via Keychain API keys, preview candidate thumbnails via a JPEG contact sheet, download/verify valid media files, record attribution/licence in `Sources.txt`, and import directly into `EditorModel` with 1-step Undo.

### Verification
- `--media-providers-test` (`M1–M6`) passes 6/6 offline using real loopback `NWListener` mock servers and child processes.
- `--extensions-test` (`7/7`) and `--hybrid-test` (`7/7`) pass without regression.
