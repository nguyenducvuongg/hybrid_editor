import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// One normalized (`0...1` across/down) crop focus keyframe on the timeline.
struct ReframeKeyframe: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
}

/// Smoothly interpolated crop center trajectory for reframing a wide sequence into `9:16`, `1:1`, or `4:5` (`I3`, `P2`).
struct ReframePath: Codable, Equatable, Sendable {
    var keyframes: [ReframeKeyframe]
    var fallbackX: Double = 0.5
    var fallbackY: Double = 0.5

    var fallback: CGPoint { CGPoint(x: fallbackX, y: fallbackY) }

    init(keyframes: [ReframeKeyframe], fallback: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.fallbackX = Self.clamp01(fallback.x)
        self.fallbackY = Self.clamp01(fallback.y)
    }

    /// Evaluates the normalized crop center (`0...1` across, top-down) at timeline timestamp `time`.
    func center(at time: Double) -> CGPoint {
        guard !keyframes.isEmpty else { return fallback }
        if time <= keyframes[0].time {
            return CGPoint(x: Self.clamp01(keyframes[0].x), y: Self.clamp01(keyframes[0].y))
        }
        if time >= keyframes[keyframes.count - 1].time {
            let last = keyframes[keyframes.count - 1]
            return CGPoint(x: Self.clamp01(last.x), y: Self.clamp01(last.y))
        }
        var lo = 0
        var hi = keyframes.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if keyframes[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = keyframes[lo]
        let b = keyframes[hi]
        let span = b.time - a.time
        let u = span > 1e-6 ? max(0, min(1, (time - a.time) / span)) : 0
        // Smoothstep avoids linear corner-jerk at keyframe boundaries.
        let s = u * u * (3 - 2 * u)
        return CGPoint(
            x: Self.clamp01(a.x + (b.x - a.x) * s),
            y: Self.clamp01(a.y + (b.y - a.y) * s)
        )
    }

    /// Converts normalized center into Core Image bottom-left canvas offset (`CompositionBuilder` coordinate space).
    func offset(at time: Double, canvas: CGSize, output: CGSize) -> CGPoint {
        let c = center(at: time)
        let maxX = max(0, canvas.width - output.width)
        let maxY = max(0, canvas.height - output.height)
        let ox = min(max(0, c.x * canvas.width - output.width / 2), maxX)
        let top = min(max(0, c.y * canvas.height - output.height / 2), maxY)
        return CGPoint(x: ox, y: maxY - top)
    }

    private static func clamp01(_ v: Double) -> Double {
        min(1.0, max(0.0, v))
    }
}

/// Offline Apple Vision face-tracking & smooth EMA crop-path generator (`I3`, `I6`).
enum AutoReframeEngine {
    /// Detects the largest human face in a `CGImage`, returning its normalized top-down center (`0...1`).
    static func detectFaceCenter(in cgImage: CGImage) -> CGPoint? {
        let req = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
        } catch {
            return nil
        }
        let faces = (req.results ?? []).filter { $0.boundingBox.width * $0.boundingBox.height > 0.004 }
        guard let best = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            return nil
        }
        // Vision boundingBox uses bottom-left origin; flip Y to top-down 0...1.
        let x = min(0.95, max(0.05, best.boundingBox.midX))
        let y = min(0.85, max(0.15, (1.0 - best.boundingBox.midY) + 0.04))
        return CGPoint(x: x, y: y)
    }

    /// Stabilizes raw detections using deadband suppression + bidirectional EMA smoothing.
    static func smooth(_ raw: [ReframeKeyframe], alpha: Double = 0.35, deadband: Double = 0.025) -> [ReframeKeyframe] {
        guard raw.count > 1 else { return raw }
        let sorted = raw.sorted { $0.time < $1.time }
        var forward = [ReframeKeyframe]()
        forward.reserveCapacity(sorted.count)
        var cx = sorted[0].x
        var cy = sorted[0].y
        forward.append(sorted[0])
        for k in sorted.dropFirst() {
            let dist = hypot(k.x - cx, k.y - cy)
            if dist >= deadband {
                cx += alpha * (k.x - cx)
                cy += alpha * (k.y - cy)
            }
            forward.append(ReframeKeyframe(time: k.time, x: cx, y: cy))
        }
        // Backward pass removes phase lag while keeping transitions silky.
        let beta = 0.25
        var out = forward
        var bx = out[out.count - 1].x
        var by = out[out.count - 1].y
        for i in stride(from: out.count - 2, through: 0, by: -1) {
            bx += beta * (out[i].x - bx)
            by += beta * (out[i].y - by)
            out[i].x = min(1.0, max(0.0, bx))
            out[i].y = min(1.0, max(0.0, by))
        }
        return out
    }

    /// Samples timeline frames through `CompositionBuilder` and builds a smooth face-tracking `ReframePath`.
    @MainActor
    static func analyze(
        project: Project,
        media: MediaStore,
        sampleIntervalSec: Double = 0.5,
        detector: (@Sendable (CGImage) -> CGPoint?)? = nil
    ) async -> ReframePath {
        let total = project.duration
        guard total > 0 else { return ReframePath(keyframes: []) }

        let aspect = Double(max(1, project.width)) / Double(max(1, project.height))
        let probeW = 480.0
        let probeH = max(2.0, ((probeW / aspect / 2.0).rounded()) * 2.0)
        guard let built = CompositionBuilder.build(
            project: project,
            media: media,
            renderSize: CGSize(width: probeW, height: probeH),
            includeAudio: false
        ) else {
            return ReframePath(keyframes: [])
        }

        let step = max(0.25, max(sampleIntervalSec, total / 120.0))
        var sampleTimes: [Double] = []
        var cursor = 0.0
        let endLimit = max(0.0, total - 0.04)
        while cursor < endLimit {
            sampleTimes.append(cursor)
            cursor += step
        }
        if sampleTimes.isEmpty || (endLimit - (sampleTimes.last ?? 0)) > 0.15 {
            sampleTimes.append(endLimit)
        }

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        if project.isHDR, #available(macOS 15, *) {
            generator.dynamicRangePolicy = .forceSDR
        }

        let detectFn: @Sendable (CGImage) -> CGPoint? = detector ?? { img in Self.detectFaceCenter(in: img) }
        var raw: [ReframeKeyframe] = []
        var lastKnown = CGPoint(x: 0.5, y: 0.5)
        var lastSeenAt: Double? = nil

        for t in sampleTimes {
            guard let cg = try? await generator.image(at: CompositionBuilder.time(t)).image else { continue }
            if let detected = detectFn(cg) {
                lastKnown = detected
                lastSeenAt = t
            } else if let prevT = lastSeenAt, t - prevT > 2.5 {
                // Gently relax back toward center during prolonged faceless B-roll stretches.
                lastKnown = CGPoint(
                    x: lastKnown.x + (0.5 - lastKnown.x) * 0.35,
                    y: lastKnown.y + (0.5 - lastKnown.y) * 0.35
                )
            }
            raw.append(ReframeKeyframe(time: t, x: lastKnown.x, y: lastKnown.y))
        }

        let smoothed = smooth(raw)
        let initial = smoothed.first.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: 0.5, y: 0.5)
        return ReframePath(keyframes: smoothed, fallback: initial)
    }
}
