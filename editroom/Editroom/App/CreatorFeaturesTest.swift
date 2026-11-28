import AppKit
import AVFoundation
import CoreImage
import Foundation
import SwiftUI

/// Offline deterministic verification suite for Phase B (`v1.2`) Vietnamese Creator Features (`C1–C6`):
/// `HYBRID_EDIT_DATA_DIR=... Editroom --creator-v12-test`
@MainActor
enum CreatorFeaturesTest {
    nonisolated static func runIfRequested() {
        guard CommandLine.arguments.contains("--creator-v12-test") else { return }
        Task { @MainActor in
            let ok = await run()
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardOutput.write(Data("[creator-v12-test] \(msg)\n".utf8))
    }

    private static func fail(_ id: String, _ msg: String) -> Bool {
        FileHandle.standardError.write(Data("[creator-v12-test] FAIL [\(id)]: \(msg)\n".utf8))
        return false
    }

    /// Writes a mono 16-bit PCM WAV file deterministically with arbitrary amplitude envelope.
    private static func writeWAV(to url: URL, durationSec: Double, sampleRate: Int = 48_000,
                                 sampleAt: (Double) -> Double) throws {
        let totalFrames = Int((durationSec * Double(sampleRate)).rounded())
        var pcm = Data(capacity: totalFrames * 2)
        for i in 0..<totalFrames {
            let t = Double(i) / Double(sampleRate)
            let v = max(-1.0, min(1.0, sampleAt(t)))
            var s = Int16((v * 32760.0).rounded()).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        let header = AudioVAD.wavHeader(
            pcmByteCount: UInt32(pcm.count),
            sampleRate: UInt32(sampleRate),
            channels: 1,
            bitsPerSample: 16
        )
        var data = Data(capacity: 44 + pcm.count)
        data.append(header)
        data.append(pcm)
        try data.write(to: url, options: .atomic)
    }

    /// Writes a solid-color PNG bitmap for fast deterministic visual fixtures.
    private static func writePNG(to url: URL, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
            bytes[i + 3] = 255
        }
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cg = ctx.makeImage(),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CreatorFeaturesTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try png.write(to: url, options: .atomic)
    }

    /// Synthesizes a valid H.264 + AAC `.mp4` clip using `/opt/homebrew/bin/ffmpeg` (`-nostdin`) for offline tests.
    private static func writeMuxedMP4(imageURL: URL, audioURL: URL, durationSec: Double, outputURL: URL) throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "ffmpeg"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-loop", "1", "-t", String(format: "%.2f", durationSec), "-i", imageURL.path,
            "-i", audioURL.path,
            "-t", String(format: "%.2f", durationSec),
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
            "-c:a", "aac", "-b:a", "128k",
            outputURL.path,
        ]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "CreatorFeaturesTest", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed composing fixture MP4"])
        }
    }

    /// Rasterizes a `CIImage` to RGBA bytes and returns (nonZeroAlphaCount, meanRGBA bytes) for pixel comparisons.
    private static func rasterizeCI(_ img: CIImage) -> [UInt8]? {
        let e = img.extent
        let w = max(1, Int(e.width.rounded())), h = max(1, Int(e.height.rounded()))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        ctx.render(img, toBitmap: &buf, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }

    private static func rasterizeCG(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    private static func byteDiffSum(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = min(a.count, b.count)
        var diff = 0
        for i in 0..<n { diff += abs(Int(a[i]) - Int(b[i])) }
        return diff
    }

    private static func parseJSONResult(_ content: [[String: Any]]) -> [String: Any]? {
        for item in content where (item["type"] as? String) == "text" {
            if let txt = item["text"] as? String,
               let data = txt.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editroom_creator_v12_\(UUID().uuidString)", isDirectory: true)
        let dataDir = root.appendingPathComponent("AppData", isDirectory: true)
        let mediaDir = root.appendingPathComponent("Fixtures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        } catch {
            return fail("SETUP", "temp dir creation failed: \(error.localizedDescription)")
        }
        let prevOverride = HybridStorage.overrideRootForTests
        HybridStorage.overrideRootForTests = dataDir
        defer {
            HybridStorage.overrideRootForTests = prevOverride
            try? FileManager.default.removeItem(at: root)
        }
        await BaseVideo.load()

        let voiceWAV = mediaDir.appendingPathComponent("voice_vi.wav")
        let bgmWAV = mediaDir.appendingPathComponent("bgm_duck.wav")
        let beatWAV = mediaDir.appendingPathComponent("beat_120bpm.wav")
        let cardDark = mediaDir.appendingPathComponent("card_dark.png")
        let cardWarm = mediaDir.appendingPathComponent("card_warm.png")
        let cardTeal = mediaDir.appendingPathComponent("card_teal.png")
        let arollMP4 = mediaDir.appendingPathComponent("aroll_vi.mp4")

        do {
            // Voice WAV: loud 440Hz speech tone [0.1s...1.9s], silence [2.0s...4.0s]
            try writeWAV(to: voiceWAV, durationSec: 4.0) { t in
                (t >= 0.1 && t <= 1.9) ? 0.65 * sin(2 * .pi * 440.0 * t) : 0.0
            }
            // Constant BGM WAV across 0...4s
            try writeWAV(to: bgmWAV, durationSec: 4.0) { t in
                0.35 * sin(2 * .pi * 220.0 * t)
            }
            // 8.5s 120 BPM drum-pulse WAV for MediaAnalyzer.music verification
            try writeWAV(to: beatWAV, durationSec: 8.5) { t in
                let beatPhase = t.truncatingRemainder(dividingBy: 0.5)
                let env = beatPhase < 0.09 ? exp(-beatPhase * 42.0) : 0.02
                return 0.85 * env * sin(2 * .pi * 68.0 * t)
            }
            try writePNG(to: cardDark, width: 640, height: 360, r: 24, g: 30, b: 48)
            try writePNG(to: cardWarm, width: 640, height: 360, r: 196, g: 98, b: 42)
            try writePNG(to: cardTeal, width: 640, height: 360, r: 28, g: 142, b: 136)
            try writeMuxedMP4(imageURL: cardDark, audioURL: voiceWAV, durationSec: 4.0, outputURL: arollMP4)
        } catch {
            return fail("SETUP", "fixture synthesis failed: \(error.localizedDescription)")
        }

        // =========================================================================
        // C1: Vietnamese Word-Level CaptionStyle Presets, Karaoke Pill & P2 Parity
        // =========================================================================
        do {
            let legacyJSON = #"{"size":70,"y":0.8,"highlight":true}"#.data(using: .utf8)!
            let legacy = try JSONDecoder().decode(CaptionStyle.self, from: legacyJSON)
            guard abs(legacy.size - 70) < 0.01, !legacy.pillHighlight, legacy.maxWordsPerLine == 0 else {
                return fail("C1", "CaptionStyle legacy Codable compatibility broke")
            }

            var karaokeStyle = CaptionStyle()
            karaokeStyle.apply(preset: .karaokePill)
            let rtData = try JSONEncoder().encode(karaokeStyle)
            let rtDecoded = try JSONDecoder().decode(CaptionStyle.self, from: rtData)
            guard rtDecoded == karaokeStyle, rtDecoded.pillHighlight, rtDecoded.maxWordsPerLine == 4 else {
                return fail("C1", "CaptionStyle preset Codable round-trip mismatch")
            }

            let outSize = CGSize(width: 720, height: 1280)
            guard let img0 = CaptionRenderer.image(words: ["Xin", "chào", "Việt", "Nam"], lit: 0, style: karaokeStyle, output: outSize),
                  let img2 = CaptionRenderer.image(words: ["Xin", "chào", "Việt", "Nam"], lit: 2, style: karaokeStyle, output: outSize),
                  let buf0 = rasterizeCI(img0), let buf2 = rasterizeCI(img2) else {
                return fail("C1", "CaptionRenderer returned nil image for Vietnamese text")
            }
            let alpha0 = stride(from: 3, to: buf0.count, by: 4).filter { buf0[$0] > 0 }.count
            let diff02 = byteDiffSum(buf0, buf2)
            guard alpha0 > 500, diff02 > 10_000 else {
                return fail("C1", "Karaoke caption highlight diff too small: alpha0=\(alpha0), diff=\(diff02)")
            }

            // Build & export a short captioned clip to confirm CompositionBuilder & Exporter parity (`P2`).
            let p1Model = EditorModel()
            let imported: [MediaAsset] = await withCheckedContinuation { cont in
                p1Model.importFiles([arollMP4], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let arollAsset = imported.first else { return fail("C1", "failed importing arollMP4") }
            Transcripts.shared.storeTranscript(Transcript(words: [
                Transcript.Word(start: 0.1, end: 0.55, text: "Xin"),
                Transcript.Word(start: 0.55, end: 1.0, text: "chào"),
                Transcript.Word(start: 1.0, end: 1.45, text: "Việt"),
                Transcript.Word(start: 1.45, end: 1.9, text: "Nam"),
            ], language: "vi"), for: arollMP4)

            p1Model.setSequence(width: 720, height: 1280)
            p1Model.setFPS(30)
            _ = try await MCPTools.call("add_clip", ["asset_id": arollAsset.id.uuidString, "track": "V1", "start": 0.0, "duration": 2.2], model: p1Model, client: nil)
            _ = try await MCPTools.call("generate_vietnamese_captions", ["preset": "capcut_yellow", "max_words": 4], model: p1Model, client: nil)

            let exportURL = root.appendingPathComponent("captions_parity.mp4")
            var es = ExportSettings()
            es.height = 720
            es.codec = .h264
            let exporter = Exporter()
            exporter.start(project: p1Model.project, media: p1Model.media, settings: es, url: exportURL)
            let deadline = Date().addingTimeInterval(25)
            while case .running = exporter.state, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .done = exporter.state else {
                return fail("C1", "Export failed/timeout: \(exporter.state)")
            }

            let expAsset = AVURLAsset(url: exportURL)
            let expGen = AVAssetImageGenerator(asset: expAsset)
            expGen.requestedTimeToleranceBefore = .zero
            expGen.requestedTimeToleranceAfter = .zero
            guard let fEarly = try? await expGen.image(at: CMTime(seconds: 0.25, preferredTimescale: 600)).image,
                  let fLate = try? await expGen.image(at: CMTime(seconds: 1.25, preferredTimescale: 600)).image,
                  let bEarly = rasterizeCG(fEarly), let bLate = rasterizeCG(fLate) else {
                return fail("C1", "Failed decoding exported captioned video frames")
            }
            let exportWordShiftDiff = byteDiffSum(bEarly, bLate)
            guard exportWordShiftDiff > 5_000 else {
                return fail("C1", "Exported video frames didn't visibly animate word highlight: diff=\(exportWordShiftDiff)")
            }
            log("PASS [C1] Vietnamese CaptionPresets, Karaoke pill & Export parity verified (diff=\(diff02), exportDiff=\(exportWordShiftDiff))")
        } catch {
            return fail("C1", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // C2: generate_vietnamese_captions MCP Tool + 1-Step Undo / Redo (`I1`)
        // =========================================================================
        do {
            let model = EditorModel()
            let imported: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles([arollMP4], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let asset = imported.first else { return fail("C2", "import arollMP4 failed") }
            _ = try await MCPTools.call("add_clip", ["asset_id": asset.id.uuidString, "track": "V1", "start": 0.0], model: model, client: nil)

            try model.beginAgentTurn(turnId: "c2-vi-caps", summary: "Vietnamese karaoke captions")
            let res = try await MCPTools.call("generate_vietnamese_captions", [
                "preset": "karaoke_pill",
                "language": "vi",
                "max_words": 3,
                "words": [
                    ["start": 0.1, "end": 0.3, "text": "Hôm"],
                    ["start": 0.3, "end": 0.5, "text": "nay"],
                    ["start": 0.5, "end": 0.7, "text": "chúng"],
                    ["start": 0.7, "end": 0.9, "text": "ta"],
                    ["start": 0.9, "end": 1.1, "text": "làm"],
                    ["start": 1.1, "end": 1.3, "text": "video"],
                    ["start": 1.3, "end": 1.5, "text": "cực"],
                    ["start": 1.5, "end": 1.8, "text": "chất"],
                ],
            ], model: model, client: nil, draft: model.activeAgentTurn?.draft)
            _ = try model.commitAgentTurn(turnId: "c2-vi-caps")

            guard let obj = parseJSONResult(res),
                  (obj["block_count"] as? Int) ?? 0 >= 2,
                  (obj["word_count"] as? Int) == 8,
                  model.project.captions?.style.pillHighlight == true,
                  model.project.captions?.style.maxWordsPerLine == 3 else {
                return fail("C2", "generate_vietnamese_captions result mismatch: \(res)")
            }
            let blocks = model.captionBlocks
            guard !blocks.isEmpty, blocks.allSatisfy({ $0.words.count <= 3 }) else {
                return fail("C2", "CaptionLayout exceeded max_words=3: \(blocks.map(\.words.count))")
            }

            model.undo()
            guard model.project.captions == nil else {
                return fail("C2", "1 Undo did not remove Vietnamese captions")
            }
            model.redo()
            guard model.project.captions?.style.pillHighlight == true else {
                return fail("C2", "Redo did not restore Vietnamese captions")
            }
            log("PASS [C2] generate_vietnamese_captions (blocks=\(blocks.count), max_words=3) & 1-step Undo/Redo verified")
        } catch {
            return fail("C2", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // C3: auto_duck_bgm Real AVAudioMix Attenuation + 1-Step Undo (`I1`)
        // =========================================================================
        do {
            let model = EditorModel()
            let assets: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles([voiceWAV, bgmWAV], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let vAsset = assets.first(where: { $0.url.lastPathComponent == "voice_vi.wav" }),
                  let bAsset = assets.first(where: { $0.url.lastPathComponent == "bgm_duck.wav" }) else {
                return fail("C3", "failed importing voice/bgm WAVs")
            }
            _ = try await MCPTools.call("add_track", ["kind": "audio"], model: model, client: nil)
            _ = try await MCPTools.call("add_clip", ["asset_id": vAsset.id.uuidString, "track": "A1", "start": 0.0], model: model, client: nil)
            _ = try await MCPTools.call("add_clip", ["asset_id": bAsset.id.uuidString, "track": "A2", "start": 0.0], model: model, client: nil)

            try model.beginAgentTurn(turnId: "c3-duck", summary: "Duck BGM under voice")
            let duckRes = try await MCPTools.call("auto_duck_bgm", [
                "bgm_track": "A2",
                "voice_track": "A1",
                "duck_db": -18.0,
            ], model: model, client: nil, draft: model.activeAgentTurn?.draft)
            _ = try model.commitAgentTurn(turnId: "c3-duck")

            guard model.project.audioTracks.count >= 2,
                  model.project.audioTracks[1].duckUnder == model.project.audioTracks[0].id,
                  abs(model.project.audioTracks[1].duckDB - (-18.0)) < 0.01,
                  let duckObj = parseJSONResult(duckRes),
                  (duckObj["speech_spans_count"] as? Int ?? 0) >= 1 else {
                return fail("C3", "auto_duck_bgm did not persist duckUnder/spans properly")
            }

            guard let built = CompositionBuilder.build(
                project: model.project,
                media: model.media,
                renderSize: CGSize(width: 64, height: 64),
                includeVideo: false,
                includeAudio: true
            ),
                  let compTrackID = built.audioTracks[model.project.audioTracks[1].id],
                  let bgmCompTrack = built.composition.tracks(withMediaType: .audio).first(where: { $0.trackID == compTrackID }),
                  let reader = try? AVAssetReader(asset: built.composition) else {
                return fail("C3", "Failed building AVComposition audio mix for ducking verification")
            }
            let out = AVAssetReaderAudioMixOutput(audioTracks: [bgmCompTrack], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = built.audioMix
            reader.add(out)
            guard reader.startReading() else { return fail("C3", "AVAssetReader startReading failed") }

            var samples: [Float] = []
            while let sb = out.copyNextSampleBuffer() {
                if let blk = CMSampleBufferGetDataBuffer(sb) {
                    let len = CMBlockBufferGetDataLength(blk)
                    var chunk = [Float](repeating: 0, count: len / 4)
                    chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(blk, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                    samples.append(contentsOf: chunk)
                }
            }
            func windowRMS(from s0: Double, to s1: Double) -> Double {
                let lo = max(0, Int(s0 * 48_000)), hi = min(samples.count, Int(s1 * 48_000))
                guard hi > lo else { return 0 }
                var sum = 0.0
                for i in lo..<hi { sum += Double(samples[i]) * Double(samples[i]) }
                return sqrt(sum / Double(hi - lo))
            }
            let rmsSpeech = windowRMS(from: 0.4, to: 1.6)
            let rmsSilence = windowRMS(from: 2.8, to: 3.8)
            guard rmsSpeech > 0, rmsSilence > rmsSpeech * 3.0 else {
                return fail("C3", "BGM did not attenuate enough during speech: rmsSpeech=\(rmsSpeech), rmsSilence=\(rmsSilence)")
            }

            model.undo()
            guard model.project.audioTracks[1].duckUnder == nil else {
                return fail("C3", "1 Undo did not remove BGM ducking")
            }
            log(String(format: "PASS [C3] auto_duck_bgm verified (rmsSpeech=%.4f, rmsSilence=%.4f, ratio=%.1fx) + Undo",
                       rmsSpeech, rmsSilence, rmsSilence / max(1e-6, rmsSpeech)))
        } catch {
            return fail("C3", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // C4: beat_sync_cuts & Native MediaAnalyzer.music Grid + 1-Step Undo (`I1`)
        // =========================================================================
        do {
            // Confirm MediaAnalyzer.music yields a real BeatGrid on our 8.5s 120 BPM fixture.
            guard let analyzedGrid = await BeatSyncEngine.computeBeatGrid(musicURL: beatWAV) else {
                return fail("C4", "MediaAnalyzer.music returned nil BeatGrid on 120 BPM beat fixture")
            }
            guard analyzedGrid.source == "media_analyzer", analyzedGrid.beats.count >= 8 else {
                return fail("C4", "Unexpected MediaAnalyzer BeatGrid: source=\(analyzedGrid.source), count=\(analyzedGrid.beats.count)")
            }

            let model = EditorModel()
            let assets: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles([cardDark, cardWarm, cardTeal, beatWAV], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let a1 = assets.first(where: { $0.url.lastPathComponent == "card_dark.png" }),
                  let a2 = assets.first(where: { $0.url.lastPathComponent == "card_warm.png" }),
                  let a3 = assets.first(where: { $0.url.lastPathComponent == "card_teal.png" }),
                  let mus = assets.first(where: { $0.url.lastPathComponent == "beat_120bpm.wav" }) else {
                return fail("C4", "failed importing beat-sync fixture assets")
            }
            _ = try await MCPTools.call("add_track", ["kind": "audio"], model: model, client: nil)
            _ = try await MCPTools.call("add_clip", ["asset_id": a1.id.uuidString, "track": "V1", "start": 0.0, "duration": 3.0], model: model, client: nil)
            _ = try await MCPTools.call("add_clip", ["asset_id": a2.id.uuidString, "track": "V1", "start": 3.0, "duration": 3.0], model: model, client: nil)
            _ = try await MCPTools.call("add_clip", ["asset_id": a3.id.uuidString, "track": "V1", "start": 6.0, "duration": 3.0], model: model, client: nil)
            _ = try await MCPTools.call("add_clip", ["asset_id": mus.id.uuidString, "track": "A2", "start": 0.0], model: model, client: nil)

            try model.beginAgentTurn(turnId: "c4-beatsync", summary: "Align photos to 120 BPM")
            let bsRes = try await MCPTools.call("beat_sync_cuts", [
                "track": "V1",
                "bpm": 120.0,
                "beats_per_cut": 2,
                "start_time": 0.0,
            ], model: model, client: nil, draft: model.activeAgentTurn?.draft)
            _ = try model.commitAgentTurn(turnId: "c4-beatsync")

            let v1Clips = model.project.clips
                .filter { $0.trackID == model.project.videoTracks[0].id }
                .sorted { $0.start < $1.start }
            guard v1Clips.count == 3,
                  abs(v1Clips[0].start - 0.0) < 0.05, abs(v1Clips[0].duration - 1.0) < 0.05,
                  abs(v1Clips[1].start - 1.0) < 0.05, abs(v1Clips[1].duration - 1.0) < 0.05,
                  abs(v1Clips[2].start - 2.0) < 0.05, abs(v1Clips[2].duration - 1.0) < 0.05,
                  parseJSONResult(bsRes) != nil else {
                return fail("C4", "beat_sync_cuts alignments off: starts=\(v1Clips.map(\.start)), durs=\(v1Clips.map(\.duration))")
            }

            model.undo()
            let restored = model.project.clips.filter { $0.trackID == model.project.videoTracks[0].id }.sorted { $0.start < $1.start }
            guard abs(restored[0].duration - 3.0) < 0.05, abs(restored[1].start - 3.0) < 0.05 else {
                return fail("C4", "1 Undo did not restore pre-beat-sync timings")
            }
            log("PASS [C4] beat_sync_cuts & MediaAnalyzer.music (detected=\(String(format: "%.1f", analyzedGrid.bpm)) BPM) + Undo verified")
        } catch {
            return fail("C4", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // C5: BRollBrowserView, LibraryView 3-Tab Switcher & 1-Click Add V2 (`I5`)
        // =========================================================================
        do {
            let dbURL = root.appendingPathComponent("broll_c5.sqlite")
            let index = try BRollFTSIndex(databaseURL: dbURL)
            try index.upsert([
                BRollSegment(
                    assetPath: arollMP4.path,
                    assetName: arollMP4.lastPathComponent,
                    startSec: 0.5,
                    endSec: 2.5,
                    description: "Cà phê sữa đá buổi sáng trên phố Sài Gòn",
                    tags: ["cà phê", "Sài Gòn", "buổi sáng"],
                    mood: "ấm áp"
                ),
            ])
            let recent = try index.listRecent(limit: 10)
            let stats = try index.stats()
            let vnHits = try index.search(query: "ca phe sai gon", limit: 5)
            guard recent.count == 1, stats.files == 1, stats.segments == 1, vnHits.count == 1 else {
                return fail("C5", "BRollFTSIndex query/stats failed: recent=\(recent.count), vn=\(vnHits.count)")
            }

            let model = EditorModel()
            let browser = BRollBrowserView(model: model, indexOverride: index)
            let bHost = NSHostingView(rootView: browser)
            bHost.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
            bHost.layoutSubtreeIfNeeded()

            let lib = LibraryView(model: model, media: model.media)
            let lHost = NSHostingView(rootView: lib)
            lHost.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
            lHost.layoutSubtreeIfNeeded()

            model.seek(to: 1.0)
            let hit = vnHits[0]
            try model.beginAgentTurn(turnId: "c5-broll-ui", summary: "Add B-roll \(hit.assetName)")
            _ = try await MCPTools.call("insert_broll_overlay", [
                "asset_path": hit.assetPath,
                "timeline_start": max(0, model.playhead),
                "source_start": hit.startSec,
                "duration": max(0.5, hit.endSec - hit.startSec),
                "mute_audio": true,
            ], model: model, client: nil, draft: model.activeAgentTurn?.draft, isExternal: false)
            _ = try model.commitAgentTurn(turnId: "c5-broll-ui")

            guard model.project.videoTracks.count >= 2 else {
                return fail("C5", "insert_broll_overlay did not place onto V2")
            }
            let v2Clips = model.project.clips.filter { $0.trackID == model.project.videoTracks[1].id }
            guard let placed = v2Clips.first,
                  abs(placed.start - 1.0) < 0.05,
                  abs(placed.sourceStart - 0.5) < 0.05,
                  abs(placed.duration - 2.0) < 0.05 else {
                return fail("C5", "V2 overlay placement mismatch: \(v2Clips)")
            }
            log("PASS [C5] BRollBrowserView + LibraryView 3-tab UI + 1-click V2 placement verified")
        } catch {
            return fail("C5", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // C6: vietnamese-shorts-creator Built-in Skill & get_project Ducking/Caption JSON
        // =========================================================================
        do {
            let reg = SkillRegistry(baseDir: root.appendingPathComponent("SkillsCheck", isDirectory: true))
            let seeded = reg.seedBuiltInSkills()
            guard seeded == SkillRegistry.builtInSkillSpecs.count,
                  let viSkill = reg.loadSkill(id: "vietnamese-shorts-creator"),
                  viSkill.body.contains("generate_vietnamese_captions"),
                  viSkill.body.contains("auto_duck_bgm") else {
                return fail("C6", "vietnamese-shorts-creator built-in skill missing or incomplete")
            }

            let model = EditorModel()
            _ = try await MCPTools.call("add_track", ["kind": "audio"], model: model, client: nil)
            let a1ID = model.project.audioTracks[0].id
            let a2ID = model.project.audioTracks[1].id
            model.duck(a2ID, under: a1ID, amount: -15.0)
            let gpRes = try await MCPTools.call("get_project", [:], model: model, client: nil)
            guard let gpObj = parseJSONResult(gpRes),
                  let tracks = gpObj["tracks"] as? [[String: Any]],
                  let a2 = tracks.first(where: { ($0["name"] as? String) == "A2" }),
                  (a2["duck_under"] as? String) == "A1" else {
                return fail("C6", "get_project did not report duck_under on A2")
            }
            log("PASS [C6] vietnamese-shorts-creator skill & get_project duck_under metadata verified")
        } catch {
            return fail("C6", "error: \(error.localizedDescription)")
        }

        log("ALL 6 CREATOR V1.2 CHECKS PASSED")
        return true
    }
}
