import Foundation

enum CatalogEntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case skill
    case plugin

    var id: String { rawValue }
    var label: String { self == .skill ? "Skill" : "Plugin" }
}

struct CommunityCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: CatalogEntryKind
    var category: String
    var description: String
    var author: String
    var githubSource: String
    var tier: String?
    var tags: [String]
}

struct CommunityCatalog: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var updatedAt: String
    var entries: [CommunityCatalogEntry]
}

enum CatalogError: LocalizedError, Equatable {
    case invalidFeedURL(String)
    case httpError(Int)
    case invalidCatalog(String)

    var errorDescription: String? {
        switch self {
        case .invalidFeedURL(let msg), .invalidCatalog(let msg): msg
        case .httpError(let code): "Catalog feed returned HTTP \(code)."
        }
    }
}

/// Community catalog store powering `Settings > Explore` and MCP `browse_catalog` (`I5`, `I6`).
@MainActor
final class ExploreCatalogStore: ObservableObject {
    static let shared = ExploreCatalogStore()
    nonisolated static let defaultFeedURL = URL(string: "https://raw.githubusercontent.com/nguyenducvuongg/hybrid_editor/main/assets/catalog/community_catalog.json")!

    @Published private(set) var entries: [CommunityCatalogEntry]
    @Published private(set) var lastUpdated: String
    @Published private(set) var isRefreshing = false

    private let customCacheURL: URL?
    private var cacheURL: URL {
        customCacheURL ?? HybridStorage.subdir("Catalog").appendingPathComponent("community_catalog.json")
    }

