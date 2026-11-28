import AppKit
import AVFoundation
import Foundation
import ImageIO

enum StockOrientation: String, Codable, CaseIterable, Sendable {
    case any
    case landscape
    case portrait
    case square
}

struct StockSearchItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var provider: String
    var kind: StockMediaKind
    var title: String
    var author: String
    var sourcePageURL: String
    var licence: String
    var width: Int
    var height: Int
    var durationSeconds: Double?
    var previewURL: URL?
    var downloadURL: URL
}

enum StockMediaError: Error, LocalizedError {
    case noProvidersConfigured
    case httpError(String, Int)
    case downloadInvalid(String)
    case itemNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noProvidersConfigured:
            return "No stock media API keys configured (add Pexels or Pixabay key in Settings > Integrations)."
        case .httpError(let provider, let code):
            return "\(provider) API returned HTTP \(code)."
        case .downloadInvalid(let msg), .itemNotFound(let msg):
            return msg
        }
    }
}

protocol StockProviderProtocol: Sendable {
    var name: String { get }
    func search(query: String, kind: StockMediaKind, orientation: StockOrientation, perPage: Int) async throws -> [StockSearchItem]
}

// MARK: - Pexels

struct PexelsProvider: StockProviderProtocol {
    let name = "pexels"
    let baseURL: URL
    private let apiKeyLookup: @Sendable () -> String?

    init(
        baseURL: URL = URL(string: "https://api.pexels.com")!,
        apiKeyLookup: @escaping @Sendable () -> String? = { try? AppSecrets.shared.get(.pexelsAPIKey) }
    ) {
        self.baseURL = baseURL
        self.apiKeyLookup = apiKeyLookup
    }

    func search(query: String, kind: StockMediaKind, orientation: StockOrientation, perPage: Int) async throws -> [StockSearchItem] {
        guard let apiKey = apiKeyLookup()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            return []
        }
        let path = kind == .photos ? "v1/search" : "videos/search"
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return []
        }
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: "\(max(1, min(20, perPage)))"),
        ]
        if orientation != .any {
            items.append(URLQueryItem(name: "orientation", value: orientation.rawValue))
        }
        comps.queryItems = items
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("Editroom", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw StockMediaError.httpError("Pexels", code)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if kind == .photos {
            let photos = (root["photos"] as? [[String: Any]]) ?? []
            return photos.compactMap { p in
                guard let pid = p["id"] as? Int,
                      let src = p["src"] as? [String: Any],
                      let dlStr = (src["large2x"] as? String) ?? (src["original"] as? String),
                      let dlURL = URL(string: dlStr) else { return nil }
                let preview = (src["medium"] as? String).flatMap(URL.init(string:))
                return StockSearchItem(
                    id: "pexels-photo-\(pid)",
                    provider: "Pexels",
                    kind: .photos,
                    title: (p["alt"] as? String)?.isEmpty == false ? (p["alt"] as! String) : "Pexels Photo \(pid)",
                    author: (p["photographer"] as? String) ?? "Pexels",
                    sourcePageURL: (p["url"] as? String) ?? "https://www.pexels.com",
                    licence: "Pexels License (Free to use)",
                    width: (p["width"] as? Int) ?? 0,
                    height: (p["height"] as? Int) ?? 0,
                    durationSeconds: nil,
                    previewURL: preview,
                    downloadURL: dlURL
                )
            }
        } else {
            let videos = (root["videos"] as? [[String: Any]]) ?? []
            return videos.compactMap { v in
                guard let vid = v["id"] as? Int,
                      let files = v["video_files"] as? [[String: Any]],
                      let best = files.sorted(by: { ($0["width"] as? Int ?? 0) > ($1["width"] as? Int ?? 0) }).first(where: { ($0["width"] as? Int ?? 0) <= 1920 }) ?? files.first,
                      let link = best["link"] as? String,
                      let dlURL = URL(string: link) else { return nil }
                let user = (v["user"] as? [String: Any])?["name"] as? String ?? "Pexels"
                let preview = (v["image"] as? String).flatMap(URL.init(string:))
                return StockSearchItem(
                    id: "pexels-video-\(vid)",
                    provider: "Pexels",
                    kind: .videos,
                    title: "Pexels Video \(vid)",
                    author: user,
                    sourcePageURL: (v["url"] as? String) ?? "https://www.pexels.com",
                    licence: "Pexels License (Free to use)",
                    width: (best["width"] as? Int) ?? (v["width"] as? Int) ?? 0,
                    height: (best["height"] as? Int) ?? (v["height"] as? Int) ?? 0,
                    durationSeconds: (v["duration"] as? Double) ?? (v["duration"] as? Int).map(Double.init),
                    previewURL: preview,
                    downloadURL: dlURL
                )
            }
        }
    }
}

