import AVFoundation
import Foundation

/// Fetches one audio file an agent found online (music for the edit) into a "Downloaded Music" folder:
/// next to the project when it's saved, otherwise in Editroom's own folder. Only audio is kept, and
/// where each file came from, and its licence, is written down beside it.
enum MediaDownload {
    struct Failure: Error { let message: String }

    static let audioTypes = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
    static let maxBytes = 200 * 1024 * 1024

    static func folder(for project: URL?) -> URL {
        if let project {
            return project.deletingLastPathComponent().appendingPathComponent("Downloaded Music", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Editroom/Downloaded Music", isDirectory: true)
    }

    /// Downloads `url` into `folder`, checks it's playable audio, and notes its source and licence.
    static func fetch(_ url: URL, name: String?, sourcePage: String?, licence: String?, into folder: URL,
                      allowFiles: Bool = false) async throws -> URL {
        guard url.scheme == "https" || (allowFiles && url.scheme == "file") else {
            throw Failure(message: "Use an https link to the audio file.")
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Editroom", forHTTPHeaderField: "User-Agent")
        let (temp, response): (URL, URLResponse)
        do {
            (temp, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw Failure(message: "Couldn't download it: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "The site answered \(http.statusCode); that link didn't give a file.")
        }
        let mime = response.mimeType ?? ""
        if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json") {
            throw Failure(message: "That link is a web page, not an audio file. Find the direct link to the file (it usually ends in .mp3 or .wav).")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw Failure(message: "The download was empty.") }
        guard size <= maxBytes else { throw Failure(message: "That file is over 200 MB, too big for a music track.") }

        // The file's type: from the link, the server's name for it, or the kind of data.
        var ext = url.pathExtension.lowercased()
        if !audioTypes.contains(ext), let suggested = response.suggestedFilename {
            ext = (suggested as NSString).pathExtension.lowercased()
        }
        if !audioTypes.contains(ext) {
            ext = switch mime {
            case "audio/mpeg", "audio/mp3": "mp3"
            case "audio/mp4", "audio/x-m4a", "audio/aac": "m4a"
            case "audio/wav", "audio/x-wav", "audio/wave": "wav"
            case "audio/aiff", "audio/x-aiff": "aiff"
            case "audio/flac", "audio/x-flac": "flac"
            default: "mp3"
            }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = clean(name ?? response.suggestedFilename.map { ($0 as NSString).deletingPathExtension } ?? url.deletingPathExtension().lastPathComponent)
        var dest = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        try fm.copyItem(at: temp, to: dest)

        // Only keep it if it really is sound, at least a second long.
        let asset = AVURLAsset(url: dest)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let length = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard !tracks.isEmpty, length >= 1 else {
            try? fm.removeItem(at: dest)
            throw Failure(message: "That file isn't audio Editroom can play. Find the direct link to an .mp3 or .wav.")
        }

        // Where it came from, for the person (and anyone who asks later).
        let note = folder.appendingPathComponent("Sources.txt")
        let date = ISO8601DateFormatter().string(from: Date())
        let entry = """
        \(dest.lastPathComponent)
          Downloaded: \(date)
          File: \(url.absoluteString)
          Found on: \(sourcePage ?? "not given")
          Licence: \(licence ?? "not given")


        """
        if let handle = try? FileHandle(forWritingTo: note) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: note, atomically: true, encoding: .utf8)
        }
        return dest
    }

    private static func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let t = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Music" : String(t.prefix(80))
    }
}
