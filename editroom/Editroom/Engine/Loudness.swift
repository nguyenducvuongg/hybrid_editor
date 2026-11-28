import AVFoundation

/// Level analysis from the waveform peaks the app already keeps for drawing.
@MainActor
enum AudioLevels {
    /// A clip's typical level in dB, from the peaks over its source range, ignoring near-silence.
    static func envelopeDB(_ c: Clip, media: MediaStore) -> Double? {
        guard let wf = media.waveform(c), !wf.peaks.isEmpty else { return nil }
        let lo = max(0, Int(c.sourceStart * wf.peaksPerSecond))
        let hi = min(wf.peaks.count, Int((c.sourceStart + c.sourceLength) * wf.peaksPerSecond))
        guard hi > lo else { return nil }
        var sum = 0.0, n = 0
        for i in lo..<hi where wf.peaks[i] > 0.003 {
            let v = Double(wf.peaks[i])
            sum += v * v
            n += 1
        }
        guard n > 0 else { return nil }
        return 10 * log10(sum / Double(n))
    }

    /// A clip's loudest peak in dB over its source range.
    static func peakDB(_ c: Clip, media: MediaStore) -> Double? {
        guard let wf = media.waveform(c), !wf.peaks.isEmpty else { return nil }
        let lo = max(0, Int(c.sourceStart * wf.peaksPerSecond))
        let hi = min(wf.peaks.count, Int((c.sourceStart + c.sourceLength) * wf.peaksPerSecond))
        guard hi > lo, let peak = wf.peaks[lo..<hi].max(), peak > 0 else { return nil }
        return 20 * log10(Double(peak))
    }

    /// Stretches of time where a track has sound, for ducking another track under it.
    static func activity(on trackID: UUID, project: Project, media: MediaStore) -> [(start: Double, end: Double)] {
        var spans: [(Double, Double)] = []
        let step = 0.05
        for c in project.clips where c.trackID == trackID && c.kind == .audio {
            guard let wf = media.waveform(c), !wf.peaks.isEmpty else { continue }
            var open: Double?
            var t = c.start
            while t < c.end {
                let src = c.sourceTime(at: t)
                let lo = max(0, Int(src * wf.peaksPerSecond))
                let hi = min(wf.peaks.count - 1, Int(c.sourceTime(at: t + step) * wf.peaksPerSecond))
                var peak: Float = 0
                if hi >= lo { for i in lo...hi { peak = max(peak, wf.peaks[i]) } }
                let active = Double(peak) * dbToLinear(c.gainDB) * c.fadeGain(at: t) > 0.03
                if active, open == nil { open = t }
                if !active, let s = open { spans.append((s, t)); open = nil }
                t += step
            }
            if let s = open { spans.append((s, c.end)) }
        }
        // Short pauses between words don't let the music back up.
        spans.sort { $0.0 < $1.0 }
        var merged: [(start: Double, end: Double)] = []
        for s in spans {
            if let last = merged.last, s.0 - last.end < 0.35 {
                merged[merged.count - 1].end = max(last.end, s.1)
            } else {
                merged.append((s.0, s.1))
            }
        }
        return merged
    }

    /// The ducking gain at a time: down by `amount` while there's activity, easing down just before
    /// it starts and back up after it stops.
    static func duckGain(at t: Double, spans: [(start: Double, end: Double)], low: Double) -> Double {
        let attack = 0.15, release = 0.5
        var g = 1.0
        for s in spans {
            if t < s.start - attack || t > s.end + release { continue }
            let f: Double
            if t < s.start { f = (s.start - t) / attack } else if t > s.end { f = (t - s.end) / release } else { f = 0 }
            g = min(g, low + (1 - low) * f)
        }
        return g
    }
}

/// Integrated loudness (ITU-R BS.1770, as LUFS) and sample peak of a timeline's audio mix.
enum LoudnessMeter {
    struct Result {
        let lufs: Double
        let peakDB: Double
    }

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    static func measure(_ built: BuiltTimeline) -> Result? {
        let comp = built.composition
        let tracks = comp.tracks(withMediaType: .audio)
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: comp) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = built.audioMix
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // K-weighting at 48 kHz: a high shelf, then a high-pass.
        func filters() -> [Biquad] {
            [Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585),
             Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)]
        }
        var left = filters(), right = filters()
        // Mean square in 100ms steps; blocks are four steps (400ms, 75% overlap).
        let step = 4800
        var steps: [Double] = []
        var acc = 0.0, count = 0
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < data.count {
                let l = data[i], r = data[i + 1]
                peak = max(peak, abs(l), abs(r))
                var x = Double(l), y = Double(r)
                x = left[1].run(left[0].run(x))
                y = right[1].run(right[0].run(y))
                acc += x * x + y * y
                count += 1
                if count == step {
                    steps.append(acc / Double(step))
                    acc = 0
                    count = 0
                }
                i += 2
            }
        }
        guard steps.count >= 4 else { return nil }
        var blocks: [Double] = []
        for k in 0...(steps.count - 4) { blocks.append((steps[k] + steps[k + 1] + steps[k + 2] + steps[k + 3]) / 4) }
        func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-12)) }
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        let integrated = lufs(gated.reduce(0, +) / Double(gated.count))
        return Result(lufs: integrated, peakDB: peak > 0 ? 20 * log10(Double(peak)) : -120)
    }
}
