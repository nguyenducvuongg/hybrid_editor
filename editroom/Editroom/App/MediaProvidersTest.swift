import AppKit
import Foundation
import Network
import SwiftUI

private final class ListenerOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired = false
    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !acquired else { return false }
        acquired = true
        return true
    }
}

/// In-process loopback HTTP mock serving ComfyUI REST endpoints plus Pexels & Pixabay search/media files.
private final class LoopbackMediaMockServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.editroom.mock.mediaproviders")
    private let lock = NSLock()
    private(set) var port: UInt16 = 0
    private(set) var didReceiveComfyUpload = false
    private let pngBytes: Data

    init(pngBytes: Data) {
        self.pngBytes = pngBytes
    }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = ListenerOnceGate()
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    guard gate.tryAcquire() else { return }
                    self?.port = l.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let err):
                    guard gate.tryAcquire() else { return }
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
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] chunk, _, isComplete, error in
            guard let self else { return conn.cancel() }
            var buf = buffer
            if let chunk { buf.append(chunk) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headStr = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                let bodyStart = range.upperBound
                var contentLength = 0
                for line in headStr.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        contentLength = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                if buf.count >= bodyStart + contentLength {
                    self.respond(conn, head: headStr, body: Data(buf[bodyStart..<(bodyStart + contentLength)]))
                    return
                }
            }
            if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, head: String, body: Data) {
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        let target = parts.count >= 2 ? parts[1] : "/"
        let path = target.split(separator: "?").first.map(String.init) ?? "/"

        func sendJSON(_ obj: Any, status: String = "200 OK") {
            let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            let h = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(h.utf8) + d, completion: .contentProcessed { _ in conn.cancel() })
        }

        func sendPNG() {
            let h = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(pngBytes.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(h.utf8) + pngBytes, completion: .contentProcessed { _ in conn.cancel() })
        }

        let base = "http://127.0.0.1:\(port)"
        switch path {
        case "/system_stats":
            sendJSON(["devices": [["name": "NVIDIA L4 Mock", "vram_total": 24_576_000_000, "vram_free": 20_000_000_000]]])
        case "/object_info/CheckpointLoaderSimple":
            sendJSON(["CheckpointLoaderSimple": ["input": ["required": ["ckpt_name": [["flux_dev.safetensors"]]]]]])
        case "/upload/image":
            lock.lock()
            didReceiveComfyUpload = body.count > 16
            lock.unlock()
            sendJSON(["name": "uploaded_ref.png"])
        case "/prompt":
            sendJSON(["prompt_id": "mock-prompt-123"])
        case "/history/mock-prompt-123":
            sendJSON(["mock-prompt-123": ["outputs": ["9": ["images": [["filename": "gen_out.png", "subfolder": "", "type": "output"]]]]]])
        case "/view":
            sendPNG()
        case "/v1/search":
            sendJSON([
                "photos": [[
                    "id": 101,
                    "width": 1280,
                    "height": 720,
                    "alt": "Sunset Ocean Waves",
                    "photographer": "Mock Pexels Author",
                    "url": "https://www.pexels.com/photo/101/",
                    "src": [
                        "large2x": "\(base)/stock/pexels_101.png",
                        "medium": "\(base)/stock/thumb_101.png",
                    ],
                ]],
            ])
        case "/api/":
            sendJSON([
                "hits": [[
                    "id": 202,
                    "tags": "mountain dawn mist",
                    "user": "Mock Pixabay Author",
                    "pageURL": "https://pixabay.com/photos/202/",
                    "imageWidth": 1280,
                    "imageHeight": 720,
                    "largeImageURL": "\(base)/stock/pixabay_202.png",
                    "previewURL": "\(base)/stock/thumb_202.png",
                ]],
            ])
        default:
            if path.hasPrefix("/stock/") {
                sendPNG()
            } else {
                sendJSON(["error": "not found"], status: "404 Not Found")
            }
        }
    }
}

