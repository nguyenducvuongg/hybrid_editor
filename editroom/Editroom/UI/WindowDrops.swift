import AppKit
import SwiftUI

/// Over the whole window: files dragged in from another app are caught here (over the timeline, the drag is handed to
/// the timeline, which places them where they're dropped), so the drop can tell macOS how to finish: their pictures vanish as they're let go and the files are
/// in Media at once, rather than macOS's fade where they were let go. Every click, scroll and hover passes through to what's below,
/// and so do drags that start in Editroom.
struct WindowDropCatcher: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.model = model
        // Files, and files another app promises (Photos, Mail).
        // Files, and files another app promises (Photos, Mail); and Editroom's own clips from Media, but only over the
        // track headers, where they're handed to the timeline.
        v.registerForDraggedTypes([.fileURL, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return v
    }

    func updateNSView(_ v: Catcher, context: Context) { v.model = model }

    final class Catcher: NSView {
        weak var model: EditorModel?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only while a drag from another app is over the window: the mouse button is down, but the event
            // isn't one of Editroom's own clicks or drags.
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return nil }
            // A Media clip being dragged over the track headers: caught, to hand to the timeline at its start. (A click
            // on a header's buttons is a mouse down or up, and passes through.)
            let inWindow = superview?.convert(point, to: nil) ?? point
            let overHeaders = MainActor.assumeIsolated {
                model?.dragPayload != nil && TimelineCanvas.current.map { $0.window == window && $0.headersInWindow.contains(inWindow) } == true
            }
            if overHeaders, let e = NSApp.currentEvent,
               ![.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(e.type) {
                return self
            }
            if let e = NSApp.currentEvent, e.window != nil,
               [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                .otherMouseDragged, .otherMouseUp, .scrollWheel].contains(e.type) { return nil }
            return super.hitTest(point) == nil ? nil : self
        }

        private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        /// Files another app will write when asked (Photos, whose library can't be read directly).
        private func promises(_ info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
            info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        }

        private func accepts(_ info: NSDraggingInfo) -> Bool { !fileURLs(info).isEmpty || !promises(info).isEmpty }

        // MARK: Over the timeline: the drag is the timeline's

        /// Whether the drag is being handed to the timeline right now.
        private var onTimeline = false

        /// The timeline, when the drag is over it: it places what's dropped where it's dropped, as before.
        private func timeline(under info: NSDraggingInfo) -> TimelineCanvas? {
            MainActor.assumeIsolated {
                guard let t = TimelineCanvas.current, t.window == window else { return nil }
                // The timeline itself, or its track headers (a drop there lands at the start of that row).
                let p = info.draggingLocation
                return t.convert(t.bounds, to: nil).contains(p) || t.headersInWindow.contains(p) ? t : nil
            }
        }

        /// Hands the drag to the timeline (or takes it back) as it moves on or off it; returns what the timeline says.
        private func route(_ info: NSDraggingInfo) -> NSDragOperation? {
            let t = timeline(under: info)
            if let t {
                MainActor.assumeIsolated { model?.importDropHover = false }
                if !onTimeline {
                    onTimeline = true
                    return t.draggingEntered(info)
                }
                return t.draggingUpdated(info)
            }
            if onTimeline {
                onTimeline = false
                MainActor.assumeIsolated { TimelineCanvas.current?.draggingExited(info) }
            }
            return nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onTimeline = false
            if let op = route(sender) { return op }
            guard accepts(sender) else { return [] }
            MainActor.assumeIsolated { model?.importDropHover = true }
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            if let op = route(sender) { return op }
            guard accepts(sender) else { return [] }
            MainActor.assumeIsolated { model?.importDropHover = true }
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            if onTimeline {
                onTimeline = false
                MainActor.assumeIsolated { TimelineCanvas.current?.draggingExited(sender) }
            }
            MainActor.assumeIsolated { model?.importDropHover = false }
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let t = timeline(under: sender) { return t.prepareForDragOperation(sender) }
            return accepts(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            // Dropped on the timeline: placed there, where it was dropped.
            if let t = timeline(under: sender) {
                onTimeline = false
                MainActor.assumeIsolated { model?.importDropHover = false }
                let done = t.performDragOperation(sender)
                t.concludeDragOperation(sender)
                return done
            }
            // A promise wins: Photos puts a ready-made preview picture of a video on the drag as a file, and the video
            // itself only as a promise. Finder never promises, so its files are taken as they are.
            let promised = promises(sender)
            let urls = promised.isEmpty ? fileURLs(sender) : []
            guard !urls.isEmpty || !promised.isEmpty else { return false }
            // No drop animation: the dragged pictures vanish the moment they're let go (they're in Media at once).
            sender.animatesToDestination = true
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self, NSFilePromiseReceiver.self], searchOptions: [:]) { item, _, _ in
                item.imageComponentsProvider = { [] }
            }
            // Imported at once: the pictures jump straight into Media (the import keeps the main thread busy through
            // the animation, which reads as an instant hand-off, and was preferred over waiting for a glide).
            MainActor.assumeIsolated {
                model?.importDropHover = false
                if !promised.isEmpty { model?.importPromised(promised) } else { model?.handleOpen(urls) }
            }
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            onTimeline = false
            MainActor.assumeIsolated { model?.importDropHover = false }
        }
    }
}
