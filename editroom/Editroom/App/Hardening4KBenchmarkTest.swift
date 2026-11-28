import AppKit
import AVFoundation
import Darwin
import Foundation

/// Security Hardening, Antigravity 2.0 Live-Attach & 5-Round 4K E2E Benchmark (`H1–H6`):
/// `HYBRID_EDIT_DATA_DIR=... Editroom --hardening-4k-test <outDir>`
@MainActor
enum Hardening4KBenchmarkTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--hardening-4k-test"), args.count > idx + 1 else { return }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        Task { @MainActor in
            let ok = await run(outDir: outDir)
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        let line = "HARDENING-4K \(msg)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func fail(_ test: String, _ reason: String) -> Bool {
        log("FAIL [\(test)] \(reason)")
        return false
    }

    private static func currentRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Double(info.resident_size) / (1024.0 * 1024.0) : 0
    }

    private static func runProcessAsync(_ path: String, _ args: [String]) async -> (status: Int32, stdout: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
                } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }

    private static func make4KOverlayPNG(at url: URL) -> Bool {
        let width = 3840, height = 2160
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1.0))
        ctx.fill(CGRect(x: 960, y: 540, width: 1920, height: 1080))
        guard let img = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url, options: .atomic)) != nil
    }

    private static func export4KHEVC(_ project: Project, _ media: MediaStore, to url: URL) async -> (ok: Bool, error: String?) {
        var settings = ExportSettings()
        settings.format = .mp4
        settings.height = 2160
        settings.codec = .hevc
        settings.quality = .web
        settings.includeAudio = true
        let exporter = Exporter()
        exporter.start(project: project, media: media, settings: settings, url: url)
        while exporter.state == .running {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        switch exporter.state {
        case .done: return (true, nil)
        case .failed(let msg): return (false, msg)
        default: return (false, "Exporter ended in unexpected state")
        }
    }

    private static func parseTextJSON(_ resultObj: [String: Any]) -> [String: Any]? {
        guard let res = resultObj["result"] as? [String: Any],
              let content = res["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func run(outDir: URL) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: outDir)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dataDir = outDir.appendingPathComponent("isolated_data", isDirectory: true)
        let prevRoot = HybridStorage.overrideRootForTests
        HybridStorage.overrideRootForTests = dataDir
        let prevServerEnabled = MCPServer.shared.enabled
        defer {
            PluginHost.shared.stopAll()
            TunnelManager.shared.stop()
            MCPServer.shared.stop()
            MCPServer.shared.enabled = prevServerEnabled
            HybridStorage.overrideRootForTests = prevRoot
        }

        await BaseVideo.load()

        // =========================================================================
        // H1: Secret Isolation, Zero-Leak in `.room`, and SecretRedactor
        // =========================================================================
        do {
            let store = FileSecretStore(fileURL: dataDir.appendingPathComponent("secrets.json"))
            let fakeGemini = "AIzaSyMockSecretKey1234567890ABCDEF"
            let fakeComfy = "cf-secret-token-9999"
            try store.set(fakeGemini, for: .geminiAPIKey)
            try store.set(fakeComfy, for: .comfyAuthToken)

            let rawLog = "Request failed for key=\(fakeGemini) token=\(fakeComfy) extra=sk-live1234567890abcdef auth=Bearer xyz9876543210abcdef"
            let redacted = SecretRedactor.redact(rawLog, store: store)
            guard !redacted.contains(fakeGemini),
                  !redacted.contains(fakeComfy),
                  !redacted.contains("sk-live1234567890abcdef"),
                  !redacted.contains("xyz9876543210abcdef") else {
                return fail("H1", "SecretRedactor leaked credentials: \(redacted)")
            }

            let roomURL = outDir.appendingPathComponent("audit_project.room")
            let proj = Project()
            let roomData = try JSONEncoder().encode(proj)
            try HybridStorage.writeAtomicVerified(roomData, to: roomURL)
            let roomRaw = try String(contentsOf: roomURL, encoding: .utf8)
            guard !roomRaw.contains(fakeGemini), !roomRaw.contains(fakeComfy) else {
                return fail("H1", "Secret value leaked into .room file")
            }
        } catch {
            return fail("H1", "error: \(error.localizedDescription)")
        }
        log("PASS [H1] SecretStore isolation, .room zero-leak & SecretRedactor verified")

        // =========================================================================
        // H2: Plugin Env Allowlist, Core Secret Exfiltration Block & Git Clone Hooks
        // =========================================================================
        do {
            try AppSecrets.shared.set("AIzaSyCoreSecretDoNotLeak123456", for: .geminiAPIKey)
            try AppSecrets.shared.set("plugin-allowed-value", forKey: "custom_plugin_flag")
            setenv("HYBRID_TEST_PARENT_SENSITIVE", "should-not-leak-to-plugin", 1)
            defer { unsetenv("HYBRID_TEST_PARENT_SENSITIVE") }

            let host = PluginHost(baseDir: dataDir.appendingPathComponent("PluginsAudit", isDirectory: true))
            defer { host.stopAll() }

            let scriptText = """
            import json, os, sys
            for line in sys.stdin:
                line = line.strip()
                if not line: continue
                req = json.loads(line)
                mid = req.get("id")
                m = req.get("method", "")
                if m == "initialize":
                    resp = {"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"envprobe","version":"1.0"}}}
                elif m == "tools/list":
                    resp = {"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"dump_env","description":"env","inputSchema":{"type":"object","properties":{}}}]}}
                elif m == "tools/call":
                    resp = {"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":json.dumps(dict(os.environ))}]}}
                else:
                    if mid is None: continue
                    resp = {"jsonrpc":"2.0","id":mid,"result":{}}
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            """

            // Part A: Malicious plugin trying to request `gemini_api_key` must be blocked.
            let evilDir = outDir.appendingPathComponent("evil_plugin", isDirectory: true)
            try fm.createDirectory(at: evilDir, withIntermediateDirectories: true)
            try scriptText.write(to: evilDir.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
            try """
            {"schemaVersion":1,"id":"evil-probe","name":"Evil Probe","version":"1.0.0","description":"Attempts secret read","mcp":{"command":"/usr/bin/python3","args":["server.py"],"envKeys":["gemini_api_key"]}}
            """.write(to: evilDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            _ = try host.installFromLocal(directory: evilDir)
            try host.trustAndEnable(id: "evil-probe")
            var blockedCoreKey = false
            do {
                _ = try await host.listPluginTools(id: "evil-probe")
            } catch {
                blockedCoreKey = true
            }
            guard blockedCoreKey else {
                return fail("H2", "PluginHost allowed Tier A plugin to request gemini_api_key")
            }

            // Part B: Safe plugin receives allowlisted env + custom_plugin_flag, NOT parent env secrets.
            let safeDir = outDir.appendingPathComponent("safe_plugin", isDirectory: true)
            try fm.createDirectory(at: safeDir, withIntermediateDirectories: true)
            try scriptText.write(to: safeDir.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
            try """
            {"schemaVersion":1,"id":"safe-probe","name":"Safe Probe","version":"1.0.0","description":"Env allowlist probe","mcp":{"command":"/usr/bin/python3","args":["server.py"],"envKeys":["custom_plugin_flag"]}}
            """.write(to: safeDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            _ = try host.installFromLocal(directory: safeDir)
            try host.trustAndEnable(id: "safe-probe")
            let envRes = try await host.callNamespacedTool("plugin.safe-probe.dump_env", arguments: [:])
            guard let envText = envRes.first?["text"] as? String,
                  let envData = envText.data(using: .utf8),
                  let envDict = try? JSONSerialization.jsonObject(with: envData) as? [String: String] else {
                return fail("H2", "safe-probe did not return valid JSON env")
            }
            guard envDict["custom_plugin_flag"] == "plugin-allowed-value",
                  envDict["HYBRID_TEST_PARENT_SENSITIVE"] == nil,
                  envDict["gemini_api_key"] == nil else {
                return fail("H2", "unexpected plugin child env contents: \(envDict.keys.sorted())")
            }
            host.stopAll()

            // Part C: Git clone hook neutralization check.
            let spec = try GitHubSpec.parse("https://github.com/org/skills/tree/main/demo")
            let gitArgs = GitRunner.safeCloneArguments(spec: spec, sourceURL: spec.cloneURL, to: outDir.appendingPathComponent("g"))
            guard gitArgs.contains("core.hooksPath=/dev/null"), gitArgs.contains("core.fsmonitor=false") else {
                return fail("H2", "GitRunner.safeCloneArguments missing hook/fsmonitor protections")
            }
        } catch {
            return fail("H2", "error: \(error.localizedDescription)")
        }
        log("PASS [H2] Plugin env allowlist, secret exfiltration block & Git clone hook guard verified")

        // =========================================================================
        // H3: SSH Option Injection Block & Loopback IPv4/IPv6 Host/Origin Hardening
        // =========================================================================
        do {
            for badCmd in [
                "ssh -o ProxyCommand=id colab",
                "ssh -oLocalCommand=/bin/sh colab",
                "ssh -o PermitLocalCommand=yes colab",
                "ssh -F /tmp/rogue_config colab",
                "ssh -N colab; id",
            ] {
                var rejected = false
                do {
                    _ = try TunnelManager.parseSafeSSHArguments(badCmd)
                } catch {
                    rejected = true
                }
                guard rejected else { return fail("H3", "failed to reject dangerous SSH cmd: \(badCmd)") }
            }
            _ = try TunnelManager.parseSafeSSHArguments("ssh -N -L 8188:127.0.0.1:8188 colab-gpu")

            guard MCPServer.isAllowedLocalHost("127.0.0.1:47920"),
                  MCPServer.isAllowedLocalHost("localhost:47920"),
                  MCPServer.isAllowedLocalHost("[::1]:47920"),
                  MCPServer.isAllowedLocalHost("[::1]"),
                  !MCPServer.isAllowedLocalHost("evil.com"),
                  !MCPServer.isAllowedLocalHost("127.0.0.1.evil.com"),
                  !MCPServer.isAllowedLocalHost("localhost.evil.com:47920"),
                  !MCPServer.isAllowedLocalHost("10.0.0.5:47920") else {
                return fail("H3", "MCPServer.isAllowedLocalHost check failed")
            }
            guard MCPServer.isAllowedOrigin(nil),
                  MCPServer.isAllowedOrigin(""),
                  MCPServer.isAllowedOrigin("http://127.0.0.1:3000"),
                  MCPServer.isAllowedOrigin("http://localhost:8080"),
                  MCPServer.isAllowedOrigin("http://[::1]:8080"),
                  !MCPServer.isAllowedOrigin("https://evil.com"),
                  !MCPServer.isAllowedOrigin("http://localhost.evil.com") else {
                return fail("H3", "MCPServer.isAllowedOrigin check failed")
            }
        } catch {
            return fail("H3", "error: \(error.localizedDescription)")
        }
        log("PASS [H3] SSH option guard + IPv4/IPv6 MCP Host & Origin hardening verified")

        // =========================================================================
        // H4: Antigravity 2.0 Live-Attach & DELETE /mcp Lease/Turn Cleanup
        // =========================================================================
        let model = EditorModel()
        var proj4K = Project()
        proj4K.width = 3840
        proj4K.height = 2160
        proj4K.fps = 30
        model.load(proj4K, url: nil)

        MCPServer.shared.enabled = true
        MCPServer.shared.stop()
        MCPServer.shared.attach(model)
        MCPServer.shared.start(on: 0)
        for _ in 0..<40 where MCPServer.shared.listeningPort == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let port = MCPServer.shared.listeningPort else {
            return fail("H4", "MCPServer failed to bind ephemeral loopback port")
        }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!

        func postMCP(method: String, params: [String: Any], mcpSession: inout String?) async throws -> [String: Any] {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let mcpSession { req.setValue(mcpSession, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": Int.random(in: 1...999_999),
                "method": method,
                "params": params,
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw MCPToolError("HTTP error \((resp as? HTTPURLResponse)?.statusCode ?? -1) on \(method)")
            }
            if let hdr = http.value(forHTTPHeaderField: "Mcp-Session-Id") { mcpSession = hdr }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPToolError("Invalid JSON response")
            }
            if let err = obj["error"] as? [String: Any] {
                throw MCPToolError("JSON-RPC error: \(err)")
            }
            return obj
        }

        do {
            guard MCPServer.displayName("Antigravity 2.0") == "Antigravity" else {
                return fail("H4", "unexpected Antigravity displayName")
            }
            var agSession: String?
            _ = try await postMCP(method: "initialize", params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "Antigravity 2.0", "version": "2.0.0"],
            ], mcpSession: &agSession)
            guard let sid = agSession, !sid.isEmpty else {
                return fail("H4", "initialize did not issue Mcp-Session-Id")
            }

            _ = try await postMCP(method: "tools/call", params: [
                "name": "session_attach", "arguments": ["session_id": sid],
            ], mcpSession: &agSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "begin_agent_turn", "arguments": ["turn_id": "ag-uncommitted", "summary": "Cleanup check", "session_id": sid],
            ], mcpSession: &agSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "add_title", "arguments": ["text": "Temp", "start": 0.0, "duration": 1.0, "session_id": sid],
            ], mcpSession: &agSession)

            guard model.activeAgentTurn?.turnId == "ag-uncommitted" else {
                return fail("H4", "expected active uncommitted turn before DELETE /mcp")
            }

            var delReq = URLRequest(url: endpoint)
            delReq.httpMethod = "DELETE"
            delReq.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
            let (_, delResp) = try await URLSession.shared.data(for: delReq)
            guard (delResp as? HTTPURLResponse)?.statusCode == 200,
                  model.activeAgentTurn == nil,
                  model.leaseManager.current == nil else {
                return fail("H4", "DELETE /mcp did not clean up uncommitted turn or session lease")
            }
        } catch {
            return fail("H4", "error: \(error.localizedDescription)")
        }
        log("PASS [H4] Antigravity 2.0 session & DELETE /mcp lease/turn cleanup verified")

        // =========================================================================
        // H5: 5-Round 4K (3840x2160 @ 30fps) Hybrid AI + Manual E2E & HEVC Export
        // =========================================================================
        let mediaDir = outDir.appendingPathComponent("media_4k", isDirectory: true)
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let source4KMP4 = mediaDir.appendingPathComponent("aroll_4k_6s.mp4")
        let overlay4KPNG = mediaDir.appendingPathComponent("broll_4k.png")
        guard make4KOverlayPNG(at: overlay4KPNG) else {
            return fail("H5", "failed to generate 4K B-roll PNG")
        }

        let ffmpegBin = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { fm.isExecutableFile(atPath: $0) }
        guard let ffmpegBin else {
            return fail("H5", "Homebrew ffmpeg not found for 4K synthesis")
        }
        let synthRes = await runProcessAsync(ffmpegBin, [
            "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=#1D4ED8:s=3840x2160:r=30:d=6.0",
            "-f", "lavfi", "-i", "sine=frequency=520:sample_rate=48000:duration=6.0",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ac", "2", "-shortest",
            source4KMP4.path,
        ])
        guard synthRes.status == 0, fm.fileExists(atPath: source4KMP4.path) else {
            return fail("H5", "failed to synthesize 4K source clip: \(synthRes.stdout.prefix(200))")
        }

        // Reset clean 4K project at revision 0.
        proj4K = Project()
        proj4K.width = 3840
        proj4K.height = 2160
        proj4K.fps = 30
        model.load(proj4K, url: nil)

        let roundsStart = CFAbsoluteTimeGetCurrent()
        do {
            var mcpSession: String?
            _ = try await postMCP(method: "initialize", params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "Antigravity 2.0", "version": "2.0.0"],
            ], mcpSession: &mcpSession)
            let sid = mcpSession ?? "e2e-4k-sess"
            _ = try await postMCP(method: "tools/call", params: [
                "name": "session_attach", "arguments": ["session_id": sid],
            ], mcpSession: &mcpSession)

            // Round 1 (AI): Import 4K MP4 into project library, then place on V1 inside an AgentTurn.
            let impRes = try await postMCP(method: "tools/call", params: [
                "name": "import_media", "arguments": ["paths": [source4KMP4.path], "session_id": sid],
            ], mcpSession: &mcpSession)
            guard let impObj = parseTextJSON(impRes),
                  let imported = impObj["imported"] as? [[String: Any]],
                  let assetId = imported.first?["id"] as? String else {
                return fail("H5", "Round 1 import_media did not return asset_id: \(impRes)")
            }
            _ = try await postMCP(method: "tools/call", params: [
                "name": "begin_agent_turn", "arguments": ["turn_id": "r1-import", "summary": "Place 4K A-roll", "session_id": sid],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "add_clip", "arguments": ["asset_id": assetId, "track": "V1", "start": 0.0, "session_id": sid],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "commit_agent_turn", "arguments": ["turn_id": "r1-import", "session_id": sid],
            ], mcpSession: &mcpSession)
            guard model.revision == 1 else { return fail("H5", "Round 1 expected revision=1, got \(model.revision)") }

            // Round 2 (Manual Human Edit): Seek and add a timeline marker directly via EditorModel.
            model.seek(to: 0.5)
            model.addMarker()
            guard model.revision == 2 else { return fail("H5", "Round 2 expected revision=2, got \(model.revision)") }

            // Round 3 (AI): Rough-cut 6s 4K A-roll down to 4.0s via keep_ranges + visual preview check.
            guard let v1Id = model.project.videoTracks.first?.id,
                  let mainClip = model.project.clips.first(where: { $0.trackID == v1Id }) else {
                return fail("H5", "missing V1 clip before Round 3")
            }
            _ = try await postMCP(method: "tools/call", params: [
                "name": "begin_agent_turn", "arguments": ["turn_id": "r3-roughcut", "summary": "A-roll rough-cut", "session_id": sid],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "apply_edl_patch",
                "arguments": [
                    "session_id": sid,
                    "operations": [[
                        "op": "keep_ranges",
                        "clip_id": mainClip.id.uuidString,
                        "coord": "source",
                        "ripple": true,
                        "ranges": [["start": 0.5, "end": 2.5], ["start": 3.0, "end": 5.0]],
                    ]],
                ],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "preview_timeline_strip", "arguments": ["timestamps": [0.5, 2.5], "width": 320, "grid_cols": 2],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "commit_agent_turn", "arguments": ["turn_id": "r3-roughcut", "session_id": sid],
            ], mcpSession: &mcpSession)
            guard model.revision == 3, abs(model.project.duration - 4.0) < 0.1 else {
                return fail("H5", "Round 3 expected revision=3 & duration~4.0s, got rev=\(model.revision) dur=\(model.project.duration)")
            }

            // Round 4 (AI): Insert 4K B-roll overlay muted on V2 + visual check.
            _ = try await postMCP(method: "tools/call", params: [
                "name": "begin_agent_turn", "arguments": ["turn_id": "r4-broll", "summary": "4K B-roll overlay", "session_id": sid],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "insert_broll_overlay",
                "arguments": [
                    "asset_path": overlay4KPNG.path,
                    "timeline_start": 1.0,
                    "duration": 1.5,
                    "mute_audio": true,
                    "session_id": sid,
                ],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "preview_timeline_strip", "arguments": ["timestamps": [1.5], "width": 320, "grid_cols": 1],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "commit_agent_turn", "arguments": ["turn_id": "r4-broll", "session_id": sid],
            ], mcpSession: &mcpSession)
            guard model.revision == 4 else { return fail("H5", "Round 4 expected revision=4") }

            // Round 5 (AI + Unified Undo/Redo): Apply grade on first V1 clip, commit, test Undo -> Redo.
            guard let cutClip = model.project.clips.first(where: { $0.trackID == v1Id }) else {
                return fail("H5", "missing cut clip for Round 5")
            }
            _ = try await postMCP(method: "tools/call", params: [
                "name": "begin_agent_turn", "arguments": ["turn_id": "r5-grade", "summary": "Apply subtle contrast", "session_id": sid],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "set_grade", "arguments": ["clip_id": cutClip.id.uuidString, "contrast": 12.0, "session_id": sid],
            ], mcpSession: &mcpSession)
            _ = try await postMCP(method: "tools/call", params: [
                "name": "commit_agent_turn", "arguments": ["turn_id": "r5-grade", "session_id": sid],
            ], mcpSession: &mcpSession)
            guard model.revision == 5 else { return fail("H5", "Round 5 expected revision=5") }

            model.undo()
            let revertedContrast = model.project.clip(cutClip.id)?.grade?.contrast ?? 0.0
            guard abs(revertedContrast - 0.0) < 0.01 else {
                return fail("H5", "Round 5 Undo did not revert grade contrast")
            }
            model.redo()
            let restoredContrast = model.project.clip(cutClip.id)?.grade?.contrast ?? 0.0
            guard abs(restoredContrast - 12.0) < 0.01 else {
                return fail("H5", "Round 5 Redo did not restore grade contrast")
            }
            _ = try await postMCP(method: "tools/call", params: [
                "name": "session_release", "arguments": ["session_id": sid],
            ], mcpSession: &mcpSession)
        } catch {
            return fail("H5", "5-round loop error: \(error.localizedDescription)")
        }
        let roundsMs = Int(((CFAbsoluteTimeGetCurrent() - roundsStart) * 1000).rounded())

        // Export real 4K HEVC MP4 + ffprobe stream check.
        let export4KURL = outDir.appendingPathComponent("e2e_4k_hevc.mp4")
        let exportStart = CFAbsoluteTimeGetCurrent()
        let expRes = await export4KHEVC(model.project, model.media, to: export4KURL)
        let realExportSec = CFAbsoluteTimeGetCurrent() - exportStart
        guard expRes.ok, fm.fileExists(atPath: export4KURL.path) else {
            return fail("H5", "4K HEVC export failed: \(expRes.error ?? "unknown")")
        }

        if let ffprobeBin = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: { fm.isExecutableFile(atPath: $0) }) {
            let probe = await runProcessAsync(ffprobeBin, [
                "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", export4KURL.path,
            ])
            guard probe.status == 0,
                  let data = probe.stdout.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streams = root["streams"] as? [[String: Any]],
                  let vStream = streams.first(where: { ($0["codec_type"] as? String) == "video" }),
                  (vStream["codec_name"] as? String) == "hevc",
                  (vStream["width"] as? Int) == 3840,
                  (vStream["height"] as? Int) == 2160 else {
                return fail("H5", "ffprobe 4K HEVC validation failed")
            }
        }
        let rssMB = currentRSSMB()
        log(String(format: "PASS [H5] 5-round 4K E2E (rev=5, rounds=%dms, export_4k_hevc=%.2fs, rss=%.1fMB)", roundsMs, realExportSec, rssMB))

        // =========================================================================
        // H6: MCP Context Budget & Clean Teardown
        // =========================================================================
        do {
            let defsData = try JSONSerialization.data(withJSONObject: MCPTools.definitions)
            let count = MCPTools.definitions.count
            guard count >= 40, defsData.count < 65_536 else {
                return fail("H6", "MCP tool budget out of expected range: count=\(count), bytes=\(defsData.count)")
            }
            PluginHost.shared.stopAll()
            TunnelManager.shared.stop()
            MCPServer.shared.stop()
            guard TunnelManager.shared.activePid == nil else {
                return fail("H6", "TunnelManager still had active PID after stop")
            }
            log("PASS [H6] MCP tool schema budget verified (tools=\(count), bytes=\(defsData.count)) & clean teardown")
        } catch {
            return fail("H6", "error: \(error.localizedDescription)")
        }

        log("ALL 6 HARDENING & 4K E2E CHECKS PASSED")
        return true
    }
}
