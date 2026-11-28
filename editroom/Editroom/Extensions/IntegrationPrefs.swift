import Foundation

enum ComfyTunnelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cloudflare
    case tailscale
    case ssh

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .tailscale: "Tailscale"
        case .ssh: "SSH Tunnel"
        }
    }
}

/// Non-secret ComfyUI Colab connection preferences (`UserDefaults`, paired with Keychain tokens in `AppSecrets`).
struct ComfyConnectionPrefs: Codable, Equatable, Sendable {
    var mode: ComfyTunnelMode = .cloudflare
    var endpointURL: String = "http://127.0.0.1:8188"
    var sshCommand: String = ""
    var localPort: Int = 8188
    var defaultImageWorkflow: String = ""
    var defaultVideoWorkflow: String = ""
    var defaultAudioWorkflow: String = ""

    private static let defaultsKey = "comfyConnectionPrefs"

    static func load(defaults: UserDefaults = .standard) -> ComfyConnectionPrefs {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ComfyConnectionPrefs.self, from: data) else {
            return ComfyConnectionPrefs()
        }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Tests connectivity to a ComfyUI endpoint (`GET /system_stats`) off `@MainActor`.
    static func testEndpoint(_ rawURL: String) async -> (ok: Bool, message: String) {
        let cleaned = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleaned)/system_stats"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return (false, "Invalid http/https ComfyUI endpoint URL.")
        }

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "GET"
        if let token = try? AppSecrets.shared.get(.comfyAuthToken), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let cfId = try? AppSecrets.shared.get(.comfyCFClientId), !cfId.isEmpty,
           let cfSecret = try? AppSecrets.shared.get(.comfyCFClientSecret), !cfSecret.isEmpty {
            req.setValue(cfId, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(cfSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                return (false, "HTTP \(code) from ComfyUI endpoint.")
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = obj["devices"] as? [[String: Any]],
               let firstName = devices.first?["name"] as? String {
                return (true, "Connected (\(firstName))")
            }
            return (true, "Connected (HTTP \(code))")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

/// Non-secret AI Chat provider defaults (`UserDefaults`).
struct ChatProviderPrefs: Codable, Equatable, Sendable {
    var selectedProvider: AgentProviderKind = .geminiAPI
    var geminiModel: String = "gemini-2.5-flash"
    var openAIModel: String = "gpt-4o"
    var ollamaModel: String = "qwen2.5:14b"
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var ollamaBaseURL: String = "http://127.0.0.1:11434/v1"

    private static let defaultsKey = "chatProviderPrefs"

    static func load(defaults: UserDefaults = .standard) -> ChatProviderPrefs {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ChatProviderPrefs.self, from: data) else {
            return ChatProviderPrefs()
        }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func activeModelId() -> String {
        switch selectedProvider {
        case .geminiAPI: geminiModel
        case .openAICompatible: openAIModel
        case .ollama: ollamaModel
        case .claudeCLI: "claude-code"
        case .codexCLI: "codex"
        case .mock: "mock"
        }
    }
}
