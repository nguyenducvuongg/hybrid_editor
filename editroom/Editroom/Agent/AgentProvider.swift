import Foundation

enum ChatRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case tool
    case system
}

struct ChatToolEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var toolName: String
    var summary: String
    var succeeded: Bool
    var timestamp: Date

    init(id: UUID = UUID(), toolName: String, summary: String, succeeded: Bool, timestamp: Date = Date()) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.succeeded = succeeded
        self.timestamp = timestamp
    }
}

struct ChatTurnLink: Codable, Equatable, Sendable {
    var turnId: String
    var summary: String
    var revisionAfterCommit: UInt64
    var affectedClipIds: [UUID]
    var reverted: Bool
}

struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var role: ChatRole
    var text: String
    var skillSlugs: [String]
    var toolEvents: [ChatToolEvent]
    var turnLink: ChatTurnLink?
    var timestamp: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, skillSlugs: [String] = [],
         toolEvents: [ChatToolEvent] = [], turnLink: ChatTurnLink? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.skillSlugs = skillSlugs
        self.toolEvents = toolEvents
        self.turnLink = turnLink
        self.timestamp = timestamp
    }
}

struct ChatThread: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var projectKey: String
    var title: String
    var providerId: String
    var modelId: String
    var messages: [ChatMessage]
    var updatedAt: Date

    init(id: UUID = UUID(), projectKey: String, title: String, providerId: String, modelId: String,
         messages: [ChatMessage] = [], updatedAt: Date = Date()) {
        self.id = id
        self.projectKey = projectKey
        self.title = title
        self.providerId = providerId
        self.modelId = modelId
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

enum AgentProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCLI
    case codexCLI
    case geminiAPI
    case openAICompatible
    case ollama
    case mock

    var id: String { rawValue }
}

enum AgentStreamEvent: Sendable {
    case status(String)
    case textDelta(String)
    case toolStarted(String)
    case toolFinished(String, Bool)
}

struct AgentRequest: @unchecked Sendable {
    var thread: ChatThread
    var userPrompt: String
    var systemPrompt: String
    var tools: [[String: Any]]
    var modelId: String
}

enum AgentProviderError: Error, LocalizedError {
    case missingCredentials(String)
    case httpError(Int, String)
    case invalidResponse(String)
    case toolLoopExceeded
    case cliUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let msg), .invalidResponse(let msg), .cliUnavailable(let msg):
            return msg
        case .httpError(let code, let body):
            return "Provider HTTP \(code): \(body.prefix(240))"
        case .toolLoopExceeded:
            return "Agent exceeded maximum tool-calling iterations."
        }
    }
}

protocol AgentProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var kind: AgentProviderKind { get }

    func runTurn(
        _ request: AgentRequest,
        toolExecutor: @escaping @Sendable (String, [String: Any]) async throws -> [[String: Any]],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> String
}

enum AgentToolFormatting {
    static func stringOutput(from content: [[String: Any]]) -> String {
        let texts = content.compactMap { $0["text"] as? String }
        if !texts.isEmpty { return texts.joined(separator: "\n") }
        let imageCount = content.filter { ($0["type"] as? String) == "image" }.count
        if imageCount > 0 { return "{\"image_count\": \(imageCount)}" }
        return "{}"
    }
}

