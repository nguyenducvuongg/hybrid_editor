import Foundation
import CoreGraphics

/// A library item shown in the main viewer while its thumbnail is hover-scrubbed. Kept apart from the
/// editor model so the frequent updates only redraw the viewer.
@MainActor
final class SourcePreviewState: ObservableObject {
    struct Current {
        let asset: MediaAsset
        var time: Double
        var image: CGImage?
        /// Said after the name: "In" or "Out" while a clip's edge is being trimmed.
        var note: String? = nil
    }

    @Published private(set) var current: Current?

    /// The viewer's player: hover frames are drawn into it on the GPU, like scrubbing.
    weak var engine: PlaybackEngine?
    /// A still is up in the viewer (drawn by the engine), to take down on clear.
    private var drawing = false

    /// Hover-scrubbing a Media item: its made-ahead frames (sharp, in playback's colours) drawn straight
    /// into the viewer, the overlay just naming it; without them, frames decoded from the file one after
    /// another (never a small, differently coloured stand-in in between, which made the colours flicker).
    func hover(_ asset: MediaAsset, at time: Double, media: MediaStore) {
        // Only with something on the timeline: an empty one has no player to draw into, so the frame
        // is drawn here instead.
        if let engine, engine.duration > 0, let still = media.scrubCache.image(asset.id, at: time), let rt = media.runtimes[asset.id] {
            engine.showStill(still, orientation: rt.orientation, time: time)
            drawing = true
            wanted = nil
            current = Current(asset: asset, time: time, image: nil)
            return
        }
        if current?.asset.id != asset.id { current = Current(asset: asset, time: time, image: nil) } else { current?.time = time }
        wanted = time
        fetch(asset, media: media)
    }

    /// `quick` is a frame already at hand (made ahead, smaller) to show at once; the exact full-size
    /// frame replaces it when it's decoded, unless the mouse has moved on by then.
    func show(_ asset: MediaAsset, at time: Double, media: MediaStore, quick: CGImage? = nil, note: String? = nil) {
        if current?.asset.id != asset.id {
            current = Current(asset: asset, time: time, image: quick, note: note)
        } else {
            current?.time = time
            current?.note = note
            if let quick { current?.image = quick }
        }
        // Trimming: the frame being decoded is finished, never cancelled, and shown (a moment behind
        // beats nothing), then the latest time is fetched; cancelling at every move of the mouse left
        // the viewer empty for as long as the drag kept moving.
        if note != nil {
            // A sharp made-ahead frame is already up: nothing to decode.
            wanted = quick == nil ? time : nil
            fetch(asset, media: media)
            return
        }
        media.viewerFrame(asset: asset.id, time: time) { [weak self] img in
            guard let self, self.current?.asset.id == asset.id, self.current?.time == time else { return }
            self.current?.image = img
        }
    }

    private var fetching = false
    private var wanted: Double?

    private func fetch(_ asset: MediaAsset, media: MediaStore) {
        guard !fetching, let time = wanted else { return }
        wanted = nil
        fetching = true
        media.viewerFrame(asset: asset.id, time: time, cancelEarlier: false) { [weak self] img in
            guard let self else { return }
            self.fetching = false
            guard self.current?.asset.id == asset.id else { return }
            self.current?.image = img
            self.fetch(asset, media: media)
        }
    }

    /// Just the overlay's time, with no picture of its own: the viewer underneath is showing the frame.
    func label(_ asset: MediaAsset, at time: Double, note: String) {
        wanted = nil
        current = Current(asset: asset, time: time, image: nil, note: note)
    }

    /// Shows a frame that has already been fetched.
    func show(_ asset: MediaAsset, at time: Double, image: CGImage) {
        current = Current(asset: asset, time: time, image: image)
    }

    func clear() {
        wanted = nil
        if drawing {
            drawing = false
            engine?.endStill()
        }
        if current != nil { current = nil }
    }
}
