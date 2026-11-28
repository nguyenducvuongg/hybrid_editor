import Foundation

enum TunnelError: Error, LocalizedError, Equatable {
    case invalidCommand(String)
    case invalidEndpoint(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand(let msg), .invalidEndpoint(let msg), .launchFailed(let msg):
            return msg
        }
    }
}

/// Manages ComfyUI transport across Cloudflare Tunnel, Tailscale, and SSH Tunnel (`I6`).
final class TunnelManager: @unchecked Sendable {
    static let shared = TunnelManager()

    private let lock = NSLock()
    private var managedProcess: Process?
    private var lastCommandKey: String?

    var activePid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = managedProcess, p.isRunning else { return nil }
        return p.processIdentifier
    }

    static func parseSafeSSHArguments(_ rawCommand: String) throws -> (executable: String, arguments: [String]) {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TunnelError.invalidCommand("SSH/Tunnel command must not be empty.")
        }
        let forbidden = CharacterSet(charactersIn: ";|&$`><\n\r")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw TunnelError.invalidCommand("Shell operators (; | & $ ` > <) are not permitted in tunnel commands.")
        }

        // Tokenize preserving simple single/double quotes cleanly.
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        for ch in trimmed {
            if let q = activeQuote {
                if ch == q {
                    activeQuote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                activeQuote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        guard activeQuote == nil else {
            throw TunnelError.invalidCommand("Unterminated quote in tunnel command.")
        }
        if !current.isEmpty { tokens.append(current) }
        guard let binary = tokens.first else {
            throw TunnelError.invalidCommand("Tunnel command has no executable.")
        }

        let resolvedExec: String
        switch binary {
        case "ssh", "/usr/bin/ssh":
            resolvedExec = "/usr/bin/ssh"
        case "cloudflared", "/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared":
            let fm = FileManager.default
            let found = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
                .first { fm.isExecutableFile(atPath: $0) }
            guard let found else {
                throw TunnelError.invalidCommand("cloudflared binary not found in /opt/homebrew/bin or /usr/local/bin.")
            }
            resolvedExec = found
        default:
            throw TunnelError.invalidCommand("Only 'ssh' or 'cloudflared' executables are allowed for managed tunnels.")
        }
        return (resolvedExec, Array(tokens.dropFirst()))
    }

    func effectiveBaseURL(for prefs: ComfyConnectionPrefs) throws -> URL {
        if prefs.mode == .ssh {
            let port = (1024...65535).contains(prefs.localPort) ? prefs.localPort : 8188
            guard let url = URL(string: "http://127.0.0.1:\(port)") else {
                throw TunnelError.invalidEndpoint("Invalid local SSH tunnel port \(port).")
            }
            return url
        }
        let cleaned = prefs.endpointURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: cleaned),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw TunnelError.invalidEndpoint("Invalid ComfyUI endpoint '\(prefs.endpointURL)'.")
        }
        return url
    }

    func ensureTunnel(for prefs: ComfyConnectionPrefs) throws {
        guard prefs.mode == .ssh else { return }
        let cmd = prefs.sshCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else {
            throw TunnelError.invalidCommand("SSH mode requires an SSH tunnel command (or configure Cloudflare/Tailscale).")
        }
        let parsed = try Self.parseSafeSSHArguments(cmd)

        lock.lock()
        let alreadyUp = managedProcess?.isRunning == true && lastCommandKey == cmd
        lock.unlock()
        if alreadyUp { return }

        stop()
        _ = try startManagedProcess(executable: parsed.executable, arguments: parsed.arguments, commandKey: cmd)
    }

    @discardableResult
    func startManagedProcess(executable: String, arguments: [String], commandKey: String? = nil) throws -> Int32 {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw TunnelError.launchFailed("Failed to launch tunnel: \(error.localizedDescription)")
        }
        lock.lock()
        managedProcess = p
        lastCommandKey = commandKey ?? executable
        lock.unlock()
        return p.processIdentifier
    }

    func stop() {
        lock.lock()
        let p = managedProcess
        managedProcess = nil
        lastCommandKey = nil
        lock.unlock()

        guard let p, p.isRunning else { return }
        let pid = p.processIdentifier
        p.terminate()
        let deadline = Date().addingTimeInterval(0.3)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if p.isRunning {
            Darwin.kill(pid, SIGKILL)
        }
    }
}