/// Calls any OpenAI-compatible `/chat/completions` API (OpenAI, Ollama, LM Studio, or custom mock endpoints).
final class OpenAICompatibleHTTPProvider: AgentProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let kind: AgentProviderKind
    let endpointURL: URL
    let defaultModel: String
    let requiresAPIKey: Bool
    private let apiKeyLookup: @Sendable () -> String?

    init(
        id: String = "openai-compatible",
        displayName: String = "OpenAI-Compatible",
        kind: AgentProviderKind = .openAICompatible,
        endpointURL: URL,
        defaultModel: String = "gpt-4o",
        requiresAPIKey: Bool = false,
        apiKeyLookup: @escaping @Sendable () -> String? = { try? AppSecrets.shared.get(.openAIAPIKey) }
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.endpointURL = endpointURL
        self.defaultModel = defaultModel
        self.requiresAPIKey = requiresAPIKey
        self.apiKeyLookup = apiKeyLookup
    }

    static func ollama(model: String = "qwen2.5:14b") -> OpenAICompatibleHTTPProvider {
        let raw = (try? AppSecrets.shared.get(.ollamaBaseURL))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (raw?.isEmpty == false ? raw! : "http://127.0.0.1:11434/v1")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(base)/chat/completions") ?? URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
        return OpenAICompatibleHTTPProvider(
            id: "ollama",
            displayName: "Ollama (Local)",
            kind: .ollama,
            endpointURL: url,
            defaultModel: model,
            requiresAPIKey: false,
            apiKeyLookup: { nil }
        )
    }

    func runTurn(
        _ request: AgentRequest,
        toolExecutor: @escaping @Sendable (String, [String: Any]) async throws -> [[String: Any]],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> String {
        let key = apiKeyLookup()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresAPIKey && (key?.isEmpty ?? true) {
            throw AgentProviderError.missingCredentials("Missing API key for \(displayName).")
        }

        let modelName = request.modelId.isEmpty ? defaultModel : request.modelId
        let openAITools: [[String: Any]] = request.tools.compactMap { def in
            guard let name = def["name"] as? String else { return nil }
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": (def["description"] as? String) ?? "",
                    "parameters": (def["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [:]],
                ],
            ]
        }

        var messages: [[String: Any]] = []
        if !request.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": request.systemPrompt])
        }
        for msg in request.thread.messages where msg.role == .user || msg.role == .assistant {
            messages.append(["role": msg.role.rawValue, "content": msg.text])
        }
        messages.append(["role": "user", "content": request.userPrompt])

        for _ in 0..<12 {
            onEvent(.status("Thinking (\(displayName))…"))
            var body: [String: Any] = [
                "model": modelName,
                "messages": messages,
            ]
            if !openAITools.isEmpty {
                body["tools"] = openAITools
            }

            var req = URLRequest(url: endpointURL)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                throw AgentProviderError.httpError(code, String(data: data, encoding: .utf8) ?? "")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                throw AgentProviderError.invalidResponse("Malformed OpenAI-compatible response.")
            }

            let contentText = (message["content"] as? String) ?? ""
            let toolCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
            if toolCalls.isEmpty {
                if !contentText.isEmpty { onEvent(.textDelta(contentText)) }
                return contentText
            }

            messages.append(message)
            for tc in toolCalls {
                let callId = (tc["id"] as? String) ?? UUID().uuidString
                let fn = (tc["function"] as? [String: Any]) ?? [:]
                let toolName = (fn["name"] as? String) ?? ""
                let argRaw = (fn["arguments"] as? String) ?? "{}"
                let parsedArgs = (argRaw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]

                onEvent(.toolStarted(toolName))
                do {
                    let result = try await toolExecutor(toolName, parsedArgs)
                    onEvent(.toolFinished(toolName, true))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": AgentToolFormatting.stringOutput(from: result),
                    ])
                } catch {
                    onEvent(.toolFinished(toolName, false))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": "{\"error\": \"\(error.localizedDescription)\"}",
                    ])
                }
            }
        }
        throw AgentProviderError.toolLoopExceeded
    }
}

/// Calls the Google Gemini `:generateContent` API with tool function declarations.
final class GeminiHTTPProvider: AgentProvider, @unchecked Sendable {
    let id = "gemini"
    let displayName = "Gemini API"
    let kind: AgentProviderKind = .geminiAPI
    let baseURL: String
    private let apiKeyLookup: @Sendable () -> String?

    init(
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta/models",
        apiKeyLookup: @escaping @Sendable () -> String? = { try? AppSecrets.shared.get(.geminiAPIKey) }
    ) {
        self.baseURL = baseURL
        self.apiKeyLookup = apiKeyLookup
    }

