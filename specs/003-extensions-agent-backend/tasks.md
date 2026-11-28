# Tasks: Milestone 2-E (`003-extensions-agent-backend`)

- [x] **E001** Update `PROJECT.md` 6-milestone roadmap and create Spec Kit `specs/003-extensions-agent-backend/`
- [x] **E002** Create `editroom/Editroom/Extensions/KeychainStore.swift` (`SecretStore`, `KeychainStore`, `FileSecretStore`, `AppSecrets`)
- [x] **E003** Create `editroom/Editroom/Extensions/SkillRegistry.swift` (`SafePath`, `GitHubSpec`, `GitRunner`, YAML frontmatter parser, local + GitHub `SKILL.md` install & `/slug` prompt composer)
- [x] **E004** Create `editroom/Editroom/Extensions/PluginHost.swift` (`PluginManifest` v1, Tier A `StdioMCPProcess` JSON-RPC sidecar with trust gate, Tier B LUT/workflow/skill asset discovery)
- [x] **E005** Create `editroom/Editroom/Agent/AgentProvider.swift` (`AgentProvider`, `OpenAICompatibleHTTPProvider`, `GeminiHTTPProvider`, `CLIProcessAgentProvider`, `ChatMessage`/`ChatThread`/`ChatTurnLink`)
- [x] **E006** Create `editroom/Editroom/Agent/ChatSessionStore.swift` (project-scoped `ChatThread` persistence, `LeaseManager` + `AgentTurn` lifecycle, `plugin.*` + `MCPTools` routing, `revertTurn`)
- [x] **E007** Wire `PluginHost`, `SkillRegistry`, `list_skills`/`list_plugins`, `.antigravity` in `AgentConnect.swift` & `SettingsView.swift`, and lifecycle hooks in `EditroomApp.swift` & `MCPTools.swift`
- [x] **E008** Create `editroom/Editroom/App/ExtensionsTest.swift` (`--extensions-test` covering `E1–E6`)
- [x] **E009** Build with `xcodebuild`, pass `--extensions-test` (6/6) and `--hybrid-test` (7/7) regression on M4 Pro
- [x] **E010** Update `PROJECT.md`, refresh `graphify update .`, and commit locally on `feat/editroom-core`
