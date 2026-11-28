import AppKit
import AVFoundation
import CoreImage
import Foundation
import SwiftUI

/// Offline deterministic verification suite for Phase C (`v1.3`) Studio & Auto-Reframe (`R1–R5`):
/// `Editroom --studio-v13-test`
@MainActor
enum StudioV13Test {
    nonisolated static func runIfRequested() {
        guard CommandLine.arguments.contains("--studio-v13-test") else { return }
        Task { @MainActor in
            let ok = await run()
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardOutput.write(Data("[studio-v13-test] \(msg)\n".utf8))
    }

    private static func fail(_ id: String, _ msg: String) -> Bool {
        FileHandle.standardError.write(Data("[studio-v13-test] FAIL [\(id)]: \(msg)\n".utf8))
        return false
    }

    /// Writes a split-color PNG (left half red RGB(220,30,30), right half blue RGB(30,60,220)) to test 16:9->9:16 panning.
    private static func writeSplitPNG(to url: URL, width: Int, height: Int) throws {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let isLeft = x < width / 2
                bytes[idx] = isLeft ? 220 : 30
                bytes[idx + 1] = isLeft ? 30 : 60
                bytes[idx + 2] = isLeft ? 30 : 220
                bytes[idx + 3] = 255
            }
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
            throw NSError(domain: "StudioV13Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed split PNG"])
        }
        try png.write(to: url, options: .atomic)
    }

    private static func writeMP4(fromImage imgURL: URL, durationSec: Double, outputURL: URL) throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "ffmpeg"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-loop", "1", "-t", String(format: "%.2f", durationSec), "-i", imgURL.path,
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
            outputURL.path,
        ]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "StudioV13Test", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed writing MP4 fixture"])
        }
    }

    private static func meanRGB(of cg: CGImage) -> (r: Double, g: Double, b: Double)? {
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
        guard ok, w > 0, h > 0 else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            sr += Double(buf[i])
            sg += Double(buf[i + 1])
            sb += Double(buf[i + 2])
        }
        let n = Double(w * h)
        return (sr / n, sg / n, sb / n)
    }

    private static func parseJSON(_ content: [[String: Any]]) -> [String: Any]? {
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
            .appendingPathComponent("editroom_studio_v13_\(UUID().uuidString)", isDirectory: true)
        let dataDir = root.appendingPathComponent("AppData", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            return fail("SETUP", "mkdir failed: \(error.localizedDescription)")
        }
        let prevOverride = HybridStorage.overrideRootForTests
        HybridStorage.overrideRootForTests = dataDir
        defer {
            ComfyProgressMonitor.shared.finish()
            HybridStorage.overrideRootForTests = prevOverride
            try? FileManager.default.removeItem(at: root)
        }

        await BaseVideo.load()

        // =========================================================================
        // R1: ReframePath Smoothstep Interpolation, Deadband & EMA Smoothing
        // =========================================================================
        do {
            let path = ReframePath(keyframes: [
                ReframeKeyframe(time: 0.0, x: 0.2, y: 0.5),
                ReframeKeyframe(time: 2.0, x: 0.8, y: 0.5),
            ])
            let c0 = path.center(at: -0.5)
            let cMid = path.center(at: 1.0)
            let cEnd = path.center(at: 3.0)
            guard abs(c0.x - 0.2) < 1e-6, abs(cMid.x - 0.5) < 1e-4, abs(cEnd.x - 0.8) < 1e-6 else {
                return fail("R1", "ReframePath center interpolation off: c0=\(c0), cMid=\(cMid), cEnd=\(cEnd)")
            }

            let offLeft = path.offset(at: 0.0, canvas: CGSize(width: 640, height: 360), output: CGSize(width: 202, height: 360))
            let offRight = path.offset(at: 2.0, canvas: CGSize(width: 640, height: 360), output: CGSize(width: 202, height: 360))
            guard offLeft.x < offRight.x, offRight.x <= 640 - 202 else {
                return fail("R1", "ReframePath offset bounds failed: left=\(offLeft), right=\(offRight)")
            }

            let noisy = [
                ReframeKeyframe(time: 0.0, x: 0.2, y: 0.5),
                ReframeKeyframe(time: 0.5, x: 0.205, y: 0.502),
                ReframeKeyframe(time: 1.0, x: 0.21, y: 0.498),
                ReframeKeyframe(time: 1.5, x: 0.8, y: 0.5),
                ReframeKeyframe(time: 2.0, x: 0.8, y: 0.5),
            ]
            let smoothed = AutoReframeEngine.smooth(noisy)
            guard smoothed.count == noisy.count,
                  smoothed[3].x > smoothed[0].x,
                  smoothed[3].x < 0.8 else {
                return fail("R1", "AutoReframeEngine.smooth did not damp step cleanly: \(smoothed)")
            }
            log("PASS [R1] ReframePath interpolation, canvas offsets & EMA deadband smoothing verified")
        }

        // =========================================================================
        // R2: Dynamic 16:9 -> 9:16 Face-Tracking Export (`P2`)
        // =========================================================================
        do {
            let splitPNG = root.appendingPathComponent("split_16_9.png")
            let splitMP4 = root.appendingPathComponent("split_16_9.mp4")
            try writeSplitPNG(to: splitPNG, width: 640, height: 360)
            try writeMP4(fromImage: splitPNG, durationSec: 2.0, outputURL: splitMP4)

            if let cgData = try? Data(contentsOf: splitPNG),
               let provider = CGDataProvider(data: cgData as CFData),
               let cg = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                // Exercise Vision VNDetectFaceRectanglesRequest cleanly on synthetic image (nil expected since no face).
                _ = AutoReframeEngine.detectFaceCenter(in: cg)
            }

            let model = EditorModel()
            let imported: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles([splitMP4], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let asset = imported.first else { return fail("R2", "import splitMP4 failed") }
            _ = try await MCPTools.call("add_clip", ["asset_id": asset.id.uuidString, "track": "V1", "start": 0.0], model: model, client: nil)

            // Keyframed path pans from left red half (0.15) to right blue half (0.85).
            let dynamicPath = ReframePath(keyframes: [
                ReframeKeyframe(time: 0.2, x: 0.15, y: 0.5),
                ReframeKeyframe(time: 1.5, x: 0.85, y: 0.5),
            ])
            var settings = ExportSettings()
            settings.shape = .vertical
            settings.height = 360
            settings.codec = .h264
            settings.includeAudio = false
            settings.autoReframe = true
            settings.reframePath = dynamicPath

            let exportURL = root.appendingPathComponent("reframed_vertical.mp4")
            let exporter = Exporter()
            exporter.start(project: model.project, media: model.media, settings: settings, url: exportURL)
            let deadline = Date().addingTimeInterval(25)
            while case .running = exporter.state, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .done = exporter.state else {
                return fail("R2", "Vertical export failed: \(exporter.state)")
            }

            let expAsset = AVURLAsset(url: exportURL)
            let expGen = AVAssetImageGenerator(asset: expAsset)
            expGen.requestedTimeToleranceBefore = .zero
            expGen.requestedTimeToleranceAfter = .zero
            guard let fEarly = try? await expGen.image(at: CMTime(seconds: 0.15, preferredTimescale: 600)).image,
                  let fLate = try? await expGen.image(at: CMTime(seconds: 1.75, preferredTimescale: 600)).image,
                  let rgbEarly = meanRGB(of: fEarly),
                  let rgbLate = meanRGB(of: fLate) else {
                return fail("R2", "Failed reading exported vertical frames")
            }
            guard fEarly.height > fEarly.width,
                  rgbEarly.r > rgbEarly.b + 80,
                  rgbLate.b > rgbLate.r + 80 else {
                return fail("R2", "Vertical crop did not follow panning ReframePath: size=\(fEarly.width)x\(fEarly.height), early=\(rgbEarly), late=\(rgbLate)")
            }
            log(String(format: "PASS [R2] 16:9->9:16 dynamic ReframePath export verified (%dx%d, earlyR=%.0f->lateB=%.0f)",
                       fEarly.width, fEarly.height, rgbEarly.r, rgbLate.b))
        } catch {
            return fail("R2", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // R3: analyze_reframe MCP Tool & ExportSheet NSHostingView Smoke
        // =========================================================================
        do {
            let model = EditorModel()
            let splitPNG = root.appendingPathComponent("split_16_9.png")
            let assets: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles([splitPNG], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let imgAsset = assets.first else { return fail("R3", "import splitPNG failed") }
            _ = try await MCPTools.call("add_clip", ["asset_id": imgAsset.id.uuidString, "track": "V1", "start": 0.0, "duration": 2.0], model: model, client: nil)

            let res = try await MCPTools.call("analyze_reframe", [
                "shape": "vertical",
                "sample_interval_sec": 0.5,
                "include_preview": true,
            ], model: model, client: nil)
            let hasImage = res.contains { ($0["type"] as? String) == "image" && !(($0["data"] as? String)?.isEmpty ?? true) }
            guard hasImage, let obj = parseJSON(res), (obj["keyframe_count"] as? Int ?? 0) >= 2 else {
                return fail("R3", "analyze_reframe did not return keyframes + preview image")
            }

            let exportView = ExportSheet(model: model)
            let host = NSHostingView(rootView: exportView)
            host.frame = NSRect(x: 0, y: 0, width: 740, height: 520)
            host.layoutSubtreeIfNeeded()
            log("PASS [R3] analyze_reframe MCP tool & ExportSheet UI smoke verified (keyframes=\(obj["keyframe_count"] ?? 0))")
        } catch {
            return fail("R3", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // R4: ComfyUI Workflow Gallery Presets (Swift + Disk JSON + comfy_status)
        // =========================================================================
        do {
            let expectedIDs = ["flux_schnell", "flux_dev", "wan21_i2v", "stable_audio_sfx"]
            let presets = ComfyUIClient.galleryPresets
            guard presets.map(\.id) == expectedIDs else {
                return fail("R4", "Unexpected gallery preset IDs: \(presets.map(\.id))")
            }
            let values: [String: Any] = [
                "{{prompt}}": "Pho Ha Noi ban dem",
                "{{negative_prompt}}": "blurry",
                "{{seed}}": 77,
                "{{width}}": 832,
                "{{height}}": 480,
                "{{frames}}": 49,
                "{{steps}}": 4,
                "{{input_image}}": "ref.png",
                "{{checkpoint}}": "flux1-schnell.safetensors",
            ]
            for pid in expectedIDs {
                guard let raw = ComfyUIClient.galleryTemplate(id: pid),
                      let bound = ComfyUIClient.substitutePlaceholders(in: raw, values: values) as? [String: Any],
                      let boundData = try? JSONSerialization.data(withJSONObject: bound),
                      let boundText = String(data: boundData, encoding: .utf8),
                      !boundText.contains("{{") else {
                    return fail("R4", "Gallery preset '\(pid)' placeholder binding incomplete")
                }
            }

            let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let workflowsFolder = repoRoot.appendingPathComponent("assets/comfy-workflows", isDirectory: true)
            if FileManager.default.fileExists(atPath: workflowsFolder.path) {
                for pid in expectedIDs {
                    let f = workflowsFolder.appendingPathComponent("\(pid).json")
                    guard let d = try? Data(contentsOf: f),
                          (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) != nil else {
                        return fail("R4", "Missing/invalid JSON in assets/comfy-workflows/\(pid).json")
                    }
                }
            }

            let model = EditorModel()
            let stRes = try await MCPTools.call("comfy_status", [:], model: model, client: nil)
            guard let stObj = parseJSON(stRes),
                  let gp = stObj["gallery_presets"] as? [[String: Any]],
                  gp.count == 4 else {
                return fail("R4", "comfy_status missing 4 gallery_presets")
            }
            log("PASS [R4] 4 ComfyUI Workflow Gallery presets & parameter bindings verified")
        } catch {
            return fail("R4", "error: \(error.localizedDescription)")
        }

        // =========================================================================
        // R5: Realtime WS Event Parsing, ComfyProgressMonitor, Export JSON & UI Smoke
        // =========================================================================
        do {
            guard ComfyUIClient.parseWebSocketEvent(#"{"type":"execution_start","data":{"prompt_id":"p-1"}}"#) == .executionStart(promptId: "p-1"),
                  ComfyUIClient.parseWebSocketEvent(#"{"type":"executing","data":{"node":"KSampler"}}"#) == .executing(node: "KSampler"),
                  ComfyUIClient.parseWebSocketEvent(#"{"type":"progress","data":{"value":2,"max":4,"node":"3"}}"#) == .progress(value: 2, max: 4, node: "3"),
                  ComfyUIClient.parseWebSocketEvent(#"{"type":"execution_error","data":{"exception_message":"OOM"}}"#) == .executionError(message: "OOM") else {
                return fail("R5", "ComfyUIClient.parseWebSocketEvent mismatch")
            }

            let mon = ComfyProgressMonitor.shared
            mon.begin(workflowName: "gallery:flux_schnell")
            if let evt = ComfyUIClient.parseWebSocketEvent(#"{"type":"progress","data":{"value":2,"max":4,"node":"3"}}"#) {
                mon.apply(event: evt)
            }
            guard mon.state.isRunning, mon.state.step == 2, mon.state.maxSteps == 4, abs(mon.state.fraction - 0.5) < 1e-6 else {
                return fail("R5", "ComfyProgressMonitor progress snapshot mismatch: \(mon.state)")
            }

            let model = EditorModel()
            let chatHost = NSHostingView(rootView: AgentChatPanel(model: model))
            chatHost.frame = NSRect(x: 0, y: 0, width: 340, height: 600)
            chatHost.layoutSubtreeIfNeeded()

            mon.finish()
            guard !mon.state.isRunning else {
                return fail("R5", "ComfyProgressMonitor did not reset on finish()")
            }

            let exportedURL = try ComfyUIClient.shared.exportGalleryPreset(id: "flux_schnell")
            guard FileManager.default.fileExists(atPath: exportedURL.path) else {
                return fail("R5", "exportGalleryPreset did not create file")
            }

            let intHost = NSHostingView(rootView: IntegrationsSettingsView())
            intHost.frame = NSRect(x: 0, y: 0, width: 620, height: 680)
            intHost.layoutSubtreeIfNeeded()
            log("PASS [R5] ComfyUI WS parser, ComfyProgressMonitor, preset export & UI smoke verified")
        } catch {
            return fail("R5", "error: \(error.localizedDescription)")
        }

        log("ALL 5 STUDIO V1.3 CHECKS PASSED")
        return true
    }
}
