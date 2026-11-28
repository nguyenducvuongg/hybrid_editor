import Foundation
import Security

/// Canonical secret identifiers stored outside `.room` project files.
enum SecretKey: String, CaseIterable, Codable {
    case geminiAPIKey = "gemini_api_key"
    case openAIAPIKey = "openai_api_key"
    case openAIBaseURL = "openai_base_url"
    case ollamaBaseURL = "ollama_base_url"
    case pexelsAPIKey = "pexels_api_key"
    case pixabayAPIKey = "pixabay_api_key"
    case comfyAuthToken = "comfy_auth_token"
    case comfyCFClientId = "comfy_cf_client_id"
    case comfyCFClientSecret = "comfy_cf_client_secret"
}

enum SecretStoreError: Error, LocalizedError, Equatable {
    case keychainStatus(OSStatus)
    case encodingFailed
    case io(String)

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(msg)"
            }
            return "Keychain error (\(status))"
        case .encodingFailed:
            return "Failed to UTF-8 encode secret value."
        case .io(let message):
            return message
        }
    }
}

protocol SecretStore: Sendable {
    func set(_ value: String, forKey key: String) throws
    func get(forKey key: String) throws -> String?
    func delete(forKey key: String) throws
}

extension SecretStore {
    func set(_ value: String, for key: SecretKey) throws { try set(value, forKey: key.rawValue) }
    func get(_ key: SecretKey) throws -> String? { try get(forKey: key.rawValue) }
    func delete(_ key: SecretKey) throws { try delete(forKey: key.rawValue) }
}

/// macOS Keychain-backed credential store used during interactive runs.
final class KeychainStore: SecretStore, @unchecked Sendable {
    let service: String

    init(service: String = "local.hybrideditvid.Editroom") {
        self.service = service
    }

    func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw SecretStoreError.encodingFailed }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw SecretStoreError.keychainStatus(status) }
        } else if existing == errSecItemNotFound {
            var attrs = query
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attrs as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError.keychainStatus(status) }
        } else {
            throw SecretStoreError.keychainStatus(existing)
        }
    }

    func get(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychainStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainStatus(status)
        }
    }
}

/// Isolated `0o600` file-backed secret store used when `HYBRID_EDIT_DATA_DIR` / test override is active (`I5`).
final class FileSecretStore: SecretStore, @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? HybridStorage.root.appendingPathComponent("secrets.json")
    }

    func set(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var map = loadLocked()
        map[key] = value
        try saveLocked(map)
    }

    func get(forKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[key]
    }

    func delete(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var map = loadLocked()
        map.removeValue(forKey: key)
        try saveLocked(map)
    }

    private func loadLocked() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func saveLocked(_ map: [String: String]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(map)
            try HybridStorage.writeAtomicVerified(data, to: fileURL, posixPermissions: 0o600)
        } catch {
            throw SecretStoreError.io(error.localizedDescription)
        }
    }
}

/// Global secret accessor routing isolated test runs away from the user Keychain.
enum AppSecrets {
    nonisolated(unsafe) static var overrideStoreForTests: (any SecretStore)?

    static var shared: any SecretStore {
        if let overrideStoreForTests { return overrideStoreForTests }
        return HybridStorage.overrideRoot != nil ? FileSecretStore() : KeychainStore()
    }
}
