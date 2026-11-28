import Foundation

enum SkillError: Error, LocalizedError, Equatable {
    case invalidSource(String)
    case invalidSkill(String)
    case pathTraversal(String)
    case gitFailed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let msg), .invalidSkill(let msg), .gitFailed(let msg), .notFound(let msg):
            return msg
        case .pathTraversal(let path):
            return "Path escapes extension root: \(path)"
        }
    }
}

enum SkillSource: Codable, Equatable {
    case builtIn
    case local(path: String)
    case github(repo: String, ref: String?, subpath: String?, commitSHA: String)
}

struct SkillMetadata: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var source: SkillSource
    var rootPath: String
    var skillFilePath: String
    var enabled: Bool
    var installedAt: Date
}

struct LoadedSkill: Equatable {
    var meta: SkillMetadata
    var body: String
    var referenceFiles: [String]
}

/// Validates slugs, relative paths, and directory trees so skills and plugins cannot escape their install root.
enum SafePath {
    static func isValidSlug(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 64 else { return false }
        for (idx, scalar) in raw.unicodeScalars.enumerated() {
            let lower = scalar.value >= 97 && scalar.value <= 122
            let digit = scalar.value >= 48 && scalar.value <= 57
            let sep = scalar.value == 45 || scalar.value == 95
            if idx == 0 ? !(lower || digit) : !(lower || digit || sep) { return false }
        }
        return true
    }

    static func sanitizeSlug(_ raw: String, fallback: String = "extension") -> String {
        let lowered = raw.lowercased().map { ch -> Character in
            let s = ch.unicodeScalars.first?.value ?? 0
            if (s >= 97 && s <= 122) || (s >= 48 && s <= 57) { return ch }
            return "-"
        }
        var collapsed = String(lowered)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if collapsed.isEmpty { collapsed = fallback }
        return String(collapsed.prefix(64))
    }

    static func safeResolve(relative: String, inside root: URL) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw SkillError.pathTraversal(relative)
        }
        let comps = trimmed.split(separator: "/").map(String.init)
        guard !comps.contains("..") else {
            throw SkillError.pathTraversal(relative)
        }
        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = rootStd.appendingPathComponent(trimmed).standardizedFileURL
        let rootPrefix = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"
        guard candidate.path == rootStd.path || candidate.path.hasPrefix(rootPrefix) else {
            throw SkillError.pathTraversal(relative)
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let real = candidate.resolvingSymlinksInPath()
            guard real.path == rootStd.path || real.path.hasPrefix(rootPrefix) else {
                throw SkillError.pathTraversal(relative)
            }
        }
        return candidate
    }

    static func validateDirectoryTree(root: URL) throws {
        let fm = FileManager.default
        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"
        guard let en = fm.enumerator(at: rootStd, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            return
        }
        for case let item as URL in en {
            let vals = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                let target = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard target == rootStd.path || target.hasPrefix(rootPrefix) else {
                    throw SkillError.pathTraversal(item.lastPathComponent)
                }
            }
        }
    }
}

/// Parses GitHub repository specs and tree subpaths safely without shell interpolation.
struct GitHubSpec: Equatable, Sendable {
    var owner: String
    var repo: String
    var ref: String?
    var subpath: String?

    var canonicalRepo: String { "\(owner)/\(repo)" }
    var cloneURL: String { "https://github.com/\(owner)/\(repo).git" }

