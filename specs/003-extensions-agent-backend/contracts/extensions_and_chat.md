# Contract: Extensions, Secrets, Plugin Host & Agent Chat Backend

**Status:** Locked for Milestone 2-E

## 1. Secrets (`editroom/Editroom/Extensions/KeychainStore.swift`)
- `SecretKey`: `geminiAPIKey`, `openAIAPIKey`, `openAIBaseURL`, `ollamaBaseURL`, `pexelsAPIKey`, `pixabayAPIKey`, `comfyAuthToken`, `comfyCFClientId`, `comfyCFClientSecret`.
- `AppSecrets.shared`: returns `FileSecretStore` (`HybridStorage.root/secrets.json`, mode `0o600`, atomic verified) when `HybridStorage.overrideRoot != nil`, and macOS `KeychainStore` (`SecItem*`, service `"local.hybrideditvid.Editroom"`) otherwise.

## 2. Skills (`editroom/Editroom/Extensions/SkillRegistry.swift`)
- Storage root: `HybridStorage.subdir("Skills")`.
- Sources: `builtIn`, `local(path)`, `github(repo, ref, subpath, commitSHA)`.
- `SafePath`: validates relative paths against `..`, absolute escapes, and outbound symlinks.
- Prompt injection: `composePromptSection(explicitSlugs:)` expands active global skills plus `/slug` invocations from chat prompts cleanly into structured prompt blocks.

## 3. Plugins (`editroom/Editroom/Extensions/PluginHost.swift`)
- Manifest: `plugin.json` (`schemaVersion == 1`, slug regex `^[a-z0-9][a-z0-9_-]{0,63}$`).
- **Tier A (MCP Sidecar):** `mcp: { command, args, envKeys? }`. Installs untrusted/disabled (`trustedForExecution = false`, `enabled = false`). Requires `trustAndEnable(id:)` before `StdioMCPProcess` can spawn; exposes `plugin.<id>.<toolName>` in `MCPTools.call`. Stopped on `applicationWillTerminate`.
- **Tier B (Asset Bundles):** `luts`, `workflows`, `skills` validated inside plugin root; `.cube` files merge into `list_looks`, workflow templates expose to M4-E ComfyUI, skills surface in `activeSkillDirectories()`.

## 4. Multi-Provider Chat Backend (`editroom/Editroom/Agent/`)
- `AgentProvider` protocol: `OpenAICompatibleHTTPProvider` (covers OpenAI, Ollama, LM Studio), `GeminiHTTPProvider`, `CLIProcessAgentProvider` (Claude Code, Codex CLI), plus `MockAgentProvider` for tests.
- `ChatSessionStore`: persists per-project `ChatThread` JSON under `HybridStorage.subdir("Chats")`, wraps each turn in `LeaseManager` + `AgentTurn`, links committed edits via `ChatTurnLink`, and supports 1-click `revertTurn` (`model.undo()` when `topUndoTurn?.turnId == link.turnId`).

## 5. MCP Discovery & 1-Click Antigravity
- `MCPTools+Hybrid`: adds read-only `list_skills` and `list_plugins`.
- `MCPTools.list_looks`: appends `PluginHost.shared.activeLUTPaths()`.
- `AgentConnect`: `.antigravity` merges `"editroom": {"url": MCPServer.endpoint}` into `~/.gemini/antigravity/mcp_config.json` non-destructively.