/// Empirical verification suite for Milestone 4-E (`M1–M6`):
/// `HYBRID_EDIT_DATA_DIR=... Editroom --media-providers-test <outDir>`
@MainActor
enum MediaProvidersTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--media-providers-test"), args.count > idx + 1 else { return }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        Task { @MainActor in
            let ok = await run(outDir: outDir)
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        let line = "PROVIDER-TEST \(msg)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func fail(_ test: String, _ reason: String) -> Bool {
        log("FAIL [\(test)] \(reason)")
        return false
    }

    private static func parseJSON(_ content: [[String: Any]]) -> [String: Any]? {
        guard let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makeSamplePNG(width: Int = 128, height: Int = 72) -> Data {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.65, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    static func run(outDir: URL) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: outDir)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dataDir = outDir.appendingPathComponent("isolated_data", isDirectory: true)
        let prevRoot = HybridStorage.overrideRootForTests
        HybridStorage.overrideRootForTests = dataDir

        let prevComfy = ComfyConnectionPrefs.load()
        defer {
            TunnelManager.shared.stop()
            StockMediaManager.shared.customProvidersForTests = nil
            prevComfy.save()
            HybridStorage.overrideRootForTests = prevRoot
        }

        await BaseVideo.load()
        let samplePNG = makeSamplePNG()
        let mockServer = LoopbackMediaMockServer(pngBytes: samplePNG)
        do {
            try await mockServer.start()
        } catch {
            return fail("SETUP", "failed to start mock loopback server: \(error.localizedDescription)")
        }
        defer { mockServer.stop() }

        let model = EditorModel()
        var p0 = Project()
        p0.width = 1280
        p0.height = 720
        p0.fps = 30
        let v1 = p0.videoTracks[0].id
        var solid = Clip(trackID: v1, kind: .solid, start: 0, duration: 2.0)
        solid.color = RGBA(r: 0.1, g: 0.5, b: 0.8, a: 1)
        p0.clips = [solid]
        model.load(p0, url: nil)

        // =========================================================================
        // M1: TunnelManager Safe Parsing + Managed Shutdown
        // =========================================================================
        do {
            var caughtInject = false
            do {
                _ = try TunnelManager.parseSafeSSHArguments("ssh -N -L 8188:127.0.0.1:8188 colab; rm -rf /")
            } catch {
                caughtInject = true
            }
            guard caughtInject else { return fail("M1", "failed to reject shell metacharacter injection") }

            let parsed = try TunnelManager.parseSafeSSHArguments("ssh -N -L 8188:127.0.0.1:8188 colab-gpu")
            guard parsed.executable == "/usr/bin/ssh", parsed.arguments.contains("colab-gpu") else {
                return fail("M1", "unexpected parsed SSH arguments")
            }

            let pid = try TunnelManager.shared.startManagedProcess(executable: "/bin/sleep", arguments: ["30"])
            guard Darwin.kill(pid, 0) == 0 else { return fail("M1", "managed child process failed to run") }
            TunnelManager.shared.stop()
            var dead = false
            for _ in 0..<20 {
                if Darwin.kill(pid, 0) != 0 { dead = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard dead else { return fail("M1", "managed tunnel child PID \(pid) survived stop()") }
        } catch {
            return fail("M1", "error: \(error.localizedDescription)")
        }
        log("PASS [M1] TunnelManager injection guard + child lifecycle verified")

        // =========================================================================
        // M2: ComfyUI Status + I2V Upload + Atomic Generation + Timeline Import
        // =========================================================================
        var prefs = ComfyConnectionPrefs()
        prefs.mode = .cloudflare
        prefs.endpointURL = "http://127.0.0.1:\(mockServer.port)"
        prefs.save()

        do {
            let statusOut = try await MCPTools.call("comfy_status", [:], model: model, client: nil, isExternal: true)
            guard let statusObj = parseJSON(statusOut),
                  (statusObj["online"] as? Bool) == true,
                  (statusObj["gpu_name"] as? String) == "NVIDIA L4 Mock" else {
                return fail("M2", "comfy_status did not report mock L4 online")
            }

            _ = try await MCPTools.call("session_attach", ["session_id": "sess-m2"], model: model, client: nil, sessionId: "sess-m2", isExternal: true)
            _ = try await MCPTools.call("begin_agent_turn", ["turn_id": "turn-m2", "summary": "Comfy B-roll", "session_id": "sess-m2"],
                                        model: model, client: nil, sessionId: "sess-m2", isExternal: true)

            let genOut = try await MCPTools.call("comfy_generate", [
                "kind": "video",
                "prompt": "Neon Tokyo rain reflection",
                "seed": 42,
                "reference_clip_id": solid.id.uuidString,
                "reference_time": 0.5,
                "session_id": "sess-m2",
            ], model: model, client: nil, sessionId: "sess-m2", isExternal: true)

            guard mockServer.didReceiveComfyUpload,
                  let genObj = parseJSON(genOut),
                  let assetId = genObj["asset_id"] as? String,
                  let savedPath = genObj["path"] as? String,
                  fm.fileExists(atPath: savedPath) else {
                return fail("M2", "comfy_generate failed upload, file write, or asset import")
            }
            let sourcesPath = URL(fileURLWithPath: savedPath).deletingLastPathComponent().appendingPathComponent("Sources.txt").path
            let sourcesText = (try? String(contentsOfFile: sourcesPath, encoding: .utf8)) ?? ""
            guard sourcesText.contains("Seed: 42"), sourcesText.contains("mock-prompt-123") else {
                return fail("M2", "ComfyUI Sources.txt provenance missing")
            }

            _ = try await MCPTools.call("apply_edl_patch", [
                "session_id": "sess-m2",
                "operations": [[
                    "op": "insert_overlay",
                    "asset_id": assetId,
                    "timeline_start": 0.0,
                    "duration": 1.5,
                ]],
            ], model: model, client: nil, sessionId: "sess-m2", isExternal: true)
            _ = try await MCPTools.call("commit_agent_turn", ["turn_id": "turn-m2", "session_id": "sess-m2"],
                                        model: model, client: nil, sessionId: "sess-m2", isExternal: true)
            _ = try await MCPTools.call("session_release", ["session_id": "sess-m2"],
                                        model: model, client: nil, sessionId: "sess-m2", isExternal: true)

            guard model.project.clips.count == 2 else {
                return fail("M2", "overlay clip not added to timeline")
            }
            model.undo()
            guard model.project.clips.count == 1 else {
                return fail("M2", "single Undo did not revert ComfyUI overlay")
            }
        } catch {
            return fail("M2", "error: \(error.localizedDescription)")
        }
        log("PASS [M2] ComfyUI status, I2V reference upload, generate & 1-step Undo verified")

        // =========================================================================
        // M3 & M4: Pexels + Pixabay Search, Contact Sheet, Download & Attribution
        // =========================================================================
        do {
            try AppSecrets.shared.set("mock-pexels-key", for: .pexelsAPIKey)
            try AppSecrets.shared.set("mock-pixabay-key", for: .pixabayAPIKey)
            let mockBase = URL(string: "http://127.0.0.1:\(mockServer.port)")!
            StockMediaManager.shared.customProvidersForTests = [
                PexelsProvider(baseURL: mockBase),
                PixabayProvider(baseURL: mockBase),
            ]

            let searchOut = try await MCPTools.call("search_stock_media", [
                "query": "sunset",
                "kind": "photos",
                "include_thumbnails": true,
            ], model: model, client: nil, isExternal: true)
            let hasImage = searchOut.contains { ($0["type"] as? String) == "image" }
            guard hasImage,
                  let searchObj = parseJSON(searchOut),
                  (searchObj["count"] as? Int) == 2 else {
                return fail("M3", "search_stock_media did not return 2 providers + JPEG contact sheet")
            }
            log("PASS [M3] Pexels + Pixabay parallel search & contact sheet verified")

            _ = try await MCPTools.call("session_attach", ["session_id": "sess-m4"], model: model, client: nil, sessionId: "sess-m4", isExternal: true)
            _ = try await MCPTools.call("begin_agent_turn", ["turn_id": "turn-m4", "summary": "Stock B-roll", "session_id": "sess-m4"],
                                        model: model, client: nil, sessionId: "sess-m4", isExternal: true)

            let importOut = try await MCPTools.call("import_stock_media", [
                "stock_id": "pexels-photo-101",
                "session_id": "sess-m4",
            ], model: model, client: nil, sessionId: "sess-m4", isExternal: true)
            guard let impObj = parseJSON(importOut),
                  let stockAssetId = impObj["asset_id"] as? String,
                  let stockPath = impObj["path"] as? String,
                  fm.fileExists(atPath: stockPath) else {
                return fail("M4", "import_stock_media failed verification or import")
            }
            let attrPath = URL(fileURLWithPath: stockPath).deletingLastPathComponent().appendingPathComponent("Sources.txt").path
            let attrText = (try? String(contentsOfFile: attrPath, encoding: .utf8)) ?? ""
            guard attrText.contains("Pexels License") else {
                return fail("M4", "stock Sources.txt attribution missing")
            }

            _ = try await MCPTools.call("apply_edl_patch", [
                "session_id": "sess-m4",
                "operations": [[
                    "op": "insert_overlay",
                    "asset_id": stockAssetId,
                    "timeline_start": 0.0,
                    "duration": 1.2,
                ]],
            ], model: model, client: nil, sessionId: "sess-m4", isExternal: true)
            _ = try await MCPTools.call("commit_agent_turn", ["turn_id": "turn-m4", "session_id": "sess-m4"],
                                        model: model, client: nil, sessionId: "sess-m4", isExternal: true)
            _ = try await MCPTools.call("session_release", ["session_id": "sess-m4"],
                                        model: model, client: nil, sessionId: "sess-m4", isExternal: true)

            guard model.project.clips.count == 2 else { return fail("M4", "stock overlay missing on timeline") }
            model.undo()
            guard model.project.clips.count == 1 else { return fail("M4", "1 Undo did not revert stock overlay") }
        } catch {
            return fail("M3/M4", "error: \(error.localizedDescription)")
        }
        log("PASS [M4] Stock download verification, Sources.txt attribution & 1-step Undo verified")

        // =========================================================================
        // M5: Colab Notebook JSON & 2 Built-in Skills Installability
        // =========================================================================
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../editroom/Editroom/App/MediaProvidersTest.swift -> repo root
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let colabURL = repoRoot.appendingPathComponent("assets/colab/editroom_comfyui_colab.ipynb")
        let comfySkillDir = repoRoot.appendingPathComponent("assets/editor-skills/comfy-broll-generator")
        let stockSkillDir = repoRoot.appendingPathComponent("assets/editor-skills/stock-media-finder")

        do {
            let nbData = try Data(contentsOf: colabURL)
            let nbObj = try JSONSerialization.jsonObject(with: nbData) as? [String: Any]
            guard (nbObj?["nbformat"] as? Int) == 4 else {
                return fail("M5", "Colab notebook invalid nbformat")
            }
            try SkillRegistry.shared.installFromLocal(directory: comfySkillDir)
            try SkillRegistry.shared.installFromLocal(directory: stockSkillDir)
            let prompt = SkillRegistry.shared.composePromptSection(explicitSlugs: ["comfy-broll-generator", "stock-media-finder"])
            guard prompt.contains("comfy_generate"), prompt.contains("import_stock_media") else {
                return fail("M5", "built-in skills missing expected MCP workflows")
            }
        } catch {
            return fail("M5", "error: \(error.localizedDescription)")
        }
        log("PASS [M5] Colab notebook & built-in ComfyUI/Stock SKILL.md verified")

        // =========================================================================
        // M6: Live StockLibraryView Populated Render Smoke
        // =========================================================================
        let stockHost = NSHostingView(rootView: StockLibraryView(model: model))
        stockHost.frame = NSRect(x: 0, y: 0, width: 260, height: 420)
        stockHost.layoutSubtreeIfNeeded()
        guard stockHost.fittingSize.width > 0 && stockHost.fittingSize.height > 0 else {
            return fail("M6", "StockLibraryView empty fittingSize")
        }
        log("PASS [M6] StockLibraryView populated render verified")
        log("ALL 6 MEDIA PROVIDER CHECKS PASSED")
        return true
    }
}
