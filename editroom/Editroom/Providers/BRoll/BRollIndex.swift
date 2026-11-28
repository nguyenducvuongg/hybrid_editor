import Foundation
import SQLite3

struct BRollSegment: Codable, Equatable, Sendable {
    var assetPath: String
    var assetName: String
    var startSec: Double
    var endSec: Double
    var description: String
    var tags: [String]
    var mood: String
}

struct BRollSearchHit: Codable, Equatable, Sendable {
    var assetPath: String
    var assetName: String
    var startSec: Double
    var endSec: Double
    var description: String
    var tags: [String]
    var mood: String
    var score: Double
}

enum BRollIndexError: LocalizedError {
    case openFailed(String)
    case sqlFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): "BRoll SQLite open failed: \(msg)"
        case .sqlFailed(let msg): "BRoll SQLite error: \(msg)"
        }
    }
}

/// Persistent SQLite3 FTS5 visual context index for local B-roll (`I5`, Tier 1).
final class BRollFTSIndex: @unchecked Sendable {
    static var defaultDatabaseURL: URL {
        HybridStorage.subdir("BRollIndex").appendingPathComponent("broll_fts5.sqlite")
    }

    private let lock = NSLock()
    private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = BRollFTSIndex.defaultDatabaseURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw BRollIndexError.openFailed(msg)
        }
        self.db = opened
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS broll_segments USING fts5(
            asset_path UNINDEXED,
            asset_name,
            start_sec UNINDEXED,
            end_sec UNINDEXED,
            description,
            tags,
            mood,
            normalized_text,
            tokenize='unicode61 remove_diacritics 0'
        );
        """)
    }

    deinit {
        lock.lock()
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        lock.unlock()
    }

    /// Normalizes Vietnamese text (including `đ`/`Đ` -> `d`) to lowercase ASCII-folded search tokens.
    static func normalizeVietnamese(_ input: String) -> String {
        let mapped = input
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
        return mapped
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
            .lowercased()
    }

    /// Sanitizes arbitrary user/agent queries into safe FTS5 MATCH tokens (`"tok"* OR ...`).
    static func safeFTSQuery(_ rawQuery: String) -> String? {
        let rawTokens = rawQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return nil }

        var seen = Set<String>()
        var clauses: [String] = []
        for token in rawTokens {
            for variant in [token, normalizeVietnamese(token)] where !variant.isEmpty {
                let sanitized = variant.replacingOccurrences(of: "\"", with: "")
                guard !sanitized.isEmpty, seen.insert(sanitized).inserted else { continue }
                clauses.append("\"\(sanitized)\"*")
            }
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " OR ")
    }

    func remove(assetPath: String) throws {
        try lock.withLock {
            try removeLocked(assetPath: assetPath)
        }
    }

    func upsert(_ segments: [BRollSegment]) throws {
        guard !segments.isEmpty else { return }
        try lock.withLock {
            guard let db else { throw BRollIndexError.openFailed("Database closed.") }
            try executeLocked("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let uniquePaths = Set(segments.map(\.assetPath))
                for path in uniquePaths {
                    try removeLocked(assetPath: path)
                }

                let sql = """
                INSERT INTO broll_segments (asset_path, asset_name, start_sec, end_sec, description, tags, mood, normalized_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                    throw BRollIndexError.sqlFailed(lastError(db))
                }
                defer { sqlite3_finalize(stmt) }

                for seg in segments {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    let joinedTags = seg.tags.joined(separator: ", ")
                    let normalized = Self.normalizeVietnamese("\(seg.assetName) \(seg.description) \(joinedTags) \(seg.mood)")

                    sqlite3_bind_text(stmt, 1, seg.assetPath, -1, sqliteTransient)
                    sqlite3_bind_text(stmt, 2, seg.assetName, -1, sqliteTransient)
                    sqlite3_bind_double(stmt, 3, seg.startSec)
                    sqlite3_bind_double(stmt, 4, seg.endSec)
                    sqlite3_bind_text(stmt, 5, seg.description, -1, sqliteTransient)
                    sqlite3_bind_text(stmt, 6, joinedTags, -1, sqliteTransient)
                    sqlite3_bind_text(stmt, 7, seg.mood, -1, sqliteTransient)
                    sqlite3_bind_text(stmt, 8, normalized, -1, sqliteTransient)

                    let stepRc = sqlite3_step(stmt)
                    guard stepRc == SQLITE_DONE else {
                        throw BRollIndexError.sqlFailed(lastError(db))
                    }
                }
                try executeLocked("COMMIT;")
            } catch {
                try? executeLocked("ROLLBACK;")
                throw error
            }
        }
    }

    func search(query: String, limit: Int = 10) throws -> [BRollSearchHit] {
        guard let ftsExpr = Self.safeFTSQuery(query) else { return [] }
        let clampedLimit = max(1, min(100, limit))
        return try lock.withLock {
            guard let db else { throw BRollIndexError.openFailed("Database closed.") }
            let sql = """
            SELECT asset_path, asset_name, start_sec, end_sec, description, tags, mood, bm25(broll_segments) AS rank_score
            FROM broll_segments
            WHERE broll_segments MATCH ?
            ORDER BY rank_score ASC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw BRollIndexError.sqlFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, ftsExpr, -1, sqliteTransient)
            sqlite3_bind_int(stmt, 2, Int32(clampedLimit))

            var hits: [BRollSearchHit] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let assetPath = columnString(stmt, 0)
                    let assetName = columnString(stmt, 1)
                    let startSec = sqlite3_column_double(stmt, 2)
                    let endSec = sqlite3_column_double(stmt, 3)
                    let desc = columnString(stmt, 4)
                    let rawTags = columnString(stmt, 5)
                    let mood = columnString(stmt, 6)
                    let bm25Score = sqlite3_column_double(stmt, 7)
                    let tags = rawTags
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let relevance = bm25Score < 0 ? -bm25Score : bm25Score
                    hits.append(BRollSearchHit(
                        assetPath: assetPath,
                        assetName: assetName,
                        startSec: startSec,
                        endSec: endSec,
                        description: desc,
                        tags: tags,
                        mood: mood,
                        score: relevance
                    ))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw BRollIndexError.sqlFailed(lastError(db))
                }
            }
            return hits
        }
    }

    func listRecent(limit: Int = 40) throws -> [BRollSearchHit] {
        let clampedLimit = max(1, min(200, limit))
        return try lock.withLock {
            guard let db else { throw BRollIndexError.openFailed("Database closed.") }
            let sql = """
            SELECT asset_path, asset_name, start_sec, end_sec, description, tags, mood
            FROM broll_segments
            ORDER BY rowid DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw BRollIndexError.sqlFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clampedLimit))

            var hits: [BRollSearchHit] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let rawTags = columnString(stmt, 5)
                    let tags = rawTags
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    hits.append(BRollSearchHit(
                        assetPath: columnString(stmt, 0),
                        assetName: columnString(stmt, 1),
                        startSec: sqlite3_column_double(stmt, 2),
                        endSec: sqlite3_column_double(stmt, 3),
                        description: columnString(stmt, 4),
                        tags: tags,
                        mood: columnString(stmt, 6),
                        score: 1.0
                    ))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw BRollIndexError.sqlFailed(lastError(db))
                }
            }
            return hits
        }
    }

    func stats() throws -> (files: Int, segments: Int) {
        try lock.withLock {
            guard let db else { throw BRollIndexError.openFailed("Database closed.") }
            let sql = "SELECT COUNT(DISTINCT asset_path), COUNT(*) FROM broll_segments;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw BRollIndexError.sqlFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw BRollIndexError.sqlFailed(lastError(db))
            }
            return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
    }

    func count() throws -> Int {
        try lock.withLock {
            guard let db else { throw BRollIndexError.openFailed("Database closed.") }
            let sql = "SELECT COUNT(*) FROM broll_segments;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw BRollIndexError.sqlFailed(lastError(db))
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw BRollIndexError.sqlFailed(lastError(db))
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func removeLocked(assetPath: String) throws {
        guard let db else { throw BRollIndexError.openFailed("Database closed.") }
        let sql = "DELETE FROM broll_segments WHERE asset_path = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw BRollIndexError.sqlFailed(lastError(db))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, assetPath, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw BRollIndexError.sqlFailed(lastError(db))
        }
    }

    private func execute(_ sql: String) throws {
        try lock.withLock { try executeLocked(sql) }
    }

    private func executeLocked(_ sql: String) throws {
        guard let db else { throw BRollIndexError.openFailed("Database closed.") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? lastError(db)
            if let errMsg { sqlite3_free(errMsg) }
            throw BRollIndexError.sqlFailed(msg)
        }
    }

    private func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    private func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
