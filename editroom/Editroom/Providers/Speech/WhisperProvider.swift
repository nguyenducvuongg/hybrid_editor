import AVFoundation
import Foundation

struct SpeechSpan: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

struct VADAnalysis: Codable, Equatable, Sendable {
    var duration: Double
    var spans: [SpeechSpan]
    var peakDB: Double
}

enum WhisperError: LocalizedError {
    case notConfigured(String)
    case audioDecodeFailed(String)
    case processFailed(Int32, String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): msg
        case .audioDecodeFailed(let msg): msg
        case .processFailed(let code, let err): "whisper-cli failed (\(code)): \(err)"
        case .invalidOutput(let msg): msg
        }
    }
}

protocol TranscriptionProvider: Sendable {
    func transcribe(audioURL: URL, language: String) async throws -> Transcript
}

/// Pure-AVFoundation 16kHz mono Voice Activity Detection, WAV exporter, and hallucination guard (`I4`, `P6`).
enum AudioVAD {
    private static let sampleRate: Double = 16_000
    private static let frameSamples = 480 // 30 ms at 16 kHz

    private static let hallucinationPhrases: [String] = [
        "cảm ơn các bạn đã xem",
        "cảm ơn đã xem",
        "cám ơn các bạn đã xem",
        "cám ơn đã xem",
        "hãy đăng ký kênh",
        "đăng ký kênh",
        "hãy subscribe",
        "like và subscribe",
        "thank you for watching",
        "thanks for watching",
        "please subscribe",
        "subtitles by",
        "amara org",
        "mbc news",
    ]

    /// Detects active speech regions using RMS energy thresholding on decoded 16kHz mono PCM.
    static func analyze(
        url: URL,
        thresholdDB: Double = -42.0,
        minSpeechSec: Double = 0.12,
        mergeGapSec: Double = 0.35,
        padSec: Double = 0.08
    ) async throws -> VADAnalysis {
        let asset = AVURLAsset(url: url)
        let loadedDuration = try await asset.load(.duration).seconds
        let duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return VADAnalysis(duration: duration, spans: [], peakDB: -120)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw WhisperError.audioDecodeFailed("Cannot configure 16kHz float PCM reader output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw WhisperError.audioDecodeFailed(reader.error?.localizedDescription ?? "AVAssetReader startReading failed.")
        }

        var bufferRemainder: [Float] = []
        bufferRemainder.reserveCapacity(frameSamples * 2)
        var frameIdx = 0
        var rawActive: [SpeechSpan] = []
        var peakDB: Double = -120
        let frameSec = Double(frameSamples) / sampleRate

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let floats = extractFloats(sampleBuffer), !floats.isEmpty {
                bufferRemainder.append(contentsOf: floats)
                var offset = 0
                while offset + frameSamples <= bufferRemainder.count {
                    var sumSq: Double = 0
                    for i in offset..<(offset + frameSamples) {
                        let v = Double(bufferRemainder[i])
                        sumSq += v * v
                    }
                    let rms = sqrt(sumSq / Double(frameSamples))
                    let db = 20.0 * log10(max(rms, 1e-9))
                    if db > peakDB { peakDB = db }
                    let t0 = Double(frameIdx) * frameSec
                    let t1 = t0 + frameSec
                    if db >= thresholdDB {
                        if let last = rawActive.last, t0 - last.end <= mergeGapSec {
                            rawActive[rawActive.count - 1].end = t1
                        } else {
                            rawActive.append(SpeechSpan(start: t0, end: t1))
                        }
                    }
                    frameIdx += 1
                    offset += frameSamples
                }
                if offset > 0 {
                    bufferRemainder.removeFirst(offset)
                }
            }
        }

        if !bufferRemainder.isEmpty {
            var sumSq: Double = 0
            for v in bufferRemainder { sumSq += Double(v) * Double(v) }
            let rms = sqrt(sumSq / Double(bufferRemainder.count))
            let db = 20.0 * log10(max(rms, 1e-9))
            if db > peakDB { peakDB = db }
            let t0 = Double(frameIdx) * frameSec
            let t1 = t0 + Double(bufferRemainder.count) / sampleRate
            if db >= thresholdDB {
                if let last = rawActive.last, t0 - last.end <= mergeGapSec {
                    rawActive[rawActive.count - 1].end = t1
                } else {
                    rawActive.append(SpeechSpan(start: t0, end: t1))
                }
            }
        }

