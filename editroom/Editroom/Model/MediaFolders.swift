import Foundation
import UniformTypeIdentifiers

/// A folder on disk brought into the project whole. The Media panel mirrors it: what's in it, and in the
/// folders inside it, is shown there, and where an item sits in Media is where its file sits on disk.
/// Folders inside it aren't stored; they're worked out from where its files are.
struct MediaFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    /// `path` as seen from the project file's folder, written on save (as for media).
    var relativePath: String?
    /// Finds the folder again after it's renamed or moved on its drive.
    var bookmark: Data?

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// Whether `path` is `folder` or inside it.
    static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The media files in a folder and the folders inside it (not hidden files, not inside packages
    /// such as app bundles or photo libraries), in name order.
    static func mediaFiles(in path: String) -> [String] {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [String] = []
        // The same folder can be spelled more than one way (/tmp and /private/tmp, a link and where it goes);
        // files are kept in the folder's own spelling, so files and folder always line up.
        let spellings = Set([root.path, root.resolvingSymlinksInPath().path, "/private" + root.path])
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }.sorted { $0.count > $1.count }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, isMedia(url) else { continue }
            let p = url.path
            if let prefix = spellings.first(where: { p.hasPrefix($0) }) {
                files.append(path + "/" + p.dropFirst(prefix.count))
            } else {
                files.append(p)
            }
        }
        return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A file Editroom can bring in, by its type.
    static func isMedia(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return types.contains { t.conforms(to: $0) }
    }

    /// What Editroom imports: anything AVFoundation reads, and formats ffmpeg converts.
    static let types: [UTType] = {
        var types: [UTType] = [.movie, .video, .audio, .image, .audiovisualContent]
        for ext in ["mkv", "webm", "avi", "flv", "wmv", "mts", "m2ts", "ts", "mxf", "ogv", "ogg", "opus", "flac", "3gp", "mpg", "mpeg", "vob", "f4v"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()
}

enum Bookmark {
    /// A small bookmark: enough to find the file after a rename or a move on the same drive.
    static func make(_ path: String) -> Data? {
        try? URL(fileURLWithPath: path).bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where a bookmarked file or folder is now, if it's still there (not gone, and not in the Trash).
    static func resolve(_ data: Data?) -> String? {
        guard let data else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path), !path.contains("/.Trash/") else { return nil }
        return path
    }
}

extension Project {
    /// The folder brought in whole that holds `path`, if any (the innermost, if they're nested).
    func linkedFolder(holding path: String) -> MediaFolder? {
        (folders ?? []).filter { MediaFolder.contains($0.path, path) }.max { $0.path.count < $1.path.count }
    }

    /// Everything at `old` (a file or folder) is now at `new`: library items, folders and hidden files
    /// under it are pointed there.
    mutating func movePaths(from old: String, to new: String) {
        guard old != new else { return }
        func moved(_ p: String) -> String? {
            MediaFolder.contains(old, p) ? new + p.dropFirst(old.count) : nil
        }
        for i in assets.indices {
            if let p = moved(assets[i].path) { assets[i].path = p }
            if let pp = assets[i].playablePath, let p = moved(pp) { assets[i].playablePath = p }
        }
        if var f = folders {
            for i in f.indices { if let p = moved(f[i].path) { f[i].path = p } }
            folders = f
        }
        hiddenMedia = hiddenMedia?.map { moved($0) ?? $0 }
    }

    /// Whether a file in a linked folder was taken out of the project.
    func isHidden(_ path: String) -> Bool {
        (hiddenMedia ?? []).contains { MediaFolder.contains($0, path) }
    }

    /// Linked folders with nothing left in the project are let go (kept while `keeping` are importing).
    mutating func pruneFolders(keeping: Set<UUID> = []) {
        guard let f = folders else { return }
        let kept = f.filter { folder in keeping.contains(folder.id) || assets.contains { MediaFolder.contains(folder.path, $0.path) } }
        folders = kept.isEmpty ? nil : kept
        // Hidden files outside every remaining folder don't matter any more.
        hiddenMedia = hiddenMedia?.filter { h in kept.contains { MediaFolder.contains($0.path, h) } }
        if hiddenMedia?.isEmpty == true { hiddenMedia = nil }
    }
}

/// Something picked in the Media panel: an item, or a folder (by path).
enum MediaPick: Hashable {
    case asset(UUID)
    case folder(String)
    /// A file another app is still writing (a placeholder in the panel).
    case incoming(UUID)
}

/// A request for the Media panel to scroll to an item or folder; each one is new, even for the same target.
struct MediaReveal: Equatable {
    let target: MediaPick
    let token = UUID()
}

/// The Media panel's folders, worked out from the project: the linked folders at the top, and inside
/// each, the folders its files are in. A folder is named by its path.
struct MediaTree {
    let roots: [MediaFolder]
    /// For each library item in a linked folder, the folder its file is in.
    private var place: [UUID: String] = [:]

    init(_ project: Project) {
        roots = (project.folders ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for a in project.assets where project.linkedFolder(holding: a.path) != nil {
            place[a.id] = (a.path as NSString).deletingLastPathComponent
        }
    }

    /// The folder an item is shown in; nil for the top of the panel.
    func folder(of asset: MediaAsset) -> String? { place[asset.id] }

    func root(of folder: String) -> MediaFolder? {
        roots.filter { MediaFolder.contains($0.path, folder) }.max { $0.path.count < $1.path.count }
    }

    /// Whether a folder can be shown: a linked folder, or a folder with something in it.
    func exists(_ folder: String) -> Bool {
        roots.contains { $0.path == folder } || place.values.contains { MediaFolder.contains(folder, $0) }
    }

    /// The folders shown inside `folder` (nil: the top), in name order.
    func folders(in folder: String?) -> [String] {
        guard let folder else { return roots.map(\.path) }
        var names = Set<String>()
        let prefix = folder + "/"
        for p in place.values where p.hasPrefix(prefix) {
            if let first = p.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(first)) }
        }
        // A linked folder inside this one's place on disk isn't possible (they're merged), so no roots here.
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { prefix + $0 }
    }

    /// The items shown directly in `folder` (nil: the top), in the library's order.
    func assets(in folder: String?, of all: [MediaAsset]) -> [MediaAsset] {
        all.filter { place[$0.id] == folder }
    }

    /// The items in a folder and every folder inside it.
    func assets(under folder: String, of all: [MediaAsset]) -> [MediaAsset] {
        all.filter { place[$0.id].map { MediaFolder.contains(folder, $0) } == true }
    }

    func count(under folder: String) -> Int {
        place.values.filter { MediaFolder.contains(folder, $0) }.count
    }

    /// The folder's path in the panel: its linked folder's name and the folders inside, "B-roll / Drone".
    func label(_ folder: String) -> String {
        guard let r = root(of: folder) else { return URL(fileURLWithPath: folder).lastPathComponent }
        let rest = folder.dropFirst(r.path.count).split(separator: "/").map(String.init)
        return ([r.name] + rest).joined(separator: " / ")
    }

    /// The folders from the top down to `folder`, for the path above the items.
    func trail(_ folder: String) -> [String] {
        guard let r = root(of: folder) else { return [folder] }
        var out = [r.path]
        var p = r.path
        for part in folder.dropFirst(r.path.count).split(separator: "/") {
            p += "/" + part
            out.append(p)
        }
        return out
    }

    func name(_ folder: String) -> String { URL(fileURLWithPath: folder).lastPathComponent }
}
