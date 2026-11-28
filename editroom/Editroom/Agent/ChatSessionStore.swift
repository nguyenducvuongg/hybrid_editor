import Foundation

enum ChatSessionError: Error, LocalizedError {
    case threadNotFound(UUID)
    case busy

    var errorDescription: String? {
        switch self {
        case .threadNotFound(let id):
            return "Chat thread \(id.uuidString) not found."
        case .busy:
            return "Another chat turn is already in progress."
        }
    }
}

/// Manages per-project `ChatThread` history and executes transactional `AgentTurn` rounds (`I1`, `I2`).
@MainActor
final class ChatSessionStore: ObservableObject {
    static let shared = ChatSessionStore()

    let baseDir: URL
    let skillRegistry: SkillRegistry
    let pluginHost: PluginHost

    @Published private(set) var threads: [ChatThread] = []
    @Published private(set) var isRunning = false
    @Published private(set) var liveStatus: String?

    init(baseDir: URL? = nil, skillRegistry: SkillRegistry = .shared, pluginHost: PluginHost = .shared) {
        self.baseDir = baseDir ?? HybridStorage.subdir("Chats")
        self.skillRegistry = skillRegistry
        self.pluginHost = pluginHost
    }

    private func fileURL(for projectKey: String) -> URL {
        baseDir.appendingPathComponent("\(HybridStorage.sha256Hex16(projectKey)).threads.json")
    }

