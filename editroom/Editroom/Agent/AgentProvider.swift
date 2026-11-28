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
    case antigravity
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
    var usesExternalMCP: Bool { get }

    func runTurn(
        _ request: AgentRequest,
        toolExecutor: @escaping @Sendable (String, [String: Any]) async throws -> [[String: Any]],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> String
}

extension AgentProvider {
    var usesExternalMCP: Bool { false }
}

struct ToolImageAttachment: Equatable, Sendable {
    var mimeType: String
    var base64Data: String
}

struct FormattedToolOutput: Equatable, Sendable {
    var text: String
    var images: [ToolImageAttachment]
}

enum AgentToolFormatting {
    static func parse(from content: [[String: Any]]) -> FormattedToolOutput {
        let texts = content.compactMap { part -> String? in
            guard (part["type"] as? String) != "image" else { return nil }
            return part["text"] as? String
        }
        let images = content.compactMap { part -> ToolImageAttachment? in
            guard (part["type"] as? String) == "image",
                  let data = part["data"] as? String, !data.isEmpty else { return nil }
            let mime = (part["mimeType"] as? String) ?? "image/jpeg"
            return ToolImageAttachment(mimeType: mime, base64Data: data)
        }
        let text: String
        if !texts.isEmpty {
            text = texts.joined(separator: "\n")
        } else if !images.isEmpty {
            text = "{\"image_count\": \(images.count)}"
        } else {
            text = "{}"
        }
        return FormattedToolOutput(text: text, images: images)
    }

    static func stringOutput(from content: [[String: Any]]) -> String {
        parse(from: content).text
    }

