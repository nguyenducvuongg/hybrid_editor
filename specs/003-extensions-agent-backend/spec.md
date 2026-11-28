# Feature Specification: Milestone 2-E — Secrets, GitHub Skills, 3-Tier Plugins & Multi-Provider Agent Chat Backend

**Feature Branch**: `feat/editroom-core`  
**Spec Directory**: `specs/003-extensions-agent-backend`  
**Created**: 2026-11-28  
**Status**: Approved for Implementation  

**Input**: Build the extensible Agent Chat backend, secure credential store (`KeychainStore`/`FileSecretStore`), GitHub/local `SKILL.md` registry (`SkillRegistry`), 3-tier extensible plugin host (`PluginHost`), 1-click Antigravity MCP registration, and `--extensions-test` (`E1–E6`) before building the native M3-E SwiftUI panels and M4-E ComfyUI/Stock providers.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Isolated Secrets & Keychain Security (`I5`)
API keys (`Gemini`, `OpenAI/Ollama`, `Pexels`, `Pixabay`, `ComfyUI Tunnel tokens`) never live in `.room` project files or plaintext app preferences. Interactive runs store secrets in macOS Keychain (`KeychainStore`), while test/isolated runs (`HybridStorage.overrideRoot != nil`) route transparently to a `0o600` file store inside `HYBRID_EDIT_DATA_DIR`.

### User Story 2 - GitHub & Local `SKILL.md` Registry (`SkillRegistry`)
Users and external agents can install reusable editing skills (`SKILL.md` with YAML frontmatter + optional `references/`) from local folders or GitHub URLs (`owner/repo`, `https://github.com/owner/repo/tree/<ref>/<subpath>`). Installed skills pin `commitSHA`, reject path-traversal/symlinks escaping the skill root, support toggleable `enabled` state, and expand cleanly into agent prompts when invoked explicitly (`/slug`) or active globally.

### User Story 3 - 3-Tier Safe Plugin Architecture (`PluginHost`)
Editroom supports modular extensions without fragile `.dylib` ABI loading:
- **Tier A (MCP Sidecar Plugins):** `plugin.json` (`schemaVersion == 1`) declares a local/scripted stdio MCP command. Newly installed executable plugins default to `trustedForExecution = false` and `enabled = false` until explicitly trusted; enabled tools expose namespaced `plugin.<id>.<tool>` names directly into `MCPTools` and Agent Chat and shut down cleanly on exit.
- **Tier B (Declarative Asset Plugins):** Zero-code bundles supplying `.cube` LUTs (`list_looks`), ComfyUI workflow JSON templates, and bundled skills directly under `HybridStorage.subdir("Plugins")`.
- **Tier C (Provider Protocols):** Clean Swift protocols (`AgentProvider`, extensible for ComfyUI/Stock in M4-E and Whisper/VLM in M5-E).

### User Story 4 - Multi-Turn Agent Chat Backend Bound to `AgentTurn` (`I1`, `I2`)
`ChatSessionStore` manages per-project multi-turn `ChatThread` persistence under `Chats/`, supports multiple AI backends (`Claude CLI`, `Codex CLI`, `Gemini API`, `OpenAI-compatible / Ollama`, `MockAgentProvider`), executes every chat edit turn through `LeaseManager` + `beginAgentTurn`/`commitAgentTurn`/`rollbackAgentTurn`, records `ChatTurnLink` (`turnId`, `revisionAfterCommit`, `affectedClipIds`, `reverted`), and lets a single UI action revert the exact top Undo step or roll back cleanly on failure.

### User Story 5 - 1-Click Antigravity Registration (`AgentConnect`)
`AgentConnect` adds `.antigravity` alongside Claude/ChatGPT/Claude Code, merging `"editroom"` (`MCPServer.endpoint`) non-destructively into `~/.gemini/antigravity/mcp_config.json` without clobbering unrelated servers.
