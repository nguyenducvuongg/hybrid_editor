<h1 align="center">Hybrid Editor (<code>hybrid_edit_vid</code>)</h1>

<p align="center">
  <strong>AI-Native macOS Video Editor built on Editroom (Swift · SwiftUI · AVFoundation · Metal · MCP)</strong><br />
  <sub>Transitional AI Agent Editing + Vietnamese Smart A-Roll + 3-Tier B-Roll Engine (Local FTS5 · Pexels/Pixabay · ComfyUI Colab)</sub>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-0568FD?style=flat" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/Platform-macOS%20Apple%20Silicon%20(M4%20Pro)-212123?style=flat" alt="Platform: macOS Apple Silicon" />
  <img src="https://img.shields.io/badge/Stack-Swift%20%2B%20Metal%20%2B%20SQLite%20FTS5%20%2B%20MCP-18181b?style=flat" alt="Stack" />
</p>

<p align="center">
  <a href="#overview"><strong>🇬🇧 English</strong></a> · <a href="#tiếng-việt"><strong>🇻🇳 Tiếng Việt</strong></a>
</p>

---

## Overview

**Hybrid Editor (`hybrid_edit_vid`)** is a native macOS Apple Silicon AI-hybrid video editor built atop [`robbietilton/Editroom`](https://github.com/robbietilton/Editroom) (`MIT`). It pairs a responsive SwiftUI + AVFoundation + Metal timeline with an **in-app AI Agent Chat (`⌘L`)**, extensible **GitHub `SKILL.md` / Plugin system**, **ComfyUI Google Colab & Stock Media integrations**, and a **Smart Vietnamese A-Roll + 3-Tier B-Roll engine**.

> **Legacy Archive:** The earlier Rust + Slint prototype based on `jub0t/Concat` is preserved intact on the [`archive/concat-m1`](../../tree/archive/concat-m1) branch (`concat-m1-archive` tag).

### Key Capabilities (`M1-E` → `M5-E` Completed)

| Milestone | Scope | Highlights |
| :--- | :--- | :--- |
| **M1-E** | Core Guardrails & Hybrid MCP | `HybridStorage` (`HYBRID_EDIT_DATA_DIR`, UTF-8 safe caches), `SessionLease` (`0o600`, `SIGKILL` recovery), transactional `AgentTurn` (`⌘Z` unified undo), `apply_edl_patch`, `preview_timeline_strip` |
| **M2-E** | Extensions & Multi-Provider Backend | Keychain/0o600 `SecretStore`, `SkillRegistry` (local & GitHub `SKILL.md`), 2-tier `PluginHost` (trusted MCP sidecars + LUTs/workflows), `ChatSessionStore` (Gemini, OpenAI-compatible, Ollama, Claude/Codex CLI) |
| **M3-E** | Native Hybrid UI | Collapsible Agent Chat sidebar (`⌘L`), `/skill` & `@playhead` composer, Undo-per-turn card, `Settings` tabs (`Skills`, `Plugins`, `Integrations`), `Library > Stock` browser |
| **M4-E** | ComfyUI Colab & Stock Media | `TunnelManager` (Cloudflare / Tailscale / SSH injection-safe args), `ComfyUIClient` (REST/WS + I2V reference upload + Colab `.ipynb`), `Pexels` + `Pixabay` parallel search, contact sheets & `Sources.txt` |
| **M5-E** | Smart A-Roll VI & 3-Tier B-Roll | `AudioVAD` + `WhisperCPPProvider` (`P6` zero-hallucination 10s silence guard), persistent **SQLite3 FTS5** index (`đ -> d` normalization), `LocalVLMVisionProvider` + Apple Vision fallback, 3-tier B-roll ladder |
| **M6-E** | Hardening & 5-Round 4K E2E | *(Next)* Security audit, Antigravity live-attach polish & 5-round 4K benchmark |

---

## Repository Structure

```text
hybrid_editor/
├── editroom/                    # Native macOS Xcode project (`Editroom.xcodeproj`, SwiftUI/AVFoundation/Metal)
│   ├── Editroom/
│   │   ├── App/                 # App entry point & offline deterministic test runners
│   │   ├── Agent/               # Multi-provider AI backend & ChatSessionStore
│   │   ├── Engine/              # PlaybackEngine, CompositionBuilder, Exporter, Transcripts
│   │   ├── Extensions/          # SecretStore, SkillRegistry, PluginHost, IntegrationPrefs
│   │   ├── MCP/                 # HTTP MCPServer, SessionLease, MCPTools & MCPTools+Hybrid (18 tools)
│   │   ├── Model/               # EditorModel, Project, AgentTurn, HybridStorage, Workspace
│   │   ├── Providers/           # ComfyUI/, Stock/, Speech/ (Whisper+VAD), BRoll/ (FTS5+VLM)
│   │   └── UI/                  # AgentChatPanel, ExtensionsSettingsView, StockLibraryView, Timeline
│   └── Vendor/ffmpeg/           # LGPL-2.1+ FFmpeg sidecar binary
├── assets/
│   ├── editor-skills/           # Runtime video-editing SKILL.md workflows (4 built-in skills)
│   └── colab/                   # `editroom_comfyui_colab.ipynb` (Cloudflare/Tailscale GPU setup)
├── specs/                       # Spec Kit design specs, contracts & checklists (`001..006`)
├── docs/
│   ├── ARCHITECTURE.md          # Detailed invariants (`I1–I6`), MCP tools & 3-tier B-roll ladder
│   └── kit/                     # Antigravity Starter Kit docs
├── .specify/                    # Constitution v2.0.0 & Spec Kit templates
├── .agents/                     # Dev-workflow skills & Graphify rules
├── PROJECT.md                   # Engineering changelog & empirical M4 Pro test metrics
├── LICENSE                      # MIT License
└── THIRD_PARTY_NOTICES.md       # Attributions (Editroom, Sparkle, FFmpeg, SQLite3)
```

---

## Build & Empirical Test Suites (macOS Apple Silicon)

Open `editroom/Editroom.xcodeproj` in Xcode, or build and run the offline test runners from Terminal:

```bash
# 1. Build Debug (ad-hoc signed locally)
xcodebuild -project editroom/Editroom.xcodeproj -scheme Editroom -configuration Debug \
  -derivedDataPath /tmp/hybrid_edit_editroom_dd CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build

BIN="/tmp/hybrid_edit_editroom_dd/Build/Products/Debug/Editroom.app/Contents/MacOS/Editroom"

# 2. Run all 4 offline verification suites (isolated via HYBRID_EDIT_DATA_DIR)
HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_test_1 "$BIN" --hybrid-test /tmp/hybrid_out_1           # 7/7 checks (T1-T7)
HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_test_2 "$BIN" --extensions-test /tmp/hybrid_out_2       # 7/7 checks (E1-E7)
HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_test_3 "$BIN" --media-providers-test /tmp/hybrid_out_3  # 6/6 checks (M1-M6)
HYBRID_EDIT_DATA_DIR=/tmp/hybrid_edit_test_4 "$BIN" --smart-editing-test /tmp/hybrid_out_4    # 6/6 checks (S1-S6)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [PROJECT.md](PROJECT.md) for detailed MCP tool schemas, architecture notes, and M4 Pro verification logs.

---

## Tiếng Việt

**Hybrid Editor (`hybrid_edit_vid`)** là trình dựng phim native cho macOS Apple Silicon, xây dựng trên lõi [`robbietilton/Editroom`](https://github.com/robbietilton/Editroom) (`Swift / SwiftUI / AVFoundation / Metal`). Ứng dụng kết hợp chỉnh sửa timeline trực tiếp của người dùng với tác tử AI (**Agent Chat `⌘L`** + **MCP Server**), cài đặt **Skill từ GitHub** & **Plugin mở rộng**, tạo sinh media trên **ComfyUI Google Colab**, tìm **Stock miễn phí (Pexels/Pixabay)**, cùng bộ **Smart A-Roll Tiếng Việt (Whisper + VAD chống ảo giác)** và **Smart B-Roll 3 tầng (Local SQLite FTS5 -> Stock -> ComfyUI)**.

> **Lưu trữ mã nguồn Concat cũ:** Phiên bản thử nghiệm Rust/Slint trước đây dựa trên `jub0t/Concat` được giữ nguyên tại nhánh [`archive/concat-m1`](../../tree/archive/concat-m1) và tag `concat-m1-archive`.

### Lộ trình hiện tại
- ✅ **M1-E → M5-E** đã hoàn thành và kiểm chứng thực nghiệm **26/26 bài test tự động** trên Apple M4 Pro.
- 🔜 **M6-E**: Hardening bảo mật, hoàn thiện live-attach và benchmark E2E 5 vòng trên footage 4K.
