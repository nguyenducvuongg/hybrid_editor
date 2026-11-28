import AVFoundation
import Accelerate
import CoreGraphics
import ImageIO
import Vision

/// What one video or photo looks like over time, measured on this Mac: no network, no key.
struct ClipAnalysis: Codable {
    struct Sample: Codable {
        var time: Double
        /// Average brightness, 0...1.
        var luma: Double
        /// Detail: variance of edges. Blurry or out-of-focus frames are low.
        var sharpness: Double
        /// Change since the previous sample: shaky or fast-panning stretches are high.
        var motion: Double
        /// How colourful, 0...1-ish.
        var color: Double
        var faces: Int
        /// Apple's aesthetics score, -1...1, where the system has it (macOS 15).
        var aesthetic: Double?
        /// A screenshot, document or receipt rather than a photo of the world.
        var utility: Bool?
    }
    var duration: Double
    var created: Date?
    var samples: [Sample]
}

/// The beat of a song.
struct MusicAnalysis: Codable {
    var duration: Double
    var bpm: Double
    var beats: [Double]
    /// Index into `beats` of the first beat of a bar; bars are four beats.
    var barPhase: Int
    /// Loudness of each beat, 0...1.
    var energy: [Float]

    var period: Double { 60 / bpm }
    func isBarStart(_ beat: Int) -> Bool { (beat - barPhase) % 4 == 0 }
}

