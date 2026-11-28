import AppKit
import SwiftUI

/// Unified Apple-HIG SwiftUI Hybrid AI sidebar (`⌘L`), uniting Antigravity 2.0 primary agent chat,
/// external/API providers, and zero-API-key on-device Quick Cuts (`Magic`).
struct AgentChatPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var chatStore = ChatSessionStore.shared
    @ObservedObject private var skills = SkillRegistry.shared
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var comfyProgress = ComfyProgressMonitor.shared
    @ObservedObject private var connections = AgentConnect.shared
    @ObservedObject private var server = MCPServer.shared
    @ObservedObject private var magicState = MagicState.shared
    @ObservedObject private var magicAgent = MagicAgent.shared
    @Environment(\.openSettings) private var openSettings

    enum StudioMode: String, CaseIterable, Identifiable {
        case agent = "Agent"
        case quickCut = "Quick Cut"
        var id: Self { self }
    }

    private struct StarterWorkflow: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let skillSlug: String?
        let prompt: String
    }

    private static let starterWorkflows: [StarterWorkflow] = [
        StarterWorkflow(
            id: "aroll",
            icon: "scissors",
            title: "A-Roll Rough Cut",
            subtitle: "Cut pauses, filler words, and retakes cleanly",
            skillSlug: "aroll-rough-cut",
            prompt: "Clean up pauses, filler words, and retakes across the talking timeline."
        ),
        StarterWorkflow(
            id: "karaoke",
            icon: "captions.bubble",
            title: "Vietnamese Karaoke Captions",
            subtitle: "Word-timed CapCut/TikTok subtitles with highlights",
            skillSlug: "vietnamese-shorts-creator",
            prompt: "Generate word-level Vietnamese karaoke captions styled for vertical shorts."
        ),
        StarterWorkflow(
            id: "duck-beat",
            icon: "waveform",
            title: "Auto-Duck BGM & Beat Sync",
            subtitle: "Duck music under speech and snap cuts to beats",
            skillSlug: nil,
            prompt: "Auto-duck background music under speech on A1 and sync video cuts to the music beat."
        ),
        StarterWorkflow(
            id: "reframe",
            icon: "crop",
            title: "Smart 9:16 Auto-Reframe",
            subtitle: "Apple Vision face tracking for Reels & TikTok",
            skillSlug: nil,
            prompt: "Analyze faces on the timeline and auto-reframe the sequence cleanly for 9:16 vertical."
        ),
    ]

    private static let quickCutPresets: [(id: String, icon: String, title: String, subtitle: String, prompt: String)] = [
        ("best", "wand.and.sparkles", "Best Auto-Cut", "Pick strongest takes and remove dead space", ""),
        ("tighten", "scissors", "Tighten Pacing", "Trim slow starts/ends and drop weak repeats", "Make this shorter and tighter: keep only the strongest moments and remove slow gaps."),
        ("beat", "metronome", "Cut to Music Beat", "Align timeline edits with audio bar starts", "Cut and pace the edit cleanly to the music beat."),
        ("vertical", "iphone", "Vertical 9:16 Reel", "Fast hook-first vertical cut for Shorts", "Make a punchy 20 second 9:16 vertical reel with a strong hook."),
    ]

    @State private var mode: StudioMode = .agent
    @State private var selectedThreadId: UUID?
    @State private var selectedSkills: Set<String> = []
    @State private var providerPrefs = ChatProviderPrefs.load()
    @State private var input = ""
    @State private var quickCutInput = ""
    @State private var errorBanner: String?

    private var projectKey: String { model.leaseProjectKey }

    private var activeThread: ChatThread? {
        if let id = selectedThreadId, let found = chatStore.thread(id: id) { return found }
        return chatStore.threads.first { $0.projectKey == projectKey } ?? chatStore.threads.first
    }

    private let selectableProviders: [AgentProviderKind] = [
        .antigravity, .geminiAPI, .ollama, .openAICompatible, .claudeCLI, .codexCLI,
    ]

    private var mcpLive: Bool { server.running && connections.antigravityConnected }

    private var hasMedia: Bool {
        model.project.assets.contains { $0.kind != .audio } || !model.project.clips.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Theme.stroke)
            modePickerBar
            Divider().overlay(Theme.stroke)

            if mode == .agent {
                providerConnectionBar
                Divider().overlay(Theme.stroke)
                messagesArea
                if comfyProgress.state.isRunning { comfyProgressStrip }
                if let errorBanner { errorStrip(errorBanner) }
                Divider().overlay(Theme.stroke)
                composerArea
            } else {
                quickCutView
            }
        }
        .background(Theme.panel)
        .id(themes.look)
        .onAppear {
            connections.refresh()
            let loaded = chatStore.loadThreads(for: projectKey)
            if selectedThreadId == nil { selectedThreadId = loaded.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connections.refresh()
        }
        .onChange(of: projectKey) { _, newKey in
            let loaded = chatStore.loadThreads(for: newKey)
            selectedThreadId = loaded.first?.id
        }
    }

    // MARK: - Header & Mode Switcher

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Hybrid AI")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if mode == .agent {
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
                .help("Switch chat thread")

                IconButton(symbol: "plus", size: 22, help: "New chat thread") {
                    startNewThread()
                }
            }

            IconButton(symbol: "slider.horizontal.3", size: 22, help: "AI & MCP Settings") {
                UserDefaults.standard.set("magic", forKey: "settingsTab")
                openSettings()
            }
            IconButton(symbol: "xmark", size: 22, help: "Hide Hybrid AI (⌘L)") {
                PanelLayout.shared.showAgentChat = false
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var modePickerBar: some View {
        HStack(spacing: 3) {
            ForEach(StudioMode.allCases) { item in
                let selected = mode == item
                Button { mode = item } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item == .agent ? "sparkles" : "wand.and.sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(item.rawValue)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(selected ? Theme.text : Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.raised : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Theme.stroke : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.bg))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Provider & MCP Status Strip

    private var providerConnectionBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(selectableProviders) { p in
                    Button {
                        providerPrefs.selectedProvider = p
                        providerPrefs.save()
                        errorBanner = nil
                    } label: {
                        HStack {
                            Text(providerMenuLabel(p))
                            if providerPrefs.selectedProvider == p {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    if p == .antigravity { Divider() }
                }
                Divider()
                Button("Configure Keys & Models…") {
                    UserDefaults.standard.set("integrations", forKey: "settingsTab")
                    openSettings()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(providerHealthColor(providerPrefs.selectedProvider))
                        .frame(width: 7, height: 7)
                    Text(providerLabel(providerPrefs.selectedProvider))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 4)

            if mcpLive {
                Button {
                    UserDefaults.standard.set("magic", forKey: "settingsTab")
                    openSettings()
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: 0x39B54A)).frame(width: 6, height: 6)
                        Text("MCP · \(server.listeningPort ?? MCPServer.port)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.field))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
                .help("Local MCP server live at \(server.localEndpoint ?? MCPServer.endpoint)")
            } else {
                Button {
                    if !server.enabled { server.enabled = true }
                    server.start()
                    connections.connect(.antigravity)
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: 0xE5A93B)).frame(width: 6, height: 6)
                        Text("Connect MCP")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Messages & Empty State

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let msgs = activeThread?.messages ?? []
                    if msgs.isEmpty && !chatStore.isRunning {
                        emptyStateView
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
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Theme.textDim)
                            }
                            if !chatStore.streamingText.isEmpty {
                                Text(chatStore.streamingText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
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

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeroCard

            Text("QUICK WORKFLOWS")
                .font(Theme.label())
                .kerning(1.3)
                .foregroundStyle(Theme.textFaint)
                .padding(.top, 2)

            VStack(spacing: 7) {
                ForEach(Self.starterWorkflows) { wf in
                    Button {
                        if let slug = wf.skillSlug, skills.skills.contains(where: { $0.id == slug }) {
                            selectedSkills.insert(slug)
                        }
                        input = wf.prompt
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: wf.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(wf.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(wf.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var statusHeroCard: some View {
        let p = providerPrefs.selectedProvider
        VStack(alignment: .leading, spacing: 8) {
            if p == .antigravity {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(mcpLive && connections.antigravityCLI != nil
                         ? "Antigravity 2.0 Ready"
                         : "Antigravity 2.0")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(connections.antigravityCLI != nil ? "PRIMARY" : "SETUP")
                        .font(.system(size: 9.5, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(mcpLive ? Color(hex: 0x39B54A) : Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((mcpLive ? Color(hex: 0x39B54A) : Theme.accent).opacity(0.16)))
                }
                Text(antigravityStatusSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if !connections.antigravityConnected || !server.enabled {
                    PillButton(title: "Connect Antigravity 2.0", prominent: true) {
                        if !server.enabled { server.enabled = true }
                        server.start()
                        connections.connect(.antigravity)
                    }
                }
            } else {
                Text(providerLabel(p))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Every edit turn commits cleanly as 1 Undo step synced with ⌘Z.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if missingCredentialNotice(for: p) != nil {
                    PillButton(title: "Configure Key in Integrations", prominent: false) {
                        UserDefaults.standard.set("integrations", forKey: "settingsTab")
                        openSettings()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var antigravityStatusSummary: String {
        if connections.antigravityCLI == nil {
            return "`agy` CLI was not found in PATH. Install Antigravity or connect external Antigravity IDE sessions via MCP."
        }
        if mcpLive {
            return "Live-attached over local MCP (\(server.localEndpoint ?? MCPServer.endpoint)). Prompts edit the timeline directly and sync with ⌘Z."
        }
        return "Connect Antigravity 2.0 to register Hybrid Editor in ~/.gemini/config and ~/.gemini/antigravity."
    }

    private func messageRow(_ msg: ChatMessage) -> some View {
        let isUser = msg.role == .user
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if !isUser {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(isUser ? "You" : "Hybrid AI")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isUser ? Theme.accent : Theme.textDim)
                if !msg.skillSlugs.isEmpty {
                    Spacer()
                    Text(msg.skillSlugs.map { "/\($0)" }.joined(separator: " "))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                }
            }

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
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(isUser ? Theme.raised : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke))
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
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Settings") {
                let target = providerPrefs.selectedProvider == .antigravity ? "magic" : "integrations"
                UserDefaults.standard.set(target, forKey: "settingsTab")
                openSettings()
            }
            .controlSize(.mini)
            Button { errorBanner = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(hex: 0xE5735C).opacity(0.1))
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !selectedSkills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(selectedSkills).sorted(), id: \.self) { slug in
                            Button { selectedSkills.remove(slug) } label: {
                                HStack(spacing: 4) {
                                    Text("/\(slug)")
                                        .font(.system(size: 10.5, design: .monospaced))
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                }
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.accent.opacity(0.22)))
                                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Ask \(providerLabel(providerPrefs.selectedProvider)) to edit, or use /Skills…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...5)
                    .onSubmit { sendPrompt() }

                HStack(spacing: 6) {
                    Menu {
                        if skills.skills.isEmpty {
                            Text("No skills installed")
                        } else {
                            ForEach(skills.skills) { skill in
                                let active = selectedSkills.contains(skill.id)
                                Button {
                                    if active { selectedSkills.remove(skill.id) } else { selectedSkills.insert(skill.id) }
                                } label: {
                                    HStack {
                                        Text("/\(skill.id) — \(skill.name)")
                                        if active { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Manage Skills…") {
                            UserDefaults.standard.set("skills", forKey: "settingsTab")
                            openSettings()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "book.closed").font(.system(size: 9.5, weight: .semibold))
                            Text(selectedSkills.isEmpty ? "Skills" : "Skills (\(selectedSkills.count))")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(selectedSkills.isEmpty ? Theme.textDim : Theme.text)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selectedSkills.isEmpty ? Theme.raised : Theme.accent.opacity(0.22)))
                        .overlay(Capsule().strokeBorder(selectedSkills.isEmpty ? Theme.stroke : Theme.accent.opacity(0.5)))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    quickInsert("@playhead")
                    quickInsert("@selected")

                    Spacer(minLength: 4)

                    if chatStore.isRunning {
                        Button { chatStore.cancelActiveTurn() } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color(hex: 0xE5735C))
                        }
                        .buttonStyle(.plain)
                        .help("Stop running turn")
                    } else {
                        let empty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button { sendPrompt() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(empty ? Theme.textFaint : Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(empty)
                        .help("Send prompt")
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
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
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.raised))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }

    // MARK: - Quick Cut Mode (On-Device / LocalMagic)

    private var quickCutView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("On-Device Quick Cut")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text("No API Key")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(hex: 0x39B54A))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(hex: 0x39B54A).opacity(0.15)))
                        }
                        Text(LocalBrain.available
                             ? "Runs Apple Intelligence & local heuristics right on this Mac. Select a preset or describe what to cut."
                             : (LocalBrain.unavailableReason ?? "Runs deterministic smart-cut heuristics directly on this Mac."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke))

                    if magicState.busy || magicState.stage != nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(magicState.activity ?? magicState.status ?? magicState.stage ?? "Editing timeline…")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Button("Stop") { MagicShow.stopAll() }
                                .controlSize(.mini)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.4)))
                    } else if let note = magicAgent.note, note.agent == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Last Quick Cut · \(note.detail)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text(note.text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                    }

                    Text("ONE-CLICK PRESETS")
                        .font(Theme.label())
                        .kerning(1.3)
                        .foregroundStyle(Theme.textFaint)

                    VStack(spacing: 7) {
                        ForEach(Self.quickCutPresets, id: \.id) { preset in
                            Button {
                                quickCutInput = preset.prompt
                                runQuickCut(preset.prompt)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 28, height: 28)
                                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(preset.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.text)
                                        Text(preset.subtitle)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(Theme.textDim)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.textFaint)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                            }
                            .buttonStyle(.plain)
                            .disabled(!hasMedia || MagicShow.isRunning || magicState.busy)
                        }
                    }
                }
                .padding(12)
            }

            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Describe quick cut (or leave empty for best cut)…", text: $quickCutInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...4)
                    .onSubmit { runQuickCut(quickCutInput) }

                HStack {
                    if !hasMedia {
                        Text("Import clips into Media first")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    if magicState.busy || magicState.stage != nil {
                        PillButton(title: "Stop", prominent: false) { MagicShow.stopAll() }
                    } else {
                        PillButton(title: "Run Quick Cut", prominent: true) {
                            runQuickCut(quickCutInput)
                        }
                        .disabled(!hasMedia || MagicShow.isRunning)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .padding(12)
        }
    }

    // MARK: - Helpers

    private func providerLabel(_ kind: AgentProviderKind) -> String {
        switch kind {
        case .antigravity: "Antigravity 2.0"
        case .geminiAPI: "Gemini API"
        case .ollama: "Ollama (Local)"
        case .openAICompatible: "OpenAI-Compat"
        case .claudeCLI: "Claude Code"
        case .codexCLI: "Codex CLI"
        case .mock: "Mock"
        }
    }

    private func providerMenuLabel(_ kind: AgentProviderKind) -> String {
        switch kind {
        case .antigravity:
            return connections.antigravityCLI != nil ? "Antigravity 2.0 (Primary · Ready)" : "Antigravity 2.0 (Primary)"
        default:
            return providerLabel(kind)
        }
    }

    private func providerHealthColor(_ kind: AgentProviderKind) -> Color {
        switch kind {
        case .antigravity:
            return (mcpLive && connections.antigravityCLI != nil) ? Color(hex: 0x39B54A) : Color(hex: 0xE5A93B)
        case .geminiAPI, .openAICompatible:
            return missingCredentialNotice(for: kind) == nil ? Color(hex: 0x39B54A) : Color(hex: 0xE5A93B)
        case .ollama:
            return Color(hex: 0x5BA8FF)
        case .claudeCLI:
            return connections.claudeCLI != nil ? Color(hex: 0x39B54A) : Color(hex: 0x8E8E93)
        case .codexCLI:
            return connections.codexCLI != nil ? Color(hex: 0x39B54A) : Color(hex: 0x8E8E93)
        case .mock:
            return Theme.textFaint
        }
    }

    private func missingCredentialNotice(for kind: AgentProviderKind) -> String? {
        switch kind {
        case .geminiAPI:
            let k = (try? AppSecrets.shared.get(.geminiAPIKey))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return k.isEmpty ? "Gemini API key not configured yet." : nil
        case .openAICompatible:
            let k = (try? AppSecrets.shared.get(.openAIAPIKey))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return k.isEmpty ? "OpenAI-compatible API key not configured yet." : nil
        default:
            return nil
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
        let liveEndpoint = server.localEndpoint ?? MCPServer.endpoint
        switch providerPrefs.selectedProvider {
        case .antigravity:
            return CLIProcessAgentProvider(
                kind: .antigravity,
                mcpEndpoint: liveEndpoint,
                cliPathProvider: { await AgentConnect.shared.antigravityCLI }
            )
        case .geminiAPI:
            return GeminiHTTPProvider()
        case .ollama:
            return OpenAICompatibleHTTPProvider.ollama(model: providerPrefs.ollamaModel)
        case .openAICompatible:
            let base = providerPrefs.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = URL(string: "\(base)/chat/completions") ?? URL(string: "https://api.openai.com/v1/chat/completions")!
            return OpenAICompatibleHTTPProvider(endpointURL: url, defaultModel: providerPrefs.openAIModel, requiresAPIKey: true)
        case .claudeCLI:
            return CLIProcessAgentProvider(
                kind: .claudeCLI,
                mcpEndpoint: liveEndpoint,
                cliPathProvider: { await AgentConnect.shared.claudeCLI }
            )
        case .codexCLI:
            return CLIProcessAgentProvider(
                kind: .codexCLI,
                mcpEndpoint: liveEndpoint,
                cliPathProvider: { await AgentConnect.shared.codexCLI }
            )
        case .mock:
            return OpenAICompatibleHTTPProvider.ollama()
        }
    }

    private func sendPrompt() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatStore.isRunning else { return }

        if let notice = missingCredentialNotice(for: providerPrefs.selectedProvider) {
            errorBanner = notice
            return
        }

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

    private func runQuickCut(_ raw: String) {
        guard hasMedia, !MagicShow.isRunning, !magicState.busy else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        quickCutInput = ""
        model.addMagicPrompt(text, tab: .local)
        LocalMagic.run(text, model: model)
    }
}
