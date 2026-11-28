import Foundation

enum LeaseRole: String, Codable, Equatable {
    case window
    case liveAgent
    case headlessAgent
}

struct SessionLease: Codable, Equatable {
    var sessionId: String
    var clientPid: Int32
    var role: LeaseRole
    var acquiredAtMs: UInt64
    var lastHeartbeatAtMs: UInt64
    var gracePeriodMs: UInt64
    var activeTurnId: String?
}

struct RecoveredLease: Equatable {
    var sessionId: String
    var clientPid: Int32
    var uncommittedTurnId: String?
}

enum LeaseError: Error, Equatable, LocalizedError {
    case busy(holderSessionId: String, clientPid: Int32)
    case notOwner
    case invalid(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .busy(let holder, let pid):
            return "Session lease held by \(holder) (pid \(pid))."
        case .notOwner:
            return "Caller does not own the active session lease."
        case .invalid(let message):
            return message
        case .io(let message):
            return message
        }
    }
}

/// Coordinates single-writer `SessionLease` ownership with PID + grace-period crash recovery (`I2`, `P8`).
final class LeaseManager: @unchecked Sendable {
    static let minGraceMs: UInt64 = 5_000
    static let maxGraceMs: UInt64 = 10_000
    static let defaultGraceMs: UInt64 = 8_000

    let leaseDir: URL
    let leaseURL: URL
    let gracePeriodMs: UInt64

    private let lock = NSLock()
    private var currentLease: SessionLease?

    init(leaseDir: URL = HybridStorage.leasesDir, projectKey: String, gracePeriodMs: UInt64 = defaultGraceMs) {
        self.leaseDir = leaseDir
        self.leaseURL = leaseDir.appendingPathComponent("\(HybridStorage.sha256Hex16(projectKey)).lease.json")
        self.gracePeriodMs = min(max(gracePeriodMs, Self.minGraceMs), Self.maxGraceMs)
        reloadFromDiskLocked()
    }

    static func nowUnixMs() -> UInt64 {
        UInt64(max(0, (Date().timeIntervalSince1970 * 1000).rounded()))
    }

    static func pidIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let res = Darwin.kill(pid, 0)
        if res == 0 { return true }
        return errno == EPERM
    }

    var current: SessionLease? {
        lock.lock()
        defer { lock.unlock() }
        return currentLease
    }

    @discardableResult
    func acquire(sessionId: String, clientPid: Int32, role: LeaseRole,
                 nowMs: UInt64 = nowUnixMs()) throws -> (SessionLease, RecoveredLease?) {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LeaseError.invalid("session_id must not be empty") }
        guard clientPid > 0 else { throw LeaseError.invalid("client_pid must be > 0") }

        lock.lock()
        defer { lock.unlock() }
        reloadFromDiskLocked()
        let recovered = reclaimIfExpiredLocked(nowMs: nowMs)

        if let existing = currentLease {
            if existing.sessionId == trimmed {
                var refreshed = existing
                refreshed.clientPid = clientPid
                refreshed.lastHeartbeatAtMs = nowMs
                try persistLocked(refreshed)
                currentLease = refreshed
                return (refreshed, recovered)
            }
            throw LeaseError.busy(holderSessionId: existing.sessionId, clientPid: existing.clientPid)
        }

        let lease = SessionLease(
            sessionId: trimmed,
            clientPid: clientPid,
            role: role,
            acquiredAtMs: nowMs,
            lastHeartbeatAtMs: nowMs,
            gracePeriodMs: gracePeriodMs,
            activeTurnId: nil
        )
        try persistLocked(lease)
        currentLease = lease
        return (lease, recovered)
    }

    @discardableResult
    func heartbeat(sessionId: String, clientPid: Int32, nowMs: UInt64 = nowUnixMs()) throws -> SessionLease {
        lock.lock()
        defer { lock.unlock() }
        reloadFromDiskLocked()
        guard var existing = currentLease else { throw LeaseError.notOwner }
        if existing.sessionId != sessionId {
            throw LeaseError.busy(holderSessionId: existing.sessionId, clientPid: existing.clientPid)
        }
        if isExpired(existing, nowMs: nowMs) {
            clearDiskLocked()
            currentLease = nil
            throw LeaseError.notOwner
        }
        existing.clientPid = clientPid
        existing.lastHeartbeatAtMs = nowMs
        try persistLocked(existing)
        currentLease = existing
        return existing
    }

    func setActiveTurn(sessionId: String, turnId: String?, nowMs: UInt64 = nowUnixMs()) throws {
        lock.lock()
        defer { lock.unlock() }
        reloadFromDiskLocked()
        guard var existing = currentLease, existing.sessionId == sessionId else {
            throw LeaseError.notOwner
        }
        existing.activeTurnId = turnId
        existing.lastHeartbeatAtMs = nowMs
        try persistLocked(existing)
        currentLease = existing
    }

    @discardableResult
    func checkWriter(sessionId: String?, nowMs: UInt64 = nowUnixMs()) throws -> RecoveredLease? {
        lock.lock()
        defer { lock.unlock() }
        reloadFromDiskLocked()
        let recovered = reclaimIfExpiredLocked(nowMs: nowMs)
        switch (currentLease, sessionId) {
        case (nil, _):
            return recovered
        case (let held?, let caller?) where held.sessionId == caller:
            return recovered
        case (let held?, _):
            throw LeaseError.busy(holderSessionId: held.sessionId, clientPid: held.clientPid)
        }
    }

    func release(sessionId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        reloadFromDiskLocked()
        guard let existing = currentLease else { return }
        guard existing.sessionId == sessionId else { throw LeaseError.notOwner }
        currentLease = nil
        clearDiskLocked()
    }

    @discardableResult
    func reclaimIfExpired(nowMs: UInt64 = nowUnixMs()) -> RecoveredLease? {
        lock.lock()
        defer { lock.unlock() }
        return reclaimIfExpiredLocked(nowMs: nowMs)
    }

    private func reclaimIfExpiredLocked(nowMs: UInt64) -> RecoveredLease? {
        reloadFromDiskLocked()
        guard let existing = currentLease, isExpired(existing, nowMs: nowMs) else { return nil }
        let rec = RecoveredLease(
            sessionId: existing.sessionId,
            clientPid: existing.clientPid,
            uncommittedTurnId: existing.activeTurnId
        )
        currentLease = nil
        clearDiskLocked()
        return rec
    }

    private func isExpired(_ lease: SessionLease, nowMs: UInt64) -> Bool {
        if !Self.pidIsAlive(lease.clientPid) { return true }
        return nowMs >= lease.lastHeartbeatAtMs && (nowMs - lease.lastHeartbeatAtMs) >= lease.gracePeriodMs
    }

    private func reloadFromDiskLocked() {
        if let data = try? Data(contentsOf: leaseURL),
           let parsed = try? JSONDecoder().decode(SessionLease.self, from: data) {
            currentLease = parsed
        } else if !FileManager.default.fileExists(atPath: leaseURL.path) {
            currentLease = nil
        }
    }

    private func persistLocked(_ lease: SessionLease) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(lease)
            try HybridStorage.writeAtomicVerified(data, to: leaseURL, posixPermissions: 0o600)
        } catch {
            throw LeaseError.io(error.localizedDescription)
        }
    }

    private func clearDiskLocked() {
        try? FileManager.default.removeItem(at: leaseURL)
    }
}
