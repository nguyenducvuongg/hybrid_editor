import AppKit
import QuartzCore

/// Connected agents' cursors while they're between edits: each waits where it last worked, with its
/// name, bobbing gently, and fades away after a while without a call.
@MainActor
final class AgentPresence {
    static let shared = AgentPresence()

    private struct Parked {
        let cursor = CALayer()
        let tag = CALayer()
        let text = CATextLayer()
        var at: CGPoint
        var since: Double
    }

    private var window: NSWindow?
    private weak var host: NSWindow?
    private let root = CALayer()
    private var parked: [String: Parked] = [:]
    private var timer: Timer?
    /// How long a cursor waits for its agent's next call.
    static let linger = 12.0

    /// Leaves an agent's cursor at a point (overlay coordinates: from the window's top-left).
    func park(_ name: String, color: NSColor, at point: CGPoint, in host: NSWindow) {
        attach(to: host)
        var p = parked.removeValue(forKey: name) ?? makeParked(name, color: color, scale: host.backingScaleFactor)
        p.at = point
        p.since = CACurrentMediaTime()
        parked[name] = p
        tick()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Takes an agent's cursor back for its next edit; returns where it was, if it's still around.
    func take(_ name: String) -> CGPoint? {
        guard let p = parked.removeValue(forKey: name) else { return nil }
        p.cursor.removeFromSuperlayer()
        p.tag.removeFromSuperlayer()
        return p.at
    }

    private func makeParked(_ name: String, color: NSColor, scale: CGFloat) -> Parked {
        let p = Parked(at: .zero, since: 0)
        p.cursor.contents = MagicShow.cursorImage(color, scale: scale)
        p.cursor.contentsScale = scale
        p.cursor.bounds = CGRect(x: 0, y: 0, width: 18, height: 24)
        p.cursor.anchorPoint = CGPoint(x: 2 / 18, y: 2 / 24)
        p.tag.backgroundColor = color.blended(withFraction: 0.18, of: .black)?.cgColor
        p.tag.cornerRadius = 4
        p.text.contentsScale = scale
        p.text.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        p.text.fontSize = 10
        p.text.foregroundColor = NSColor.white.cgColor
        p.text.alignmentMode = .center
        p.text.string = name
        let w = ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 12
        p.tag.bounds = CGRect(x: 0, y: 0, width: w, height: 16)
        p.text.frame = CGRect(x: 0, y: 1.5, width: w, height: 14)
        p.tag.addSublayer(p.text)
        root.addSublayer(p.tag)
        root.addSublayer(p.cursor)
        return p
    }

    private func attach(to host: NSWindow) {
        if window != nil, self.host === host { return }
        let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let view = PresenceView(frame: NSRect(origin: .zero, size: host.frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.frame = view.bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        w.contentView = view
        host.addChildWindow(w, ordered: .above)
        window = w
        self.host = host
    }

    private func tick() {
        guard let host, let window else { return }
        if window.frame != host.frame { window.setFrame(host.frame, display: false) }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (name, p) in parked {
            let age = now - p.since
            if age > Self.linger + 0.5 {
                _ = take(name)
                continue
            }
            // A slow bob, so it reads as waiting rather than stuck.
            let bob = CGFloat(sin(now * 2.2 + Double(name.hashValue % 7))) * 2
            let fade = Float(max(0, min(1, (Self.linger + 0.5 - age) / 0.5)))
            p.cursor.position = CGPoint(x: p.at.x, y: p.at.y + bob)
            p.tag.position = CGPoint(x: p.at.x + 10 + p.tag.bounds.width / 2, y: p.at.y + 26 + bob)
            p.cursor.opacity = fade
            p.tag.opacity = fade
        }
        CATransaction.commit()
        if parked.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

private final class PresenceView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
