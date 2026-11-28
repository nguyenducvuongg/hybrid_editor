import AppKit
import Foundation
import Network

private final class SmartOnceGate: @unchecked Sendable {
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

/// Loopback OpenAI-compatible mock VLM server for testing `LocalVLMVisionProvider` (`S4`).
private final class LoopbackVLMMockServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.editroom.mock.vlm")
    private let lock = NSLock()
    private(set) var port: UInt16 = 0
    private(set) var requestCount = 0

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = SmartOnceGate()
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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 2_097_152) { [weak self] chunk, _, isComplete, error in
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
                    self.respond(conn)
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

    private func respond(_ conn: NWConnection) {
        lock.lock()
        requestCount += 1
        lock.unlock()

        let innerJSON = #"{"description":"Ly cà phê sữa đá buổi sáng trên bàn gỗ","tags":["cà phê","buổi sáng","bàn gỗ"],"mood":"ấm áp"}"#
        let payload: [String: Any] = [
            "id": "mock-vlm-1",
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": innerJSON,
                ],
            ]],
        ]
        let d = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let h = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(h.utf8) + d, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Offline deterministic verification suite for Milestone 5-E (`S1–S6`):
/// `HYBRID_EDIT_DATA_DIR=... Editroom --smart-editing-test <outDir>`
@MainActor
enum SmartEditingTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--smart-editing-test"), args.count > idx + 1 else { return }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        Task { @MainActor in
            let ok = await run(outDir: outDir)
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        let line = "SMART-TEST \(msg)\n"
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

    private static func writeWAV(to url: URL, durationSec: Double, toneSpans: [(start: Double, end: Double)]) throws {
        let sampleRate = 16_000
        let totalSamples = Int((durationSec * Double(sampleRate)).rounded())
        var pcm = Data(capacity: totalSamples * 2)
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            let active = toneSpans.contains { t >= $0.start && t <= $0.end }
            let sample: Int16 = active ? Int16((sin(2.0 * .pi * 440.0 * t) * 16_000.0).rounded()) : 0
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        let header = AudioVAD.wavHeader(pcmByteCount: UInt32(pcm.count), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        var file = Data(capacity: 44 + pcm.count)
        file.append(header)
        file.append(pcm)
        try file.write(to: url, options: .atomic)
    }

    private static func writeMockWhisperCLI(at url: URL, markerURL: URL?, jsonBody: String) throws {
        let markerLine = markerURL.map { "touch \"\($0.path)\"" } ?? ""
        let script = """
        #!/bin/sh
        \(markerLine)
        OUT_PREFIX=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -of) OUT_PREFIX="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        cat > "${OUT_PREFIX}.json" <<'JSON'
        \(jsonBody)
        JSON
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func makeSamplePNG(width: Int = 256, height: Int = 144, red: CGFloat = 0.25) -> Data {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(red: red, green: 0.55, blue: 0.85, alpha: 1))
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

        let prevSpeech = SpeechPrefs.load()
        let prevVLM = VLMIndexPrefs.load()
        defer {
            prevSpeech.save()
            prevVLM.save()
            HybridStorage.overrideRootForTests = prevRoot
        }

        await BaseVideo.load()

        // =========================================================================
        // S1: P6 10-Second Pure Silence Hallucination Guard
        // =========================================================================
        let dummyModel = outDir.appendingPathComponent("ggml-large-v3-turbo.bin")
        try? Data("mock-ggml".utf8).write(to: dummyModel)
        let silentWav = outDir.appendingPathComponent("silence_10s.wav")
        let silentScript = outDir.appendingPathComponent("mock_whisper_silent.sh")
        let calledFlag = outDir.appendingPathComponent("whisper_silent_called.flag")
        do {
            try writeWAV(to: silentWav, durationSec: 10.0, toneSpans: [])
            try writeMockWhisperCLI(
                at: silentScript,
                markerURL: calledFlag,
                jsonBody: #"{"transcription":[{"offsets":{"from":0,"to":2500},"text":"Cảm ơn các bạn đã xem video"},{"offsets":{"from":2600,"to":5000},"text":"Hãy subscribe"}]}"#
            )
            let vad = try await AudioVAD.analyze(url: silentWav)
            guard vad.spans.isEmpty else {
                return fail("S1", "expected 0 VAD speech spans for 10s silence, got \(vad.spans.count)")
            }
            let whisper = WhisperCPPProvider(binaryURL: silentScript, modelURL: dummyModel)
            let transcript = try await whisper.transcribe(audioURL: silentWav, language: "vi")
            guard transcript.words.isEmpty else {
                return fail("S1", "P6 violation: expected 0 words on 10s silence, got \(transcript.words.count)")
            }
            guard !fm.fileExists(atPath: calledFlag.path) else {
                return fail("S1", "AudioVAD did not short-circuit before launching Whisper binary")
            }
        } catch {
            return fail("S1", "error: \(error.localizedDescription)")
        }
        log("PASS [S1] P6 10-second pure silence short-circuited with 0 hallucinations")

        // =========================================================================
        // S2: Vietnamese Whisper + VAD Filtering + transcribe_aroll Keep Ranges
        // =========================================================================
        let speechWav = outDir.appendingPathComponent("speech_vi_4s.wav")
        let speechScript = outDir.appendingPathComponent("mock_whisper_vi.sh")
        do {
            try writeWAV(to: speechWav, durationSec: 4.0, toneSpans: [(0.50, 1.40), (2.40, 3.40)])
            try writeMockWhisperCLI(
                at: speechScript,
                markerURL: nil,
                jsonBody: #"{"transcription":[{"offsets":{"from":520,"to":1380},"text":"Xin chào các bạn"},{"offsets":{"from":1680,"to":2120},"text":"Cảm ơn các bạn đã xem"},{"offsets":{"from":2420,"to":3380},"text":"Hôm nay trời rất đẹp"}]}"#
            )
            let sp = SpeechPrefs(
                preferWhisper: true,
                whisperBinaryPath: speechScript.path,
                whisperModelPath: dummyModel.path,
                whisperLanguage: "vi",
                vadThresholdDB: -42.0,
                minSilenceSec: 0.7
            )
            sp.save()

            let model = EditorModel()
            model.load(Project(), url: nil)
            let out = try await MCPTools.call("transcribe_aroll", [
                "path": speechWav.path,
                "language": "vi",
                "min_silence_sec": 0.7,
            ], model: model, client: nil, isExternal: false)
            guard let obj = parseJSON(out),
                  (obj["provider"] as? String) == "whisper.cpp",
                  let fullText = obj["text"] as? String,
                  let keep = obj["suggested_keep_ranges"] as? [[String: Any]] else {
                return fail("S2", "invalid transcribe_aroll response")
            }
            guard fullText.contains("chào"), fullText.contains("đẹp") else {
                return fail("S2", "Vietnamese UTF-8 diacritics missing in transcript: \(fullText)")
            }
            guard !fullText.localizedCaseInsensitiveContains("Cảm ơn") else {
                return fail("S2", "Silence-gap hallucination was not stripped: \(fullText)")
            }
            guard keep.count == 2 else {
                return fail("S2", "expected 2 suggested_keep_ranges splitting dead air, got \(keep.count)")
            }
        } catch {
            return fail("S2", "error: \(error.localizedDescription)")
        }
        log("PASS [S2] Vietnamese Whisper + VAD filtering + transcribe_aroll keep_ranges verified")

        // =========================================================================
        // S3: SQLite3 FTS5 B-Roll Index & Accented/Unaccented Vietnamese Search
        // =========================================================================
        let customDB = outDir.appendingPathComponent("broll_test.sqlite")
        do {
            var idx: BRollFTSIndex? = try BRollFTSIndex(databaseURL: customDB)
            try idx?.upsert([
                BRollSegment(assetPath: "/tmp/cafe.mp4", assetName: "cafe.mp4", startSec: 0, endSec: 5,
                             description: "Cà phê sáng trên đường phố Sài Gòn", tags: ["cà phê", "đường phố"], mood: "ấm áp"),
                BRollSegment(assetPath: "/tmp/beach.mp4", assetName: "beach.mp4", startSec: 2, endSec: 7,
                             description: "Hoàng hôn bãi biển Đà Nẵng", tags: ["biển", "hoàng hôn"], mood: "thư giãn"),
                BRollSegment(assetPath: "/tmp/code.mp4", assetName: "code.mp4", startSec: 0, endSec: 4,
                             description: "Developer typing on laptop at dark desk", tags: ["coding", "laptop"], mood: "focused"),
            ])
            idx = nil

            let reopened = try BRollFTSIndex(databaseURL: customDB)
            guard try reopened.count() == 3 else { return fail("S3", "SQLite FTS5 persistence count mismatch") }

            let accentedHits = try reopened.search(query: "cà phê đường phố")
            guard accentedHits.first?.assetName == "cafe.mp4" else {
                return fail("S3", "accented Vietnamese FTS5 search failed: \(accentedHits)")
            }
            let unaccentedHits = try reopened.search(query: "ca phe duong pho")
            guard unaccentedHits.first?.assetName == "cafe.mp4" else {
                return fail("S3", "unaccented Vietnamese (đ -> d) FTS5 search failed: \(unaccentedHits)")
            }
            let enHits = try reopened.search(query: "laptop coding")
            guard enHits.first?.assetName == "code.mp4" else {
                return fail("S3", "English FTS5 search failed")
            }
            // Malformed FTS5 operator characters must be safely neutralized without throwing.
            _ = try reopened.search(query: "coffee (morning) -bad \"unclosed *")
        } catch {
            return fail("S3", "SQLite FTS5 error: \(error.localizedDescription)")
        }
        log("PASS [S3] SQLite3 FTS5 accented/unaccented Vietnamese + query safety verified")

        // =========================================================================
        // S4: Loopback Local VLM Vision Indexer + index_broll_folder + search_broll
        // =========================================================================
        let vlmServer = LoopbackVLMMockServer()
        let brollDir = outDir.appendingPathComponent("local_broll", isDirectory: true)
        let img1 = brollDir.appendingPathComponent("morning_coffee.png")
        let img2 = brollDir.appendingPathComponent("cafe_table.png")
        do {
            try fm.createDirectory(at: brollDir, withIntermediateDirectories: true)
            try makeSamplePNG(red: 0.4).write(to: img1)
            try makeSamplePNG(red: 0.7).write(to: img2)
            try await vlmServer.start()
        } catch {
            return fail("S4", "setup error: \(error.localizedDescription)")
        }
        defer { vlmServer.stop() }

        let model = EditorModel()
        var p0 = Project()
        p0.width = 1280
        p0.height = 720
        p0.fps = 30
        let v1 = p0.videoTracks[0].id
        var baseClip = Clip(trackID: v1, kind: .solid, start: 0, duration: 6.0)
        baseClip.color = RGBA(r: 0.1, g: 0.2, b: 0.3, a: 1)
        p0.clips = [baseClip]
        model.load(p0, url: nil)

        do {
            let idxOut = try await MCPTools.call("index_broll_folder", [
                "folder_path": brollDir.path,
                "vlm_base_url": "http://127.0.0.1:\(vlmServer.port)/v1",
                "vlm_model": "mock-qwen-vl",
            ], model: model, client: nil, isExternal: false)
            guard let idxObj = parseJSON(idxOut),
                  (idxObj["indexed_files"] as? Int) == 2,
                  (idxObj["indexed_segments"] as? Int) == 2,
                  vlmServer.requestCount == 2 else {
                return fail("S4", "index_broll_folder unexpected counts or mock VLM not hit")
            }

            let hitOut = try await MCPTools.call("search_broll", ["query": "ca phe buoi sang"], model: model, client: nil, isExternal: false)
            guard let hitObj = parseJSON(hitOut),
                  (hitObj["fallback_tier"] as? Int) == 1,
                  let count = hitObj["count"] as? Int, count >= 1 else {
                return fail("S4", "search_broll expected local Tier 1 hit")
            }

            let missOut = try await MCPTools.call("search_broll", ["query": "spaceship crater mars"], model: model, client: nil, isExternal: false)
            guard let missObj = parseJSON(missOut),
                  (missObj["count"] as? Int) == 0,
                  (missObj["fallback_tier"] as? Int) == 2 else {
                return fail("S4", "search_broll expected fallback_tier=2 on miss")
            }
        } catch {
            return fail("S4", "error: \(error.localizedDescription)")
        }
        log("PASS [S4] Local VLM loopback indexer + search_broll Tier 1 & Tier 2 fallback hint verified")

        // =========================================================================
        // S5: insert_broll_overlay inside AgentTurn + 1-Step Undo
        // =========================================================================
        do {
            let revBefore = model.revision
            _ = try await MCPTools.call("session_attach", ["session_id": "sess-s5"], model: model, client: nil, sessionId: "sess-s5", isExternal: true)
            _ = try await MCPTools.call("begin_agent_turn", ["turn_id": "turn-s5", "summary": "Insert B-roll overlay", "session_id": "sess-s5"],
                                        model: model, client: nil, sessionId: "sess-s5", isExternal: true)
            let insOut = try await MCPTools.call("insert_broll_overlay", [
                "asset_path": img1.path,
                "timeline_start": 1.0,
                "duration": 2.5,
                "mute_audio": true,
                "session_id": "sess-s5",
            ], model: model, client: nil, sessionId: "sess-s5", isExternal: true)
            _ = try await MCPTools.call("commit_agent_turn", ["turn_id": "turn-s5", "session_id": "sess-s5"],
                                        model: model, client: nil, sessionId: "sess-s5", isExternal: true)

            guard let insObj = parseJSON(insOut),
                  (insObj["inserted_clip_ids"] as? [String])?.isEmpty == false,
                  model.revision == revBefore + 1 else {
                return fail("S5", "insert_broll_overlay commit or revision check failed")
            }
            guard model.project.videoTracks.count >= 2 else {
                return fail("S5", "expected overlay track V2+ created")
            }
            let overlayTrackId = model.project.videoTracks[1].id
            guard model.project.clips.contains(where: { $0.trackID == overlayTrackId && abs($0.start - 1.0) < 0.05 && abs($0.duration - 2.5) < 0.05 }) else {
                return fail("S5", "inserted B-roll clip missing on V2 at 1.0..3.5s")
            }

            model.undo()
            guard !model.project.clips.contains(where: { $0.trackID == overlayTrackId }) else {
                return fail("S5", "1-step Undo did not revert insert_broll_overlay cleanly")
            }
        } catch {
            return fail("S5", "error: \(error.localizedDescription)")
        }
        log("PASS [S5] insert_broll_overlay inside AgentTurn + 1-step Undo verified")

        // =========================================================================
        // S6: Built-in Skills (aroll-rough-cut & smart-broll-inserter)
        // =========================================================================
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let arollSkillDir = repoRoot.appendingPathComponent("assets/editor-skills/aroll-rough-cut", isDirectory: true)
        let brollSkillDir = repoRoot.appendingPathComponent("assets/editor-skills/smart-broll-inserter", isDirectory: true)
        do {
            let registry = SkillRegistry(baseDir: dataDir.appendingPathComponent("SkillsTest", isDirectory: true))
            let arollSkill = try registry.installFromLocal(directory: arollSkillDir)
            let brollSkill = try registry.installFromLocal(directory: brollSkillDir)
            guard arollSkill.id == "aroll-rough-cut",
                  brollSkill.id == "smart-broll-inserter" else {
                return fail("S6", "unexpected skill ids")
            }
            let slugs = SkillRegistry.extractSlashSlugs(from: "/smart-broll-inserter tìm B-roll cà phê sáng")
            let prompt = registry.composePromptSection(explicitSlugs: slugs)
            guard slugs == ["smart-broll-inserter"],
                  prompt.contains("search_broll"),
                  prompt.contains("search_stock_media"),
                  prompt.contains("comfy_generate") else {
                return fail("S6", "smart-broll-inserter prompt missing 3-tier ladder instructions")
            }
        } catch {
            return fail("S6", "SkillRegistry install/compose error: \(error.localizedDescription)")
        }
        log("PASS [S6] Built-in skills aroll-rough-cut & smart-broll-inserter verified")

        return true
    }
}