        let effectiveDuration = max(duration, Double(frameIdx) * frameSec + Double(bufferRemainder.count) / sampleRate)
        let filtered = rawActive.filter { ($0.end - $0.start) >= minSpeechSec }
        var padded: [SpeechSpan] = []
        for span in filtered {
            let s = max(0, span.start - padSec)
            let e = effectiveDuration > 0 ? min(effectiveDuration, span.end + padSec) : (span.end + padSec)
            if let last = padded.last, s <= last.end + 1e-6 {
                padded[padded.count - 1].end = max(last.end, e)
            } else {
                padded.append(SpeechSpan(start: s, end: e))
            }
        }
        return VADAnalysis(duration: effectiveDuration, spans: padded, peakDB: peakDB)
    }

    /// Exports decoded 16kHz mono 16-bit PCM WAV for `whisper-cli`.
    static func exportMono16kWAV(from sourceURL: URL, to wavURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WhisperError.audioDecodeFailed("Source media has no audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw WhisperError.audioDecodeFailed("Cannot configure 16-bit PCM reader output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw WhisperError.audioDecodeFailed(reader.error?.localizedDescription ?? "AVAssetReader failed.")
        }

        var pcmData = Data()
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let len = CMBlockBufferGetDataLength(block)
                if len > 0 {
                    var chunk = Data(count: len)
                    let status = chunk.withUnsafeMutableBytes { ptr -> OSStatus in
                        guard let base = ptr.baseAddress else { return -1 }
                        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: base)
                    }
                    if status == kCMBlockBufferNoErr {
                        pcmData.append(chunk)
                    }
                }
            }
        }

        let header = wavHeader(pcmByteCount: UInt32(min(pcmData.count, Int(UInt32.max - 44))), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        var fileData = Data(capacity: 44 + pcmData.count)
        fileData.append(header)
        fileData.append(pcmData)
        try FileManager.default.createDirectory(at: wavURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileData.write(to: wavURL, options: .atomic)
        return Double(pcmData.count / 2) / sampleRate
    }

    static func wavHeader(pcmByteCount: UInt32, sampleRate: UInt32 = 16_000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let riffSize = UInt32(36) + pcmByteCount
        var d = Data(capacity: 44)
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: "RIFF".utf8)
        appendLE(riffSize)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(channels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        d.append(contentsOf: "data".utf8)
        appendLE(pcmByteCount)
        return d
    }

    /// Rejects silence boilerplate / non-speech tags produced by Whisper models (`P6`).
    static func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        if (lower.hasPrefix("[") && lower.hasSuffix("]")) || (lower.hasPrefix("(") && lower.hasSuffix(")")) {
            return true
        }
        let cleaned = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return true }
        for phrase in hallucinationPhrases {
            if cleaned == phrase || cleaned.contains(phrase) {
                return true
            }
        }
        return false
    }

    /// Computes source-timeline keep intervals by cutting gaps longer than `minSilenceSec`.
    static func suggestKeepRanges(
        words: [Transcript.Word],
        spans: [SpeechSpan],
        duration: Double,
        minSilenceSec: Double = 0.7,
        padSec: Double = 0.1
    ) -> [SpeechSpan] {
        let raw: [SpeechSpan] = words.isEmpty
            ? spans
            : words.map { SpeechSpan(start: $0.start, end: $0.end) }
        guard !raw.isEmpty else { return [] }

        var merged: [SpeechSpan] = []
        for seg in raw.sorted(by: { $0.start < $1.start }) {
            let s = max(0, seg.start - padSec)
            let e = duration > 0 ? min(duration, seg.end + padSec) : (seg.end + padSec)
            guard e > s else { continue }
            if let last = merged.last, s - last.end < minSilenceSec {
                merged[merged.count - 1].end = max(last.end, e)
            } else {
                merged.append(SpeechSpan(start: s, end: e))
            }
        }
        return merged
    }

    private static func extractFloats(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let byteLen = CMBlockBufferGetDataLength(block)
        let floatCount = byteLen / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }
        var out = [Float](repeating: 0, count: floatCount)
        let status = out.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floatCount * MemoryLayout<Float>.size, destination: base)
        }
        return status == kCMBlockBufferNoErr ? out : nil
    }
}

/// Whisper.cpp (`whisper-cli`) provider pre-gated by `AudioVAD` (`I4`, `I6`, `P6`).
struct WhisperCPPProvider: TranscriptionProvider {
    let binaryURL: URL?
    let modelURL: URL?
    let vadThresholdDB: Double
    let extraArgs: [String]

    init(
        binaryURL: URL? = nil,
        modelURL: URL? = nil,
        vadThresholdDB: Double = -42.0,
        extraArgs: [String] = []
    ) {
        self.binaryURL = binaryURL
        self.modelURL = modelURL
        self.vadThresholdDB = vadThresholdDB
        self.extraArgs = extraArgs
    }

    var isConfigured: Bool { binaryURL != nil && modelURL != nil }

    static func fromPrefs(_ prefs: SpeechPrefs = .load()) -> WhisperCPPProvider {
        WhisperCPPProvider(
            binaryURL: discoverBinary(preferred: prefs.whisperBinaryPath),
            modelURL: discoverModel(preferred: prefs.whisperModelPath),
            vadThresholdDB: prefs.vadThresholdDB
        )
    }

