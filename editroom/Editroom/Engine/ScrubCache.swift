import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Frames from each video, twelve a second, made ahead in the background so dragging the playhead or
/// skimming shows a picture at once. Exact seeks into long-GOP footage (a 4K screen recording, a phone
/// clip) take tens of milliseconds each, so the viewer fell behind a quick drag; these frames are
/// already decoded, and the viewer is composited from them on the GPU while the scrub moves, with the
/// exact frame following as soon as it rests. As sharp as the viewer's own picture (up to 1920 pixels,
/// what the player renders at), so nothing goes soft while scrubbing. HEIC, one file per video on disk,
/// read only as frames are needed, so long footage doesn't fill memory; reopening a project has them at
/// once. The file's own pixels, not turned upright: the compositor turns them as it does the player's.
@MainActor
final class ScrubCache {
    nonisolated static let rate = 12.0
    /// The longest side: the preview's own size, so a scrub frame is as sharp as the exact one.
    nonisolated static let maxSide = 1920.0

    /// A video's frames: the file, mapped (not read in), and where each frame starts and ends.
    struct Store {
        let data: Data
        let ranges: [Range<Int>]
    }
    private var frames: [UUID: Store] = [:]
    private var queue: [(UUID, URL, Double)] = []
    private var working: UUID?
    /// Being made from a file that has since changed: thrown away when done, and made again from the
    /// new file if it was asked for meanwhile.
    private var stale = Set<UUID>()
    private var again: [UUID: (URL, Double)] = [:]

    func has(_ id: UUID) -> Bool { frames[id] != nil }

    /// The frame nearest a time in the file, if its frames are made. Decoded when it's drawn (on the
    /// scrub queue, by the GPU's image decoder), not here.
    func image(_ id: UUID, at time: Double) -> CIImage? {
        guard let f = frames[id], !f.ranges.isEmpty else { return nil }
        let i = min(f.ranges.count - 1, max(0, Int((time * Self.rate).rounded())))
        // Its values as they are (Rec.709, like the player's frames), not colour-matched on the way in.
        return CIImage(data: f.data.subdata(in: f.ranges[i]), options: [.colorSpace: NSNull()])
    }

    /// Queues a video's frames (once).
    func make(_ id: UUID, url: URL, duration: Double) {
        if working == id, stale.contains(id) { again[id] = (url, duration); return }
        guard frames[id] == nil, working != id, duration > 0, !queue.contains(where: { $0.0 == id }) else { return }
        queue.append((id, url, duration))
        next()
    }

    func forget(_ id: UUID) {
        frames[id] = nil
        queue.removeAll { $0.0 == id }
        if working == id { stale.insert(id) }
    }

    private func next() {
        guard working == nil, !queue.isEmpty else { return }
        let (id, url, duration) = queue.removeFirst()
        working = id
        Task.detached(priority: .utility) { [weak self] in
            let made = await Self.build(url, duration: duration)
            await MainActor.run {
                guard let self else { return }
                self.working = nil
                if self.stale.remove(id) != nil {
                    if let (url, d) = self.again.removeValue(forKey: id) { self.queue.append((id, url, d)) }
                } else if let made { self.frames[id] = made }
                self.next()
            }
        }
    }

    // MARK: Making them

    nonisolated private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Scrub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Unmanaged, like the compositor's: the file's Rec.709 values go in and come out untouched (a
    /// managed context turned them into sRGB, which looked brighter and more saturated than playback).
    nonisolated private static let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
    ])
    /// What the frames are tagged as, so shown on their own (trimming) they look as playback does.
    nonisolated private static let rec709 = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    /// Reads the file through once, start to end (much faster than seeking), keeping a frame every tenth
    /// of a second.
    nonisolated static func build(_ url: URL, duration: Double) async -> Store? {
        let file = folder.appendingPathComponent(ReverseAudio.cacheName(for: url) + ".scrub709")
        if let saved = load(file) { return saved }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        let count = Int((duration * rate).rounded(.up)) + 1
        // Written to disk as they're made (an eleven-minute file is thousands of frames): first room for
        // how many and where each ends, then the frames; the ends go in once they're all known.
        let partial = file.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else { return nil }
        defer { try? handle.close() }
        let head = 8 + count * 8
        try? handle.write(contentsOf: Data(count: head))
        var ends: [UInt64] = []
        var size = UInt64(0)
        var last: Data?
        func put(_ frame: Data) {
            try? handle.write(contentsOf: frame)
            size += UInt64(frame.count)
            ends.append(size)
            last = frame
        }
        while ends.count < count, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // This frame stands for every twelfth of a second it's the latest one for.
            while ends.count < count, Double(ends.count) / rate <= t + 0.5 / rate {
                guard let frame = autoreleasepool(invoking: { encode(buffer) }) else {
                    try? FileManager.default.removeItem(at: partial)
                    return nil
                }
                put(frame)
            }
        }
        reader.cancelReading()
        guard let end = last else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        // The end of the file: the last frame stands in.
        while ends.count < count { put(end) }
        var header = Data()
        var n = UInt64(count)
        header.append(Data(bytes: &n, count: 8))
        for var e in ends { header.append(Data(bytes: &e, count: 8)) }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: header)
        try? handle.close()
        try? FileManager.default.removeItem(at: file)
        guard (try? FileManager.default.moveItem(at: partial, to: file)) != nil else { return nil }
        trim()
        return load(file)
    }

    /// Keeps the folder under 6 GB: the files used longest ago go first (they're made again if needed).
    nonisolated private static func trim() {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        // (Older kinds of scrub file are just removed.)
        for old in files where ["scrubhd", "scrub10"].contains(old.pathExtension) { try? FileManager.default.removeItem(at: old) }
        let scrub = files.filter { $0.pathExtension == "scrub709" }.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentAccessDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = scrub.reduce(0) { $0 + $1.2 }
        for (url, _, size) in scrub where total > 6_000_000_000 {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    /// A saved file, mapped rather than read, with its frames' places.
    nonisolated private static func load(_ file: URL) -> Store? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count > 8 else { return nil }
        func word(_ at: Int) -> Int { Int(data.subdata(in: at..<at + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) }
        let n = word(0)
        let head = 8 + n * 8
        guard n > 0, data.count >= head else { return nil }
        var ranges: [Range<Int>] = []
        var start = head
        for i in 0..<n {
            let end = head + word(8 + i * 8)
            guard end > start, end <= data.count else { return nil }
            ranges.append(start..<end)
            start = end
        }
        return Store(data: data, ranges: ranges)
    }

    nonisolated private static func encode(_ buffer: CVPixelBuffer) -> Data? {
        let img = CIImage(cvPixelBuffer: buffer)
        let e = img.extent
        guard e.width > 0 else { return nil }
        let s = min(1, maxSide / max(e.width, e.height))
        let sized = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = context.createCGImage(sized, from: sized.extent, format: .RGBA8, colorSpace: rec709) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
