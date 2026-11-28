import AppKit
import AVFoundation
import Foundation

/// Empirical verification suite for Milestone 1-E (`T1–T7`):
/// `HYBRID_EDIT_DATA_DIR=... Editroom --hybrid-test <outDir>`
@MainActor
enum HybridGuardrailsTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--hybrid-test"), args.count > idx + 1 else { return }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        Task { @MainActor in
            let ok = await run(outDir: outDir)
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ msg: String) {
        let line = "HYBRID-TEST \(msg)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func fail(_ test: String, _ reason: String) -> Bool {
        log("FAIL [\(test)] \(reason)")
        return false
    }

    private static func parseJSONObject(from content: [[String: Any]]) -> [String: Any]? {
        guard let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func runFFmpeg(_ args: [String]) -> Bool {
        let fm = FileManager.default
        let systemFFmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { fm.isExecutableFile(atPath: $0) }
        guard let bin = systemFFmpeg ?? FFmpeg.binary else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-nostdin"] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
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

    private static func makeTransparentOverlayPNG(at url: URL, size: Int = 256) -> Bool {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        // Draw centered opaque red square inside transparent border.
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        let inset = CGFloat(size) * 0.25
        ctx.fill(CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset))
        guard let img = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func cornerPixelRGB(cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let ctx = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                                  bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let px = min(max(0, x), cgImage.width - 1)
        let py = min(max(0, y), cgImage.height - 1)
        let offset = (py * cgImage.width + px) * 4
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        return (ptr[offset], ptr[offset + 1], ptr[offset + 2])
    }

    private static func exportProject(_ project: Project, _ media: MediaStore, to url: URL) async -> Bool {
        var settings = ExportSettings()
        settings.format = .mp4
        settings.codec = .h264
        settings.quality = .high
        let exporter = Exporter()
        exporter.start(project: project, media: media, settings: settings, url: url)
        while exporter.state == .running {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .done = exporter.state { return true }
        return false
    }

    static func run(outDir: URL) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: outDir)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dataDir = outDir.appendingPathComponent("isolated_data", isDirectory: true)
        let mediaDir = outDir.appendingPathComponent("media", isDirectory: true)
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let previousTestRoot = HybridStorage.overrideRootForTests
        HybridStorage.overrideRootForTests = dataDir
        defer {
            HybridStorage.overrideRootForTests = previousTestRoot
            MCPServer.shared.stop()
        }

        await BaseVideo.load()
        guard let ffmpeg = FFmpeg.binary else {
            return fail("SETUP", "FFmpeg binary not available")
        }

        // Generate real 3s 1280x720 bright-green test MP4 + audio, plus transparent PNG overlay.
        let greenMP4 = mediaDir.appendingPathComponent("sample_green.mp4")
        guard runFFmpeg([
            "-y",
            "-f", "lavfi", "-i", "color=c=green:s=1280x720:r=30:d=3.0",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3.0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest",
            greenMP4.path,
        ]) else {
            return fail("SETUP", "ffmpeg failed to synthesize test clip at \(greenMP4.path) (\(ffmpeg))")
        }

        let overlayPNG = mediaDir.appendingPathComponent("overlay.png")
        guard makeTransparentOverlayPNG(at: overlayPNG) else {
            return fail("SETUP", "failed to write overlay.png")
        }

        // =========================================================================
        // T1: Data Isolation (`I5`) & APFS UTF-8 Safe Naming (`I4`, `P7`)
        // =========================================================================
        let isoPrefix = dataDir.standardizedFileURL.path
        let folders: [(String, URL)] = [
            ("Reverser.folder", Reverser.folder),
            ("Transcripts.folder", Transcripts.folder),
            ("SceneTagStore.folder", SceneTagStore.folder),
            ("ScrubStrips.folder", ScrubStrips.folder),
            ("WaveformReader.folder", WaveformReader.folder),
            ("FFmpeg.cacheDir", FFmpeg.cacheDir),
            ("MediaAnalyzer.folder", MediaAnalyzer.folder),
            ("MediaNotes.folder", MediaNotes.folder),
            ("MediaDownload.folder", MediaDownload.folder(for: nil)),
            ("EditorModel.heldMediaFolder", EditorModel.heldMediaFolder),
            ("HybridStorage.leasesDir", HybridStorage.leasesDir),
        ]
        for (label, url) in folders {
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(isoPrefix) else {
                return fail("T1", "\(label) escaped isolation root: \(p) vs \(isoPrefix)")
            }
        }

        let longVietName = "Cảnh quay ngoại cảnh đường phố Sài Gòn buổi sáng sớm nắng đẹp rực rỡ với âm thanh sống động và chuyển động mượt mà rất dài vượt quá giới hạn thông thường 1234567890.mp4"
        let longVietURL = mediaDir.appendingPathComponent(longVietName)
        guard (try? fm.copyItem(at: greenMP4, to: longVietURL)) != nil || fm.fileExists(atPath: longVietURL.path) else {
            return fail("T1", "failed to copy long Vietnamese filename")
        }
        let stem = HybridStorage.derivedCacheStem(for: longVietURL)
        let cacheStem = ReverseAudio.cacheName(for: longVietURL)
        let suffixed = cacheStem + "-v2.json"
        guard stem.utf8.count <= 140, suffixed.utf8.count <= 200 else {
            return fail("T1", "UTF-8 cache filename exceeded cap: stem=\(stem.utf8.count) suffixed=\(suffixed.utf8.count)")
        }
        guard String(decoding: Data(suffixed.utf8), as: UTF8.self) == suffixed else {
            return fail("T1", "invalid UTF-8 boundary truncation")
        }
        let verifiedFile = dataDir.appendingPathComponent(suffixed)
        do {
            try HybridStorage.writeAtomicVerified(Data("verified".utf8), to: verifiedFile, posixPermissions: 0o600)
            let attrs = try fm.attributesOfItem(atPath: verifiedFile.path)
            let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard perm & 0o777 == 0o600 else {
                return fail("T1", "expected 0o600 permissions, got \(String(perm, radix: 8))")
            }
        } catch {
            return fail("T1", "writeAtomicVerified failed: \(error.localizedDescription)")
        }
        log("PASS [T1] Data isolation & UTF-8 APFS-safe naming verified (suffixed=\(suffixed.utf8.count)B)")

        // Build base model with imported test media
        let model = EditorModel()
        guard let videoAsset = await model.media.importFile(greenMP4),
              let pngAsset = await model.media.importFile(overlayPNG) else {
            return fail("SETUP", "MediaStore.importFile failed")
        }
        var baseProject = Project()
        baseProject.width = 1280
        baseProject.height = 720
        baseProject.fps = 30
        baseProject.assets = [videoAsset, pngAsset]
        let v1 = baseProject.videoTracks[0].id
        let a1 = baseProject.audioTracks[0].id
        let link0 = UUID()
        var initV = Clip(trackID: v1, kind: .video, assetID: videoAsset.id, start: 0, duration: 3.0)
        initV.linkID = link0
        var initA = Clip(trackID: a1, kind: .audio, assetID: videoAsset.id, start: 0, duration: 3.0)
        initA.linkID = link0
        baseProject.clips = [initV, initA]
        model.load(baseProject, url: nil)

        // =========================================================================
        // T2: ViewState Isolation (`P1`, `P4`)
        // =========================================================================
        let t2Rev0 = model.revision
        let t2Dirty0 = model.isDirty
        for step in 0..<20 {
            model.seek(to: Double(step) * 0.1)
            model.selection = step.isMultiple(of: 2) ? [initV.id] : []
            model.setView(pps: CGFloat(60 + step * 2), scrollX: CGFloat(step * 5), scrollY: 0, rowHeight: nil)
            model.skimming.toggle()
        }
        guard model.revision == t2Rev0, !model.canUndo, model.isDirty == t2Dirty0 else {
            return fail("T2", "ViewState touched revision/undo/dirty: rev \(t2Rev0)->\(model.revision) canUndo=\(model.canUndo) dirty=\(model.isDirty)")
        }
        log("PASS [T2] ViewState isolation verified (20 view changes, revision=\(model.revision), canUndo=false)")

        // =========================================================================
        // T3: Transactional `AgentTurn` Unified Undo/Redo & Rollback (`I1`)
        // =========================================================================
        do {
            _ = try await MCPTools.call("session_attach", ["session_id": "sess-t3", "grace_ms": 8000],
                                        model: model, client: nil, sessionId: "sess-t3", isExternal: true)
            let revBefore = model.revision
            let clipCountBefore = model.project.clips.count

            _ = try await MCPTools.call("begin_agent_turn", [
                "turn_id": "turn-t3", "summary": "3-step atomic edit", "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)

            let t1Out = try await MCPTools.call("add_title", [
                "text": "Step1", "start": 0.0, "duration": 1.0, "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)
            guard let t1Obj = parseJSONObject(from: t1Out),
                  let added = t1Obj["added"] as? [String: Any],
                  let titleId = added["id"] as? String else {
                return fail("T3", "add_title did not return added.id")
            }
            _ = try await MCPTools.call("move_clip", [
                "clip_id": titleId, "start": 0.5, "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)
            _ = try await MCPTools.call("set_grade", [
                "clip_ids": [initV.id.uuidString], "saturation": 25.0, "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)

            let commitOut = try await MCPTools.call("commit_agent_turn", [
                "turn_id": "turn-t3", "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)
            guard let commitObj = parseJSONObject(from: commitOut),
                  (commitObj["pushed_undo_step"] as? Bool) == true,
                  model.revision == revBefore + 1,
                  model.project.clips.count == clipCountBefore + 1 else {
                return fail("T3", "commit_agent_turn did not collapse 3 edits into +1 revision")
            }

            // 1 Undo must revert all 3 edits cleanly.
            model.undo()
            guard model.project.clips.count == clipCountBefore,
                  (model.project.clip(initV.id)?.grade?.saturation ?? 0) == 0,
                  model.revision == revBefore + 2 else {
                return fail("T3", "single Undo did not revert whole AgentTurn cleanly")
            }

            // 1 Redo must reapply all 3 edits cleanly.
            model.redo()
            guard model.project.clips.count == clipCountBefore + 1,
                  model.project.clip(initV.id)?.grade?.saturation == 25.0,
                  model.revision == revBefore + 3 else {
                return fail("T3", "single Redo did not reapply AgentTurn cleanly")
            }

            // Rollback check.
            let revBeforeRb = model.revision
            let countBeforeRb = model.project.clips.count
            _ = try await MCPTools.call("begin_agent_turn", [
                "turn_id": "turn-rb", "summary": "Will rollback", "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)
            _ = try await MCPTools.call("add_title", [
                "text": "RolledBack", "start": 1.0, "duration": 1.0, "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)
            _ = try await MCPTools.call("rollback_agent_turn", [
                "turn_id": "turn-rb", "session_id": "sess-t3",
            ], model: model, client: nil, sessionId: "sess-t3", isExternal: true)

            guard model.revision == revBeforeRb,
                  model.activeAgentTurn == nil,
                  model.project.clips.count == countBeforeRb else {
                return fail("T3", "rollback_agent_turn leaked edits or incremented revision")
            }
            _ = try await MCPTools.call("session_release", ["session_id": "sess-t3"],
                                        model: model, client: nil, sessionId: "sess-t3", isExternal: true)
        } catch {
            return fail("T3", "unexpected error: \(error.localizedDescription)")
        }
        log("PASS [T3] Transactional AgentTurn unified Undo/Redo + Rollback verified")

        // =========================================================================
        // T4: Single-Writer `SessionLease` & Real `SIGKILL` Crash Recovery (`I2`, `P8`)
        // =========================================================================
        do {
            let dummy = Process()
            dummy.executableURL = URL(fileURLWithPath: "/bin/sleep")
            dummy.arguments = ["30"]
            try dummy.run()
            let deadPid = dummy.processIdentifier

            _ = try await MCPTools.call("session_attach", [
                "session_id": "sess-a", "client_pid": Int(deadPid), "grace_ms": 6000,
            ], model: model, client: nil, sessionId: "sess-a", isExternal: true)

            let leasePath = model.leaseManager.leaseURL.path
            let attrs = try fm.attributesOfItem(atPath: leasePath)
            let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard perm & 0o777 == 0o600 else {
                dummy.terminate()
                return fail("T4", "lease file does not have 0o600 mode")
            }

            let revPreCrash = model.revision
            let countPreCrash = model.project.clips.count
            _ = try await MCPTools.call("begin_agent_turn", [
                "turn_id": "turn-crashed", "summary": "Crashed turn", "session_id": "sess-a",
            ], model: model, client: nil, sessionId: "sess-a", isExternal: true)
            _ = try await MCPTools.call("add_title", [
                "text": "Ghost", "start": 0.2, "duration": 0.8, "session_id": "sess-a",
            ], model: model, client: nil, sessionId: "sess-a", isExternal: true)

            // Client B must be rejected while dummy PID is alive.
            var rejectedB = false
            do {
                _ = try await MCPTools.call("session_attach", ["session_id": "sess-b"],
                                            model: model, client: nil, sessionId: "sess-b", isExternal: true)
            } catch {
                rejectedB = true
            }
            guard rejectedB else {
                dummy.terminate()
                return fail("T4", "client B acquired lease while live client A held it")
            }

            // Simulate sudden crash with SIGKILL.
            Darwin.kill(deadPid, SIGKILL)
            dummy.waitUntilExit()

            let recOut = try await MCPTools.call("session_attach", ["session_id": "sess-b"],
                                                 model: model, client: nil, sessionId: "sess-b", isExternal: true)
            guard let recObj = parseJSONObject(from: recOut),
                  (recObj["recovered_rolled_back_turn_id"] as? String) == "turn-crashed",
                  model.activeAgentTurn == nil,
                  model.project.clips.count == countPreCrash,
                  model.revision == revPreCrash else {
                return fail("T4", "crash recovery did not roll back uncommitted turn cleanly")
            }
            _ = try await MCPTools.call("session_release", ["session_id": "sess-b"],
                                        model: model, client: nil, sessionId: "sess-b", isExternal: true)
        } catch {
            return fail("T4", "unexpected error: \(error.localizedDescription)")
        }
        log("PASS [T4] SessionLease single-writer & SIGKILL crash recovery verified (0o600)")

        // =========================================================================
        // T5: Semantic Batch EDL Patch (`apply_edl_patch`)
        // =========================================================================
        // Reset cleanly onto just the 3.0s V1+A1 video clip before EDL test.
        model.load(baseProject, url: nil)
        do {
            _ = try await MCPTools.call("session_attach", ["session_id": "sess-t5"],
                                        model: model, client: nil, sessionId: "sess-t5", isExternal: true)
            _ = try await MCPTools.call("begin_agent_turn", [
                "turn_id": "turn-edl", "summary": "Keep 2 ranges", "session_id": "sess-t5",
            ], model: model, client: nil, sessionId: "sess-t5", isExternal: true)
            _ = try await MCPTools.call("apply_edl_patch", [
                "session_id": "sess-t5",
                "operations": [[
                    "op": "keep_ranges",
                    "clip_id": initV.id.uuidString,
                    "coord": "timeline",
                    "ripple": true,
                    "ranges": [
                        ["start": 0.2, "end": 1.0],
                        ["start": 1.8, "end": 2.6],
                    ],
                ]],
            ], model: model, client: nil, sessionId: "sess-t5", isExternal: true)
            _ = try await MCPTools.call("commit_agent_turn", [
                "turn_id": "turn-edl", "session_id": "sess-t5",
            ], model: model, client: nil, sessionId: "sess-t5", isExternal: true)

            let v1Clips = model.project.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
            guard v1Clips.count == 2,
                  abs(v1Clips[0].start - 0.0) < 0.05,
                  abs(v1Clips[1].end - 1.6) < 0.05 else {
                return fail("T5", "unexpected V1 clips after keep_ranges: count=\(v1Clips.count)")
            }
            model.undo()
            let restored = model.project.clips.filter { $0.trackID == v1 }
            guard restored.count == 1, abs(restored[0].duration - 3.0) < 0.05 else {
                return fail("T5", "1 Undo did not restore original 3.0s V1 clip")
            }
            _ = try await MCPTools.call("session_release", ["session_id": "sess-t5"],
                                        model: model, client: nil, sessionId: "sess-t5", isExternal: true)
        } catch {
            return fail("T5", "unexpected error: \(error.localizedDescription)")
        }
        log("PASS [T5] apply_edl_patch keep_ranges + 1-step Undo verified")

        // =========================================================================
        // T6: Core Renderer `preview_timeline_strip` & Export Parity (`I3`, `P2`)
        // =========================================================================
        var parityProject = baseProject
        parityProject.clips[0].transform = ClipTransform(scale: 0.5, x: 0, y: 0)
        parityProject.clips[1].transform = ClipTransform() // audio unchanged
        let v2 = parityProject.videoTracks[1].id
        var ovClip = Clip(trackID: v2, kind: .image, assetID: pngAsset.id, start: 0, duration: 2.0)
        ovClip.transform = ClipTransform(scale: 0.3, x: 0, y: 0)
        parityProject.clips.append(ovClip)
        model.load(parityProject, url: nil)

        let stripURL = outDir.appendingPathComponent("strip.jpg")
        do {
            let stripOut = try await MCPTools.call("preview_timeline_strip", [
                "timestamps": [0.5, 1.0],
                "width": 320,
                "grid_cols": 2,
                "output": stripURL.path,
            ], model: model, client: nil, sessionId: nil, isExternal: true)
            guard let imgItem = stripOut.first(where: { ($0["type"] as? String) == "image" }),
                  let b64 = imgItem["data"] as? String,
                  let jpgData = Data(base64Encoded: b64),
                  let nsImg = NSImage(data: jpgData),
                  let stripCG = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  fm.fileExists(atPath: stripURL.path) else {
                return fail("T6", "preview_timeline_strip failed to return/write valid JPEG")
            }
            // Sample bottom-right corner of tile 0 (avoids top-left timestamp pill) to verify solid black margin.
            guard let stripCorner = cornerPixelRGB(cgImage: stripCG, x: 300, y: stripCG.height - 12),
                  stripCorner.r < 12, stripCorner.g < 12, stripCorner.b < 12 else {
                return fail("T6", "preview_timeline_strip margin was not black")
            }
        } catch {
            return fail("T6", "preview_timeline_strip threw: \(error.localizedDescription)")
        }

        let exportURL = outDir.appendingPathComponent("parity.mp4")
        guard await exportProject(model.project, model.media, to: exportURL) else {
            return fail("T6", "Exporter failed for parity.mp4")
        }
        let expAsset = AVURLAsset(url: exportURL)
        let expGen = AVAssetImageGenerator(asset: expAsset)
        expGen.requestedTimeToleranceBefore = .zero
        expGen.requestedTimeToleranceAfter = .zero
        guard let expCG = try? await expGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image,
              let expCorner = cornerPixelRGB(cgImage: expCG, x: 10, y: expCG.height - 10),
              expCorner.r < 12, expCorner.g < 12, expCorner.b < 12 else {
            return fail("T6", "exported frame margin was not solid black")
        }
        log("PASS [T6] preview_timeline_strip & Exporter margin parity verified (RGB < 12 black)")

        // =========================================================================
        // T7: Live HTTP Host Security (`P3`) + 5-Round E2E Revision Consistency (`P1`)
        // =========================================================================
        let prevServerEnabled = MCPServer.shared.enabled
        MCPServer.shared.enabled = true
        defer {
            MCPServer.shared.enabled = prevServerEnabled
            MCPServer.shared.stop()
        }
        MCPServer.shared.stop()
        MCPServer.shared.attach(model)
        MCPServer.shared.start(on: 0)
        for _ in 0..<40 where MCPServer.shared.listeningPort == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let port = MCPServer.shared.listeningPort else {
            return fail("T7", "MCPServer failed to bind loopback ephemeral port")
        }

        // Verify non-loopback Host header is rejected with 403 Forbidden (`P3`).
        let hostCheck = await runProcessAsync("/usr/bin/curl", [
            "-s", "-i", "--max-time", "5", "-X", "POST",
            "-H", "Host: evil.example.com",
            "-H", "Content-Type: application/json",
            "-d", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            "http://127.0.0.1:\(port)/mcp",
        ])
        guard hostCheck.stdout.contains("403 Forbidden") else {
            return fail("T7", "expected 403 Forbidden on spoofed Host header, got: \(hostCheck.stdout.prefix(120))")
        }

        // 5 consecutive live HTTP rounds over URLSession (`begin_agent_turn` -> edit -> `commit_agent_turn` -> `get_project`).
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
                throw MCPToolError("HTTP error on \(method): \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            if let hdr = http.value(forHTTPHeaderField: "Mcp-Session-Id") { mcpSession = hdr }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPToolError("Invalid JSON response for \(method)")
            }
            if let err = obj["error"] as? [String: Any] {
                throw MCPToolError("JSON-RPC error: \(err["message"] ?? err)")
            }
            return (obj["result"] as? [String: Any]) ?? [:]
        }

        func callHTTPTool(_ tool: String, _ args: [String: Any], mcpSession: inout String?) async throws -> [String: Any] {
            let res = try await postMCP(method: "tools/call", params: ["name": tool, "arguments": args], mcpSession: &mcpSession)
            if (res["isError"] as? Bool) == true {
                let msg = ((res["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "unknown tool error"
                throw MCPToolError("\(tool) returned error: \(msg)")
            }
            let content = (res["content"] as? [[String: Any]]) ?? []
            return parseJSONObject(from: content) ?? [:]
        }

        do {
            var httpSessionId: String? = nil
            _ = try await postMCP(method: "initialize", params: ["clientInfo": ["name": "HybridTestHTTP"]], mcpSession: &httpSessionId)
            guard let sid = httpSessionId else {
                return fail("T7", "missing Mcp-Session-Id from initialize")
            }
            _ = try await callHTTPTool("session_attach", ["session_id": sid], mcpSession: &httpSessionId)

            var expectedRev = Int(model.revision)
            for round in 1...5 {
                let tid = "http-round-\(round)"
                _ = try await callHTTPTool("begin_agent_turn", [
                    "turn_id": tid, "summary": "HTTP Round \(round)", "session_id": sid,
                ], mcpSession: &httpSessionId)
                _ = try await callHTTPTool("add_title", [
                    "text": "R\(round)", "start": Double(round) * 0.2, "duration": 0.4, "session_id": sid,
                ], mcpSession: &httpSessionId)
                let committed = try await callHTTPTool("commit_agent_turn", [
                    "turn_id": tid, "session_id": sid,
                ], mcpSession: &httpSessionId)
                expectedRev += 1
                let committedRev = committed["revision"] as? Int
                let queried = try await callHTTPTool("get_project", [:], mcpSession: &httpSessionId)
                let queriedRev = queried["revision"] as? Int
                guard committedRev == expectedRev, queriedRev == expectedRev else {
                    return fail("T7", "round \(round) revision mismatch: expected=\(expectedRev) commit=\(String(describing: committedRev)) get_project=\(String(describing: queriedRev))")
                }
            }
            _ = try await callHTTPTool("session_release", ["session_id": sid], mcpSession: &httpSessionId)
        } catch {
            return fail("T7", "live HTTP E2E failed: \(error.localizedDescription)")
        }
        log("PASS [T7] Live HTTP Host security (403) + 5-round revision E2E verified (port=\(port))")
        log("ALL 7 GUARDRAIL CHECKS PASSED")
        return true
    }
}