    static func parse(_ raw: String) throws -> GitHubSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let badChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";|&$`><"))
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: badChars) == nil, !trimmed.contains("..") else {
            throw SkillError.invalidSource("Invalid GitHub repository reference.")
        }

        let parts: [String]
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let url = URL(string: trimmed), url.host?.lowercased() == "github.com" else {
                throw SkillError.invalidSource("Only https://github.com repositories are supported.")
            }
            parts = url.pathComponents.filter { $0 != "/" }
        } else {
            parts = trimmed.split(separator: "/").map(String.init)
        }

        guard parts.count >= 2 else {
            throw SkillError.invalidSource("Expected owner/repo or GitHub URL.")
        }
        let owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty, !owner.hasPrefix("-"), !repo.hasPrefix("-") else {
            throw SkillError.invalidSource("Invalid GitHub owner or repository name.")
        }

        var ref: String?
        var subpath: String?
        if parts.count >= 4, parts[2] == "tree" {
            ref = parts[3]
            if parts.count > 4 { subpath = parts.dropFirst(4).joined(separator: "/") }
        } else if parts.count > 2 {
            subpath = parts.dropFirst(2).joined(separator: "/")
        }
        if let ref, ref.isEmpty || ref.hasPrefix("-") {
            throw SkillError.invalidSource("Invalid git ref '\(ref)'.")
        }
        return GitHubSpec(owner: owner, repo: repo, ref: ref, subpath: subpath)
    }
}

/// Injectable off-main-actor git subprocess runner used by `SkillRegistry` and `PluginHost` (`I6`).
struct GitRunner: Sendable {
    var run: @Sendable (_ args: [String], _ cwd: URL?) async throws -> (status: Int32, stdout: String)
    var cloneURLOverride: (@Sendable (GitHubSpec) -> String)?

    static let system = GitRunner(
        run: { args, cwd in
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    p.arguments = args
                    p.currentDirectoryURL = cwd
                    var env = ProcessInfo.processInfo.environment
                    env["GIT_TERMINAL_PROMPT"] = "0"
                    p.environment = env
                    p.standardInput = FileHandle.nullDevice
                    let pipe = Pipe()
                    p.standardOutput = pipe
                    p.standardError = pipe
                    do {
                        try p.run()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        p.waitUntilExit()
                        cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        },
        cloneURLOverride: nil
    )

    static func safeCloneArguments(spec: GitHubSpec, sourceURL: String, to tempDir: URL) -> [String] {
        var args = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "clone", "--depth", "1",
        ]
        if let ref = spec.ref {
            args += ["--branch", ref]
        }
        args += ["--", sourceURL, tempDir.path]
        return args
    }