// MARK: - Pixabay

struct PixabayProvider: StockProviderProtocol {
    let name = "pixabay"
    let baseURL: URL
    private let apiKeyLookup: @Sendable () -> String?

    init(
        baseURL: URL = URL(string: "https://pixabay.com")!,
        apiKeyLookup: @escaping @Sendable () -> String? = { try? AppSecrets.shared.get(.pixabayAPIKey) }
    ) {
        self.baseURL = baseURL
        self.apiKeyLookup = apiKeyLookup
    }

    func search(query: String, kind: StockMediaKind, orientation: StockOrientation, perPage: Int) async throws -> [StockSearchItem] {
        guard let apiKey = apiKeyLookup()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            return []
        }
        let path = kind == .photos ? "api/" : "api/videos/"
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return []
        }
        var items = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "\(max(3, min(20, perPage)))"),
        ]
        if kind == .photos {
            items.append(URLQueryItem(name: "image_type", value: "photo"))
            if orientation == .landscape { items.append(URLQueryItem(name: "orientation", value: "horizontal")) }
            if orientation == .portrait { items.append(URLQueryItem(name: "orientation", value: "vertical")) }
        }
        comps.queryItems = items
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Editroom", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw StockMediaError.httpError("Pixabay", code)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = root["hits"] as? [[String: Any]] else { return [] }

        if kind == .photos {
            return hits.compactMap { h in
                guard let hid = h["id"] as? Int,
                      let dlStr = (h["largeImageURL"] as? String) ?? (h["webformatURL"] as? String),
                      let dlURL = URL(string: dlStr) else { return nil }
                let preview = (h["previewURL"] as? String ?? h["webformatURL"] as? String).flatMap(URL.init(string:))
                return StockSearchItem(
                    id: "pixabay-photo-\(hid)",
                    provider: "Pixabay",
                    kind: .photos,
                    title: (h["tags"] as? String) ?? "Pixabay Photo \(hid)",
                    author: (h["user"] as? String) ?? "Pixabay",
                    sourcePageURL: (h["pageURL"] as? String) ?? "https://pixabay.com",
                    licence: "Pixabay Content License",
                    width: (h["imageWidth"] as? Int) ?? 0,
                    height: (h["imageHeight"] as? Int) ?? 0,
                    durationSeconds: nil,
                    previewURL: preview,
                    downloadURL: dlURL
                )
            }
        } else {
            return hits.compactMap { h in
                guard let hid = h["id"] as? Int,
                      let vids = h["videos"] as? [String: Any],
                      let variant = (vids["large"] as? [String: Any]) ?? (vids["medium"] as? [String: Any]),
                      let dlStr = variant["url"] as? String,
                      let dlURL = URL(string: dlStr) else { return nil }
                let preview = (variant["thumbnail"] as? String).flatMap(URL.init(string:))
                return StockSearchItem(
                    id: "pixabay-video-\(hid)",
                    provider: "Pixabay",
                    kind: .videos,
                    title: (h["tags"] as? String) ?? "Pixabay Video \(hid)",
                    author: (h["user"] as? String) ?? "Pixabay",
                    sourcePageURL: (h["pageURL"] as? String) ?? "https://pixabay.com",
                    licence: "Pixabay Content License",
                    width: (variant["width"] as? Int) ?? 0,
                    height: (variant["height"] as? Int) ?? 0,
                    durationSeconds: (h["duration"] as? Double) ?? (h["duration"] as? Int).map(Double.init),
                    previewURL: preview,
                    downloadURL: dlURL
                )
            }
        }
    }
}

// MARK: - Stock Media Coordinator

@MainActor
final class StockMediaManager: ObservableObject {
    static let shared = StockMediaManager()

    @Published private(set) var lastResults: [StockSearchItem] = []
    private var cacheById: [String: StockSearchItem] = [:]

    var customProvidersForTests: [any StockProviderProtocol]?

    func setResultsForTests(_ items: [StockSearchItem]) {
        lastResults = items
        for it in items { cacheById[it.id] = it }
    }

    func item(for id: String) -> StockSearchItem? {
        cacheById[id]
    }

    private func activeProviders(filter: String?) -> [any StockProviderProtocol] {
        let pool = customProvidersForTests ?? [PexelsProvider(), PixabayProvider()]
        guard let f = filter?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty else {
            return pool
        }
        return pool.filter { $0.name.lowercased() == f }
    }

