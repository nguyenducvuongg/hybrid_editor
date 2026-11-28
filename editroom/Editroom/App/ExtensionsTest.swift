import AppKit
import Foundation
import Network
import SwiftUI

/// Mock `AgentProvider` for deterministic multi-turn `AgentTurn` + rollback verification.
private final class MockAgentProvider: AgentProvider, @unchecked Sendable {
    let id = "mock"
    let displayName = "Mock Provider"
    let kind: AgentProviderKind = .mock
    let shouldFailAfterMutation: Bool

    init(shouldFailAfterMutation: Bool = false) {
        self.shouldFailAfterMutation = shouldFailAfterMutation
    }

    func runTurn(
        _ request: AgentRequest,
        toolExecutor: @escaping @Sendable (String, [String: Any]) async throws -> [[String: Any]],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> String {
        onEvent(.status("Mock planning…"))
        onEvent(.toolStarted("add_title"))
        let added = try await toolExecutor("add_title", [
            "text": shouldFailAfterMutation ? "FailedTurnTitle" : "ChatTitle",
            "start": 0.0,
            "duration": 1.2,
        ])
        onEvent(.toolFinished("add_title", true))

        if shouldFailAfterMutation {
            throw AgentProviderError.invalidResponse("Simulated provider crash mid-turn")
        }

        if let text = added.first?["text"] as? String,
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let clipId = (obj["added"] as? [String: Any])?["id"] as? String {
            onEvent(.toolStarted("move_clip"))
            _ = try await toolExecutor("move_clip", [
                "clip_id": clipId,
                "start": 0.8,
            ])
            onEvent(.toolFinished("move_clip", true))
        }
        return "Completed multi-step edit via mock turn."
    }
}

/// Minimal in-process loopback HTTP mock answering OpenAI `/v1/chat/completions` with tool calls.
private final class LoopbackOpenAIMockServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.editroom.mock.openai")
    private let lock = NSLock()
    private var callCount = 0
    private(set) var port: UInt16 = 0

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            l.stateUpdateHandler = { [weak self] st in
                guard !resumed else { return }
                switch st {
                case .ready:
                    resumed = true
                    self?.port = l.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveLoop(conn, buffer: Data())
    }

    private func receiveLoop(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return conn.cancel() }
            var buf = buffer
            if let chunk { buf.append(chunk) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                let bodyStart = range.upperBound
                var contentLength = 0
                for line in headerText.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        contentLength = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                if buf.count >= bodyStart + contentLength {
                    self.respond(conn)
                    return
                }
            }
            if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receiveLoop(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection) {
        lock.lock()
        callCount += 1
        let turn = callCount
        lock.unlock()

        let jsonObj: [String: Any]
        if turn == 1 {
            jsonObj = [
                "id": "mockcmpl-1",
                "object": "chat.completion",
                "choices": [[
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [[
                            "id": "call_1",
                            "type": "function",
                            "function": [
                                "name": "add_title",
                                "arguments": #"{"text":"HTTP Chat Title","start":0.4,"duration":1.0}"#,
                            ],
                        ]],
                    ],
                    "finish_reason": "tool_calls",
                ]],
            ]
        } else {
            jsonObj = [
                "id": "mockcmpl-2",
                "object": "chat.completion",
                "choices": [[
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "Added title via live HTTP mock.",
                    ],
                    "finish_reason": "stop",
                ]],
            ]
        }

        let body = (try? JSONSerialization.data(withJSONObject: jsonObj)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

/// Empirical verification suite for Milestone 2-E (`E1–E6`):
/// `HYBRID_EDIT_DATA_DIR=... Editroom --extensions-test <outDir>`
@MainActor
enum ExtensionsTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--extensions-test"), args.count > idx + 1 else { return }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        Task { @MainActor in
            let ok = await run(outDir: outDir)
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        let line = "EXT-TEST \(msg)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func fail(_ test: String, _ reason: String) -> Bool {
        log("FAIL [\(test)] \(reason)")
        return false
    }

