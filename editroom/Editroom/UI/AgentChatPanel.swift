import SwiftUI

/// Collapsible multi-turn Agent Chat sidebar (`⌘L`) wired to `ChatSessionStore` & `AgentTurn` (`I1`).
struct AgentChatPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var chatStore = ChatSessionStore.shared
    @ObservedObject private var skills = SkillRegistry.shared
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var comfyProgress = ComfyProgressMonitor.shared
    @Environment(\.openSettings) private var openSettings

    @State private var selectedThreadId: UUID?
    @State private var selectedSkills: Set<String> = []
    @State private var providerPrefs = ChatProviderPrefs.load()
    @State private var input = ""
    @State private var errorBanner: String?

    private var projectKey: String { model.leaseProjectKey }

    private var activeThread: ChatThread? {
        if let id = selectedThreadId, let found = chatStore.thread(id: id) { return found }
        return chatStore.threads.first { $0.projectKey == projectKey } ?? chatStore.threads.first
    }

    private let selectableProviders: [AgentProviderKind] = [
        .geminiAPI, .ollama, .openAICompatible, .claudeCLI, .codexCLI,
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Theme.stroke)
            skillsBar
            Divider().overlay(Theme.stroke)
            messagesArea
            if comfyProgress.state.isRunning { comfyProgressStrip }
            if let errorBanner { errorStrip(errorBanner) }
            Divider().overlay(Theme.stroke)
            composerArea
        }
        .background(Theme.panel)
        .id(themes.look)
        .onAppear {
            let loaded = chatStore.loadThreads(for: projectKey)
            if selectedThreadId == nil { selectedThreadId = loaded.first?.id }
        }
        .onChange(of: projectKey) { _, newKey in
            let loaded = chatStore.loadThreads(for: newKey)
            selectedThreadId = loaded.first?.id
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Text("AGENT CHAT")
                .font(Theme.label())
                .kerning(1.5)
                .foregroundStyle(Theme.textDim)
            Spacer()
            Picker("", selection: Binding(
                get: { providerPrefs.selectedProvider },
                set: { next in
                    providerPrefs.selectedProvider = next
                    providerPrefs.save()
                }
            )) {
                ForEach(selectableProviders) { p in
                    Text(providerLabel(p)).tag(p)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 118)

            Menu {
                ForEach(chatStore.threads) { t in
                    Button(t.title) { selectedThreadId = t.id }
                }
                if !chatStore.threads.isEmpty { Divider() }
                Button("New Thread") { startNewThread() }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch or create chat thread")

            IconButton(symbol: "plus", size: 22, help: "New chat thread") {
                startNewThread()
            }
            IconButton(symbol: "xmark", size: 22, help: "Hide Agent Chat (⌘L)") {
                PanelLayout.shared.showAgentChat = false
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    // MARK: Skills Strip

    private var skillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    UserDefaults.standard.set("skills", forKey: "settingsTab")
                    openSettings()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 9.5, weight: .semibold))
                        Text("Skills").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.field))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)

                ForEach(skills.skills) { skill in
                    let active = selectedSkills.contains(skill.id)
                    Button {
                        if active { selectedSkills.remove(skill.id) } else { selectedSkills.insert(skill.id) }
                    } label: {
                        Text("/\(skill.id)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(active ? Theme.text : Theme.textDim)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(active ? Theme.accent.opacity(0.24) : Theme.field))
                            .overlay(Capsule().strokeBorder(active ? Theme.accent : Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .help(skill.description.isEmpty ? skill.name : skill.description)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    // MARK: Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let msgs = activeThread?.messages ?? []
                    if msgs.isEmpty && !chatStore.isRunning {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Multi-turn Video Agent")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("Every edit turn groups cleanly into 1 Undo step synced with Cmd+Z. Type /skill to inject a workflow or @playhead / @selected.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                            PillButton(title: "Configure Providers & APIs", prominent: false) {
                                UserDefaults.standard.set("integrations", forKey: "settingsTab")
                                openSettings()
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                    } else {
                        ForEach(msgs) { msg in
                            messageRow(msg)
                                .id(msg.id)
                        }
                    }

                    if chatStore.isRunning {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(chatStore.liveStatus ?? "Working…")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textDim)
                            }
                            if !chatStore.streamingText.isEmpty {
                                Text(chatStore.streamingText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                        .id("live-status")
                    }
                }
                .padding(12)
            }
            .onChange(of: activeThread?.messages.count ?? 0) { _, _ in
                if let last = activeThread?.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func messageRow(_ msg: ChatMessage) -> some View {
        let isUser = msg.role == .user
        return VStack(alignment: .leading, spacing: 6) {
            Text(isUser ? "You" : "Agent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isUser ? Theme.accent : Theme.textFaint)

            if !msg.text.isEmpty {
                Text(msg.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !msg.toolEvents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(msg.toolEvents) { ev in
                            HStack(spacing: 3) {
                                Image(systemName: ev.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(ev.succeeded ? Color(hex: 0x39B54A) : Color(hex: 0xE5735C))
                                Text(ev.toolName)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textDim)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.bg))
                        }
                    }
                }
            }

            if let link = msg.turnLink {
                HStack(spacing: 8) {
                    Text("Turn rev #\(link.revisionAfterCommit) · \(link.affectedClipIds.count) clips")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    if link.reverted {
                        Text("Reverted")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textFaint)
                    } else if let tid = activeThread?.id {
                        Button("Undo Turn") {
                            _ = chatStore.revertTurn(messageId: msg.id, in: tid, on: model)
                        }
                        .controlSize(.mini)
                        .disabled(model.topUndoTurn?.turnId != link.turnId)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isUser ? Theme.raised : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var comfyProgressStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(comfyProgress.state.workflowName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(comfyProgress.state.phase)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            if comfyProgress.state.maxSteps > 0 {
                ProgressView(value: comfyProgress.state.fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.raised)
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xE5735C))
                .lineLimit(2)
            Spacer()
            Button("Integrations") {
                UserDefaults.standard.set("integrations", forKey: "settingsTab")
                openSettings()
            }
            .controlSize(.mini)
            Button { errorBanner = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(hex: 0xE5735C).opacity(0.1))
    }

    // MARK: Composer

    private var composerArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                quickInsert("@playhead")
                quickInsert("@selected")
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask agent to edit, or type /skill…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...5)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                    .onSubmit { sendPrompt() }

                if chatStore.isRunning {
                    PillButton(title: "Stop", prominent: false) { chatStore.cancelActiveTurn() }
                } else {
                    PillButton(title: "Send", prominent: true) { sendPrompt() }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
    }

    private func quickInsert(_ token: String) -> some View {
        Button(token) {
            if input.isEmpty || input.hasSuffix(" ") {
                input += "\(token) "
            } else {
                input += " \(token) "
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.field))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }

    // MARK: Helpers

    private func providerLabel(_ kind: AgentProviderKind) -> String {
        switch kind {
        case .geminiAPI: "Gemini API"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-Compat"
        case .claudeCLI: "Claude Code"
        case .codexCLI: "Codex CLI"
        case .mock: "Mock"
        }
    }

    private func startNewThread() {
        let count = chatStore.threads.filter { $0.projectKey == projectKey }.count + 1
        let t = chatStore.createThread(
            for: projectKey,
            title: "Chat \(count)",
            providerId: providerPrefs.selectedProvider.rawValue,
            modelId: providerPrefs.activeModelId()
        )
        selectedThreadId = t.id
    }

    private func buildActiveProvider() -> any AgentProvider {
        switch providerPrefs.selectedProvider {
        case .geminiAPI:
            return GeminiHTTPProvider()
        case .ollama:
            return OpenAICompatibleHTTPProvider.ollama(model: providerPrefs.ollamaModel)
        case .openAICompatible:
            let base = providerPrefs.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = URL(string: "\(base)/chat/completions") ?? URL(string: "https://api.openai.com/v1/chat/completions")!
            return OpenAICompatibleHTTPProvider(endpointURL: url, defaultModel: providerPrefs.openAIModel, requiresAPIKey: true)
        case .claudeCLI:
            return CLIProcessAgentProvider(kind: .claudeCLI, cliPathProvider: { await AgentConnect.shared.claudeCLI })
        case .codexCLI:
            return CLIProcessAgentProvider(kind: .codexCLI, cliPathProvider: { await AgentConnect.shared.codexCLI })
        case .mock:
            return OpenAICompatibleHTTPProvider.ollama()
        }
    }

    private func sendPrompt() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatStore.isRunning else { return }

        let targetThread: ChatThread
        if let existing = activeThread {
            targetThread = existing
        } else {
            targetThread = chatStore.createThread(
                for: projectKey,
                title: "Chat 1",
                providerId: providerPrefs.selectedProvider.rawValue,
                modelId: providerPrefs.activeModelId()
            )
            selectedThreadId = targetThread.id
        }

        let explicit = Array(selectedSkills)
        let provider = buildActiveProvider()
        let modelId = providerPrefs.activeModelId()
        input = ""
        errorBanner = nil

        Task {
            do {
                _ = try await chatStore.send(
                    prompt: trimmed,
                    explicitSkills: explicit,
                    in: targetThread.id,
                    model: model,
                    provider: provider,
                    modelId: modelId
                )
            } catch is CancellationError {
                errorBanner = nil
            } catch {
                errorBanner = SecretRedactor.redact(error.localizedDescription)
            }
        }
    }
}
