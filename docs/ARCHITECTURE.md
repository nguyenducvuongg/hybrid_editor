# Hybrid Editor Architecture (`editroom/` Core)

## 1. Core Design Principles (`I1–I6`)
- **`I1` · Unified Command Bus & Transactional `AgentTurn`**: Both manual timeline actions and external/embedded MCP tools mutate `EditorModel` through `AgentTurn` (`beginAgentTurn` / `commitAgentTurn` / `rollbackAgentTurn`), coalescing $N$ agent edits into 1 unified Undo/Redo entry (`⌘Z`).
- **`I2` · Live-Attach & Recoverable Leases**: `LeaseManager` (`editroom/Editroom/MCP/SessionLease.swift`) persists single-writer leases at `0o600` (`5_000–10_000` ms grace, PID liveness check via `Darwin.kill(pid, 0)`) and rolls back uncommitted turns automatically if an MCP client crashes (`SIGKILL`).
- **`I3` · Single Renderer Parity**: `preview_timeline_strip` renders frames through `CompositionBuilder` + `TimelineCompositor` (`AVAssetImageGenerator`) without UI chrome, ensuring canvas/color parity (`P2`) with `Exporter`.
- **`I4` · Skill Separation & Caching**: Dev-workflow skills stay in `.agents/skills/`; runtime video-editing skills live cleanly in `assets/editor-skills/` and `HYBRID_EDIT_DATA_DIR/Skills/`.
- **`I5` · Data Isolation**: `HybridStorage` (`editroom/Editroom/Model/AppStorage.swift`) honors `HYBRID_EDIT_DATA_DIR`, enforces APFS UTF-8 safe cache stems (`<= 200` bytes), and performs atomic verified writes (`P7`).
- **`I6` · Off-Main-Actor Heavy Work**: `AVAssetReader` VAD/WAV decode, `whisper-cli`, `AVAssetImageGenerator`, VLM HTTP calls, ComfyUI WebSocket jobs, and SQLite3 FTS5 indexing run off `@MainActor`.

## 2. Hybrid MCP Surface (`editroom/Editroom/MCP/MCPTools+Hybrid.swift`)

| Category | Tools | Purpose |
| :--- | :--- | :--- |
| **Session & `AgentTurn`** | `session_attach`, `session_heartbeat`, `session_release`, `begin_agent_turn`, `commit_agent_turn`, `rollback_agent_turn` | Single-writer lease + transactional undo grouping |
| **Timeline & Vision** | `apply_edl_patch`, `preview_timeline_strip` | Batch A-roll/B-roll EDL cuts & visual contact sheet verification |
| **Extensibility** | `list_skills`, `list_plugins` | Expose installed `SKILL.md` workflows & trusted LUT/workflow/MCP plugins |
| **Generative & Stock** | `comfy_status`, `comfy_generate`, `search_stock_media`, `import_stock_media` | ComfyUI Colab (Cloudflare/Tailscale/SSH + I2V upload) & Pexels/Pixabay stock with `Sources.txt` |
| **Smart A-Roll & B-Roll** | `transcribe_aroll`, `index_broll_folder`, `search_broll`, `insert_broll_overlay` | `AudioVAD` (`P6` 10s silence guard) + `WhisperCPPProvider`, SQLite3 FTS5 + VLM/Apple Vision, 3-tier B-roll placement |

## 3. 3-Tier Smart B-Roll Fallback Ladder
1. **Tier 1 — Local Context Index (`search_broll`)**: Persistent SQLite3 FTS5 store (`BRollFTSIndex`, accented & unaccented Vietnamese `đ -> d`) indexed by `LocalVLMVisionProvider` or `AppleVisionFallbackProvider`.
2. **Tier 2 — Royalty-Free Stock (`search_stock_media` -> `import_stock_media`)**: Parallel search on Pexels & Pixabay with contact-sheet preview, media verification (`CGImageSource` / `AVURLAsset`), and `Sources.txt` attribution.
3. **Tier 3 — Remote Generative AI (`comfy_status` -> `comfy_generate`)**: Custom B-roll or I2V clips generated on Google Colab ComfyUI over secure Cloudflare/Tailscale/SSH tunnels (`TunnelManager`).
