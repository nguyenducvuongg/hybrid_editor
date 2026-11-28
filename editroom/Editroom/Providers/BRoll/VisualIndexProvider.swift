import AppKit
import AVFoundation
import Foundation
import ImageIO
import Vision

struct VisualCaption: Codable, Equatable, Sendable {
    var description: String
    var tags: [String]
    var mood: String
}

enum VisualIndexError: LocalizedError {
    case invalidEndpoint(String)
    case httpError(Int, String)
    case invalidImage
    case unsupportedMedia(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let msg): msg
        case .httpError(let code, let body): "VLM endpoint returned HTTP \(code): \(body)"
        case .invalidImage: "Failed to decode frame/image into CGImage."
        case .unsupportedMedia(let msg): msg
        }
    }
}

protocol VisualIndexProvider: Sendable {
    var providerName: String { get }
    func describe(jpegData: Data, filename: String) async throws -> VisualCaption
}

/// OpenAI-compatible local Vision-Language Model provider (Ollama / LM Studio `/v1/chat/completions`).
struct LocalVLMVisionProvider: VisualIndexProvider {
    let baseURL: String
    let model: String
    let apiKey: String?
    let timeout: TimeInterval

    var providerName: String { "local-vlm(\(model))" }

    init(
        baseURL: String = VLMIndexPrefs.load().vlmBaseURL,
        model: String = VLMIndexPrefs.load().vlmModel,
        apiKey: String? = nil,
        timeout: TimeInterval = 20
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
    }

    func describe(jpegData: Data, filename: String) async throws -> VisualCaption {
        let cleaned = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointStr = cleaned.hasSuffix("/chat/completions") ? cleaned : "\(cleaned)/chat/completions"
        guard let url = URL(string: endpointStr),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw VisualIndexError.invalidEndpoint("Invalid VLM URL: \(baseURL)")
        }

