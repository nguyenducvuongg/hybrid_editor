import AVFoundation
import os

/// Audio scrubbing that answers instantly. The edit's mixed sound is rendered into memory in the
/// background whenever the audio changes; scrubbing then plays straight out of that memory through
/// a low-latency render callback, so sound starts within one audio buffer (about 10 ms) of the
/// mouse moving. The mix is the same composition and audio mix as playback, so gains, fades,
/// mute/solo and ducking are all heard.
final class AudioScrubber: @unchecked Sendable {
    /// How long each scrub position keeps sounding if the mouse stops.
    static let snippet = 0.08
    static let rate = 32000.0
    /// Longer edits aren't held in memory; scrubbing falls back to reading from the media.
    static let maxSeconds = 45.0 * 60

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private var lock = os_unfair_lock()

    // Shared with the render callback, under `lock`.
    private var samples: [Int16] = []     // interleaved stereo
    private var readFrame = 0
    private var remaining = 0
    private var fadeIn = 0

    private var fingerprint: Int?
    private var renderTask: Task<Void, Never>?
    private(set) var ready = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, list -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(list)
            guard bufs.count >= 2, let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            os_unfair_lock_lock(&self.lock)
            var pos = self.readFrame, remain = self.remaining, fade = self.fadeIn
            let count = self.samples.count / 2
            self.samples.withUnsafeBufferPointer { s in
                for i in 0..<Int(frameCount) {
                    if remain > 0, pos < count, pos >= 0 {
                        // Ease in after each jump and out at the end, so nothing clicks.
                        var g: Float = 1
                        if fade < 96 { g = Float(fade) / 96; fade += 1 }
                        if remain < 160 { g *= Float(remain) / 160 }
                        l[i] = Float(s[pos * 2]) / 32768 * g
                        r[i] = Float(s[pos * 2 + 1]) / 32768 * g
                        pos += 1
                        remain -= 1
                    } else {
                        l[i] = 0
                        r[i] = 0
                    }
                }
            }
            self.readFrame = pos
            self.remaining = remain
            self.fadeIn = fade
            os_unfair_lock_unlock(&self.lock)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    /// Starts the audio output ahead of time, so the first scrub isn't delayed.
    func warmUp() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    func shutDown() {
        os_unfair_lock_lock(&lock)
        remaining = 0
        os_unfair_lock_unlock(&lock)
        engine.pause()
    }

    /// Renders the mix into memory when the edit's audio has changed since last time.
    @MainActor
    func prepare(project: Project, media: MediaStore) {
        var h = Hasher()
        h.combine(project.audioTracks)
        for c in project.clips where c.kind == .audio { h.combine(c) }
        for a in project.assets where a.kind != .image { h.combine(a.id); h.combine(media.runtimes[a.id] != nil); h.combine(media.runtimes[a.id]?.reversedAudio != nil) }
        let print = h.finalize()
        guard print != fingerprint else { return }
        fingerprint = print
        guard project.duration > 0, project.duration < Self.maxSeconds,
              let built = CompositionBuilder.build(project: project, media: media, renderSize: CGSize(width: 16, height: 16),
                                                   includeVideo: false, includeAudio: true), built.hasAudio else {
            os_unfair_lock_lock(&lock); samples = []; remaining = 0; os_unfair_lock_unlock(&lock)
            ready = false
            return
        }
        renderTask?.cancel()
        let comp = built.composition, mix = built.audioMix
        renderTask = Task.detached(priority: .utility) { [weak self] in
            guard let rendered = Self.renderAll(comp, mix: mix), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                os_unfair_lock_lock(&self.lock)
                self.samples = rendered
                os_unfair_lock_unlock(&self.lock)
                self.ready = true
            }
        }
    }

    /// Plays from a time on the timeline. Each call restarts the short burst from the new place.
    func play(at time: Double) {
        let frame = Int(max(0, time) * Self.rate)
        os_unfair_lock_lock(&lock)
        readFrame = frame
        remaining = Int(Self.snippet * Self.rate)
        fadeIn = 0
        os_unfair_lock_unlock(&lock)
    }

    private static func renderAll(_ asset: AVAsset, mix: AVAudioMix?) -> [Int16]? {
        let tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = mix
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var out: [Int16] = []
        out.reserveCapacity(Int(asset.duration.seconds * rate * 2) + 4096)
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let n = length / 2
            let start = out.count
            out.append(contentsOf: repeatElement(0, count: n))
            out.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 2, destination: raw.baseAddress! + start * 2)
            }
        }
        return out
    }

    /// The mix at a time, for checking: peak level over a short stretch, 0...1.
    func peak(at time: Double, seconds: Double = 0.05) -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let a = Int(time * Self.rate) * 2, b = min(samples.count, a + Int(seconds * Self.rate) * 2)
        guard a >= 0, a < b else { return 0 }
        var m: Int16 = 0
        for i in a..<b { m = max(m, abs(samples[i] == .min ? .max : samples[i])) }
        return Float(m) / 32768
    }
}
