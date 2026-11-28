import AppKit

/// Full-screen viewer, done the way an image editor does it rather than with macOS's full screen:
/// the window itself covers the screen at once, with the Dock, menu bar, toolbar and window buttons
/// hidden, instead of animating into a new space. Leaving puts the window back exactly as it was.
@MainActor
enum ViewerScreen {
    private static var before: (frame: NSRect, transparentTitlebar: Bool, titleVisibility: NSWindow.TitleVisibility,
                                fullSizeContent: Bool, presentation: NSApplication.PresentationOptions)?
    /// Black over the screen around the window: its rounded corners and the faint rim macOS draws at its edge.
    private static var cover: NSWindow?
    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    static func enter(_ window: NSWindow) {
        // Already in macOS full screen, the window has the screen; only the toolbar needs putting away.
        if window.styleMask.contains(.fullScreen) {
            window.toolbar?.isVisible = false
            return
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        before = (window.frame, window.titlebarAppearsTransparent, window.titleVisibility,
                  window.styleMask.contains(.fullSizeContentView), NSApp.presentationOptions)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.toolbar?.isVisible = false
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        buttons.forEach { window.standardWindowButton($0)?.isHidden = true }
        window.setFrame(screen.frame, display: true, animate: false)

        let frame = cover ?? NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.isReleasedWhenClosed = false
        frame.ignoresMouseEvents = true
        frame.hasShadow = false
        frame.setFrame(screen.frame, display: false)
        // The window may stop short of the screen's top, kept clear of the menu bar it hides.
        let inside = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).insetBy(dx: 2, dy: 2)
        frame.contentView = CoverView(inside: inside)
        window.addChildWindow(frame, ordered: .above)
        cover = frame
    }

    static func exit(_ window: NSWindow) {
        guard let b = before else {
            window.toolbar?.isVisible = true
            return
        }
        // Title bar first, then toolbar, then size, so the toolbar lays out beside the window buttons as before.
        NSApp.presentationOptions = b.presentation
        if !b.fullSizeContent { window.styleMask.remove(.fullSizeContentView) }
        window.titlebarAppearsTransparent = b.transparentTitlebar
        window.titleVisibility = b.titleVisibility
        buttons.forEach { window.standardWindowButton($0)?.isHidden = false }
        window.toolbar?.isVisible = true
        window.setFrame(b.frame, display: true, animate: false)
        if let frame = cover {
            window.removeChildWindow(frame)
            frame.orderOut(nil)
        }
        before = nil
    }
}

private final class CoverView: NSView {
    private let inside: NSRect

    init(inside: NSRect) {
        self.inside = inside
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let path = NSBezierPath(rect: bounds)
        // Rounder than the window's own corners, so the black reaches into them.
        path.append(NSBezierPath(roundedRect: inside, xRadius: 26, yRadius: 26))
        path.windingRule = .evenOdd
        path.fill()
    }
}