        let b64 = jpegData.base64EncodedString()
        let prompt = """
        Analyze this B-roll frame (filename: \(filename)). Respond ONLY with valid JSON:
        {"description": "<1 short Vietnamese or English sentence describing subject & action>", "tags": ["<tag1>", "<tag2>", "<tag3>"], "mood": "<1-2 word mood>"}
        """
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.1,
            "max_tokens": 220,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
                ],
            ]],
        ]

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw VisualIndexError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        return Self.parseChatCompletionCaption(data: data, fallbackName: filename)
    }

    static func parseChatCompletionCaption(data: Data, fallbackName: String) -> VisualCaption {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return VisualCaption(description: fallbackName, tags: [], mood: "neutral")
        }

        let rawText: String
        if let str = message["content"] as? String {
            rawText = str
        } else if let parts = message["content"] as? [[String: Any]] {
            rawText = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else {
            rawText = ""
        }

        if let jsonObj = extractJSONObject(from: rawText) {
            let desc = (jsonObj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackName
            let tags = (jsonObj["tags"] as? [String])?.filter { !$0.isEmpty } ?? []
            let mood = (jsonObj["mood"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "neutral"
            return VisualCaption(description: desc.isEmpty ? fallbackName : desc, tags: tags, mood: mood.isEmpty ? "neutral" : mood)
        }

        let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VisualCaption(description: cleaned.isEmpty ? fallbackName : cleaned, tags: [], mood: "neutral")
    }

    private static func extractJSONObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}

/// Offline Apple Vision fallback classifier when no local VLM server is running (`I6`).
struct AppleVisionFallbackProvider: VisualIndexProvider {
    var providerName: String { "apple-vision" }

    func describe(jpegData: Data, filename: String) async throws -> VisualCaption {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisualIndexError.invalidImage
        }
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([req])
        let labels = (req.results ?? [])
            .filter { $0.confidence >= 0.2 }
            .prefix(6)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let desc = labels.isEmpty ? filename : labels.joined(separator: ", ")
        return VisualCaption(description: desc, tags: labels, mood: "neutral")
    }
}

/// Scans a local folder off `@MainActor`, samples video/image keyframes, and stores FTS5 records (`I6`).
struct BRollIndexer {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    func indexFolder(
        _ folderURL: URL,
        index: BRollFTSIndex,
        provider: any VisualIndexProvider,
        fallbackProvider: (any VisualIndexProvider)? = AppleVisionFallbackProvider(),
        sampleIntervalSec: Double = 4.0,
        maxFramesPerVideo: Int = 4
    ) async throws -> (files: Int, segments: Int, usedProvider: String) {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let mediaURLs = items.filter { url in
            let ext = url.pathExtension.lowercased()
            return Self.videoExtensions.contains(ext) || Self.imageExtensions.contains(ext)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var totalSegments = 0
        var lastUsedProvider = provider.providerName
        let interval = max(1.0, sampleIntervalSec)

        for fileURL in mediaURLs {
            let ext = fileURL.pathExtension.lowercased()
            var fileSegments: [BRollSegment] = []

            if Self.imageExtensions.contains(ext) {
                if let jpeg = Self.loadResizedImageJPEG(url: fileURL, maxDimension: 512) {
                    let (caption, used) = try await describeWithFallback(
                        jpeg: jpeg,
                        filename: fileURL.lastPathComponent,
                        primary: provider,
                        fallback: fallbackProvider
                    )
                    lastUsedProvider = used
                    fileSegments.append(BRollSegment(
                        assetPath: fileURL.path,
                        assetName: fileURL.lastPathComponent,
                        startSec: 0,
                        endSec: 5.0,
                        description: caption.description,
                        tags: caption.tags,
                        mood: caption.mood
                    ))
                }
            } else {
                let frames = await Self.extractVideoKeyframes(url: fileURL, intervalSec: interval, maxFrames: maxFramesPerVideo, maxDimension: 512)
                for frame in frames {
                    let (caption, used) = try await describeWithFallback(
                        jpeg: frame.jpeg,
                        filename: fileURL.lastPathComponent,
                        primary: provider,
                        fallback: fallbackProvider
                    )
                    lastUsedProvider = used
                    fileSegments.append(BRollSegment(
                        assetPath: fileURL.path,
                        assetName: fileURL.lastPathComponent,
                        startSec: frame.start,
                        endSec: frame.end,
                        description: caption.description,
                        tags: caption.tags,
                        mood: caption.mood
                    ))
                }
            }

            if !fileSegments.isEmpty {
                try index.upsert(fileSegments)
                totalSegments += fileSegments.count
            }
        }

        return (mediaURLs.count, totalSegments, lastUsedProvider)
    }

    private func describeWithFallback(
        jpeg: Data,
        filename: String,
        primary: any VisualIndexProvider,
        fallback: (any VisualIndexProvider)?
    ) async throws -> (VisualCaption, String) {
        do {
            let caption = try await primary.describe(jpegData: jpeg, filename: filename)
            return (caption, primary.providerName)
        } catch {
            guard let fallback else { throw error }
            let caption = try await fallback.describe(jpegData: jpeg, filename: filename)
            return (caption, fallback.providerName)
        }
    }

    static func loadResizedImageJPEG(url: URL, maxDimension: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }

    static func extractVideoKeyframes(
        url: URL,
        intervalSec: Double,
        maxFrames: Int,
        maxDimension: Int
    ) async -> [(start: Double, end: Double, jpeg: Data)] {
        let asset = AVURLAsset(url: url)
        guard let loadedDur = try? await asset.load(.duration).seconds, loadedDur.isFinite, loadedDur > 0 else {
            return []
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var times: [Double] = []
        var cursor = min(0.25, loadedDur * 0.2)
        while cursor < loadedDur, times.count < maxFrames {
            times.append(cursor)
            cursor += intervalSec
        }
        if times.isEmpty { times = [0] }

        var results: [(start: Double, end: Double, jpeg: Data)] = []
        for (idx, t) in times.enumerated() {
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
               let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.78]) {
                let segEnd = idx + 1 < times.count ? times[idx + 1] : loadedDur
                results.append((start: max(0, t - 0.25), end: max(t + 0.5, segEnd), jpeg: jpeg))
            }
        }
        return results
    }
}
