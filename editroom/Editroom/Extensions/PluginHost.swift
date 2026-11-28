import Foundation

struct PluginMCPConfig: Codable, Equatable, Sendable {
    var command: String
    var args: [String]
    var envKeys: [String]?
}

struct PluginManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var mcp: PluginMCPConfig?
    var luts: [String]?
    var workflows: [String]?
    var skills: [String]?
}

struct InstalledPlugin: Codable, Equatable, Identifiable, Sendable {
    var id: String { manifest.id }
    var manifest: PluginManifest
    var installDir: String
    var source: String
    var enabled: Bool
    var trustedForExecution: Bool
    var installedAt: Date
    var commitSHA: String?
}

enum PluginError: Error, LocalizedError, Equatable {
    case invalidManifest(String)
    case pathTraversal(String)
    case untrustedExecution(String)
    case notFound(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let msg), .untrustedExecution(let msg), .notFound(let msg), .processFailed(let msg):
            return msg
        case .pathTraversal(let path):
            return "Plugin path escapes plugin directory: \(path)"
        }
    }
}

/// Manages a Tier A stdio JSON-RPC 2.0 MCP sidecar subprocess off `@MainActor` (`I6`).
final class StdioMCPProcess: @unchecked Sendable {
    let command: String
    let args: [String]
    let workingDir: URL
    let extraEnv: [String: String]

    private let ioQueue = DispatchQueue(label: "local.editroom.plugin.stdio", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestId = 1
    private var pending: [Int: (CheckedContinuation<[String: Any], Error>, DispatchWorkItem)] = [:]
    private(set) var cachedTools: [[String: Any]] = []

    init(command: String, args: [String], workingDir: URL, extraEnv: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.workingDir = workingDir
        self.extraEnv = extraEnv
    }

    var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    var isRunning: Bool { pid != nil }

    func startAndInitialize() async throws {
        lock.lock()
        let alreadyRunning = process?.isRunning == true
        lock.unlock()
        if alreadyRunning { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args
        p.currentDirectoryURL = workingDir
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.failAllPending(PluginError.processFailed("Plugin process closed stdout."))
                return
            }
            self.ingest(chunk)
        }
        p.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            self?.failAllPending(PluginError.processFailed("Plugin process terminated."))
        }

        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            throw PluginError.processFailed("Failed to launch plugin '\(command)': \(error.localizedDescription)")
        }

        lock.lock()
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        lock.unlock()

        _ = try await sendRPC(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Editroom", "version": "1.0"],
        ])
        sendNotification(method: "notifications/initialized", params: [:])
        let listRes = try await sendRPC(method: "tools/list", params: [:])
        let tools = (listRes["tools"] as? [[String: Any]]) ?? []
        lock.lock()
        cachedTools = tools
        lock.unlock()
    }

    func listTools() async throws -> [[String: Any]] {
        if !isRunning { try await startAndInitialize() }
        lock.lock()
        let tools = cachedTools
        lock.unlock()
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [[String: Any]] {
        if !isRunning { try await startAndInitialize() }
        let res = try await sendRPC(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        if (res["isError"] as? Bool) == true {
            let msg = ((res["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "Plugin tool '\(name)' failed."
            throw PluginError.processFailed(msg)
        }
        return (res["content"] as? [[String: Any]]) ?? []
    }

    func stop() {
        lock.lock()
        let proc = process
        let inHandle = stdinHandle
        process = nil
        stdinHandle = nil
        lock.unlock()

        try? inHandle?.close()
        failAllPending(PluginError.processFailed("Plugin stopped."))

        guard let proc, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        let deadline = Date().addingTimeInterval(0.3)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            Darwin.kill(pid, SIGKILL)
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]) else { return }
        var line = data
        line.append(0x0A)
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        ioQueue.async {
            try? handle?.write(contentsOf: line)
        }
    }

    private func sendRPC(method: String, params: [String: Any], timeoutSeconds: Double = 15) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            let reqId = nextRequestId
            nextRequestId += 1
            guard let handle = stdinHandle else {
                lock.unlock()
                cont.resume(throwing: PluginError.processFailed("Plugin stdin not open."))
                return
            }

            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let removed = self.pending.removeValue(forKey: reqId)
                self.lock.unlock()
                removed?.0.resume(throwing: PluginError.processFailed("Plugin RPC '\(method)' timed out after \(Int(timeoutSeconds))s."))
            }
            pending[reqId] = (cont, timeoutItem)
            lock.unlock()

            ioQueue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": reqId,
                "method": method,
                "params": params,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
                lock.lock()
                let removed = pending.removeValue(forKey: reqId)
                lock.unlock()
                removed?.1.cancel()
                removed?.0.resume(throwing: PluginError.processFailed("Failed to encode RPC request."))
                return
            }
            var line = json
            line.append(0x0A)
            ioQueue.async {
                do {
                    try handle.write(contentsOf: line)
                } catch {
                    self.lock.lock()
                    let removed = self.pending.removeValue(forKey: reqId)
                    self.lock.unlock()
                    removed?.1.cancel()
                    removed?.0.resume(throwing: PluginError.processFailed("Write failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func ingest(_ chunk: Data) {
        lock.lock()
        stdoutBuffer.append(chunk)
        var lines: [Data] = []
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<nl])
            stdoutBuffer.removeSubrange(...nl)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            lock.lock()
            let entry = pending.removeValue(forKey: id)
            lock.unlock()
            guard let (cont, timer) = entry else { continue }
            timer.cancel()
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: PluginError.processFailed((err["message"] as? String) ?? "JSON-RPC error"))
            } else {
                cont.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
            }
        }
    }

    private func failAllPending(_ error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, pair) in all {
            pair.1.cancel()
            pair.0.resume(throwing: error)
        }
    }
}

