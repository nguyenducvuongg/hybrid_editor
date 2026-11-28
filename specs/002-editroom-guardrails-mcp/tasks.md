# Tasks: Milestone 1-E (`002-editroom-guardrails-mcp`)

- [x] **T001** Lock Spec Kit artifacts (`spec.md`, `plan.md`, `contracts/hybrid_mcp_tools.md`, `tasks.md`)
- [x] **T002** Create `editroom/Editroom/Model/AppStorage.swift` (`enum HybridStorage`: `HYBRID_EDIT_DATA_DIR`, `derivedCacheStem`, `writeAtomicVerified`)
- [x] **T003** Wire all 12 Editroom storage & cache call sites to `HybridStorage` (`I5`, `P7`)
- [x] **T004** Create `editroom/Editroom/MCP/SessionLease.swift` (`LeaseManager`, `SessionLease`, `Darwin.kill`, `0o600`, `P8`)
- [x] **T005** Create `editroom/Editroom/Model/AgentTurn.swift` and wire `revision`, `undoTurns`/`redoTurns`, `begin/commit/rollbackAgentTurn`, `leaseManager` into `EditorModel.swift` (`I1`, `P4`)
- [x] **T006** Create `editroom/Editroom/MCP/MCPTools+Hybrid.swift` (`session_*`, `*_agent_turn`, `apply_edl_patch`, `preview_timeline_strip`) and wire into `MCPServer.swift` & `MCPTools.swift` (`I2`, `I3`, `P1`, `P2`, `P3`)
- [x] **T007** Create `editroom/Editroom/App/HybridGuardrailsTest.swift` (`--hybrid-test` covering `T1–T7` including real `SIGKILL` & 5-round live HTTP E2E) and register in `EditroomApp.swift`
- [x] **T008** Build with `xcodebuild` and pass all 7 `--hybrid-test` checks on M4 Pro
- [x] **T009** Update `PROJECT.md`, refresh `graphify update .`, and commit on `feat/editroom-core`