    static func jsonError(_ message: String) -> String {
        let payload = ["error": SecretRedactor.redact(message)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Tool execution failed\"}"
        }
        return str
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
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                throw AgentProviderError.httpError(code, SecretRedactor.redact(rawBody))
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
            var stepImages: [ToolImageAttachment] = []
            for tc in toolCalls {
                try Task.checkCancellation()
                let callId = (tc["id"] as? String) ?? UUID().uuidString
                let fn = (tc["function"] as? [String: Any]) ?? [:]
                let toolName = (fn["name"] as? String) ?? ""
                let argRaw = (fn["arguments"] as? String) ?? "{}"
                let parsedArgs = (argRaw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]

                onEvent(.toolStarted(toolName))
                do {
                    let result = try await toolExecutor(toolName, parsedArgs)
                    let parsed = AgentToolFormatting.parse(from: result)
                    stepImages.append(contentsOf: parsed.images)
                    onEvent(.toolFinished(toolName, true))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": parsed.text,
                    ])
                } catch {
                    onEvent(.toolFinished(toolName, false))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": AgentToolFormatting.jsonError(error.localizedDescription),
                    ])
                }
            }
            if !stepImages.isEmpty {
                var blocks: [[String: Any]] = [
                    ["type": "text", "text": "Attached visual frames from the previous tool responses:"]
                ]
                for img in stepImages {
                    blocks.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64Data)"],
                    ])
                }
                messages.append(["role": "user", "content": blocks])
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

    /// Filters MCP JSON Schemas down to the subset accepted by Gemini `:generateContent` `Schema` objects.
    static func sanitizeGeminiSchema(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let typeStr = raw["type"] as? String {
            out["type"] = typeStr.lowercased()
        } else if let types = raw["type"] as? [String] {
            let nonNull = types.map { $0.lowercased() }.filter { $0 != "null" }
            out["type"] = nonNull.first ?? "string"
            if types.contains(where: { $0.lowercased() == "null" }) {
                out["nullable"] = true
            }
        }
        if let desc = raw["description"] as? String, !desc.isEmpty {
            out["description"] = desc
        }
        if let enums = raw["enum"] as? [String], !enums.isEmpty {
            out["enum"] = enums
        }
        if let fmt = raw["format"] as? String, !fmt.isEmpty {
            out["format"] = fmt
        }
        if let nullable = raw["nullable"] as? Bool {
            out["nullable"] = nullable
        }
        if let items = raw["items"] as? [String: Any] {
            var sanitizedItems = sanitizeGeminiSchema(items)
            if sanitizedItems["type"] == nil { sanitizedItems["type"] = "string" }
            out["items"] = sanitizedItems
        }
        if let props = raw["properties"] as? [String: Any] {
            var cleanProps: [String: Any] = [:]
            for (k, v) in props {
                if let sub = v as? [String: Any] {
                    cleanProps[k] = sanitizeGeminiSchema(sub)
                }
            }
            if !cleanProps.isEmpty {
                out["properties"] = cleanProps
            }
        }
        if let req = raw["required"] as? [String], !req.isEmpty {
            if let props = out["properties"] as? [String: Any] {
                let validReq = req.filter { props[$0] != nil }
                if !validReq.isEmpty { out["required"] = validReq }
            }
        }
        if out["type"] == nil {
            out["type"] = (out["properties"] != nil) ? "object" : "string"
        }
        return out
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
            let rawSchema = (def["inputSchema"] as? [String: Any]) ?? ["type": "object"]
            return [
                "name": name,
                "description": (def["description"] as? String) ?? "",
                "parameters": Self.sanitizeGeminiSchema(rawSchema),
            ]
        }

        var contents: [[String: Any]] = []
        for msg in request.thread.messages where msg.role == .user || msg.role == .assistant {
            let role = msg.role == .assistant ? "model" : "user"
            contents.append(["role": role, "parts": [["text": msg.text]]])
        }
        contents.append(["role": "user", "parts": [["text": request.userPrompt]]])

        for _ in 0..<12 {
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                throw AgentProviderError.httpError(code, SecretRedactor.redact(rawBody))
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
            var stepImages: [ToolImageAttachment] = []
            for call in calls {
                try Task.checkCancellation()
                let toolName = (call["name"] as? String) ?? ""
                let args = (call["args"] as? [String: Any]) ?? [:]
                onEvent(.toolStarted(toolName))
                do {
                    let result = try await toolExecutor(toolName, args)
                    let parsed = AgentToolFormatting.parse(from: result)
                    stepImages.append(contentsOf: parsed.images)
                    onEvent(.toolFinished(toolName, true))
                    responseParts.append([
                        "functionResponse": [
                            "name": toolName,
                            "response": ["result": parsed.text],
                        ],
                    ])
                } catch {
                    onEvent(.toolFinished(toolName, false))
                    responseParts.append([
                        "functionResponse": [
                            "name": toolName,
                            "response": ["error": SecretRedactor.redact(error.localizedDescription)],
                        ],
                    ])
                }
            }
            for img in stepImages {
                responseParts.append([
                    "inlineData": [
                        "mimeType": img.mimeType,
                        "data": img.base64Data,
                    ],
                ])
            }
            contents.append(["role": "user", "parts": responseParts])
        }
        throw AgentProviderError.toolLoopExceeded
    }
}

