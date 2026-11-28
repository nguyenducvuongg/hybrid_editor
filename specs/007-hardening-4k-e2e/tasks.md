# Tasks: Milestone 6-E — Hardening & 5-Round 4K E2E Benchmark

- [x] **T001** Author `specs/007-hardening-4k-e2e/{spec.md, plan.md, tasks.md}`.
- [x] **T002** Harden `KeychainStore.swift` (`ThisDeviceOnly` + `SecretRedactor`).
- [x] **T003** Harden `PluginHost.swift` (minimal env allowlist + block core secret key extraction + command hygiene).
- [x] **T004** Harden `SkillRegistry.swift` (`core.hooksPath=/dev/null`, `core.fsmonitor=false`, `GIT_TERMINAL_PROMPT=0`).
- [x] **T005** Harden `TunnelManager.swift` (`-F` and `-o ProxyCommand/LocalCommand/...` rejection).
- [x] **T006** Harden & polish `MCPServer.swift` & `AgentConnect.swift` (`isAllowedLocalHost`/`isAllowedOrigin`, `DELETE /mcp` cleanup, `Antigravity` name, `0o600`).
- [x] **T007** Hook & implement `Hardening4KBenchmarkTest.swift` (`--hardening-4k-test`, `H1–H6`).
- [x] **T008** Build Debug and pass all 5 suites (`32/32` checks total) on M4 Pro.
- [x] **T009** Update `PROJECT.md`, `README.md`, and run `graphify update .`.
- [x] **T010** Commit Milestone 6-E cleanly on `main`.
