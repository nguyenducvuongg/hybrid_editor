import AppKit
import SwiftUI

// MARK: - Skills Settings Tab

struct SkillsSettingsView: View {
    @ObservedObject private var registry = SkillRegistry.shared
    @State private var repoInput = ""
    @State private var installing = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Skills")
                VStack(alignment: .leading, spacing: 20) {
                    SettingsSection("Install SKILL.md") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                TextField("GitHub URL or owner/repo/tree/main/skills/name", text: $repoInput)
                                    .textFieldStyle(.roundedBorder)
                                if installing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    PillButton(title: "Install", prominent: true) { installGitHub() }
                                        .disabled(repoInput.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                            HStack(spacing: 10) {
                                PillButton(title: "Add Local Folder…", prominent: false) { pickLocalFolder() }
                                PillButton(title: "Restore Built-in", prominent: false) { restoreBuiltIn() }
                                if let statusMessage {
                                    Text(statusMessage)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(isError ? Color(hex: 0xE5735C) : Theme.textDim)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(14)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Installed Skills (\(registry.skills.count))")
                        if registry.skills.isEmpty {
                            Text("No skills installed yet. Install a GitHub SKILL.md repo or add a local folder above, then invoke it with /slug in Agent Chat.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textDim)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                        } else {
                            VStack(spacing: 10) {
                                ForEach(registry.skills) { skill in
                                    SkillCard(
                                        skill: skill,
                                        loaded: registry.loadSkill(id: skill.id),
                                        onToggle: { on in try? registry.setEnabled(id: skill.id, enabled: on) },
                                        onRemove: { try? registry.remove(id: skill.id) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func installGitHub() {
        let raw = repoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        installing = true
        statusMessage = nil
        isError = false
        Task {
            do {
                let meta = try await registry.installFromGitHub(raw)
                repoInput = ""
                statusMessage = "Installed /\(meta.id)"
            } catch {
                isError = true
                statusMessage = error.localizedDescription
            }
            installing = false
        }
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let meta = try registry.installFromLocal(directory: url)
            isError = false
            statusMessage = "Added /\(meta.id)"
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }

    private func restoreBuiltIn() {
        let added = registry.seedBuiltInSkills(force: true)
        isError = false
        statusMessage = "Restored \(added) built-in skills"
    }
}

private struct SkillCard: View {
    let skill: SkillMetadata
    let loaded: LoadedSkill?
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void
    @State private var expanded = false

    private var sourceLabel: String {
        switch skill.source {
        case .builtIn: "Built-in"
        case .local: "Local"
        case .github(let repo, _, _, let sha): "GitHub · \(repo) @ \(sha.prefix(7))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("/\(skill.id)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description).font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    }
                    Text(sourceLabel).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { skill.enabled }, set: onToggle))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Theme.accent)
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
            }

            if let loaded, !loaded.body.isEmpty {
                DisclosureGroup("Instructions", isExpanded: $expanded) {
                    Text(loaded.body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: - Plugins Settings Tab

struct PluginsSettingsView: View {
    @ObservedObject private var host = PluginHost.shared
    @State private var repoInput = ""
    @State private var installing = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var pendingTrustPlugin: InstalledPlugin?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Plugins")
                VStack(alignment: .leading, spacing: 20) {
                    SettingsSection("Install Plugin") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                TextField("GitHub URL or owner/repo containing plugin.json", text: $repoInput)
                                    .textFieldStyle(.roundedBorder)
                                if installing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    PillButton(title: "Install", prominent: true) { installGitHub() }
                                        .disabled(repoInput.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                            HStack(spacing: 10) {
                                PillButton(title: "Add Local Plugin…", prominent: false) { pickLocalPlugin() }
                                if let statusMessage {
                                    Text(statusMessage)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(isError ? Color(hex: 0xE5735C) : Theme.textDim)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(14)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Installed Plugins (\(host.plugins.count))")
                        if host.plugins.isEmpty {
                            Text("Install Tier A MCP sidecar plugins or Tier B asset packs (LUTs, ComfyUI workflows, skill bundles) safely isolated inside HYBRID_EDIT_DATA_DIR/Plugins.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textDim)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                        } else {
                            VStack(spacing: 10) {
                                ForEach(host.plugins) { plugin in
                                    PluginCard(
                                        plugin: plugin,
                                        onToggle: { on in
                                            do {
                                                try host.setEnabled(id: plugin.id, enabled: on)
                                            } catch {
                                                isError = true
                                                statusMessage = error.localizedDescription
                                            }
                                        },
                                        onRequestTrust: { pendingTrustPlugin = plugin },
                                        onRemove: { try? host.remove(id: plugin.id) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .alert("Trust Plugin Executable?", isPresented: Binding(
            get: { pendingTrustPlugin != nil },
            set: { if !$0 { pendingTrustPlugin = nil } }
        )) {
            Button("Trust & Enable") {
                if let p = pendingTrustPlugin {
                    try? host.trustAndEnable(id: p.id)
                    statusMessage = "Trusted and enabled \(p.manifest.name)."
                    isError = false
                }
                pendingTrustPlugin = nil
            }
            Button("Cancel", role: .cancel) { pendingTrustPlugin = nil }
        } message: {
            if let p = pendingTrustPlugin, let mcp = p.manifest.mcp {
                Text("This plugin will execute local command:\n\(mcp.command) \(mcp.args.joined(separator: " "))")
            }
        }
    }

    private func installGitHub() {
        let raw = repoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        installing = true
        statusMessage = nil
        isError = false
        Task {
            do {
                let p = try await host.installFromGitHub(raw)
                repoInput = ""
                statusMessage = p.trustedForExecution ? "Installed \(p.manifest.name)" : "Installed \(p.manifest.name) (needs Trust)"
            } catch {
                isError = true
                statusMessage = error.localizedDescription
            }
            installing = false
        }
    }

    private func pickLocalPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try host.installFromLocal(directory: url)
            isError = false
            statusMessage = p.trustedForExecution ? "Added \(p.manifest.name)" : "Added \(p.manifest.name) (needs Trust)"
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }
}

private struct PluginCard: View {
    let plugin: InstalledPlugin
    let onToggle: (Bool) -> Void
    let onRequestTrust: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(plugin.manifest.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("v\(plugin.manifest.version)").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        if plugin.manifest.mcp != nil { badge("MCP Sidecar", tint: Theme.accent) }
                        if !(plugin.manifest.luts ?? []).isEmpty { badge("LUTs", tint: Color(hex: 0x5BA8FF)) }
                        if !(plugin.manifest.workflows ?? []).isEmpty { badge("Workflows", tint: Color(hex: 0x39B54A)) }
                    }
                    Text(plugin.manifest.description).font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if plugin.manifest.mcp != nil && !plugin.trustedForExecution {
                    PillButton(title: "Trust & Enable", prominent: true, action: onRequestTrust)
                } else {
                    Toggle("", isOn: Binding(get: { plugin.enabled }, set: onToggle))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(Theme.accent)
                }
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
            }

            if let mcp = plugin.manifest.mcp, !plugin.trustedForExecution {
                Text("Untrusted command: \(mcp.command) \(mcp.args.joined(separator: " "))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xE5A93B))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xE5A93B).opacity(0.12)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// MARK: - Integrations Settings Tab

struct IntegrationsSettingsView: View {
    @State private var chatPrefs = ChatProviderPrefs.load()
    @State private var comfyPrefs = ComfyConnectionPrefs.load()
    @State private var speechPrefs = SpeechPrefs.load()
    @State private var vlmPrefs = VLMIndexPrefs.load()

    @State private var geminiKey = (try? AppSecrets.shared.get(.geminiAPIKey)) ?? ""
    @State private var openAIKey = (try? AppSecrets.shared.get(.openAIAPIKey)) ?? ""
    @State private var pexelsKey = (try? AppSecrets.shared.get(.pexelsAPIKey)) ?? ""
    @State private var pixabayKey = (try? AppSecrets.shared.get(.pixabayAPIKey)) ?? ""
    @State private var comfyToken = (try? AppSecrets.shared.get(.comfyAuthToken)) ?? ""
    @State private var comfyCFId = (try? AppSecrets.shared.get(.comfyCFClientId)) ?? ""
    @State private var comfyCFSecret = (try? AppSecrets.shared.get(.comfyCFClientSecret)) ?? ""

    @State private var savedBanner: String?
    @State private var testingComfy = false
    @State private var comfyTestResult: (ok: Bool, text: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("Integrations")
                VStack(alignment: .leading, spacing: 20) {
                    SettingsSection("AI Chat Providers") {
                        VStack(spacing: 0) {
                            SettingsRow("Gemini API Key", detail: "Stored in Keychain") {
                                SecureField("AIza…", text: $geminiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Gemini Model") {
                                TextField("gemini-2.5-flash", text: $chatPrefs.geminiModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("OpenAI-Compatible Key") {
                                SecureField("sk-…", text: $openAIKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("OpenAI Base URL") {
                                TextField("https://api.openai.com/v1", text: $chatPrefs.openAIBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("OpenAI Model") {
                                TextField("gpt-4o", text: $chatPrefs.openAIModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Ollama Base URL") {
                                TextField("http://127.0.0.1:11434/v1", text: $chatPrefs.ollamaBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Ollama Model") {
                                TextField("qwen2.5:14b", text: $chatPrefs.ollamaModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                        }
                    }

                    SettingsSection("Free Stock Media APIs") {
                        VStack(spacing: 0) {
                            SettingsRow("Pexels API Key", detail: pexelsKey.isEmpty ? "Not configured" : "Configured in Keychain") {
                                SecureField("Pexels Key", text: $pexelsKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Pixabay API Key", detail: pixabayKey.isEmpty ? "Not configured" : "Configured in Keychain") {
                                SecureField("Pixabay Key", text: $pixabayKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                        }
                    }

                    SettingsSection("ComfyUI on Google Colab (Tunnel)") {
                        VStack(spacing: 0) {
                            SettingsRow("Tunnel Mode") {
                                Picker("", selection: $comfyPrefs.mode) {
                                    ForEach(ComfyTunnelMode.allCases) { m in
                                        Text(m.title).tag(m)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("ComfyUI Endpoint URL") {
                                TextField("https://xxx.trycloudflare.com", text: $comfyPrefs.endpointURL)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            if comfyPrefs.mode == .ssh {
                                Divider().overlay(Theme.stroke)
                                SettingsRow("SSH Tunnel Command") {
                                    TextField("ssh -N -L 8188:127.0.0.1:8188 colab", text: $comfyPrefs.sshCommand)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                }
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Auth Token (optional)") {
                                SecureField("Bearer token", text: $comfyToken)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            if comfyPrefs.mode == .cloudflare {
                                Divider().overlay(Theme.stroke)
                                SettingsRow("CF Access Client ID") {
                                    SecureField("Optional", text: $comfyCFId)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                }
                                Divider().overlay(Theme.stroke)
                                SettingsRow("CF Access Secret") {
                                    SecureField("Optional", text: $comfyCFSecret)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                }
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Connection Check") {
                                HStack(spacing: 8) {
                                    if let res = comfyTestResult {
                                        Text(res.text)
                                            .font(.system(size: 11))
                                            .foregroundStyle(res.ok ? Color(hex: 0x39B54A) : Color(hex: 0xE5735C))
                                            .lineLimit(1)
                                    }
                                    if testingComfy {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        PillButton(title: "Test Connection", prominent: false) { testComfy() }
                                    }
                                }
                            }
                        }
                    }

                    SettingsSection("Smart A-Roll (Whisper Metal) & B-Roll VLM") {
                        VStack(spacing: 0) {
                            SettingsRow("Prefer Whisper (whisper-cli)", detail: "Pre-gated by AudioVAD") {
                                Toggle("", isOn: $speechPrefs.preferWhisper)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .tint(Theme.accent)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Whisper Binary Path") {
                                TextField("/opt/homebrew/bin/whisper-cli", text: $speechPrefs.whisperBinaryPath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Whisper GGML Model") {
                                TextField("ggml-large-v3-turbo.bin", text: $speechPrefs.whisperModelPath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("A-Roll Language") {
                                TextField("vi", text: $speechPrefs.whisperLanguage)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Local VLM Base URL", detail: "OpenAI-compatible /v1") {
                                TextField("http://127.0.0.1:11434/v1", text: $vlmPrefs.vlmBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Divider().overlay(Theme.stroke)
                            SettingsRow("Local VLM Model") {
                                TextField("qwen2.5vl:7b", text: $vlmPrefs.vlmModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        PillButton(title: "Save Keys & Settings", prominent: true) { saveAll() }
                        if let savedBanner {
                            Text(savedBanner)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: 0x39B54A))
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func storeSecret(_ value: String, for key: SecretKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try AppSecrets.shared.delete(key)
        } else {
            try AppSecrets.shared.set(trimmed, for: key)
        }
    }

    private func saveAll() {
        do {
            try storeSecret(geminiKey, for: .geminiAPIKey)
            try storeSecret(openAIKey, for: .openAIAPIKey)
            try storeSecret(chatPrefs.openAIBaseURL, for: .openAIBaseURL)
            try storeSecret(chatPrefs.ollamaBaseURL, for: .ollamaBaseURL)
            try storeSecret(pexelsKey, for: .pexelsAPIKey)
            try storeSecret(pixabayKey, for: .pixabayAPIKey)
            try storeSecret(comfyToken, for: .comfyAuthToken)
            try storeSecret(comfyCFId, for: .comfyCFClientId)
            try storeSecret(comfyCFSecret, for: .comfyCFClientSecret)
            chatPrefs.save()
            comfyPrefs.save()
            speechPrefs.save()
            vlmPrefs.save()
            savedBanner = "Saved securely."
        } catch {
            savedBanner = "Save failed: \(error.localizedDescription)"
        }
    }

    private func testComfy() {
        saveAll()
        testingComfy = true
        comfyTestResult = nil
        let target = comfyPrefs.endpointURL
        Task {
            let res = await ComfyConnectionPrefs.testEndpoint(target)
            comfyTestResult = (res.ok, res.message)
            testingComfy = false
        }
    }
}