    static func run(outDir: URL) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: outDir)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dataDir = outDir.appendingPathComponent("isolated_data", isDirectory: true)
        let prevRoot = HybridStorage.overrideRootForTests
        HybridStorage.overrideRootForTests = dataDir
        defer {
            PluginHost.shared.stopAll()
            HybridStorage.overrideRootForTests = prevRoot
        }

        await BaseVideo.load()
        var initProject = Project()
        initProject.width = 1280
        initProject.height = 720
        initProject.fps = 30
        let model = EditorModel()
        model.load(initProject, url: nil)

        // =========================================================================
        // E1: Isolated Secrets Store (`KeychainStore` / `FileSecretStore` `0o600`)
        // =========================================================================
        do {
            try AppSecrets.shared.set("sk-gemini-test-123", for: .geminiAPIKey)
            guard try AppSecrets.shared.get(.geminiAPIKey) == "sk-gemini-test-123" else {
                return fail("E1", "failed to read stored gemini API key")
            }
            let secretsFile = dataDir.appendingPathComponent("secrets.json")
            let attrs = try fm.attributesOfItem(atPath: secretsFile.path)
            let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard perm & 0o777 == 0o600 else {
                return fail("E1", "secrets.json does not have 0o600 permissions")
            }
            try AppSecrets.shared.set("sk-gemini-updated", for: .geminiAPIKey)
            guard try AppSecrets.shared.get(.geminiAPIKey) == "sk-gemini-updated" else {
                return fail("E1", "failed to update secret")
            }
            try AppSecrets.shared.delete(.geminiAPIKey)
            guard try AppSecrets.shared.get(.geminiAPIKey) == nil else {
                return fail("E1", "failed to delete secret")
            }
        } catch {
            return fail("E1", "error: \(error.localizedDescription)")
        }
        log("PASS [E1] Isolated SecretStore (0o600) CRUD verified")

        // =========================================================================
        // E2: SkillRegistry (Local + GitHub repo + Path-Traversal Guard)
        // =========================================================================
        do {
            let localSkill = outDir.appendingPathComponent("local_skill_src", isDirectory: true)
            let refsDir = localSkill.appendingPathComponent("references", isDirectory: true)
            try fm.createDirectory(at: refsDir, withIntermediateDirectories: true)
            try """
            ---
            name: aroll-helper
            description: "Vietnamese A-roll cut rules"
            ---
            Keep speech natural and tighten dead air > 0.45s.
            """.write(to: localSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "Speech pacing notes".write(to: refsDir.appendingPathComponent("rules.md"), atomically: true, encoding: .utf8)

            let installedLocal = try SkillRegistry.shared.installFromLocal(directory: localSkill)
            guard installedLocal.id == "aroll-helper",
                  let loaded = SkillRegistry.shared.loadSkill(id: "aroll-helper"),
                  loaded.body.contains("tighten dead air"),
                  loaded.referenceFiles == ["references/rules.md"] else {
                return fail("E2", "local skill install/parse mismatch")
            }

            // Real local git repo pretending to be GitHub tree URL.
            let gitRepo = outDir.appendingPathComponent("mock_github_repo", isDirectory: true)
            let subSkill = gitRepo.appendingPathComponent("skills/broll-helper", isDirectory: true)
            try fm.createDirectory(at: subSkill, withIntermediateDirectories: true)
            try """
            ---
            name: broll-helper
            description: "Insert matched B-roll overlays"
            ---
            Always inspect timeline before placing overlays.
            """.write(to: subSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

            _ = try await GitRunner.system.run(["init", "-b", "main"], gitRepo)
            _ = try await GitRunner.system.run(["config", "user.email", "test@example.com"], gitRepo)
            _ = try await GitRunner.system.run(["config", "user.name", "Test"], gitRepo)
            _ = try await GitRunner.system.run(["add", "."], gitRepo)
            let commitRes = try await GitRunner.system.run(["commit", "-m", "initial"], gitRepo)
            guard commitRes.status == 0 else {
                return fail("E2", "git init/commit failed: \(commitRes.stdout)")
            }

            let mockGit = GitRunner(run: GitRunner.system.run, cloneURLOverride: { _ in gitRepo.path })
            let ghMeta = try await SkillRegistry.shared.installFromGitHub(
                "https://github.com/test/edit-skills/tree/main/skills/broll-helper",
                gitRunner: mockGit
            )
            guard case .github(let repo, let ref, let sub, let sha) = ghMeta.source,
                  repo == "test/edit-skills", ref == "main", sub == "skills/broll-helper", sha.count >= 12 else {
                return fail("E2", "GitHub skill install metadata incomplete")
            }

            // Path-traversal and symlink escape checks.
            var caughtTraversal = false
            do {
                _ = try SafePath.safeResolve(relative: "../../etc/passwd", inside: dataDir)
            } catch {
                caughtTraversal = true
            }
            guard caughtTraversal else { return fail("E2", "failed to reject .. path traversal") }

            let symlinkSkill = outDir.appendingPathComponent("bad_symlink_skill", isDirectory: true)
            try fm.createDirectory(at: symlinkSkill, withIntermediateDirectories: true)
            try "---\nname: bad\n---\nhi".write(to: symlinkSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(atPath: symlinkSkill.appendingPathComponent("escape").path, withDestinationPath: "/etc/hosts")
            var caughtSymlink = false
            do {
                _ = try SkillRegistry.shared.installFromLocal(directory: symlinkSkill)
            } catch {
                caughtSymlink = true
            }
            guard caughtSymlink else { return fail("E2", "failed to reject outbound symlink in skill tree") }

            try SkillRegistry.shared.setEnabled(id: "aroll-helper", enabled: false)
            let composed = SkillRegistry.shared.composePromptSection(explicitSlugs: ["aroll-helper"])
            guard composed.contains("## Skill /aroll-helper:"), composed.contains("## Skill /broll-helper:") else {
                return fail("E2", "composePromptSection missing explicit or active skill")
            }
            try SkillRegistry.shared.setEnabled(id: "aroll-helper", enabled: true)
        } catch {
            return fail("E2", "error: \(error.localizedDescription)")
        }
        log("PASS [E2] SkillRegistry local + GitHub pin + traversal guard verified")

        // =========================================================================
        // E3: Tier B Declarative Asset Plugin & `list_looks` Integration
        // =========================================================================
        do {
            let tierBDir = outDir.appendingPathComponent("tier_b_plugin", isDirectory: true)
            try fm.createDirectory(at: tierBDir.appendingPathComponent("luts"), withIntermediateDirectories: true)
            try fm.createDirectory(at: tierBDir.appendingPathComponent("workflows"), withIntermediateDirectories: true)
            try fm.createDirectory(at: tierBDir.appendingPathComponent("skills/cine"), withIntermediateDirectories: true)
            try "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
                .write(to: tierBDir.appendingPathComponent("luts/warm.cube"), atomically: true, encoding: .utf8)
            try #"{"3":{"class_type":"KSampler"}}"#
                .write(to: tierBDir.appendingPathComponent("workflows/wan.json"), atomically: true, encoding: .utf8)
            try "---\nname: cine\n---\nColor notes"
                .write(to: tierBDir.appendingPathComponent("skills/cine/SKILL.md"), atomically: true, encoding: .utf8)
            try """
            {
              "schemaVersion": 1,
              "id": "cine-pack",
              "name": "Cine Pack",
              "version": "1.0.0",
              "description": "LUTs & workflows",
              "luts": ["luts/warm.cube"],
              "workflows": ["workflows/wan.json"],
              "skills": ["skills/cine"]
            }
            """.write(to: tierBDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

            let installed = try PluginHost.shared.installFromLocal(directory: tierBDir)
            guard installed.enabled, installed.trustedForExecution,
                  PluginHost.shared.activeComfyWorkflowPaths().count == 1,
                  PluginHost.shared.activeSkillDirectories().count == 1 else {
                return fail("E3", "Tier B plugin failed to activate asset paths")
            }

            let looksOut = try await MCPTools.call("list_looks", [:], model: model, client: nil, isExternal: true)
            let looksText = (looksOut.first?["text"] as? String) ?? ""
            guard looksText.contains("warm.cube") else {
                return fail("E3", "list_looks did not include plugin LUT path: \(looksText)")
            }

            let badPluginDir = outDir.appendingPathComponent("bad_plugin", isDirectory: true)
            try fm.createDirectory(at: badPluginDir, withIntermediateDirectories: true)
            try """
            {
              "schemaVersion": 1,
              "id": "bad-pack",
              "name": "Bad Pack",
              "version": "1.0.0",
              "description": "Traversal",
              "luts": ["../../etc/passwd"]
            }
            """.write(to: badPluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            var caughtBad = false
            do {
                _ = try PluginHost.shared.installFromLocal(directory: badPluginDir)
            } catch {
                caughtBad = true
            }
            guard caughtBad else { return fail("E3", "failed to reject plugin LUT path traversal") }
        } catch {
            return fail("E3", "error: \(error.localizedDescription)")
        }
        log("PASS [E3] PluginHost Tier B assets + list_looks + traversal guard verified")

        // =========================================================================
        // E4: Tier A Executable Python MCP Sidecar + Trust Gate + Shutdown
        // =========================================================================
        do {
            let tierADir = outDir.appendingPathComponent("tier_a_plugin", isDirectory: true)
            try fm.createDirectory(at: tierADir, withIntermediateDirectories: true)
            try """
            import json, sys
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                msg = json.loads(line)
                mid = msg.get("id")
                method = msg.get("method")
                if method == "initialize":
                    res = {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "mock-mcp"}}
                elif method == "tools/list":
                    res = {"tools": [{"name": "echo_stats", "description": "Echo args", "inputSchema": {"type": "object", "properties": {"msg": {"type": "string"}}}}]}
                elif method == "tools/call":
                    args = msg.get("params", {}).get("arguments", {})
                    res = {"content": [{"type": "text", "text": json.dumps({"status": "echoed", "msg": args.get("msg", "")})}], "isError": False}
                else:
                    continue
                if mid is not None:
                    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": res}) + "\\n")
                    sys.stdout.flush()
            """.write(to: tierADir.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)

            try """
            {
              "schemaVersion": 1,
              "id": "mock-mcp",
              "name": "Mock MCP Sidecar",
              "version": "1.0.0",
              "description": "Test stdio MCP sidecar",
              "mcp": {
                "command": "/usr/bin/python3",
                "args": ["server.py"]
              }
            }
            """.write(to: tierADir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

            let installed = try PluginHost.shared.installFromLocal(directory: tierADir)
            guard !installed.trustedForExecution, !installed.enabled else {
                return fail("E4", "Tier A plugin must default to untrusted + disabled")
            }

            var blockedUntrusted = false
            do {
                _ = try await MCPTools.call("plugin.mock-mcp.echo_stats", ["msg": "blocked"],
                                            model: model, client: nil, isExternal: true)
            } catch {
                blockedUntrusted = true
            }
            guard blockedUntrusted else { return fail("E4", "untrusted Tier A plugin executed without consent") }

            try PluginHost.shared.trustAndEnable(id: "mock-mcp")
            let tools = try await PluginHost.shared.listPluginTools(id: "mock-mcp")
            guard tools.contains(where: { ($0["name"] as? String) == "plugin.mock-mcp.echo_stats" }) else {
                return fail("E4", "plugin tool missing namespaced name")
            }

            let out = try await MCPTools.call("plugin.mock-mcp.echo_stats", ["msg": "hello-plugin"],
                                              model: model, client: nil, isExternal: true)
            let replyText = (out.first?["text"] as? String) ?? ""
            guard replyText.contains("hello-plugin") else {
                return fail("E4", "unexpected Tier A echo reply: \(replyText)")
            }

            guard let pid = PluginHost.shared.activeMCPProcessPid(id: "mock-mcp"),
                  Darwin.kill(pid, 0) == 0 else {
                return fail("E4", "Tier A MCP process PID not alive")
            }
            PluginHost.shared.stopAll()
            var dead = false
            for _ in 0..<20 {
                if Darwin.kill(pid, 0) != 0 {
                    dead = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard dead else { return fail("E4", "Tier A MCP child PID \(pid) survived stopAll()") }
        } catch {
            return fail("E4", "error: \(error.localizedDescription)")
        }
        log("PASS [E4] Tier A MCP sidecar trust gate, RPC & clean stopAll() verified")

        // =========================================================================
        // E5: ChatSessionStore Multi-Turn Undo/Rollback + Antigravity Config Merge
        // =========================================================================
        do {
            let chatsDir = dataDir.appendingPathComponent("Chats", isDirectory: true)
            let store = ChatSessionStore(baseDir: chatsDir)
            let thread = store.createThread(for: model.leaseProjectKey, title: "M2-E Thread",
                                            providerId: "mock", modelId: "mock-1")

            let rev0 = model.revision
            let clips0 = model.project.clips.count
            let msg = try await store.send(prompt: "Add title & move /aroll-helper",
                                             in: thread.id, model: model, provider: MockAgentProvider())
            guard model.revision == rev0 + 1,
                  model.project.clips.count == clips0 + 1,
                  msg.turnLink?.reverted == false,
                  msg.toolEvents.count == 2 else {
                return fail("E5", "ChatSessionStore successful turn mismatch")
            }

            guard store.revertTurn(messageId: msg.id, in: thread.id, on: model),
                  model.project.clips.count == clips0 else {
                return fail("E5", "revertTurn did not undo whole chat turn cleanly")
            }

            // Failing mid-turn must roll back cleanly without advancing revision or leaving lease held.
            let revBeforeFail = model.revision
            let clipsBeforeFail = model.project.clips.count
            var threwFailure = false
            do {
                _ = try await store.send(prompt: "Fail halfway",
                                         in: thread.id, model: model, provider: MockAgentProvider(shouldFailAfterMutation: true))
            } catch {
                threwFailure = true
            }
            guard threwFailure,
                  model.revision == revBeforeFail,
                  model.project.clips.count == clipsBeforeFail,
                  model.activeAgentTurn == nil,
                  model.leaseManager.current == nil else {
                return fail("E5", "failed chat turn leaked edits, revision, or lease")
            }

            let reloaded = ChatSessionStore(baseDir: chatsDir).loadThreads(for: model.leaseProjectKey)
            guard reloaded.first?.messages.count == 2 else {
                return fail("E5", "persisted thread reload mismatch: count=\(reloaded.first?.messages.count ?? -1)")
            }

            // Antigravity config merge preserves existing entries cleanly across v1 & v2 paths.
            let mockHome = outDir.appendingPathComponent("mock_home", isDirectory: true)
            let agyDir = mockHome.appendingPathComponent(".gemini/antigravity", isDirectory: true)
            try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
            let cfgURL = agyDir.appendingPathComponent("mcp_config.json")
            let v2CfgURL = mockHome.appendingPathComponent(".gemini/config/mcp_config.json")
            try #"{"mcpServers":{"other_tool":{"url":"http://127.0.0.1:9999/mcp"}}}"#
                .write(to: cfgURL, atomically: true, encoding: .utf8)

            let prevHome = AgentConnect.shared.home
            AgentConnect.shared.home = mockHome
            defer { AgentConnect.shared.home = prevHome }

            try AgentConnect.shared.connectAntigravity()
            let mergedData = try Data(contentsOf: cfgURL)
            let mergedObj = (try? JSONSerialization.jsonObject(with: mergedData) as? [String: Any]) ?? [:]
            let mergedServers = (mergedObj["mcpServers"] as? [String: Any]) ?? [:]
            let v2Data = try Data(contentsOf: v2CfgURL)
            let v2Obj = (try? JSONSerialization.jsonObject(with: v2Data) as? [String: Any]) ?? [:]
            let v2Servers = (v2Obj["mcpServers"] as? [String: Any]) ?? [:]
            guard mergedServers["other_tool"] != nil,
                  mergedServers["editroom"] != nil,
                  v2Servers["editroom"] != nil else {
                return fail("E5", "connectAntigravity failed non-destructive merge")
            }
            try AgentConnect.shared.disconnectAntigravity()
            let afterDisData = try Data(contentsOf: cfgURL)
            let afterDisObj = (try? JSONSerialization.jsonObject(with: afterDisData) as? [String: Any]) ?? [:]
            let afterServers = (afterDisObj["mcpServers"] as? [String: Any]) ?? [:]
            let afterV2Data = try Data(contentsOf: v2CfgURL)
            let afterV2Obj = (try? JSONSerialization.jsonObject(with: afterV2Data) as? [String: Any]) ?? [:]
            let afterV2Servers = (afterV2Obj["mcpServers"] as? [String: Any]) ?? [:]
            guard afterServers["other_tool"] != nil,
                  afterServers["editroom"] == nil,
                  afterV2Servers["editroom"] == nil else {
                return fail("E5", "disconnectAntigravity damaged existing server entry")
            }
        } catch {
            return fail("E5", "error: \(error.localizedDescription)")
        }
        log("PASS [E5] ChatSessionStore AgentTurn undo/rollback + persistence + Antigravity merge verified")

        // =========================================================================
        // E6: Live `OpenAICompatibleHTTPProvider` over Loopback `NWListener`
        // =========================================================================
        let server = LoopbackOpenAIMockServer()
        defer { server.stop() }
        do {
            try await server.start()
            let endpoint = URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!
            let httpProvider = OpenAICompatibleHTTPProvider(
                id: "mock-http",
                displayName: "Loopback Mock OpenAI",
                endpointURL: endpoint,
                defaultModel: "mock-gpt",
                requiresAPIKey: false
            )
            let chatsDir = dataDir.appendingPathComponent("Chats", isDirectory: true)
            let store = ChatSessionStore(baseDir: chatsDir)
            _ = store.loadThreads(for: model.leaseProjectKey)
            let thread = store.createThread(for: model.leaseProjectKey, title: "HTTP Chat",
                                            providerId: httpProvider.id, modelId: "mock-gpt")

            let revBefore = model.revision
            let clipsBefore = model.project.clips.count
            let reply = try await store.send(prompt: "Create HTTP title /aroll-helper",
                                               in: thread.id, model: model, provider: httpProvider)
            guard reply.text.contains("live HTTP mock"),
                  model.revision == revBefore + 1,
                  model.project.clips.count == clipsBefore + 1 else {
                return fail("E6", "HTTP provider tool loop failed to commit title cleanly")
            }
            model.undo()
            guard model.project.clips.count == clipsBefore else {
                return fail("E6", "Undo did not revert HTTP chat turn cleanly")
            }
        } catch {
            return fail("E6", "error: \(error.localizedDescription)")
        }
        log("PASS [E6] Live OpenAICompatibleHTTPProvider tool-call E2E verified")

        // =========================================================================
        // E7: Native Hybrid UI Smoke & Preferences Round-Trip (`M3-E`)
        // =========================================================================
        let suiteName = "local.hybrideditvid.m3e-test-\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            return fail("E7", "could not create isolated UserDefaults suite")
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        var comfy = ComfyConnectionPrefs()
        comfy.mode = .tailscale
        comfy.endpointURL = "http://100.64.0.12:8188"
        comfy.save(defaults: testDefaults)
        let loadedComfy = ComfyConnectionPrefs.load(defaults: testDefaults)
        guard loadedComfy == comfy else {
            return fail("E7", "ComfyConnectionPrefs UserDefaults round-trip mismatch")
        }

        var chatPrefs = ChatProviderPrefs()
        guard chatPrefs.selectedProvider == .antigravity else {
            return fail("E7", "Default ChatProviderPrefs provider should be .antigravity")
        }
        chatPrefs.selectedProvider = .ollama
        chatPrefs.ollamaModel = "qwen2.5:14b"
        chatPrefs.save(defaults: testDefaults)
        let loadedChat = ChatProviderPrefs.load(defaults: testDefaults)
        guard loadedChat == chatPrefs else {
            return fail("E7", "ChatProviderPrefs UserDefaults round-trip mismatch")
        }

        let prevShowChat = PanelLayout.shared.showAgentChat
        PanelLayout.shared.showAgentChat.toggle()
        guard PanelLayout.shared.showAgentChat != prevShowChat else {
            return fail("E7", "PanelLayout.showAgentChat did not toggle")
        }
        PanelLayout.shared.showAgentChat = prevShowChat

        let hosts: [(String, NSView, CGSize)] = [
            ("AgentChatPanel", NSHostingView(rootView: AgentChatPanel(model: model)), CGSize(width: 360, height: 580)),
            ("SettingsView", NSHostingView(rootView: SettingsView(model: model)), CGSize(width: 760, height: 660)),
            ("SkillsSettingsView", NSHostingView(rootView: SkillsSettingsView()), CGSize(width: 680, height: 560)),
            ("PluginsSettingsView", NSHostingView(rootView: PluginsSettingsView()), CGSize(width: 680, height: 560)),
            ("IntegrationsSettingsView", NSHostingView(rootView: IntegrationsSettingsView()), CGSize(width: 680, height: 560)),
            ("StockLibraryView", NSHostingView(rootView: StockLibraryView(model: model)), CGSize(width: 260, height: 420)),
        ]
        for (name, view, sz) in hosts {
            view.frame = NSRect(origin: .zero, size: sz)
            view.layoutSubtreeIfNeeded()
            let fit = view.fittingSize
            guard fit.width > 0 && fit.height > 0 else {
                return fail("E7", "\(name) produced empty fittingSize \(fit)")
            }
        }
        log("PASS [E7] Native Hybrid UI NSHostingView smoke + prefs round-trip verified")
        log("ALL 7 EXTENSION CHECKS PASSED")
        return true
    }
}