    func clonePinned(_ spec: GitHubSpec, to tempDir: URL) async throws -> String {
        let sourceURL = cloneURLOverride?(spec) ?? spec.cloneURL
        let args = Self.safeCloneArguments(spec: spec, sourceURL: sourceURL, to: tempDir)
        let cloneRes = try await run(args, nil)
        guard cloneRes.status == 0 else {
            throw SkillError.gitFailed("git clone failed: \(cloneRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let shaRes = try await run(["rev-parse", "HEAD"], tempDir)
        guard shaRes.status == 0 else {
            throw SkillError.gitFailed("git rev-parse HEAD failed.")
        }
        return shaRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Registry for local and GitHub-installed `SKILL.md` agent workflows (`HybridStorage.subdir("Skills")`).
@MainActor
final class SkillRegistry: ObservableObject {
    static let shared = SkillRegistry()

    let baseDir: URL
    private var indexURL: URL { baseDir.appendingPathComponent("skills_index.json") }

    @Published private(set) var skills: [SkillMetadata] = []

    init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? HybridStorage.subdir("Skills")
        reload()
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexURL),
              let parsed = try? decoder.decode([SkillMetadata].self, from: data) else {
            skills = []
            return
        }
        skills = parsed
    }

    private func saveIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(skills)
        try HybridStorage.writeAtomicVerified(data, to: indexURL)
    }

    static func parseSkillMarkdown(_ content: String, fallbackName: String) -> (name: String, description: String, body: String) {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        var name = fallbackName
        var description = ""
        var body = normalized

        if normalized.hasPrefix("---\n") {
            let afterOpen = normalized.dropFirst(4)
            if let closeRange = afterOpen.range(of: "\n---\n") ?? afterOpen.range(of: "\n---") {
                let yaml = String(afterOpen[..<closeRange.lowerBound])
                body = String(afterOpen[closeRange.upperBound...])
                for rawLine in yaml.components(separatedBy: "\n") {
                    guard let colon = rawLine.firstIndex(of: ":") else { continue }
                    let k = rawLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    var v = rawLine[yaml.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                        v = String(v.dropFirst().dropLast())
                    }
                    if k == "name", !v.isEmpty { name = v }
                    if k == "description", !v.isEmpty { description = v }
                }
            }
        }
        return (name, description, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func installFromLocal(directory: URL, idOverride: String? = nil, sourceOverride: SkillSource? = nil) throws -> SkillMetadata {
        let fm = FileManager.default
        let sourceDir = directory.standardizedFileURL
        try SafePath.validateDirectoryTree(root: sourceDir)

        let skillFile = sourceDir.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: skillFile.path),
              let content = try? String(contentsOf: skillFile, encoding: .utf8) else {
            throw SkillError.invalidSkill("Missing readable SKILL.md in \(sourceDir.lastPathComponent).")
        }
        let parsed = Self.parseSkillMarkdown(content, fallbackName: sourceDir.lastPathComponent)
        let id = SafePath.sanitizeSlug(idOverride ?? parsed.name, fallback: "skill")
        guard SafePath.isValidSlug(id) else {
            throw SkillError.invalidSkill("Invalid skill id '\(id)'.")
        }

        let destDir = baseDir.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: destDir)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceDir, to: destDir)
        try? fm.removeItem(at: destDir.appendingPathComponent(".git"))

        let meta = SkillMetadata(
            id: id,
            name: parsed.name,
            description: parsed.description,
            source: sourceOverride ?? .local(path: sourceDir.path),
            rootPath: destDir.path,
            skillFilePath: destDir.appendingPathComponent("SKILL.md").path,
            enabled: true,
            installedAt: Date()
        )
        skills.removeAll { $0.id == id }
        skills.append(meta)
        skills.sort { $0.id < $1.id }
        try saveIndex()
        return meta
    }