/// Coordinates Tier A (MCP Sidecar) and Tier B (LUT, ComfyUI Workflow, Skill Bundle) plugins (`HybridStorage.subdir("Plugins")`).
@MainActor
final class PluginHost: ObservableObject {
    static let shared = PluginHost()

    let baseDir: URL
    private var indexURL: URL { baseDir.appendingPathComponent("plugins_index.json") }

    @Published private(set) var plugins: [InstalledPlugin] = []
    private var processes: [String: StdioMCPProcess] = [:]

    init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? HybridStorage.subdir("Plugins")
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: indexURL),
              let parsed = try? JSONDecoder().decode([InstalledPlugin].self, from: data) else {
            plugins = []
            return
        }
        plugins = parsed
    }

    private func saveIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plugins)
        try HybridStorage.writeAtomicVerified(data, to: indexURL)
    }

    @discardableResult
    func installFromLocal(directory: URL, sourceLabel: String? = nil, commitSHA: String? = nil) throws -> InstalledPlugin {
        let fm = FileManager.default
        let sourceDir = directory.standardizedFileURL
        do {
            try SafePath.validateDirectoryTree(root: sourceDir)
        } catch let err as SkillError {
            if case .pathTraversal(let p) = err { throw PluginError.pathTraversal(p) }
            throw err
        }

        let manifestURL = sourceDir.appendingPathComponent("plugin.json")
        guard fm.fileExists(atPath: manifestURL.path),
              let raw = try? Data(contentsOf: manifestURL) else {
            throw PluginError.invalidManifest("Missing plugin.json in \(sourceDir.lastPathComponent).")
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: raw)
        } catch {
            throw PluginError.invalidManifest("Invalid plugin.json: \(error.localizedDescription)")
        }
        guard manifest.schemaVersion == 1 else {
            throw PluginError.invalidManifest("Unsupported plugin schemaVersion \(manifest.schemaVersion); expected 1.")
        }
        guard SafePath.isValidSlug(manifest.id) else {
            throw PluginError.invalidManifest("Invalid plugin id '\(manifest.id)'.")
        }

        // Validate every declared Tier B asset stays inside plugin root and exists.
        let declaredPaths = (manifest.luts ?? []) + (manifest.workflows ?? []) + (manifest.skills ?? [])
        for rel in declaredPaths {
            let resolved: URL
            do {
                resolved = try SafePath.safeResolve(relative: rel, inside: sourceDir)
            } catch {
                throw PluginError.pathTraversal(rel)
            }
            guard fm.fileExists(atPath: resolved.path) else {
                throw PluginError.invalidManifest("Declared plugin asset missing: \(rel)")
            }
        }
        if let mcp = manifest.mcp, mcp.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PluginError.invalidManifest("MCP command must not be empty.")
        }

        let destDir = baseDir.appendingPathComponent(manifest.id, isDirectory: true)
        stopMCP(id: manifest.id)
        try? fm.removeItem(at: destDir)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceDir, to: destDir)
        try? fm.removeItem(at: destDir.appendingPathComponent(".git"))

        // Tier A executable MCP plugins default to untrusted + disabled until explicit user consent.
        let isTierA = manifest.mcp != nil
        let installed = InstalledPlugin(
            manifest: manifest,
            installDir: destDir.path,
            source: sourceLabel ?? sourceDir.path,
            enabled: !isTierA,
            trustedForExecution: !isTierA,
            installedAt: Date(),
            commitSHA: commitSHA
        )
        plugins.removeAll { $0.id == installed.id }
        plugins.append(installed)
        plugins.sort { $0.id < $1.id }
        try saveIndex()
        return installed
    }

    @discardableResult
    func installFromGitHub(_ rawURL: String, gitRunner: GitRunner = .system) async throws -> InstalledPlugin {
        let spec = try GitHubSpec.parse(rawURL)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("editroom-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sha = try await gitRunner.clonePinned(spec, to: tmp)
        let targetDir = try spec.subpath.map { try SafePath.safeResolve(relative: $0, inside: tmp) } ?? tmp
        return try installFromLocal(directory: targetDir, sourceLabel: "github:\(spec.canonicalRepo)", commitSHA: sha)
    }

    func trustAndEnable(id: String) throws {
        guard let idx = plugins.firstIndex(where: { $0.id == id }) else {
            throw PluginError.notFound("Plugin '\(id)' not found.")
        }
        plugins[idx].trustedForExecution = true
        plugins[idx].enabled = true
        try saveIndex()
    }

    func setEnabled(id: String, enabled: Bool) throws {
        guard let idx = plugins.firstIndex(where: { $0.id == id }) else {
            throw PluginError.notFound("Plugin '\(id)' not found.")
        }
        if enabled, plugins[idx].manifest.mcp != nil, !plugins[idx].trustedForExecution {
            throw PluginError.untrustedExecution("Plugin '\(id)' requires explicit trust confirmation before enabling.")
        }
        plugins[idx].enabled = enabled
        if !enabled { stopMCP(id: id) }
        try saveIndex()
    }

    func remove(id: String) throws {
        guard let idx = plugins.firstIndex(where: { $0.id == id }) else {
            throw PluginError.notFound("Plugin '\(id)' not found.")
        }
        stopMCP(id: id)
        let removed = plugins.remove(at: idx)
        try? FileManager.default.removeItem(atPath: removed.installDir)
        try saveIndex()
    }

    // MARK: Tier B Assets

    func activeLUTPaths() -> [(name: String, path: String)] {
        var out: [(String, String)] = []
        for plugin in plugins where plugin.enabled {
            let root = URL(fileURLWithPath: plugin.installDir)
            for rel in plugin.manifest.luts ?? [] {
                if let url = try? SafePath.safeResolve(relative: rel, inside: root) {
                    out.append((url.deletingPathExtension().lastPathComponent, url.path))
                }
            }
        }
        return out
    }

    func activeComfyWorkflowPaths() -> [(name: String, path: String)] {
        var out: [(String, String)] = []
        for plugin in plugins where plugin.enabled {
            let root = URL(fileURLWithPath: plugin.installDir)
            for rel in plugin.manifest.workflows ?? [] {
                if let url = try? SafePath.safeResolve(relative: rel, inside: root) {
                    out.append((url.deletingPathExtension().lastPathComponent, url.path))
                }
            }
        }
        return out
    }

    func activeSkillDirectories() -> [URL] {
        var out: [URL] = []
        for plugin in plugins where plugin.enabled {
            let root = URL(fileURLWithPath: plugin.installDir)
            for rel in plugin.manifest.skills ?? [] {
                if let url = try? SafePath.safeResolve(relative: rel, inside: root) {
                    out.append(url)
                }
            }
        }
        return out
    }

    // MARK: Tier A MCP Sidecar Lifecycle

    private func makeProcess(for plugin: InstalledPlugin) throws -> StdioMCPProcess {
        guard let mcp = plugin.manifest.mcp else {
            throw PluginError.invalidManifest("Plugin '\(plugin.id)' does not declare an MCP server.")
        }
        let root = URL(fileURLWithPath: plugin.installDir)
        let cmd: String
        if mcp.command.hasPrefix("/") {
            cmd = mcp.command
        } else {
            cmd = try SafePath.safeResolve(relative: mcp.command, inside: root).path
        }
        var env: [String: String] = [:]
        for key in mcp.envKeys ?? [] {
            if let val = try? AppSecrets.shared.get(forKey: key) {
                env[key] = val
            }
        }
        return StdioMCPProcess(command: cmd, args: mcp.args, workingDir: root, extraEnv: env)
    }

    func startMCP(id: String) async throws {
        guard let plugin = plugins.first(where: { $0.id == id }) else {
            throw PluginError.notFound("Plugin '\(id)' not found.")
        }
        guard plugin.trustedForExecution, plugin.enabled else {
            throw PluginError.untrustedExecution("Plugin '\(id)' is not trusted/enabled for execution.")
        }
        if let existing = processes[id], existing.isRunning { return }
        let proc = try makeProcess(for: plugin)
        processes[id] = proc
        try await proc.startAndInitialize()
    }

    func stopMCP(id: String) {
        if let proc = processes.removeValue(forKey: id) {
            proc.stop()
        }
    }

    func stopAll() {
        for (_, proc) in processes { proc.stop() }
        processes.removeAll()
    }

    func activeMCPProcessPid(id: String) -> Int32? {
        processes[id]?.pid
    }

    func listPluginTools(id: String) async throws -> [[String: Any]] {
        try await startMCP(id: id)
        guard let proc = processes[id] else { return [] }
        let raw = try await proc.listTools()
        return raw.map { tool in
            var copy = tool
            if let name = tool["name"] as? String {
                copy["name"] = "plugin.\(id).\(name)"
            }
            return copy
        }
    }

    func callNamespacedTool(_ namespacedName: String, arguments: [String: Any]) async throws -> [[String: Any]] {
        let parts = namespacedName.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "plugin" else {
            throw PluginError.invalidManifest("Invalid namespaced tool '\(namespacedName)'; expected plugin.<id>.<tool>.")
        }
        let pluginId = parts[1], rawTool = parts[2]
        try await startMCP(id: pluginId)
        guard let proc = processes[pluginId] else {
            throw PluginError.processFailed("MCP sidecar for '\(pluginId)' is not running.")
        }
        return try await proc.callTool(name: rawTool, arguments: arguments)
    }
}