    @discardableResult
    func loadThreads(for projectKey: String) -> [ChatThread] {
        let url = fileURL(for: projectKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let parsed = try? decoder.decode([ChatThread].self, from: data) {
            threads = parsed.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            threads = []
        }
        return threads
    }

    @discardableResult
    func createThread(for projectKey: String, title: String = "New Chat",
                      providerId: String = "gemini", modelId: String = "gemini-2.5-flash") -> ChatThread {
        if threads.isEmpty || threads.first?.projectKey != projectKey {
            _ = loadThreads(for: projectKey)
        }
        let thread = ChatThread(projectKey: projectKey, title: title, providerId: providerId, modelId: modelId)
        threads.insert(thread, at: 0)
        try? save(thread)
        return thread
    }

    func save(_ thread: ChatThread) throws {
        var list = threads.filter { $0.projectKey == thread.projectKey }
        list.removeAll { $0.id == thread.id }
        list.insert(thread, at: 0)
        list.sort { $0.updatedAt > $1.updatedAt }
        threads = list

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(list)
        try HybridStorage.writeAtomicVerified(data, to: fileURL(for: thread.projectKey))
    }

    func thread(id: UUID) -> ChatThread? {
        threads.first { $0.id == id }
    }

    @discardableResult
    func send(
        prompt: String,
        explicitSkills: [String] = [],
        in threadId: UUID,
        model: EditorModel,
        provider: any AgentProvider,
        modelId: String = "",
        sessionId: String = "in-app-chat",
        onEvent: ((AgentStreamEvent) -> Void)? = nil
    ) async throws -> ChatMessage {
        guard !isRunning else { throw ChatSessionError.busy }
        guard var currentThread = threads.first(where: { $0.id == threadId }) else {
            throw ChatSessionError.threadNotFound(threadId)
        }

        isRunning = true
        liveStatus = "Preparing turn…"
        defer {
            isRunning = false
            liveStatus = nil
        }

        let detectedSlugs = SkillRegistry.extractSlashSlugs(from: prompt)
        var allSlugs = explicitSkills.map { $0.lowercased() }
        for slug in detectedSlugs where !allSlugs.contains(slug) {
            allSlugs.append(slug)
        }

        let skillPrompt = skillRegistry.composePromptSection(explicitSlugs: allSlugs)
        let baseSystem = """
        You are Editroom's editing assistant working inside a live project timeline.
        Always inspect with get_project / list_media before mutating. Keep explanations concise.
        """
        let fullSystemPrompt = skillPrompt.isEmpty ? baseSystem : "\(baseSystem)\n\n\(skillPrompt)"

        let pid = ProcessInfo.processInfo.processIdentifier
        let (_, recovered) = try model.leaseManager.acquire(sessionId: sessionId, clientPid: pid, role: .liveAgent)
        if let rec = recovered, rec.uncommittedTurnId != nil {
            _ = model.rollbackAnyActiveAgentTurn()
        }

        let turnId = "chat-\(UUID().uuidString.prefix(12))"
        let turnSummary = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        try model.beginAgentTurn(turnId: turnId, summary: turnSummary.isEmpty ? "Chat edit" : turnSummary, sessionId: sessionId)
        try? model.leaseManager.setActiveTurn(sessionId: sessionId, turnId: turnId)

        var turnCommitted = false
        defer {
            if !turnCommitted {
                _ = try? model.rollbackAgentTurn(turnId: turnId)
                try? model.leaseManager.setActiveTurn(sessionId: sessionId, turnId: nil)
            }
            try? model.leaseManager.release(sessionId: sessionId)
        }

        // Gather standard MCP tools + enabled & trusted Tier A plugin tools.
        var tools = MCPTools.definitions
        for plugin in pluginHost.plugins where plugin.enabled && plugin.trustedForExecution && plugin.manifest.mcp != nil {
            if let pTools = try? await pluginHost.listPluginTools(id: plugin.id) {
                tools.append(contentsOf: pTools)
            }
        }

        var recordedEvents: [ChatToolEvent] = []
        let requestSnapshot = AgentRequest(
            thread: currentThread,
            userPrompt: prompt,
            systemPrompt: fullSystemPrompt,
            tools: tools,
            modelId: modelId.isEmpty ? currentThread.modelId : modelId
        )

        let replyText = try await provider.runTurn(
            requestSnapshot,
            toolExecutor: { [weak self, weak model] toolName, args in
                guard let self, let model else {
                    throw MCPToolError("Editor session is no longer active.")
                }
                if toolName.hasPrefix("plugin.") {
                    let res = try await self.pluginHost.callNamespacedTool(toolName, arguments: args)
                    recordedEvents.append(ChatToolEvent(toolName: toolName, summary: "plugin", succeeded: true))
                    return res
                }
                do {
                    let out = try await MCPTools.call(
                        toolName,
                        args,
                        model: model,
                        client: nil,
                        draft: model.activeAgentTurn?.draft,
                        sessionId: sessionId,
                        isExternal: true
                    )
                    recordedEvents.append(ChatToolEvent(toolName: toolName, summary: "ok", succeeded: true))
                    return out
                } catch {
                    recordedEvents.append(ChatToolEvent(toolName: toolName, summary: error.localizedDescription, succeeded: false))
                    throw error
                }
            },
            onEvent: { [weak self] ev in
                Task { @MainActor in
                    switch ev {
                    case .status(let msg): self?.liveStatus = msg
                    case .toolStarted(let name): self?.liveStatus = "Running \(name)…"
                    case .toolFinished(let name, let ok): self?.liveStatus = ok ? "Done \(name)" : "Failed \(name)"
                    case .textDelta: break
                    }
                    onEvent?(ev)
                }
            }
        )

        let commit = try model.commitAgentTurn(turnId: turnId)
        turnCommitted = true
        try? model.leaseManager.setActiveTurn(sessionId: sessionId, turnId: nil)

        let turnLink: ChatTurnLink? = commit.pushedUndoStep ? ChatTurnLink(
            turnId: commit.turnId,
            summary: commit.summary,
            revisionAfterCommit: commit.revision,
            affectedClipIds: commit.affectedClipIds,
            reverted: false
        ) : nil

        let userMsg = ChatMessage(role: .user, text: prompt, skillSlugs: allSlugs)
        let assistantMsg = ChatMessage(
            role: .assistant,
            text: replyText,
            skillSlugs: allSlugs,
            toolEvents: recordedEvents,
            turnLink: turnLink
        )
        currentThread.providerId = provider.id
        if !modelId.isEmpty { currentThread.modelId = modelId }
        currentThread.messages.append(userMsg)
        currentThread.messages.append(assistantMsg)
        currentThread.updatedAt = Date()
        try save(currentThread)
        return assistantMsg
    }

    @discardableResult
    func revertTurn(messageId: UUID, in threadId: UUID, on model: EditorModel) -> Bool {
        guard let tIdx = threads.firstIndex(where: { $0.id == threadId }),
              let mIdx = threads[tIdx].messages.firstIndex(where: { $0.id == messageId }),
              let link = threads[tIdx].messages[mIdx].turnLink,
              !link.reverted,
              model.topUndoTurn?.turnId == link.turnId else {
            return false
        }
        model.undo()
        threads[tIdx].messages[mIdx].turnLink?.reverted = true
        threads[tIdx].updatedAt = Date()
        try? save(threads[tIdx])
        return true
    }
}
