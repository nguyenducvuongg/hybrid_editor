import AVFoundation
import AppKit

/// `Editroom --format-check <outDir> <file>...`: imports each file and reports what the app made of
/// it, then checks a frame from playback, from a reversed copy, from the library thumbnail and from
/// an export. Test clips made with six flat colour patches (named sdr_, hlg_, pq_, applelog_) also
/// get their colours compared with what they should look like.
@MainActor
enum FormatCheck {
    /// The patches' intended look, in sRGB.
    static let expected: [(Int, Int, Int)] = [(118, 118, 118), (235, 235, 235), (200, 40, 40), (40, 170, 60), (40, 60, 200), (224, 172, 105)]

    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--format-check"), args.count > i + 2 else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            await BaseVideo.load()
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let fmt = { (m: [[Double]]) in m.map { $0.map { String(format: "%.4f", $0) }.joined(separator: " ") }.joined(separator: " | ") }
            log("FORMAT matrix Rec.2020 to 709: \(fmt(SourceColor.rec2020To709))")
            log("FORMAT matrix Apple Wide Gamut to 709: \(fmt(SourceColor.wideGamutTo709))")
            var assets: [MediaAsset] = []
            for f in files { if let a = await check(f, out: out) { assets.append(a) } }
            // Every video clip in a row: a timeline mixing formats, as people really edit. The
            // system can hand frames over differently here than for a clip on its own.
            let mixedMedia = MediaStore()
            var p = Project()
            for f in files { if let a = await mixedMedia.importFile(f) { p.assets.append(a) } }
            var t = 0.0
            for a in p.assets where a.kind == .video {
                p.clips.append(Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: a.id, start: t, duration: min(a.duration, 2)))
                t += min(a.duration, 2)
            }
            p.width = 1920; p.height = 1080
            var start = 0.0
            for c in p.clips {
                let name = p.assets.first { $0.id == c.assetID }?.name ?? "?"
                let px = frame(p, media: mixedMedia, at: start + 1)
                let patches = ["sdr_", "hlg_", "pq_", "applelog_"].contains { name.hasPrefix($0) }
                if let px, patches {
                    let worst = zip(px, expected).map { max(abs($0.0 - $1.0), abs($0.1 - $1.1), abs($0.2 - $1.2)) }.max() ?? 0
                    log("FORMAT mixed timeline, \(name): worst off by \(worst)  [\(px.map { "\($0.0),\($0.1),\($0.2)" }.joined(separator: "  "))]")
                } else {
                    log("FORMAT mixed timeline, \(name): \(px == nil ? "NO FRAME" : "frame ok")")
                }
                start += c.duration
            }
            _ = assets
            if let data = try? JSONEncoder().encode(SavedDocument(project: p)) {
                try? data.write(to: out.appendingPathComponent("formats.room"))
            }
            exit(0)
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    @discardableResult
    static func check(_ file: URL, out: URL) async -> MediaAsset? {
        let name = file.lastPathComponent
        let media = MediaStore()
        let t0 = Date()
        guard let a = await media.importFile(file) else { log("FORMAT \(name): IMPORT FAILED"); return nil }
        let rt = media.runtimes[a.id]
        let audioDesc: String = {
            guard let t = rt?.audioTrack, let fd = t.formatDescriptions.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd as! CMAudioFormatDescription)?.pointee else { return "none" }
            let id = asbd.mFormatID
            let code = String(bytes: [UInt8(id >> 24 & 255), UInt8(id >> 16 & 255), UInt8(id >> 8 & 255), UInt8(id & 255)], encoding: .ascii) ?? "?"
            return "\(code) \(asbd.mChannelsPerFrame)ch \(Int(asbd.mSampleRate))Hz"
        }()
        log(String(format: "FORMAT %@: imported in %.2fs as %@ %dx%d %.3f fps %.2fs, audio %@%@, colour %@", name, Date().timeIntervalSince(t0),
                   a.kind == .video ? "video" : "audio", a.width, a.height, a.fps, a.duration, audioDesc,
                   a.playablePath != nil ? " (converted with ffmpeg)" : "", "\(rt?.sourceColor ?? .standard)"))
        guard a.kind == .video else { return a }

        var p = Project()
        p.width = a.width; p.height = a.height; p.fps = EditorModel.standardFPS(a.fps)
        p.assets = [a]
        let clip = Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: a.id, start: 0, duration: min(a.duration, 1.5))
        p.clips = [clip]
        let patches = name.hasPrefix("sdr_") || name.hasPrefix("hlg_") || name.hasPrefix("pq_") || name.hasPrefix("applelog_")

        func report(_ label: String, _ px: [(Int, Int, Int)]?) {
            guard let px else { log("FORMAT \(name): \(label) NO FRAME"); return }
            guard patches else { log("FORMAT \(name): \(label) frame ok"); return }
            let worst = zip(px, expected).map { max(abs($0.0 - $1.0), abs($0.1 - $1.1), abs($0.2 - $1.2)) }.max() ?? 0
            let s = px.map { "\($0.0),\($0.1),\($0.2)" }.joined(separator: "  ")
            log("FORMAT \(name): \(label) worst off by \(worst)  [\(s)]")
        }

        report("playback", frame(p, media: media))
        var rev = p
        rev.clips[0].reversed = true
        report("reversed", frame(rev, media: media))
        // Hover preview frames (the same grabber as library tiles and filmstrips), early and late.
        if let gen = rt?.viewerGenerator {
            for at in [0.2, min(1.0, a.duration * 0.6)] {
                let cg: CGImage? = await withCheckedContinuation { cont in
                    gen.generateCGImageAsynchronously(for: CMTime(seconds: at, preferredTimescale: 600)) { cg, _, _ in cont.resume(returning: cg) }
                }
                report(String(format: "preview at %.1fs %@", at, cg.map { "\($0.width)x\($0.height)" } ?? ""), cg.flatMap(sample))
            }
        }

        let url = out.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".mp4")
        let exporter = Exporter()
        exporter.start(project: p, media: media, settings: ExportSettings(), url: url)
        while exporter.state == .running { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard case .done = exporter.state else { log("FORMAT \(name): EXPORT FAILED \(exporter.state)"); return a }
        let exported = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: exported)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let dur = (try? await exported.load(.duration).seconds) ?? 0
        let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        report(String(format: "export (%.2fs)", dur), cg.flatMap(sample))
        return a
    }

    /// A frame at `at` seconds through the same pipeline playback uses, at full size.
    static func frame(_ p: Project, media: MediaStore, at: Double = 0.5) -> [(Int, Int, Int)]? {
        let size = CGSize(width: p.width, height: p.height)
        guard let built = CompositionBuilder.build(project: p, media: media, renderSize: size, includeAudio: false),
              let reader = try? AVAssetReader(asset: built.composition) else { return nil }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video),
                                                         videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = built.videoComposition
        reader.add(output)
        // Read from the start, as export does, and keep the frame at 0.5 s.
        guard reader.startReading() else { return nil }
        var found: CMSampleBuffer?
        while let s = output.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(s).seconds >= at - 1e-3 { found = s; break }
        }
        guard let s = found, let pb = CMSampleBufferGetImageBuffer(s) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        return (0..<6).map { i in
            let x = (2 * i + 1) * w / 12, y = h * 3 / 10
            let o = y * row + x * 4
            return (Int(base[o + 2]), Int(base[o + 1]), Int(base[o]))
        }
    }

    /// Patch colours of an image, converted to sRGB.
    static func sample(_ cg: CGImage) -> [(Int, Int, Int)]? {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (0..<6).map { i in
            let x = (2 * i + 1) * w / 12, y = h * 3 / 10
            let o = y * w * 4 + x * 4
            return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
        }
    }
}
