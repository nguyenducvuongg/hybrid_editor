import Foundation

/// A zoom over a clip, set on its Scale: the picture moves between the full frame and the clip's Scale and
/// position (the zoomed-in framing), in, out, or in and back out.
struct ZoomMove: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable {
        /// From the full frame to the zoomed framing.
        case zoomIn = "in"
        /// In, hold, and back out.
        case inOut
        /// From the zoomed framing back to the full frame.
        case zoomOut = "out"
    }

    var mode: Mode
    /// Seconds from the clip's start: the move in runs `p1...p2`, the move out `p3...p4`.
    var p1: Double
    var p2: Double
    var p3: Double
    var p4: Double
    /// Eased at both ends of each move; otherwise at an even pace.
    var smooth = true

    /// Mode last picked, which new zooms start in.
    static let modeKey = "zoomMoveMode"
    static var lastMode: Mode { UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .zoomIn }

    /// A starting zoom for a clip `length` seconds long: each move a quarter of the clip, between half a
    /// second and two (and never more than half a short clip).
    static func starter(_ mode: Mode, length: Double) -> ZoomMove {
        let m = min(max(length * 0.25, 0.5), 2, length / 2)
        switch mode {
        case .zoomIn: return ZoomMove(mode: mode, p1: 0, p2: m, p3: length, p4: length)
        case .zoomOut: return ZoomMove(mode: mode, p1: 0, p2: 0, p3: length - m, p4: length)
        case .inOut: return ZoomMove(mode: mode, p1: 0, p2: m, p3: length - m, p4: length)
        }
    }

    /// How far in at `u` seconds into the clip: 0 is the full frame, 1 the clip's Scale.
    func amount(at u: Double) -> Double {
        switch mode {
        case .zoomIn: return ramp(u, p1, p2)
        case .zoomOut: return 1 - ramp(u, p3, p4)
        case .inOut: return u < p3 ? ramp(u, p1, p2) : 1 - ramp(u, p3, p4)
        }
    }

    private func ramp(_ u: Double, _ a: Double, _ b: Double) -> Double {
        guard b - a > 1e-6 else { return u >= a ? 1 : 0 }
        let k = min(max((u - a) / (b - a), 0), 1)
        return smooth ? k * k * (3 - 2 * k) : k
    }

    /// Where it's all the way in, for showing the zoomed framing.
    func zoomedTime(length: Double) -> Double {
        switch mode {
        case .zoomIn: return min(max(p2, 0), max(0, length - 1e-3))
        case .zoomOut: return min(max(0, p3 - 1e-3), max(0, length - 1e-3))
        case .inOut: return min(max(p2, 0), max(0, length - 1e-3))
        }
    }

    /// Kept within a clip `length` long and in order. In a clip cut from a longer one, a move that's
    /// fallen off an end is gone: an in-and-out cut in the middle leaves an in and an out.
    mutating func fit(length: Double) {
        let c = { (v: Double) in min(max(v, 0), length) }
        p1 = c(p1); p2 = max(p1, c(p2)); p3 = max(p2, c(p3)); p4 = max(p3, c(p4))
    }

    /// After the clip's start moves later by `d` seconds (its head trimmed), so the zoom stays on its picture.
    mutating func shift(by d: Double, length: Double) {
        p1 -= d; p2 -= d; p3 -= d; p4 -= d
        fit(length: length)
    }
}

extension ClipTransform {
    /// The framing at `u` seconds into the clip, with any zoom applied; nil when that's the plain full frame.
    func at(_ u: Double) -> ClipTransform? {
        guard let zoom else {
            var t = self
            (t.x, t.y) = zoomedOffset
            return t.isIdentity ? nil : t
        }
        let k = zoom.amount(at: u)
        var t = ClipTransform()
        t.scale = 1 + (scale - 1) * k
        // The framing zooms toward a fixed point, so the offset grows with the scale; zoomed in, it never
        // shows past the picture's edge.
        let o = zoomedOffset
        t.x = o.x * k
        t.y = o.y * k
        return t.isIdentity ? nil : t
    }

    /// Bigger than the frame: placed by where it frames, never past its edges.
    var fills: Bool { scale > 1.001 }

    /// The offset when all the way in, kept so a picture bigger than the frame still covers it.
    var zoomedOffset: (x: Double, y: Double) {
        guard fills else { return (x, y) }
        let m = (scale - 1) / 2
        return (min(max(x, -m), m), min(max(y, -m), m))
    }
}
