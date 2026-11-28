# Tasks: Milestone 4-E (`005-comfyui-stock-providers`)

- [x] **M001** Create Spec Kit `specs/005-comfyui-stock-providers/` (`spec.md`, `plan.md`, `contracts/media_providers.md`, `tasks.md`)
- [x] **M002** Create `assets/colab/editroom_comfyui_colab.ipynb` and built-in skills (`comfy-broll-generator`, `stock-media-finder`)
- [x] **M003** Implement `editroom/Editroom/Providers/ComfyUI/TunnelManager.swift` (SSH/Tailscale/Cloudflare + clean shutdown)
- [x] **M004** Implement `editroom/Editroom/Providers/ComfyUI/ComfyUIClient.swift` (status, `/upload/image`, placeholder templates, WS+history polling, atomic verified download)
- [x] **M005** Implement `editroom/Editroom/Providers/Stock/StockMediaClient.swift` (`PexelsProvider`, `PixabayProvider`, contact sheet, download verify + `Sources.txt`)
- [x] **M006** Wire live Stock search & 1-click Import in `StockLibraryView.swift`
- [x] **M007** Add `comfy_status`, `comfy_generate`, `search_stock_media`, `import_stock_media` to `MCPTools+Hybrid.swift` and wire `TunnelManager.stop()` + `MediaProvidersTest` in `EditroomApp.swift`
- [x] **M008** Create `editroom/Editroom/App/MediaProvidersTest.swift` (`M1–M6`) and pass build + `--media-providers-test` + `--extensions-test` + `--hybrid-test`
- [x] **M009** Update `PROJECT.md`, refresh `graphify update .`, and commit locally on `feat/editroom-core`