    static func discoverBinary(preferred: String = "") -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(preferred.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let env = ProcessInfo.processInfo.environment["WHISPER_CLI_PATH"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
        ])
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func discoverModel(preferred: String = "") -> URL? {
        let fm = FileManager.default
        var explicit: [String] = []
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            explicit.append(preferred.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let env = ProcessInfo.processInfo.environment["WHISPER_MODEL_PATH"], !env.isEmpty {
            explicit.append(env)
        }
        for path in explicit where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let modelsDir = HybridStorage.subdir("Models")
        if let items = try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) {
            let bins = items.filter { $0.pathExtension.lowercased() == "bin" }
            if let turbo = bins.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains("large-v3-turbo") }) {
                return turbo
            }
            if let first = bins.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                return first
            }
        }
        return nil
    }

    func transcribe(audioURL: URL, language: String = "vi") async throws -> Transcript {
        let vad = try await AudioVAD.analyze(url: audioURL, thresholdDB: vadThresholdDB)
        // P6 invariant: zero active speech frames -> short-circuit immediately with 0 words.
        guard !vad.spans.isEmpty else {
            return Transcript(words: [], language: language)
        }
        guard let bin = binaryURL, FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw WhisperError.notConfigured("whisper-cli binary not found. Install whisper-cpp or configure binary path in Settings.")
        }
        guard let model = modelURL, FileManager.default.fileExists(atPath: model.path) else {
            throw WhisperError.notConfigured("Whisper GGML model (.bin) not found. Place ggml-large-v3-turbo.bin in Models or configure in Settings.")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editroom_whisper_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let wavURL = workDir.appendingPathComponent("input.wav")
        _ = try await AudioVAD.exportMono16kWAV(from: audioURL, to: wavURL)
        let outPrefix = workDir.appendingPathComponent("transcript")
        let outJSON = workDir.appendingPathComponent("transcript.json")

        let args = [
            "-m", model.path,
            "-f", wavURL.path,
            "-l", language,
            "-ojf",
            "-of", outPrefix.path,
        ] + extraArgs

        let (code, stdout, stderr) = try await Self.runCLIAsync(executable: bin, arguments: args)
        guard code == 0 else {
            throw WhisperError.processFailed(code, stderr.isEmpty ? stdout : stderr)
        }

        let jsonData: Data
        if FileManager.default.fileExists(atPath: outJSON.path) {
            jsonData = try Data(contentsOf: outJSON)
        } else if let fallbackData = stdout.data(using: .utf8), !fallbackData.isEmpty {
            jsonData = fallbackData
        } else {
            throw WhisperError.invalidOutput("whisper-cli produced no JSON output.")
        }

        return try Self.parseWhisperJSON(data: jsonData, language: language, vadSpans: vad.spans)
    }

    static func parseWhisperJSON(data: Data, language: String, vadSpans: [SpeechSpan]) throws -> Transcript {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperError.invalidOutput("Invalid Whisper JSON root.")
        }

        var rawSegments: [(start: Double, end: Double, text: String)] = []

        if let words = root["words"] as? [[String: Any]] {
            var directWords: [Transcript.Word] = []
            for item in words {
                guard let s = number(item["start"]), let e = number(item["end"]),
                      let text = item["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !AudioVAD.isHallucination(trimmed),
                      overlapsVAD(start: s, end: e, spans: vadSpans) else { continue }
                directWords.append(Transcript.Word(start: s, end: max(s + 0.05, e), text: trimmed))
            }
            return Transcript(words: directWords.sorted { $0.start < $1.start }, language: language)
        }

        if let transcription = root["transcription"] as? [[String: Any]] {
            for item in transcription {
                let offsets = item["offsets"] as? [String: Any]
                let startMs = number(offsets?["from"]) ?? 0
                let endMs = number(offsets?["to"]) ?? startMs
                let text = (item["text"] as? String) ?? ""
                rawSegments.append((startMs / 1000.0, max(startMs / 1000.0 + 0.05, endMs / 1000.0), text))
            }
        } else if let segments = root["segments"] as? [[String: Any]] {
            for item in segments {
                let s = number(item["start"]) ?? 0
                let e = number(item["end"]) ?? (s + 0.05)
                let text = (item["text"] as? String) ?? ""
                rawSegments.append((s, max(s + 0.05, e), text))
            }
        } else {
            throw WhisperError.invalidOutput("Unrecognized Whisper JSON structure.")
        }

        var words: [Transcript.Word] = []
        for seg in rawSegments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !AudioVAD.isHallucination(trimmed),
                  overlapsVAD(start: seg.start, end: seg.end, spans: vadSpans) else { continue }

            let pieces = trimmed
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            guard !pieces.isEmpty else { continue }

            let totalDur = max(0.05 * Double(pieces.count), seg.end - seg.start)
            let step = totalDur / Double(pieces.count)
            for (idx, piece) in pieces.enumerated() {
                let wStart = seg.start + Double(idx) * step
                let wEnd = seg.start + Double(idx + 1) * step
                words.append(Transcript.Word(start: wStart, end: wEnd, text: piece))
            }
        }

        return Transcript(words: words.sorted { $0.start < $1.start }, language: language)
    }

    private static func overlapsVAD(start: Double, end: Double, spans: [SpeechSpan], tolerance: Double = 0.25) -> Bool {
        let s = start - tolerance
        let e = end + tolerance
        return spans.contains { span in
            span.end >= s && span.start <= e
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    private static func runCLIAsync(executable: URL, arguments: [String]) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = executable
                proc.arguments = arguments
                proc.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }

                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                proc.waitUntilExit()
                group.wait()

                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus, outStr, errStr))
            }
        }
    }
}