enum MediaAnalyzer {
    static let version = 2

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A cache file named for the source file's path, size and date, so an edited file is looked at again.
    static func cacheURL(_ source: URL, kind: String) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let stamp = "\(source.path)|\(attrs?[.size] ?? 0)|\(attrs?[.modificationDate] ?? Date.distantPast)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in stamp.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let name = source.deletingPathExtension().lastPathComponent + "-" + String(hash, radix: 36)
        return folder.appendingPathComponent("\(name)-\(kind)-v\(version).json")
    }

    private static func cached<T: Decodable>(_ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private static func store<T: Encodable>(_ value: T, _ url: URL) {
        if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Clips

    static func clip(_ url: URL, kind: MediaKind) async -> ClipAnalysis? {
        let cache = cacheURL(url, kind: "clip")
        if let hit: ClipAnalysis = cached(cache) { return hit }
        let result = kind == .image ? await photo(url) : await video(url)
        if let result { store(result, cache) }
        return result
    }

    private static func photo(_ url: URL) async -> ClipAnalysis? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        var measure = FrameMeasure()
        guard var s = measure.sample(img, time: 0) else { return nil }
        s.faces = faces(img)
        (s.aesthetic, s.utility) = aesthetics(img)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ClipAnalysis(duration: 5, created: attrs?[.creationDate] as? Date, samples: [s])
    }

    private static func video(_ url: URL) async -> ClipAnalysis? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0.2 else { return nil }
        var created: Date?
        if let item = try? await asset.load(.creationDate) { created = try? await item.load(.dateValue) }
        if created == nil { created = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        // Near enough is fine, and much quicker: frames close to the asked-for time decode fastest.
        let tolerance = CMTime(seconds: 0.12, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        let step = max(0.25, duration / 60)
        let times = stride(from: step / 2, to: duration - 0.04, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var measure = FrameMeasure()
        var samples: [ClipAnalysis.Sample] = []
        for await result in gen.images(for: times) {
            guard let img = try? result.image else { continue }
            let t = result.requestedTime.seconds
            guard var s = measure.sample(img, time: t) else { continue }
            // Faces on every other frame, the slower aesthetics check about once a second.
            if samples.count % 2 == 0 { s.faces = faces(img) } else { s.faces = samples.last?.faces ?? 0 }
            if samples.count % max(1, Int((1 / step).rounded())) == 0 {
                (s.aesthetic, s.utility) = aesthetics(img)
            } else {
                s.aesthetic = samples.last?.aesthetic
                s.utility = samples.last?.utility
            }
            samples.append(s)
        }
        guard !samples.isEmpty else { return nil }
        return ClipAnalysis(duration: duration, created: created, samples: samples)
    }

    private static func faces(_ img: CGImage) -> Int {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: img).perform([req])
        // Tiny faces in the background don't count.
        return (req.results ?? []).filter { $0.boundingBox.width * $0.boundingBox.height > 0.004 }.count
    }

    private static func aesthetics(_ img: CGImage) -> (Double?, Bool?) {
        guard #available(macOS 15.0, *) else { return (nil, nil) }
        let req = VNCalculateImageAestheticsScoresRequest()
        try? VNImageRequestHandler(cgImage: img).perform([req])
        guard let o = req.results?.first else { return (nil, nil) }
        return (Double(o.overallScore), o.isUtility)
    }

    /// Brightness, detail, colour and change from one small frame to the next.
    private struct FrameMeasure {
        static let w = 160, h = 90
        var previous: [UInt8]?

        mutating func sample(_ img: CGImage, time: Double) -> ClipAnalysis.Sample? {
            let w = Self.w, h = Self.h
            var gray = [UInt8](repeating: 0, count: w * h)
            var rgba = [UInt8](repeating: 0, count: 48 * 27 * 4)
            let drewGray = gray.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            let drewColor = rgba.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: 48, height: 27, bitsPerComponent: 8, bytesPerRow: 48 * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: 48, height: 27))
                return true
            }
            guard drewGray, drewColor else { return nil }

            var sum = 0.0
            for v in gray { sum += Double(v) }
            let luma = sum / Double(w * h) / 255

            // Laplacian variance: a standard measure of focus.
            var lap = [Double]()
            lap.reserveCapacity((w - 2) * (h - 2))
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let c = Double(gray[row + x]) * 4
                    let n = Double(gray[row + x - 1]) + Double(gray[row + x + 1]) + Double(gray[row - w + x]) + Double(gray[row + w + x])
                    lap.append(n - c)
                }
            }
            let mean = lap.reduce(0, +) / Double(lap.count)
            let variance = lap.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lap.count)

            var motion = 0.0
            if let prev = previous {
                var d = 0
                for i in 0..<(w * h) { d += abs(Int(gray[i]) - Int(prev[i])) }
                motion = Double(d) / Double(w * h) / 255
            }
            previous = gray

            // Colourfulness (Hasler and Süsstrunk).
            var rg = [Double](), yb = [Double]()
            for i in stride(from: 0, to: rgba.count, by: 4) {
                let r = Double(rgba[i]), g = Double(rgba[i + 1]), b = Double(rgba[i + 2])
                rg.append(r - g)
                yb.append(0.5 * (r + g) - b)
            }
            func stats(_ a: [Double]) -> (Double, Double) {
                let m = a.reduce(0, +) / Double(a.count)
                return (m, (a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)).squareRoot())
            }
            let (mrg, srg) = stats(rg), (myb, syb) = stats(yb)
            let color = ((srg * srg + syb * syb).squareRoot() + 0.3 * (mrg * mrg + myb * myb).squareRoot()) / 110

            return ClipAnalysis.Sample(time: time, luma: luma, sharpness: variance, motion: motion, color: min(1.5, color),
                                       faces: 0, aesthetic: nil, utility: nil)
        }
    }

    // MARK: Music

    static func music(_ url: URL) async -> MusicAnalysis? {
        let cache = cacheURL(url, kind: "beat")
        if let hit: MusicAnalysis = cached(cache) { return hit }
        guard let samples = await readMono(url, rate: 22050) else { return nil }
        let result = beats(samples, rate: 22050)
        if let result { store(result, cache) }
        return result
    }

    /// The whole file as one channel of floats at `rate`.
    static func readMono(_ url: URL, rate: Double) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(out)
        guard reader.startReading() else { return nil }
        // Decoded off the shared task threads, and given up if the file stops giving sound.
        return await BlockingWork.run {
            let stall = StallGuard(reader)
            defer { stall.stop() }
            var all: [Float] = []
            while let sb = out.copyNextSampleBuffer() {
                stall.tick()
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let n = CMBlockBufferGetDataLength(block) / 4
                var chunk = [Float](repeating: 0, count: n)
                chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                all.append(contentsOf: chunk)
            }
            return all.isEmpty || reader.status == .cancelled ? nil : all
        }
    }

    /// Finds the tempo and beats: an onset envelope from spectral flux, tempo by autocorrelation
    /// (favouring common tempos), the best-fitting beat grid, nudged beat by beat to the onsets, and
    /// which beat starts each bar (where the bass hits hardest).
    static func beats(_ x: [Float], rate: Double) -> MusicAnalysis? {
        let n = 1024, hop = 512
        // Finding a tempo needs a few seconds of sound (a sound effect has no beat to find, and too
        // little sound to look for one).
        guard x.count > n * 8, Double(x.count) > rate * 6 else { return nil }
        let log2n = vDSP_Length(10)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let frames = (x.count - n) / hop
        let half = n / 2
        let lowBins = max(2, Int(150 / (rate / Double(n))))
        var prev = [Float](repeating: 0, count: half)
        var flux = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var rms = [Float](repeating: 0, count: frames)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        for f in 0..<frames {
            x.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            var level: Float = 0
            vDSP_rmsqv(frame, 1, &level, vDSP_Length(n))
            rms[f] = level
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            var total: Float = 0, bass: Float = 0
            for k in 1..<half {
                let v = log1p(100 * mag[k])
                let d = v - prev[k]
                if d > 0 {
                    total += d
                    if k < lowBins { bass += d }
                }
                prev[k] = v
            }
            flux[f] = total
            low[f] = bass
        }

        // Onset strength above its local average.
        let fps = rate / Double(hop)
        func detrend(_ a: [Float]) -> [Float] {
            let r = max(1, Int(fps * 0.25))
            var out = [Float](repeating: 0, count: a.count)
            var run: Float = 0
            var prefix = [Float](repeating: 0, count: a.count + 1)
            for i in 0..<a.count { run += a[i]; prefix[i + 1] = run }
            for i in 0..<a.count {
                let lo = max(0, i - r), hi = min(a.count, i + r + 1)
                let m = (prefix[hi] - prefix[lo]) / Float(hi - lo)
                out[i] = max(0, a[i] - m)
            }
            return out
        }
        let env = detrend(flux)
        let bassEnv = detrend(low)

        // Tempo: autocorrelation, weighted toward 120 BPM over about an octave.
        var best = (bpm: 120.0, score: -Double.infinity)
        var scores: [(Double, Double)] = []
        for bpmTimes10 in stride(from: 700, through: 1800, by: 2) {
            let bpm = Double(bpmTimes10) / 10
            let lag = 60 / bpm * fps
            let l0 = Int(lag), frac = Float(lag - Double(l0))
            var s: Float = 0
            var count = 0
            for i in 0..<(env.count - l0 - 1) {
                let v = env[i + l0] * (1 - frac) + env[i + l0 + 1] * frac
                s += env[i] * v
                count += 1
            }
            let octave = log2(bpm / 120)
            let weighted = Double(s) / Double(max(1, count)) * exp(-0.5 * octave * octave / (0.9 * 0.9))
            scores.append((bpm, weighted))
            if weighted > best.score { best = (bpm, weighted) }
        }
        let period = 60 / best.bpm * fps

        // Beat grid phase that lines up with the most onset strength, with the bass (kick drums)
        // counting as much as everything else, so the grid sits on the beat rather than between.
        let envTop = max(env.max() ?? 1, 1e-6), bassTop = max(bassEnv.max() ?? 1, 1e-6)
        let pulse = zip(env, bassEnv).map { $0 / envTop + $1 / bassTop }
        var phase = 0.0, phaseScore: Float = -1
        for p in stride(from: 0.0, to: period, by: 0.5) {
            var s: Float = 0
            var t = p
            while Int(t) < pulse.count { s += pulse[Int(t)]; t += period }
            if s > phaseScore { phaseScore = s; phase = p }
        }
        // Follow the music: each beat may move a little toward the strongest onset near where it's expected.
        var beatFrames: [Double] = [phase]
        var t = phase
        while true {
            let predicted = t + period
            guard Int(predicted) < pulse.count - 1 else { break }
            let lo = max(0, Int(predicted - period * 0.08)), hi = min(pulse.count - 1, Int(predicted + period * 0.08))
            var at = predicted, top: Float = 0
            for i in lo...hi where pulse[i] > top { top = pulse[i]; at = Double(i) }
            t = top > 0 ? predicted + (at - predicted) * 0.5 : predicted
            beatFrames.append(t)
        }
        // Most songs keep strict time: fit one straight grid through the tracked beats, which also
        // undoes the analysis frames' coarseness. Where a song really drifts (live playing), keep the
        // tracked beats, lightly smoothed.
        if beatFrames.count > 8 {
            let k = Double(beatFrames.count)
            let meanI = (k - 1) / 2
            let meanT = beatFrames.reduce(0, +) / k
            var num = 0.0, den = 0.0
            for (i, b) in beatFrames.enumerated() { num += (Double(i) - meanI) * (b - meanT); den += (Double(i) - meanI) * (Double(i) - meanI) }
            let slope = num / den, intercept = meanT - slope * meanI
            let fitted = beatFrames.indices.map { intercept + slope * Double($0) }
            let residual = (zip(beatFrames, fitted).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / k).squareRoot() / fps
            if residual < 0.03 {
                beatFrames = fitted.filter { $0 >= 0 }
            } else {
                beatFrames = beatFrames.indices.map { i in
                    let lo = max(0, i - 1), hi = min(beatFrames.count - 1, i + 1)
                    return beatFrames[lo...hi].reduce(0, +) / Double(hi - lo + 1)
                }
            }
        }
        let bpm = 60 / (beatFrames.count > 1 ? (beatFrames.last! - beatFrames.first!) / Double(beatFrames.count - 1) / fps : 60 / best.bpm)

        // Bars start where the bass lands hardest.
        var barPhase = 0, barScore: Float = -1
        for m in 0..<4 {
            var s: Float = 0
            for (i, b) in beatFrames.enumerated() where i % 4 == m {
                let k = Int(b.rounded())
                s += bassEnv[max(0, min(bassEnv.count - 1, k))] + 0.25 * env[max(0, min(env.count - 1, k))]
            }
            if s > barScore { barScore = s; barPhase = m }
        }
        // Loudness of each beat.
        var energy: [Float] = []
        for (i, b) in beatFrames.enumerated() {
            let lo = Int(b), hi = min(rms.count, Int(i + 1 < beatFrames.count ? beatFrames[i + 1] : b + period))
            guard hi > lo else { energy.append(0); continue }
            energy.append(rms[lo..<hi].reduce(0, +) / Float(hi - lo))
        }
        let top = energy.max() ?? 1
        if top > 0 { energy = energy.map { $0 / top } }
        // Frame times are for the middle of each analysis window.
        let offset = Double(n / 2) / rate
        let beats = beatFrames.map { $0 / fps + offset }
        return MusicAnalysis(duration: Double(x.count) / rate, bpm: bpm, beats: beats, barPhase: barPhase, energy: energy)
    }
}

