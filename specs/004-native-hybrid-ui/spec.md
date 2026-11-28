# Feature Specification: Milestone 3-E — Native Hybrid UI (`AgentChatPanel`, Extensions Settings & Quick Stock Browser)

**Feature Branch**: `feat/editroom-core`  
**Spec Directory**: `specs/004-native-hybrid-ui`  
**Created**: 2026-11-28  
**Status**: Approved for Implementation  

**Input**: Surface native SwiftUI controls atop M2-E's backend without duplicating AI or data pipelines: a collapsible Agent Chat sidebar (`⌘L`), Settings tabs for GitHub/local **Skills**, 3-tier **Plugins** (with explicit Trust prompt), and **Integrations** (AI Chat keys, Pexels/Pixabay keys, ComfyUI Colab Tunnel prefs + live Test Connection), plus a quick Stock mode switcher in `LibraryView`.

---

## User Scenarios & Testing

### User Story 1 - Multi-Turn Agent Chat Sidebar (`⌘L`)
Editors open/close the right-hand Agent Chat sidebar (`⌘L` or toolbar `"Chat"` pill) alongside `InspectorView`, switch AI providers (`Gemini`, `Ollama`, `OpenAI-Compatible`, `Claude Code CLI`, `Codex CLI`), toggle active `/skill` chips, insert `@playhead`/`@selected` references, view live tool calls, and revert any committed `AgentTurn` in 1 click directly from the chat message card.

### User Story 2 - GitHub Skills, 3-Tier Plugins & Integrations Settings
In Settings (`⌘,`), dedicated **Skills**, **Plugins**, and **Integrations** tabs allow installing `SKILL.md` or plugins from GitHub URLs or local directories, requiring explicit Trust confirmation before enabling Tier A MCP sidecars, storing API keys cleanly in `AppSecrets.shared`, and testing ComfyUI Cloudflare/Tailscale/SSH endpoints.

### User Story 3 - Quick Stock Panel in `LibraryView`
Users can flip `LibraryView` between local **Media** and **Stock** (Pexels / Pixabay), showing configured provider status or an immediate shortcut to **Integrations** Settings.

### Verification
- `xcodebuild` Debug build succeeds with 0 errors.
- `Editroom --extensions-test` (`E1–E7`, including offscreen `NSHostingView` rendering smoke check for all new views) passes 7/7 with exit code `0`.
- `--hybrid-test` regression passes 7/7 with exit code `0`.