    static let builtInSkillSpecs: [(id: String, markdown: String)] = [
        ("aroll-rough-cut", """
        ---
        name: aroll-rough-cut
        description: Cắt dựng thô A-roll tiếng Việt với Whisper Metal + VAD lọc khoảng lặng, giữ câu nói tự nhiên trong 1 AgentTurn có thể Undo.
        ---

        # A-Roll Rough-Cut (Tiếng Việt + VAD Guard)
        1. Gọi `get_project` lấy `clip_id` A-roll trên `V1`.
        2. Gọi `transcribe_aroll(language: "vi", min_silence_sec: 0.7, pad_sec: 0.12)` để nhận `speech_spans`, `words` và `suggested_keep_ranges` (VAD chống ảo giác P6).
        3. Mở 1 `AgentTurn` (nếu chưa có) và gọi `apply_edl_patch` (`keep_ranges`, `coord: "source"`, `ripple: true`).
        4. Kiểm tra trực quan bằng `preview_timeline_strip` trước khi chốt.
        """),
        ("smart-broll-inserter", """
        ---
        name: smart-broll-inserter
        description: Chèn B-roll thông minh theo thác 3 tầng tự động (Local B-Roll FTS5 -> Free Stock Pexels/Pixabay -> ComfyUI Colab) vào V2+ trong 1 AgentTurn.
        ---

        # Smart B-Roll Inserter (Thác Tự Động 3 Tầng)
        1. Tầng 1: Gọi `search_broll(query: "<ngữ cảnh>", limit: 6)` (nếu index rỗng, chạy `index_broll_folder`).
        2. Tầng 2: Nếu `fallback_tier == 2`, gọi `search_stock_media` -> `import_stock_media`.
        3. Tầng 3: Nếu Stock chưa khớp hoặc cần cảnh đặc biệt, gọi `comfy_status` -> `comfy_generate`.
        4. Đặt B-roll muted lên `V2`+ bằng `insert_broll_overlay(mute_audio: true)` và kiểm tra qua `preview_timeline_strip`.
        """),
        ("comfy-broll-generator", """
        ---
        name: comfy-broll-generator
        description: Generate custom B-roll images, videos (including Image-to-Video from timeline frames), or audio on a remote Google Colab ComfyUI server and insert them onto the timeline.
        ---

        # ComfyUI B-Roll & Asset Generator
        1. Call `comfy_status` first to verify Colab GPU connectivity, VRAM, and checkpoints.
        2. Call `comfy_generate` (`kind`: `image`, `video`, or `audio`; pass `reference_clip_id` & `reference_time` for I2V).
        3. Insert onto `V2`+ with `insert_broll_overlay` or `apply_edl_patch` (`insert_overlay`) and inspect via `preview_timeline_strip`.
        """),
        ("stock-media-finder", """
        ---
        name: stock-media-finder
        description: Search Pexels and Pixabay for free B-roll photos and HD/4K videos matching timeline pacing, visually inspect candidates, and import chosen assets with attribution.
        ---

        # Free Stock Media Finder (Pexels / Pixabay)
        1. Call `get_project` for sequence aspect ratio and gaps.
        2. Call `search_stock_media` with `include_thumbnails: true` to inspect candidates visually.
        3. Call `import_stock_media(stock_id: ...)` and place muted on `V2`+ with `insert_broll_overlay`, then verify via `preview_timeline_strip`.
        """),
        ("vietnamese-shorts-creator", """
        ---
        name: vietnamese-shorts-creator
        description: Dựng video Reels/Shorts/TikTok tiếng Việt trọn quy trình: cắt thô A-roll VAD, phụ đề karaoke từng từ CapCut, chèn B-roll 3 tầng theo nhịp beat, và auto-ducking nhạc nền trong 1 AgentTurn.
        ---

        # Vietnamese Shorts & Reels Creator
        1. Cài khung `1080x1920` (`set_sequence`), kiểm tra `get_project`.
        2. Cắt thô A-roll bằng `transcribe_aroll(language: "vi")` -> `apply_edl_patch(keep_ranges)`.
        3. Bật phụ đề karaoke từng từ bằng `generate_vietnamese_captions(preset: "karaoke_pill", max_words: 4)`.
        4. Chèn B-roll `V2`+ (`search_broll` -> `search_stock_media` -> `comfy_generate` -> `insert_broll_overlay`) và khớp nhịp nhạc `beat_sync_cuts`.
        5. Gọi `auto_duck_bgm(duck_db: -14)` hạ nhạc nền mượt dưới giọng nói và xác minh qua `preview_timeline_strip`.
        """),
    ]