/// Runs local CLI agent binaries (`agy` Antigravity 2.0 / `claude` / `codex`) off `@MainActor` (`I6`).
final class CLIProcessAgentProvider: AgentProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let kind: AgentProviderKind
    let usesExternalMCP: Bool = true
    private let cliPathProvider: @Sendable () async -> URL?
    private let mcpEndpoint: String

    init(
        kind: AgentProviderKind,
        mcpEndpoint: String? = nil,
        cliPathProvider: @escaping @Sendable () async -> URL?
    ) {
        self.id = kind.rawValue
        switch kind {
        case .antigravity: self.displayName = "Antigravity 2.0"
        case .claudeCLI: self.displayName = "Claude Code CLI"
        case .codexCLI: self.displayName = "Codex CLI"
        default: self.displayName = kind.rawValue
        }
        self.kind = kind
        self.mcpEndpoint = mcpEndpoint ?? MCPServer.endpoint
        self.cliPathProvider = cliPathProvider
    }

    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?
        private var buf = Data()

        func setProcess(_ p: Process?) {
            lock.lock(); proc = p; lock.unlock()
        }

        func terminate() {
            lock.lock(); let p = proc; lock.unlock()
            p?.terminate()
        }

        func append(_ data: Data) {
            lock.lock(); buf.append(data); lock.unlock()
        }

        func text() -> String {
            lock.lock(); let d = buf; lock.unlock()
            return String(data: d, encoding: .utf8) ?? ""
        }
    }

    func runTurn(
        _ request: AgentRequest,
        toolExecutor: @escaping @Sendable (String, [String: Any]) async throws -> [[String: Any]],
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> String {
        guard let cliURL = await cliPathProvider() else {
            if kind == .antigravity {
                throw AgentProviderError.cliUnavailable(
                    "Antigravity 2.0 CLI (`agy`) was not found. Install Antigravity or connect in Settings > AI & MCP."
                )
            }
            throw AgentProviderError.cliUnavailable("\(displayName) executable was not found on this Mac.")
        }
        onEvent(.status("Running \(displayName)…"))

        let historyBlock = request.thread.messages.suffix(8).compactMap { msg -> String? in
            guard msg.role == .user || msg.role == .assistant else { return nil }
            let who = msg.role == .assistant ? "Assistant" : "User"
            return "\(who): \(msg.text)"
        }.joined(separator: "\n")

        let mcpNote = """
        Hybrid Editor live MCP endpoint: \(mcpEndpoint) (server name: "editroom").
        IMPORTANT: Edit the currently open Hybrid Editor timeline EXCLUSIVELY through the `editroom` MCP tools \
        (start with `get_project` and `list_media`, wrap multi-step edits with `agent_turn` / `begin_turn` + `commit_turn` if modifying directly, or direct edit tools). \
        Do NOT inspect or modify application source files on disk.
        """
        let promptPayload = [
            request.systemPrompt,
            mcpNote,
            historyBlock.isEmpty ? "" : "Recent conversation:\n\(historyBlock)",
            "User: \(request.userPrompt)",
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let args: [String]
        switch kind {
        case .antigravity:
            var a = [
                "--print",
                "--output-format", "text",
                "--mode", "auto",
                "--dangerously-skip-permissions",
            ]
            let modelId = request.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !modelId.isEmpty, modelId.lowercased() != "auto" {
                a += ["--model", modelId]
            }
            a.append(promptPayload)
            args = a
        case .claudeCLI:
            args = ["-p", promptPayload, "--output-format", "text"]
        default:
            args = ["exec", promptPayload]
        }

        let state = ProcessState()
        let (status, stdout): (Int32, String) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process()
                    p.executableURL = cliURL
                    p.arguments = args
                    p.currentDirectoryURL = HybridStorage.subdir("Magic")
                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                    p.environment = env
                    p.standardInput = FileHandle.nullDevice

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    p.standardOutput = outPipe
                    p.standardError = errPipe

                    outPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        state.append(chunk)
                        if let str = String(data: chunk, encoding: .utf8), !str.isEmpty {
                            onEvent(.textDelta(str))
                        }
                    }

                    state.setProcess(p)
                    do {
                        try p.run()
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        p.waitUntilExit()
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
                        if !remaining.isEmpty {
                            state.append(remaining)
                            if let str = String(data: remaining, encoding: .utf8), !str.isEmpty {
                                onEvent(.textDelta(str))
                            }
                        }
                        let combinedOut = state.text()
                        let finalText = combinedOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? (String(data: errData, encoding: .utf8) ?? "")
                            : combinedOut
                        cont.resume(returning: (p.terminationStatus, finalText))
                    } catch {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.terminate()
        }

        try Task.checkCancellation()
        guard status == 0 else {
            throw AgentProviderError.cliUnavailable("\(displayName) exited \(status): \(SecretRedactor.redact(String(stdout.prefix(240))))")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