    func runTurn(
        _ request: AgentRequest,
        toolExecutor: @escaping @Sendable (String, [String: Any]) async throws -> [[String: Any]],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> String {
        guard let apiKey = apiKeyLookup()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw AgentProviderError.missingCredentials("Gemini API key is missing in Settings.")
        }

        let modelName = request.modelId.isEmpty ? "gemini-2.5-flash" : request.modelId
        guard let url = URL(string: "\(baseURL)/\(modelName):generateContent") else {
            throw AgentProviderError.invalidResponse("Invalid Gemini model URL.")
        }

        let decls: [[String: Any]] = request.tools.compactMap { def in
            guard let name = def["name"] as? String else { return nil }
            return [
                "name": name,
                "description": (def["description"] as? String) ?? "",
                "parameters": (def["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [:]],
            ]
        }

        var contents: [[String: Any]] = []
        for msg in request.thread.messages where msg.role == .user || msg.role == .assistant {
            let role = msg.role == .assistant ? "model" : "user"
            contents.append(["role": role, "parts": [["text": msg.text]]])
        }
        contents.append(["role": "user", "parts": [["text": request.userPrompt]]])

        for _ in 0..<12 {
            onEvent(.status("Thinking (Gemini)…"))
            var body: [String: Any] = ["contents": contents]
            if !request.systemPrompt.isEmpty {
                body["systemInstruction"] = ["parts": [["text": request.systemPrompt]]]
            }
            if !decls.isEmpty {
                body["tools"] = [["functionDeclarations": decls]]
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                throw AgentProviderError.httpError(code, String(data: data, encoding: .utf8) ?? "")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = root["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw AgentProviderError.invalidResponse("Malformed Gemini response.")
            }

            contents.append(content)
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            if calls.isEmpty {
                let reply = parts.compactMap { $0["text"] as? String }.joined()
                if !reply.isEmpty { onEvent(.textDelta(reply)) }
                return reply
            }

            var responseParts: [[String: Any]] = []
            for call in calls {
                let toolName = (call["name"] as? String) ?? ""
                let args = (call["args"] as? [String: Any]) ?? [:]
                onEvent(.toolStarted(toolName))
                do {
                    let result = try await toolExecutor(toolName, args)
                    onEvent(.toolFinished(toolName, true))
                    responseParts.append([
                        "functionResponse": [
                            "name": toolName,
                            "response": ["result": AgentToolFormatting.stringOutput(from: result)],
                        ],
                    ])
                } catch {
                    onEvent(.toolFinished(toolName, false))
                    responseParts.append([
                        "functionResponse": [
                            "name": toolName,
                            "response": ["error": error.localizedDescription],
                        ],
                    ])
                }
            }
            contents.append(["role": "user", "parts": responseParts])
        }
        throw AgentProviderError.toolLoopExceeded
    }
}

/// Runs local CLI agent binaries (`claude` / `codex`) off `@MainActor` (`I6`).
final class CLIProcessAgentProvider: AgentProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let kind: AgentProviderKind
    private let cliPathProvider: @Sendable () async -> URL?

    init(kind: AgentProviderKind, cliPathProvider: @escaping @Sendable () async -> URL?) {
        self.id = kind.rawValue
        self.displayName = kind == .claudeCLI ? "Claude Code CLI" : "Codex CLI"
        self.kind = kind
        self.cliPathProvider = cliPathProvider
    }

    func runTurn(
        _ request: AgentRequest,
        toolExecutor: @escaping @Sendable (String, [String: Any]) async throws -> [[String: Any]],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> String {
        guard let cliURL = await cliPathProvider() else {
            throw AgentProviderError.cliUnavailable("\(displayName) executable was not found on this Mac.")
        }
        onEvent(.status("Running \(displayName)…"))

        let promptPayload = [request.systemPrompt, request.userPrompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let args = kind == .claudeCLI
            ? ["-p", promptPayload, "--output-format", "text"]
            : ["exec", promptPayload]

        let (status, stdout): (Int32, String) = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = cliURL
                p.arguments = args
                p.currentDirectoryURL = HybridStorage.subdir("Magic")
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
        guard status == 0 else {
            throw AgentProviderError.cliUnavailable("\(displayName) exited \(status): \(stdout.prefix(240))")
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onEvent(.textDelta(trimmed)) }
        return trimmed
    }
}
