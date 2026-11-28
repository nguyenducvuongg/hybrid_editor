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

    func clonePinned(_ spec: GitHubSpec, to tempDir: URL) async throws -> String {
        let sourceURL = cloneURLOverride?(spec) ?? spec.cloneURL
        var args = ["clone", "--depth", "1"]
        if let ref = spec.ref {
            args += ["--branch", ref]
        }
        args += ["--", sourceURL, tempDir.path]
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