    /// Seeds the 4 built-in editor workflow skills idempotently into `baseDir`.
    @discardableResult
    func seedBuiltInSkills(force: Bool = false) -> Int {
        let fm = FileManager.default
        var installedCount = 0
        for spec in Self.builtInSkillSpecs {
            if !force, skills.contains(where: { $0.id == spec.id }) { continue }
            let destDir = baseDir.appendingPathComponent(spec.id, isDirectory: true)
            let skillURL = destDir.appendingPathComponent("SKILL.md")
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                try spec.markdown.write(to: skillURL, atomically: true, encoding: .utf8)
                let parsed = Self.parseSkillMarkdown(spec.markdown, fallbackName: spec.id)
                let meta = SkillMetadata(
                    id: spec.id,
                    name: parsed.name,
                    description: parsed.description,
                    source: .builtIn,
                    rootPath: destDir.path,
                    skillFilePath: skillURL.path,
                    enabled: true,
                    installedAt: Date()
                )
                skills.removeAll { $0.id == spec.id }
                skills.append(meta)
                installedCount += 1
            } catch {
                continue
            }
        }
        if installedCount > 0 {
            skills.sort { $0.id < $1.id }
            try? saveIndex()
        }
        return installedCount
    }

    @discardableResult
    func installFromGitHub(_ rawURL: String, gitRunner: GitRunner = .system, idOverride: String? = nil) async throws -> SkillMetadata {
        let spec = try GitHubSpec.parse(rawURL)
        let fm = FileManager.default
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("editroom-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sha = try await gitRunner.clonePinned(spec, to: tmp)
        let targetDir: URL
        if let sub = spec.subpath {
            targetDir = try SafePath.safeResolve(relative: sub, inside: tmp)
        } else {
            targetDir = tmp
        }
        let source = SkillSource.github(repo: spec.canonicalRepo, ref: spec.ref, subpath: spec.subpath, commitSHA: sha)
        return try installFromLocal(directory: targetDir, idOverride: idOverride, sourceOverride: source)
    }

    func setEnabled(id: String, enabled: Bool) throws {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { throw SkillError.notFound("Skill '\(id)' not found.") }
        skills[idx].enabled = enabled
        try saveIndex()
    }

    func remove(id: String) throws {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { throw SkillError.notFound("Skill '\(id)' not found.") }
        let removed = skills.remove(at: idx)
        try? FileManager.default.removeItem(atPath: removed.rootPath)
        try saveIndex()
    }

    func loadSkill(id: String) -> LoadedSkill? {
        guard let meta = skills.first(where: { $0.id == id }),
              let raw = try? String(contentsOfFile: meta.skillFilePath, encoding: .utf8) else {
            return nil
        }
        let parsed = Self.parseSkillMarkdown(raw, fallbackName: meta.name)
        var refs: [String] = []
        let refsDir = URL(fileURLWithPath: meta.rootPath).appendingPathComponent("references", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: refsDir.path) {
            refs = items.sorted().map { "references/\($0)" }
        }
        return LoadedSkill(meta: meta, body: parsed.body, referenceFiles: refs)
    }

    /// Extracts `/slug` mentions from user chat text.
    static func extractSlashSlugs(from prompt: String) -> [String] {
        var out: [String] = []
        for token in prompt.components(separatedBy: .whitespacesAndNewlines) where token.hasPrefix("/") {
            let clean = String(token.dropFirst())
                .trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_")))
                .lowercased()
            if SafePath.isValidSlug(clean), !out.contains(clean) {
                out.append(clean)
            }
        }
        return out
    }

    func activeSkills(filterSlugs: [String]? = nil) -> [LoadedSkill] {
        let wantSet = filterSlugs.map { Set($0.map { $0.lowercased() }) }
        return skills.compactMap { meta in
            if let wantSet {
                guard wantSet.contains(meta.id.lowercased()) else { return nil }
            } else if !meta.enabled {
                return nil
            }
            return loadSkill(id: meta.id)
        }
    }

    /// Composes prompt instructions from enabled skills plus any explicitly requested `/slug` skills.
    func composePromptSection(explicitSlugs: [String] = []) -> String {
        var orderedIDs: [String] = []
        for slug in explicitSlugs where !orderedIDs.contains(slug.lowercased()) {
            orderedIDs.append(slug.lowercased())
        }
        for meta in skills where meta.enabled && !orderedIDs.contains(meta.id.lowercased()) {
            orderedIDs.append(meta.id.lowercased())
        }
        let loaded = orderedIDs.compactMap { loadSkill(id: $0) }
        guard !loaded.isEmpty else { return "" }
        return loaded.map { s in
            let header = "## Skill /\(s.meta.id): \(s.meta.name)"
            let desc = s.meta.description.isEmpty ? "" : "\(s.meta.description)\n\n"
            return "\(header)\n\(desc)\(s.body)"
        }.joined(separator: "\n\n---\n\n")
    }
}