    init(cacheURL: URL? = nil) {
        self.customCacheURL = cacheURL
        let url = cacheURL ?? HybridStorage.subdir("Catalog").appendingPathComponent("community_catalog.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(CommunityCatalog.self, from: data),
           decoded.schemaVersion == 1, !decoded.entries.isEmpty {
            self.entries = decoded.entries
            self.lastUpdated = decoded.updatedAt
        } else {
            self.entries = Self.embeddedCatalog.entries
            self.lastUpdated = Self.embeddedCatalog.updatedAt
        }
    }

    static let embeddedCatalog = CommunityCatalog(
        schemaVersion: 1,
        updatedAt: "2026-11-28",
        entries: [
            CommunityCatalogEntry(
                id: "vietnamese-shorts-creator",
                name: "Vietnamese Shorts & Reels Creator",
                kind: .skill,
                category: "Vietnamese Creator",
                description: "Dựng Shorts/Reels/TikTok tiếng Việt trọn quy trình: A-roll VAD, phụ đề Karaoke CapCut, B-roll 3 tầng khớp beat & Auto-Ducking nhạc nền.",
                author: "hybrid_edit_vid",
                githubSource: "nguyenducvuongg/hybrid_editor/tree/main/assets/editor-skills/vietnamese-shorts-creator",
                tier: nil,
                tags: ["vietnamese", "shorts", "reels", "karaoke", "captions", "tiếng việt"]
            ),
            CommunityCatalogEntry(
                id: "aroll-rough-cut",
                name: "A-Roll Rough-Cut (Vietnamese + VAD)",
                kind: .skill,
                category: "Vietnamese Creator",
                description: "Cắt dựng thô A-roll tiếng Việt với Whisper Metal + VAD lọc khoảng lặng, giữ câu nói tự nhiên trong 1 AgentTurn.",
                author: "hybrid_edit_vid",
                githubSource: "nguyenducvuongg/hybrid_editor/tree/main/assets/editor-skills/aroll-rough-cut",
                tier: nil,
                tags: ["aroll", "whisper", "vad", "tiếng việt", "cắt dựng"]
            ),
            CommunityCatalogEntry(
                id: "smart-broll-inserter",
                name: "Smart B-Roll Inserter (3-Tier)",
                kind: .skill,
                category: "B-Roll & Stock",
                description: "Chèn B-roll theo thác 3 tầng: Local SQLite FTS5 -> Stock Pexels/Pixabay -> ComfyUI Colab lên V2+.",
                author: "hybrid_edit_vid",
                githubSource: "nguyenducvuongg/hybrid_editor/tree/main/assets/editor-skills/smart-broll-inserter",
                tier: nil,
                tags: ["broll", "fts5", "stock", "comfyui", "v2"]
            ),
            CommunityCatalogEntry(
                id: "comfy-broll-generator",
                name: "ComfyUI B-Roll & Asset Generator",
                kind: .skill,
                category: "ComfyUI",
                description: "Generate custom Flux images, Wan2.1 I2V clips from timeline frames, or Stable Audio SFX via remote Colab GPU.",
                author: "hybrid_edit_vid",
                githubSource: "nguyenducvuongg/hybrid_editor/tree/main/assets/editor-skills/comfy-broll-generator",
                tier: nil,
                tags: ["comfyui", "flux", "wan2.1", "i2v", "colab", "ai generation"]
            ),
            CommunityCatalogEntry(
                id: "stock-media-finder",
                name: "Free Stock Media Finder",
                kind: .skill,
                category: "B-Roll & Stock",
                description: "Search Pexels and Pixabay for HD/4K stock footage, inspect numbered contact sheets, and place directly on V2.",
                author: "hybrid_edit_vid",
                githubSource: "nguyenducvuongg/hybrid_editor/tree/main/assets/editor-skills/stock-media-finder",
                tier: nil,
                tags: ["stock", "pexels", "pixabay", "video", "photo"]
            ),
            CommunityCatalogEntry(
                id: "vietnamese-cinematic-pack",
                name: "Vietnamese Cinematic Pack",
                kind: .plugin,
                category: "Color & LUTs",
                description: "Bundle Tier B gồm LUT 3D Saigon Golden Hour (.cube) dùng ngay với `list_looks`/`set_grade` và workflow ComfyUI Saigon Street Flux.",
                author: "hybrid_edit_vid",
                githubSource: "nguyenducvuongg/hybrid_editor/tree/main/assets/plugins/vietnamese-cinematic-pack",
                tier: "Tier B · Assets",
                tags: ["lut", "cube", "color grade", "saigon", "comfyui", "tiếng việt"]
            ),
        ]
    )

    func search(query: String, kind: CatalogEntryKind? = nil) -> [CommunityCatalogEntry] {
        let filteredByKind = kind.map { k in entries.filter { $0.kind == k } } ?? entries
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return filteredByKind }
        let needles = BRollFTSIndex.normalizeVietnamese(trimmed)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return filteredByKind }
        return filteredByKind.filter { entry in
            let haystack = BRollFTSIndex.normalizeVietnamese(
                "\(entry.id) \(entry.name) \(entry.category) \(entry.description) \(entry.author) \(entry.tags.joined(separator: " "))"
            )
            return needles.allSatisfy { haystack.contains($0) }
        }
    }

    func refresh(from url: URL = ExploreCatalogStore.defaultFeedURL, allowLoopbackForTests: Bool = false) async throws {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let isAllowedLoopback = allowLoopbackForTests && (scheme == "http" || scheme == "https") && (host == "127.0.0.1" || host == "localhost")
        guard scheme == "https" || isAllowedLoopback else {
            throw CatalogError.invalidFeedURL("Community catalog feed must use HTTPS.")
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let req = URLRequest(url: url, timeoutInterval: 15)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw CatalogError.httpError(code)
        }
        guard let decoded = try? JSONDecoder().decode(CommunityCatalog.self, from: data),
              decoded.schemaVersion == 1, !decoded.entries.isEmpty else {
            throw CatalogError.invalidCatalog("Invalid or unsupported community catalog JSON.")
        }
        try HybridStorage.writeAtomicVerified(data, to: cacheURL)
        self.entries = decoded.entries
        self.lastUpdated = decoded.updatedAt
    }
}
