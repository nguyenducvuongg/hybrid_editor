import CryptoKit
import Foundation

/// Centralized external data directory (`I5`) and APFS UTF-8 safe derived artifact helpers (`I4`, `P7`).
enum HybridStorage {
    static let envKey = "HYBRID_EDIT_DATA_DIR"
    static let defaultFolderName = "hybrid_edit_vid"

    /// Optional test-only root override (used by `--hybrid-test`).
    nonisolated(unsafe) static var overrideRootForTests: URL?

    /// Returns the isolated override root when `HYBRID_EDIT_DATA_DIR` or test override is active.
    static var overrideRoot: URL? {
        if let testRoot = overrideRootForTests { return testRoot }
        guard let raw = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Root directory for all application caches, recovery files, downloads, and leases (`I5`).
    static var root: URL {
        let base = overrideRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Creates and returns a subdirectory inside `HybridStorage.root`.
    static func subdir(_ name: String) -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var leasesDir: URL { subdir("leases") }

    /// First 16 lowercase hex characters of SHA-256 over `input`.
    static func sha256Hex16(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Produces a deterministic, UTF-8 byte-bounded cache filename stem (`<= maxPrefixBytes + 17` bytes) (`P7`).
    /// Never splits multi-byte UTF-8 characters and incorporates path, size, mtime, and inode.
    static func derivedCacheStem(for source: URL, maxPrefixBytes: Int = 120) -> String {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let stamp = "\(source.standardizedFileURL.path)|\(size)|\(mtime)|\(inode)"
        let hash = sha256Hex16(stamp)

        let rawBase = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = truncateUTF8(rawBase, maxBytes: maxPrefixBytes)
        return prefix.isEmpty ? hash : "\(prefix)-\(hash)"
    }

    /// Truncates `text` strictly on valid `Character` boundaries so `result.utf8.count <= maxBytes`.
    static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if text.utf8.count <= maxBytes { return text }
        var out = ""
        var bytes = 0
        for ch in text {
            let len = String(ch).utf8.count
            if bytes + len > maxBytes { break }
            out.append(ch)
            bytes += len
        }
        return out
    }

    /// Writes `data` atomically via sibling `.tmp-<uuid>`, optionally sets POSIX permissions (`0o600`),
    /// renames into `url`, and verifies destination existence and exact byte size (`P7`).
    static func writeAtomicVerified(_ data: Data, to url: URL, posixPermissions: Int? = nil) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [])
        if let posixPermissions {
            try fm.setAttributes([.posixPermissions: posixPermissions], ofItemAtPath: tmp.path)
        }
        if Darwin.rename(tmp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Failed to atomically rename \(url.lastPathComponent): \(String(cString: strerror(code)))",
            ])
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let actualSize = (attrs[.size] as? NSNumber)?.intValue ?? -1
        guard fm.fileExists(atPath: url.path), actualSize == data.count else {
            throw NSError(domain: "hybrid_edit_vid.AppStorage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Verified write mismatch for \(url.lastPathComponent): expected \(data.count) bytes, got \(actualSize).",
            ])
        }
    }
}
