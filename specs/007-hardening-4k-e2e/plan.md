# Implementation Plan: Milestone 6-E — Hardening & 5-Round 4K E2E Benchmark

**Branch**: `main` | **Spec**: [spec.md](file:///Users/nguyenducvuong/Projects/hybrid_edit_vid/specs/007-hardening-4k-e2e/spec.md)

## Target Changes
- `editroom/Editroom/Extensions/KeychainStore.swift`: `ThisDeviceOnly` Keychain attribute + `SecretRedactor`.
- `editroom/Editroom/Extensions/PluginHost.swift`: Child env allowlist, command validation, core secret key block.
- `editroom/Editroom/Extensions/SkillRegistry.swift`: `GitRunner.safeCloneArguments` + `GIT_TERMINAL_PROMPT=0`.
- `editroom/Editroom/Providers/ComfyUI/TunnelManager.swift`: Block `-F` & `-o ProxyCommand/LocalCommand/...`.
- `editroom/Editroom/MCP/MCPServer.swift`: Strict IPv4/IPv6 Host & Origin validation, `Antigravity` display name, `DELETE /mcp` lease/turn cleanup.
- `editroom/Editroom/MCP/AgentConnect.swift`: `0o600` permissions for `mcp_config.json`.
- `editroom/Editroom/App/Hardening4KBenchmarkTest.swift` + `EditroomApp.swift`: `--hardening-4k-test` (`H1–H6`).

## Verification Matrix
- `--hardening-4k-test` (`H1–H6`, including real 4K HEVC export + `ffprobe`)
- `--smart-editing-test` (`S1–S6`)
- `--media-providers-test` (`M1–M6`)
- `--extensions-test` (`E1–E7`)
- `--hybrid-test` (`T1–T7`)
