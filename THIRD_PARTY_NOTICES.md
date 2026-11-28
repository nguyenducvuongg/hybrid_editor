# Third-Party Notices & Attributions

This repository (`hybrid_edit_vid`) builds on the native macOS Swift/AVFoundation/Metal core of **Editroom** and integrates open-source libraries, CLI tools, and optional remote services listed below.

## Core & Libraries

| Component | Source / Version | License | Notes |
| :--- | :--- | :--- | :--- |
| **Editroom** | [`robbietilton/Editroom`](https://github.com/robbietilton/Editroom) (`490a7aa`) | **MIT** | Native macOS timeline engine, Metal compositor, SwiftUI interface (`editroom/LICENSE`) |
| **Sparkle** | [`sparkle-project/Sparkle`](https://github.com/sparkle-project/Sparkle) (`2.10.1`, SPM) | **MIT** | macOS application update framework |
| **FFmpeg** (bundled sidecar) | `editroom/Vendor/ffmpeg/` (`9.1`) | **LGPL-2.1+** | Separate child process binary (`editroom/Vendor/ffmpeg/README.md`) |
| **SQLite3** | Apple macOS System Library (`libsqlite3`) | **Public Domain** | Persistent FTS5 B-roll context index (`BRollFTSIndex`) |

## Optional Runtime Tools & Integrations

- **`whisper.cpp` (`whisper-cli`)**: MIT License — optional local Metal-accelerated ASR invoked as an external process by `WhisperCPPProvider`.
- **Ollama / LM Studio**: Optional OpenAI-compatible local endpoints for Agent Chat and VLM B-roll visual indexing.
- **ComfyUI (Google Colab)**: Optional remote image/video/audio generation over Cloudflare / Tailscale / SSH tunnel (`assets/colab/editroom_comfyui_colab.ipynb`).
- **Pexels & Pixabay APIs**: Optional free stock media search & import; per-asset licensing attribution is logged automatically to `Sources.txt`.

## Archived Prototype

- **Concat (`jub0t/Concat`, `v0.2.12`)**: Archived intact on branch `archive/concat-m1` and tag `concat-m1-archive` under its upstream **AGPL-3.0-or-later** license.