/// Studies new media in the background after import (each clip's moments, each song's beats), one file
/// at a time, so Magic's first run on new footage doesn't wait for it. Results are kept on disk by
/// MediaAnalyzer itself, so this does nothing for files already studied.
@MainActor
final class AnalysisWarmer {
    static let shared = AnalysisWarmer()
    private var queue: [(URL, MediaKind, Bool)] = []
    private var queued = Set<String>()
    private var working = false

    /// A file changed on disk, so it can be looked at again (its saved results are named for the old file).
    func forget(_ url: URL) { queued.remove(url.path) }

    /// Queues a file: a song (`song`) for its beats, anything else for its moments.
    func warm(_ url: URL, kind: MediaKind, song: Bool) {
        guard !queued.contains(url.path) else { return }
        queued.insert(url.path)
        queue.append((url, kind, song))
        next()
    }

    private func next() {
        guard !working, !queue.isEmpty else { return }
        let (url, kind, song) = queue.removeFirst()
        working = true
        Task.detached(priority: .utility) {
            if song { _ = await MediaAnalyzer.music(url) } else { _ = await MediaAnalyzer.clip(url, kind: kind) }
            await MainActor.run {
                AnalysisWarmer.shared.working = false
                AnalysisWarmer.shared.next()
            }
        }
    }
}
