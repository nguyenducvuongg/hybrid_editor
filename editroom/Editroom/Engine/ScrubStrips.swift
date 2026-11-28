import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Frames from across each video, made ahead of time in the background, so hover-scrubbing a Media
/// item is instant: moving the mouse picks a frame that's already there instead of decoding one from
/// the file. Kept small (JPEG, 480 pixels) in memory and on disk, so reopening a project has them at once.
@MainActor
final class ScrubStrips {
    struct Strip {
        let frames: [Data]
        var count: Int { frames.count }
    }

    private var strips: [UUID: Strip] = [:]
    private var queue: [(UUID, MediaRuntime, Double)] = []
    private var working: UUID?
    /// Being made from a file that has since changed: thrown away when done, and made again from the
    /// new file if it was asked for meanwhile.
    private var stale = Set<UUID>()
    private var again: [UUID: (MediaRuntime, Double)] = [:]
    /// Frames already decoded for the item being hovered.
    private var decoded: [Int: CGImage] = [:]
    private var decodedFor: UUID?

    /// How many frames for a file this long: a few a second, 24 to 120.
    nonisolated static func count(for duration: Double) -> Int { min(120, max(24, Int(duration * 4))) }

    /// The frame nearest a point across the item (0 at the start, 1 at the end), if its strip is made.
    func frame(_ id: UUID, at fraction: Double) -> CGImage? {
        guard let s = strips[id], s.count > 0 else { return nil }
        let i = min(s.count - 1, max(0, Int((fraction * Double(s.count - 1)).rounded())))
        if decodedFor != id { decoded = [:]; decodedFor = id }
        if let img = decoded[i] { return img }
        guard let src = CGImageSourceCreateWithData(s.frames[i] as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        decoded[i] = img
        return img
    }

    func has(_ id: UUID) -> Bool { strips[id] != nil }

    /// Queues a video's strip. `soon` puts it first (it's being hovered now).
    func make(_ id: UUID, _ rt: MediaRuntime, duration: Double, soon: Bool = false) {
        if working == id, stale.contains(id) { again[id] = (rt, duration); return }
        guard strips[id] == nil, working != id, rt.videoTrack != nil, duration > 0 else { return }
        if let i = queue.firstIndex(where: { $0.0 == id }) {
            guard soon else { return }
            queue.remove(at: i)
        }
        if soon { queue.insert((id, rt, duration), at: 0) } else { queue.append((id, rt, duration)) }
        next()
    }

    func forget(_ id: UUID) {
        strips[id] = nil
        queue.removeAll { $0.0 == id }
        if working == id { stale.insert(id) }
        if decodedFor == id { decoded = [:]; decodedFor = nil }
    }

    private func next() {
        guard working == nil, !queue.isEmpty else { return }
        let (id, rt, duration) = queue.removeFirst()
        working = id
        Task.detached(priority: .utility) { [weak self] in
            let frames = await Self.build(rt, duration: duration)
            await MainActor.run {
                guard let self else { return }
                self.working = nil
                if self.stale.remove(id) != nil {
                    if let (rt, d) = self.again.removeValue(forKey: id) { self.queue.append((id, rt, d)) }
                } else if let frames, !frames.isEmpty { self.strips[id] = Strip(frames: frames) }
                self.next()
            }
        }
    }

    // MARK: Making a strip

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Scrub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func build(_ rt: MediaRuntime, duration: Double) async -> [Data]? {
        let file = folder.appendingPathComponent(ReverseAudio.cacheName(for: rt.asset.url) + ".strip")
        if let data = try? Data(contentsOf: file),
           let frames = try? PropertyListDecoder().decode([Data].self, from: data), !frames.isEmpty { return frames }
        let n = count(for: duration)
        // Its own grabber, so hovering elsewhere doesn't cancel it.
        let grabber = await MainActor.run { rt.makeGenerator(maximumSize: CGSize(width: 480, height: 480), tolerance: CMTime(value: 1, timescale: 15)) }
        var frames: [Data] = []
        for i in 0..<n {
            let t = min(max(0, duration - 0.05), Double(i) / Double(max(1, n - 1)) * duration)
            let image: CGImage? = await withCheckedContinuation { done in
                grabber.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 600)) { cg, _, _ in done.resume(returning: cg) }
            }
            // A frame that wouldn't come: the one before it stands in.
            guard let image, let jpeg = jpeg(image) else {
                if let last = frames.last { frames.append(last) }
                continue
            }
            frames.append(jpeg)
        }
        guard frames.count == n else { return nil }
        if let data = try? PropertyListEncoder().encode(frames) { try? data.write(to: file, options: .atomic) }
        return frames
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