    func search(
        query: String,
        kind: StockMediaKind,
        orientation: StockOrientation = .any,
        providerFilter: String? = nil,
        perPage: Int = 8
    ) async throws -> [StockSearchItem] {
        let providers = activeProviders(filter: providerFilter)
        var all: [StockSearchItem] = []
        var firstError: Error?

        try await withThrowingTaskGroup(of: Result<[StockSearchItem], Error>.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return .success(try await provider.search(query: query, kind: kind, orientation: orientation, perPage: perPage))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for try await res in group {
                switch res {
                case .success(let items): all.append(contentsOf: items)
                case .failure(let err): if firstError == nil { firstError = err }
                }
            }
        }

        if all.isEmpty, let firstError {
            throw firstError
        }
        lastResults = all
        for item in all { cacheById[item.id] = item }
        return all
    }

    func downloadAndVerify(_ item: StockSearchItem, into folder: URL) async throws -> URL {
        let scheme = item.downloadURL.scheme?.lowercased()
        let host = item.downloadURL.host?.lowercased() ?? ""
        let isLocalLoopback = (host == "127.0.0.1" || host == "localhost")
        guard scheme == "https" || (scheme == "http" && isLocalLoopback) else {
            throw StockMediaError.downloadInvalid("Only https stock media downloads are allowed.")
        }

        var req = URLRequest(url: item.downloadURL, timeoutInterval: 120)
        req.setValue("Editroom", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code), !data.isEmpty else {
            throw StockMediaError.downloadInvalid("Failed to download stock item (HTTP \(code)).")
        }

        let mime = (resp as? HTTPURLResponse)?.mimeType?.lowercased() ?? ""
        let rawExt = item.downloadURL.pathExtension.lowercased()
        let ext: String
        if item.kind == .photos {
            ext = ["jpg", "jpeg", "png", "webp"].contains(rawExt) ? rawExt : (mime.contains("png") ? "png" : "jpg")
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(src) > 0 else {
                throw StockMediaError.downloadInvalid("Downloaded file is not a valid image.")
            }
        } else {
            ext = ["mp4", "mov", "m4v"].contains(rawExt) ? rawExt : "mp4"
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = HybridStorage.truncateUTF8("\(item.provider.lowercased())-\(item.id)-\(item.title)", maxBytes: 120)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dest = folder.appendingPathComponent("\(stem).\(ext)")
        try HybridStorage.writeAtomicVerified(data, to: dest)

        if item.kind == .videos {
            let asset = AVURLAsset(url: dest)
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if tracks.isEmpty {
                try? FileManager.default.removeItem(at: dest)
                throw StockMediaError.downloadInvalid("Downloaded stock video has no playable video track.")
            }
        }

        appendAttribution(item, filename: dest.lastPathComponent, in: folder)
        return dest
    }

    func renderContactSheet(for items: [StockSearchItem]) async -> Data? {
        let candidates = Array(items.prefix(6))
        guard !candidates.isEmpty else { return nil }

        var fetched: [(Int, NSImage)] = []
        await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (idx, item) in candidates.enumerated() {
                group.addTask {
                    guard let url = item.previewURL else { return (idx, nil) }
                    var req = URLRequest(url: url, timeoutInterval: 10)
                    req.setValue("Editroom", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await URLSession.shared.data(for: req) else { return (idx, nil) }
                    return (idx, NSImage(data: data))
                }
            }
            for await (idx, img) in group {
                if let img { fetched.append((idx, img)) }
            }
        }
        guard !fetched.isEmpty else { return nil }
        fetched.sort { $0.0 < $1.0 }

        let cols = min(3, fetched.count)
        let rows = (fetched.count + cols - 1) / cols
        let cellW = 240, cellH = 135, gap = 4
        let sheetW = cols * cellW + (cols - 1) * gap
        let sheetH = rows * cellH + (rows - 1) * gap

        guard let ctx = CGContext(
            data: nil,
            width: sheetW,
            height: sheetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        for (slot, (itemIdx, nsImg)) in fetched.enumerated() {
            let x = (slot % cols) * (cellW + gap)
            let y = sheetH - (slot / cols + 1) * cellH - (slot / cols) * gap
            let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
            if let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.draw(cg, in: rect)
            }
            let item = candidates[itemIdx]
            let tag = "#\(itemIdx + 1) \(item.provider)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let sz = tag.size(withAttributes: attrs)
            let box = CGRect(x: rect.minX + 4, y: rect.maxY - sz.height - 6, width: sz.width + 8, height: sz.height + 4)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
            ctx.fill(box)
            tag.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private func appendAttribution(_ item: StockSearchItem, filename: String, in folder: URL) {
        let note = folder.appendingPathComponent("Sources.txt")
        let entry = """
        \(filename)
          Downloaded: \(ISO8601DateFormatter().string(from: Date()))
          Provider: \(item.provider) (\(item.id))
          Author: \(item.author)
          Source: \(item.sourcePageURL)
          Licence: \(item.licence)


        """
        if let h = try? FileHandle(forWritingTo: note) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        } else {
            try? entry.write(to: note, atomically: true, encoding: .utf8)
        }
    }
}
