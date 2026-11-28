# Feature Specification: Milestone 6-E — Hardening & 5-Round 4K E2E Benchmark

**Branch**: `main` | **Created**: 2026-11-28 | **Status**: Active | **Constitution**: v2.0.0 (`I1–I6`)

## Scope
1. **Security Hardening:**
   - **Keychain & Secret Redaction (`KeychainStore.swift`):** Restrict Keychain items to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and add `SecretRedactor` to scrub stored secrets and API token patterns before logging/reporting.
   - **Plugin Execution Isolation (`PluginHost.swift`):** Sanitize `StdioMCPProcess` child environment to an explicit allowlist (`PATH`, `HOME`, `TMPDIR`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `HYBRID_EDIT_DATA_DIR`), reject control characters/NUL in executable commands, and forbid Tier A plugin `envKeys` from extracting core app credentials (`SecretRedactor.sensitiveSecretKeys`).
   - **Git Clone Hardening (`SkillRegistry.swift`):** Disable repository hooks and filesystem monitors (`-c core.hooksPath=/dev/null -c core.fsmonitor=false`) and disable interactive prompts (`GIT_TERMINAL_PROMPT=0`) when cloning untrusted GitHub skills/plugins.
   - **SSH Tunnel Injection Hardening (`TunnelManager.swift`):** Reject `-F` config overrides and dangerous SSH `-o` directives (`ProxyCommand`, `LocalCommand`, `PermitLocalCommand`, `RemoteCommand`, `KnownHostsCommand`, `Match`, `ProxyUseFdpass`, `PKCS11Provider`, `SecurityKeyProvider`).
   - **MCP Localhost Hardening (`MCPServer.swift`, `AgentConnect.swift`):** Fix IPv6 `[::1]:port` validation cleanly in `isAllowedLocalHost`/`isAllowedOrigin`, reject subdomain spoofs (`localhost.evil.com`), enforce `0o600` on Antigravity MCP config writes, and cleanly roll back/release active `AgentTurn`/`SessionLease` on `DELETE /mcp`.
2. **Antigravity 2.0 Live-Attach Polish:** Proper `displayName("Antigravity ...") -> "Antigravity"` cursor attribution and clean session termination.
3. **5-Round 4K E2E Benchmark (`--hardening-4k-test`):** Execute 5 alternating AI (`AgentTurn`) + Manual editing rounds on real `3840x2160 @ 30fps` H.264/AAC footage + 4K B-roll overlay, export to 4K HEVC via `Exporter`, and verify output streams using `ffprobe`.
