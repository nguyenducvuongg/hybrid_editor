import Foundation

enum ComfyMediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
    case audio
}

/// Curated workflow gallery entry exposed to Settings UI, Agent Chat, and `comfy_status`.
struct ComfyWorkflowPreset: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: ComfyMediaKind
    var badge: String
    var description: String
    var defaultWidth: Int
    var defaultHeight: Int
    var defaultFrames: Int
    var defaultSteps: Int
    var recommendedVRAMGB: Int
}

/// Structured event decoded from ComfyUI `/ws?clientId=...` messages.
enum ComfyWSEvent: Equatable, Sendable {
    case executionStart(promptId: String?)
    case executing(node: String?)
    case progress(value: Int, max: Int, node: String?)
    case executionError(message: String)
}

/// Live ComfyUI generation progress snapshot observed by `AgentChatPanel`.
struct ComfyProgressState: Equatable, Sendable {
    var isRunning: Bool = false
    var promptId: String? = nil
    var workflowName: String = ""
    var phase: String = "Idle"
    var step: Int = 0
    var maxSteps: Int = 0
    var nodeName: String? = nil

    var fraction: Double {
        guard maxSteps > 0 else { return 0 }
        return min(1.0, max(0.0, Double(step) / Double(maxSteps)))
    }
}

/// Observable realtime WebSocket progress hub for active ComfyUI generations (`I6`).
@MainActor
final class ComfyProgressMonitor: ObservableObject {
    static let shared = ComfyProgressMonitor()
    @Published private(set) var state = ComfyProgressState()

    func begin(workflowName: String) {
        state = ComfyProgressState(isRunning: true, promptId: nil, workflowName: workflowName, phase: "Submitting prompt…", step: 0, maxSteps: 0, nodeName: nil)
    }

    func update(phase: String, promptId: String? = nil, step: Int? = nil, maxSteps: Int? = nil, nodeName: String? = nil) {
        var next = state
        next.isRunning = true
        next.phase = phase
        if let promptId { next.promptId = promptId }
        if let step { next.step = step }
        if let maxSteps { next.maxSteps = maxSteps }
        if let nodeName { next.nodeName = nodeName }
        state = next
    }

    func apply(event: ComfyWSEvent) {
        var next = state
        next.isRunning = true
        switch event {
        case .executionStart(let pid):
            next.phase = "Executing workflow…"
            if let pid { next.promptId = pid }
        case .executing(let node):
            next.nodeName = node
            if let node, !node.isEmpty {
                next.phase = "Running node \(node)…"
            } else {
                next.phase = "Finalizing output…"
            }
        case .progress(let val, let maxVal, let node):
            next.step = max(0, val)
            next.maxSteps = max(0, maxVal)
            next.nodeName = node ?? next.nodeName
            next.phase = maxVal > 0 ? "Denoising step \(val)/\(maxVal)" : "Processing…"
        case .executionError(let msg):
            next.phase = "Error: \(msg)"
        }
        state = next
    }

    func finish() {
        state = ComfyProgressState()
    }
}

struct ComfySystemStatus: Codable, Equatable, Sendable {
    var endpoint: String
    var mode: String
    var online: Bool
    var gpuName: String?
    var vramTotalMB: Int?
    var vramFreeMB: Int?
    var availableWorkflows: [String]
    var checkpoints: [String]
    var galleryPresets: [ComfyWorkflowPreset] = ComfyUIClient.galleryPresets
    var errorMessage: String?
}

struct ComfyGenerationRequest: @unchecked Sendable {
    var kind: ComfyMediaKind
    var prompt: String
    var negativePrompt: String
    var workflowNameOrPath: String?
    var rawWorkflowJSON: [String: Any]?
    var width: Int
    var height: Int
    var frames: Int
    var steps: Int?
    var seed: Int
    var referenceImagePNG: Data?
    var referenceFilename: String?

    init(
        kind: ComfyMediaKind,
        prompt: String,
        negativePrompt: String = "blurry, low quality, distorted",
        workflowNameOrPath: String? = nil,
        rawWorkflowJSON: [String: Any]? = nil,
        width: Int = 1024,
        height: Int = 576,
        frames: Int = 25,
        steps: Int? = nil,
        seed: Int = Int.random(in: 1...Int(Int32.max)),
        referenceImagePNG: Data? = nil,
        referenceFilename: String? = nil
    ) {
        self.kind = kind
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.workflowNameOrPath = workflowNameOrPath
        self.rawWorkflowJSON = rawWorkflowJSON
        self.width = width
        self.height = height
        self.frames = frames
        self.steps = steps
        self.seed = seed
        self.referenceImagePNG = referenceImagePNG
        self.referenceFilename = referenceFilename
    }
}

struct ComfyGenerationResult: Sendable {
    var promptId: String
    var kind: ComfyMediaKind
    var localURL: URL
    var filename: String
    var seed: Int
    var workflowName: String
}

enum ComfyError: Error, LocalizedError {
    case invalidEndpoint(String)
    case invalidWorkflow(String)
    case httpError(Int, String)
    case generationFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let msg), .invalidWorkflow(let msg), .generationFailed(let msg):
            return msg
        case .httpError(let code, let body):
            return "ComfyUI HTTP \(code): \(body.prefix(240))"
        case .timeout:
            return "ComfyUI generation timed out."
        }
    }
}

/// REST + WebSocket ComfyUI client supporting Google Colab Cloudflare/Tailscale/SSH tunnels (`I6`).
final class ComfyUIClient: @unchecked Sendable {
    static let shared = ComfyUIClient()

    var workflowsDir: URL { HybridStorage.subdir("ComfyWorkflows") }

    // MARK: Workflow Discovery & Template Binding

    func listSavedWorkflows(pluginWorkflows: [(name: String, path: String)] = []) -> [(name: String, path: String)] {
        var rows: [(String, String)] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: workflowsDir, includingPropertiesForKeys: nil) {
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension.lowercased() == "json" {
                rows.append((f.deletingPathExtension().lastPathComponent, f.path))
            }
        }
        rows.append(contentsOf: pluginWorkflows)
        return rows
    }

    static let galleryPresets: [ComfyWorkflowPreset] = [
        ComfyWorkflowPreset(
            id: "flux_schnell",
            name: "Flux.1 Schnell",
            kind: .image,
            badge: "4 Steps · Fast",
            description: "High-speed B-roll stills via FLUX.1-schnell (Euler/Simple 4 steps, CFG 1.0).",
            defaultWidth: 1024,
            defaultHeight: 1024,
            defaultFrames: 1,
            defaultSteps: 4,
            recommendedVRAMGB: 8
        ),
        ComfyWorkflowPreset(
            id: "flux_dev",
            name: "Flux.1 Dev",
            kind: .image,
            badge: "24 Steps · Quality",
            description: "Studio stills with fine Vietnamese cultural/product detail via FLUX.1-dev.",
            defaultWidth: 1024,
            defaultHeight: 1024,
            defaultFrames: 1,
            defaultSteps: 24,
            recommendedVRAMGB: 12
        ),
        ComfyWorkflowPreset(
            id: "wan21_i2v",
            name: "Wan2.1 I2V",
            kind: .video,
            badge: "Video I2V · 49f",
            description: "Image-to-Video animation from captured timeline frame or key visual.",
            defaultWidth: 832,
            defaultHeight: 480,
            defaultFrames: 49,
            defaultSteps: 20,
            recommendedVRAMGB: 16
        ),
        ComfyWorkflowPreset(
            id: "stable_audio_sfx",
            name: "Stable Audio / SFX",
            kind: .audio,
            badge: "Audio · SFX/BGM",
            description: "Procedural ambient sound effects and short stingers synchronized to cuts.",
            defaultWidth: 512,
            defaultHeight: 512,
            defaultFrames: 1,
            defaultSteps: 50,
            recommendedVRAMGB: 8
        ),
    ]

    static func galleryTemplate(id rawID: String) -> [String: Any]? {
        let key = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "gallery:", with: "")
            .lowercased()
        switch key {
        case "flux_schnell":
            return [
                "3": [
                    "class_type": "KSampler",
                    "inputs": [
                        "seed": "{{seed}}",
                        "steps": "{{steps}}",
                        "cfg": 1.0,
                        "sampler_name": "euler",
                        "scheduler": "simple",
                        "denoise": 1.0,
                        "model": ["4", 0],
                        "positive": ["6", 0],
                        "negative": ["7", 0],
                        "latent_image": ["5", 0],
                    ],
                ],
                "4": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": "{{checkpoint}}"]],
                "5": ["class_type": "EmptySD3LatentImage", "inputs": ["width": "{{width}}", "height": "{{height}}", "batch_size": 1]],
                "6": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{prompt}}", "clip": ["4", 1]]],
                "7": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{negative_prompt}}", "clip": ["4", 1]]],
                "8": ["class_type": "VAEDecode", "inputs": ["samples": ["3", 0], "vae": ["4", 2]]],
                "9": ["class_type": "SaveImage", "inputs": ["filename_prefix": "editroom_flux_schnell", "images": ["8", 0]]],
            ]
        case "flux_dev":
            return [
                "3": [
                    "class_type": "KSampler",
                    "inputs": [
                        "seed": "{{seed}}",
                        "steps": "{{steps}}",
                        "cfg": 3.5,
                        "sampler_name": "euler",
                        "scheduler": "beta",
                        "denoise": 1.0,
                        "model": ["4", 0],
                        "positive": ["6", 0],
                        "negative": ["7", 0],
                        "latent_image": ["5", 0],
                    ],
                ],
                "4": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": "{{checkpoint}}"]],
                "5": ["class_type": "EmptySD3LatentImage", "inputs": ["width": "{{width}}", "height": "{{height}}", "batch_size": 1]],
                "6": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{prompt}}", "clip": ["4", 1]]],
                "7": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{negative_prompt}}", "clip": ["4", 1]]],
                "8": ["class_type": "VAEDecode", "inputs": ["samples": ["3", 0], "vae": ["4", 2]]],
                "9": ["class_type": "SaveImage", "inputs": ["filename_prefix": "editroom_flux_dev", "images": ["8", 0]]],
            ]
        case "wan21_i2v":
            return [
                "1": ["class_type": "LoadImage", "inputs": ["image": "{{input_image}}"]],
                "2": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": "{{checkpoint}}"]],
                "3": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{prompt}}", "clip": ["2", 1]]],
                "4": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{negative_prompt}}", "clip": ["2", 1]]],
                "5": [
                    "class_type": "WanImageToVideo",
                    "inputs": [
                        "width": "{{width}}",
                        "height": "{{height}}",
                        "length": "{{frames}}",
                        "batch_size": 1,
                        "positive": ["3", 0],
                        "negative": ["4", 0],
                        "start_image": ["1", 0],
                    ],
                ],
                "6": [
                    "class_type": "KSampler",
                    "inputs": [
                        "seed": "{{seed}}",
                        "steps": "{{steps}}",
                        "cfg": 6.0,
                        "sampler_name": "uni_pc",
                        "scheduler": "simple",
                        "denoise": 1.0,
                        "model": ["2", 0],
                        "positive": ["5", 0],
                        "negative": ["5", 1],
                        "latent_image": ["5", 2],
                    ],
                ],
                "7": ["class_type": "VAEDecode", "inputs": ["samples": ["6", 0], "vae": ["2", 2]]],
                "8": ["class_type": "SaveWEBM", "inputs": ["filename_prefix": "editroom_wan21_i2v", "images": ["7", 0], "fps": 16]],
            ]
        case "stable_audio_sfx":
            return [
                "1": ["class_type": "EmptyLatentAudio", "inputs": ["seconds": 8.0, "batch_size": 1]],
                "2": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{prompt}}"]],
                "3": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{negative_prompt}}"]],
                "4": [
                    "class_type": "KSampler",
                    "inputs": [
                        "seed": "{{seed}}",
                        "steps": "{{steps}}",
                        "cfg": 7.0,
                        "sampler_name": "dpmpp_3m_sde",
                        "scheduler": "exponential",
                        "denoise": 1.0,
                        "positive": ["2", 0],
                        "negative": ["3", 0],
                        "latent_image": ["1", 0],
                    ],
                ],
                "5": ["class_type": "SaveAudio", "inputs": ["filename_prefix": "editroom_sfx", "audio": ["4", 0]]],
            ]
        default:
            return nil
        }
    }

    @discardableResult
    func exportGalleryPreset(id: String) throws -> URL {
        guard let template = Self.galleryTemplate(id: id) else {
            throw ComfyError.invalidWorkflow("Unknown ComfyUI gallery preset '\(id)'.")
        }
        try FileManager.default.createDirectory(at: workflowsDir, withIntermediateDirectories: true)
        let slug = id.replacingOccurrences(of: "gallery:", with: "").lowercased()
        let dest = workflowsDir.appendingPathComponent("\(slug).json")
        let data = try JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys])
        try HybridStorage.writeAtomicVerified(data, to: dest)
        return dest
    }

    static func builtInTemplate(for kind: ComfyMediaKind) -> [String: Any] {
        switch kind {
        case .image:
            return [
                "3": [
                    "class_type": "KSampler",
                    "inputs": [
                        "seed": "{{seed}}",
                        "steps": 20,
                        "cfg": 7.0,
                        "sampler_name": "euler",
                        "scheduler": "normal",
                        "denoise": 1.0,
                        "model": ["4", 0],
                        "positive": ["6", 0],
                        "negative": ["7", 0],
                        "latent_image": ["5", 0],
                    ],
                ],
                "4": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": "{{checkpoint}}"]],
                "5": ["class_type": "EmptyLatentImage", "inputs": ["width": "{{width}}", "height": "{{height}}", "batch_size": 1]],
                "6": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{prompt}}", "clip": ["4", 1]]],
                "7": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{negative_prompt}}", "clip": ["4", 1]]],
                "8": ["class_type": "VAEDecode", "inputs": ["samples": ["3", 0], "vae": ["4", 2]]],
                "9": ["class_type": "SaveImage", "inputs": ["filename_prefix": "editroom", "images": ["8", 0]]],
            ]
        case .video:
            return [
                "1": ["class_type": "LoadImage", "inputs": ["image": "{{input_image}}"]],
                "2": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{prompt}}"]],
                "3": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{negative_prompt}}"]],
                "4": ["class_type": "EmptyLatentImage", "inputs": ["width": "{{width}}", "height": "{{height}}", "length": "{{frames}}"]],
                "5": ["class_type": "KSampler", "inputs": ["seed": "{{seed}}", "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0]]],
                "6": ["class_type": "SaveAnimatedWEBP", "inputs": ["filename_prefix": "editroom_vid", "images": ["5", 0]]],
            ]
        case .audio:
            return [
                "1": ["class_type": "CLIPTextEncode", "inputs": ["text": "{{prompt}}"]],
                "2": ["class_type": "KSampler", "inputs": ["seed": "{{seed}}", "positive": ["1", 0]]],
                "3": ["class_type": "SaveAudio", "inputs": ["filename_prefix": "editroom_audio", "audio": ["2", 0]]],
            ]
        }
    }

    static func substitutePlaceholders(in value: Any, values: [String: Any]) -> Any {
        if let str = value as? String {
            if let exact = values[str] {
                return exact
            }
            var replaced = str
            for (k, v) in values {
                replaced = replaced.replacingOccurrences(of: k, with: "\(v)")
            }
            return replaced
        }
        if let arr = value as? [Any] {
            return arr.map { substitutePlaceholders(in: $0, values: values) }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = substitutePlaceholders(in: v, values: values)
            }
            return out
        }
        return value
    }

    // MARK: Auth & Status

    private func applyAuthHeaders(to req: inout URLRequest, secrets: any SecretStore) {
        if let token = try? secrets.get(.comfyAuthToken), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let cfId = try? secrets.get(.comfyCFClientId), !cfId.isEmpty,
           let cfSecret = try? secrets.get(.comfyCFClientSecret), !cfSecret.isEmpty {
            req.setValue(cfId, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(cfSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    func status(prefs: ComfyConnectionPrefs, secrets: any SecretStore = AppSecrets.shared) async -> ComfySystemStatus {
        let pluginWorkflows = await MainActor.run { PluginHost.shared.activeComfyWorkflowPaths() }
        let workflows = listSavedWorkflows(pluginWorkflows: pluginWorkflows).map(\.name)
            + Self.galleryPresets.map { "gallery:\($0.id)" }
            + ["built-in:image", "built-in:video", "built-in:audio"]

        let baseURL: URL
        do {
            try TunnelManager.shared.ensureTunnel(for: prefs)
            baseURL = try TunnelManager.shared.effectiveBaseURL(for: prefs)
        } catch {
            return ComfySystemStatus(
                endpoint: prefs.endpointURL,
                mode: prefs.mode.rawValue,
                online: false,
                gpuName: nil,
                vramTotalMB: nil,
                vramFreeMB: nil,
                availableWorkflows: workflows,
                checkpoints: [],
                errorMessage: error.localizedDescription
            )
        }

        var statsReq = URLRequest(url: baseURL.appendingPathComponent("system_stats"), timeoutInterval: 6)
        applyAuthHeaders(to: &statsReq, secrets: secrets)

        do {
            let (data, resp) = try await URLSession.shared.data(for: statsReq)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                return ComfySystemStatus(
                    endpoint: baseURL.absoluteString,
                    mode: prefs.mode.rawValue,
                    online: false,
                    gpuName: nil,
                    vramTotalMB: nil,
                    vramFreeMB: nil,
                    availableWorkflows: workflows,
                    checkpoints: [],
                    errorMessage: "HTTP \(code)"
                )
            }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let firstDevice = (obj["devices"] as? [[String: Any]])?.first
            let gpuName = firstDevice?["name"] as? String
            let vramTotal = (firstDevice?["vram_total"] as? NSNumber).map { Int($0.doubleValue / (1024 * 1024)) }
            let vramFree = (firstDevice?["vram_free"] as? NSNumber).map { Int($0.doubleValue / (1024 * 1024)) }
            let checkpoints = await fetchCheckpoints(baseURL: baseURL, secrets: secrets)

            return ComfySystemStatus(
                endpoint: baseURL.absoluteString,
                mode: prefs.mode.rawValue,
                online: true,
                gpuName: gpuName,
                vramTotalMB: vramTotal,
                vramFreeMB: vramFree,
                availableWorkflows: workflows,
                checkpoints: checkpoints,
                errorMessage: nil
            )
        } catch {
            return ComfySystemStatus(
                endpoint: baseURL.absoluteString,
                mode: prefs.mode.rawValue,
                online: false,
                gpuName: nil,
                vramTotalMB: nil,
                vramFreeMB: nil,
                availableWorkflows: workflows,
                checkpoints: [],
                errorMessage: error.localizedDescription
            )
        }
    }

    private func fetchCheckpoints(baseURL: URL, secrets: any SecretStore) async -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("object_info/CheckpointLoaderSimple"), timeoutInterval: 5)
        applyAuthHeaders(to: &req, secrets: secrets)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? -1),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = root["CheckpointLoaderSimple"] as? [String: Any],
              let input = node["input"] as? [String: Any],
              let required = input["required"] as? [String: Any],
              let ckptSpec = required["ckpt_name"] as? [Any],
              let names = ckptSpec.first as? [String] else {
            return []
        }
        return names
    }

    // MARK: Upload & Generation

    func uploadImage(pngData: Data, filename: String, baseURL: URL, secrets: any SecretStore = AppSecrets.shared) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        body.append(pngData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: baseURL.appendingPathComponent("upload/image"), timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &req, secrets: secrets)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw ComfyError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["name"] as? String, !name.isEmpty {
            return name
        }
        return filename
    }

    private func resolveWorkflowTemplate(request: ComfyGenerationRequest, pluginWorkflows: [(name: String, path: String)]) throws -> (name: String, graph: [String: Any]) {
        if let raw = request.rawWorkflowJSON {
            return (request.workflowNameOrPath ?? "inline", raw)
        }
        if let selector = request.workflowNameOrPath?.trimmingCharacters(in: .whitespacesAndNewlines), !selector.isEmpty {
            let candidates = listSavedWorkflows(pluginWorkflows: pluginWorkflows)
            if let match = candidates.first(where: { $0.name == selector || $0.path == selector }),
               let data = try? Data(contentsOf: URL(fileURLWithPath: match.path)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (match.name, json)
            }
            let directURL = URL(fileURLWithPath: (selector as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: directURL.path),
               let data = try? Data(contentsOf: directURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (directURL.deletingPathExtension().lastPathComponent, json)
            }
            if selector.hasPrefix("built-in:") {
                let k = ComfyMediaKind(rawValue: String(selector.dropFirst("built-in:".count))) ?? request.kind
                return (selector, Self.builtInTemplate(for: k))
            }
            if let galleryGraph = Self.galleryTemplate(id: selector) {
                let normalized = selector.hasPrefix("gallery:") ? selector : "gallery:\(selector)"
                return (normalized, galleryGraph)
            }
            throw ComfyError.invalidWorkflow("Workflow '\(selector)' not found.")
        }
        return ("built-in:\(request.kind.rawValue)", Self.builtInTemplate(for: request.kind))
    }

    func generate(
        _ request: ComfyGenerationRequest,
        prefs: ComfyConnectionPrefs,
        outputFolder: URL,
        secrets: any SecretStore = AppSecrets.shared,
        pollIntervalMs: UInt64 = 250,
        timeoutSeconds: Double = 300,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ComfyGenerationResult {
        try TunnelManager.shared.ensureTunnel(for: prefs)
        let baseURL = try TunnelManager.shared.effectiveBaseURL(for: prefs)

        var uploadedImageName = ""
        if let refPNG = request.referenceImagePNG {
            onProgress?("Uploading timeline reference frame…")
            uploadedImageName = try await uploadImage(
                pngData: refPNG,
                filename: request.referenceFilename ?? "editroom_ref_\(UUID().uuidString.prefix(8)).png",
                baseURL: baseURL,
                secrets: secrets
            )
        }

        let pluginWorkflows = await MainActor.run { PluginHost.shared.activeComfyWorkflowPaths() }
        let (wfName, rawGraph) = try resolveWorkflowTemplate(request: request, pluginWorkflows: pluginWorkflows)
        await MainActor.run { ComfyProgressMonitor.shared.begin(workflowName: wfName) }
        defer { Task { @MainActor in ComfyProgressMonitor.shared.finish() } }

        var resolvedCheckpoint = "model.safetensors"
        if wfName.hasPrefix("built-in:") || wfName.hasPrefix("gallery:") || String(describing: rawGraph).contains("{{checkpoint}}") {
            let ckpts = await fetchCheckpoints(baseURL: baseURL, secrets: secrets)
            if let firstCkpt = ckpts.first, !firstCkpt.isEmpty {
                resolvedCheckpoint = firstCkpt
            }
        }
        let defaultSteps = Self.galleryPresets.first(where: { wfName.contains($0.id) })?.defaultSteps ?? 20
        let stepCount = max(1, min(100, request.steps ?? defaultSteps))
        let values: [String: Any] = [
            "{{prompt}}": request.prompt,
            "{{negative_prompt}}": request.negativePrompt,
            "{{seed}}": request.seed,
            "{{width}}": request.width,
            "{{height}}": request.height,
            "{{frames}}": request.frames,
            "{{steps}}": stepCount,
            "{{input_image}}": uploadedImageName,
            "{{checkpoint}}": resolvedCheckpoint,
        ]
        guard let boundGraph = Self.substitutePlaceholders(in: rawGraph, values: values) as? [String: Any] else {
            throw ComfyError.invalidWorkflow("Failed to bind ComfyUI workflow parameters.")
        }

        let clientId = UUID().uuidString
        let promptPayload: [String: Any] = ["prompt": boundGraph, "client_id": clientId]
        var promptReq = URLRequest(url: baseURL.appendingPathComponent("prompt"), timeoutInterval: 30)
        promptReq.httpMethod = "POST"
        promptReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &promptReq, secrets: secrets)
        promptReq.httpBody = try JSONSerialization.data(withJSONObject: promptPayload)

        let (promptData, promptResp) = try await URLSession.shared.data(for: promptReq)
        let promptCode = (promptResp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(promptCode) else {
            throw ComfyError.httpError(promptCode, String(data: promptData, encoding: .utf8) ?? "")
        }
        guard let promptObj = try? JSONSerialization.jsonObject(with: promptData) as? [String: Any],
              let promptId = promptObj["prompt_id"] as? String, !promptId.isEmpty else {
            throw ComfyError.generationFailed("ComfyUI /prompt response missing prompt_id.")
        }

        // Open optional WebSocket progress monitor without failing if server only speaks HTTP.
        let wsTask = openProgressWebSocket(baseURL: baseURL, clientId: clientId, secrets: secrets, onProgress: onProgress)
        defer { wsTask?.cancel(with: .normalClosure, reason: nil) }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var matchedFile: (filename: String, subfolder: String, type: String)?

        while Date() < deadline {
            var histReq = URLRequest(url: baseURL.appendingPathComponent("history/\(promptId)"), timeoutInterval: 10)
            applyAuthHeaders(to: &histReq, secrets: secrets)
            if let (hData, hResp) = try? await URLSession.shared.data(for: histReq),
               (200..<300).contains((hResp as? HTTPURLResponse)?.statusCode ?? -1),
               let hRoot = try? JSONSerialization.jsonObject(with: hData) as? [String: Any],
               let entry = (hRoot[promptId] as? [String: Any]) ?? hRoot["outputs"].map({ ["outputs": $0] }),
               let outputs = entry["outputs"] as? [String: Any],
               let found = extractFirstOutput(outputs) {
                matchedFile = found
                break
            }
            try await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }

        guard let target = matchedFile else {
            throw ComfyError.timeout
        }

        guard var comps = URLComponents(url: baseURL.appendingPathComponent("view"), resolvingAgainstBaseURL: false) else {
            throw ComfyError.invalidEndpoint("Invalid /view URL.")
        }
        comps.queryItems = [
            URLQueryItem(name: "filename", value: target.filename),
            URLQueryItem(name: "subfolder", value: target.subfolder),
            URLQueryItem(name: "type", value: target.type),
        ]
        guard let viewURL = comps.url else { throw ComfyError.invalidEndpoint("Invalid /view query URL.") }

        var viewReq = URLRequest(url: viewURL, timeoutInterval: 120)
        applyAuthHeaders(to: &viewReq, secrets: secrets)
        let (fileData, fileResp) = try await URLSession.shared.data(for: viewReq)
        let viewCode = (fileResp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(viewCode), !fileData.isEmpty else {
            throw ComfyError.httpError(viewCode, "Empty or failed /view response")
        }

        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: target.filename).pathExtension.isEmpty ? defaultExtension(for: request.kind)
            : URL(fileURLWithPath: target.filename).pathExtension
        let safeStem = HybridStorage.truncateUTF8("comfy-\(String(promptId.prefix(8)))-\(URL(fileURLWithPath: target.filename).deletingPathExtension().lastPathComponent)", maxBytes: 120)
        let dest = outputFolder.appendingPathComponent("\(safeStem).\(ext)")
        try HybridStorage.writeAtomicVerified(fileData, to: dest)
        appendProvenance(to: outputFolder, filename: dest.lastPathComponent, request: request, promptId: promptId, workflowName: wfName)

        return ComfyGenerationResult(
            promptId: promptId,
            kind: request.kind,
            localURL: dest,
            filename: dest.lastPathComponent,
            seed: request.seed,
            workflowName: wfName
        )
    }

    private func defaultExtension(for kind: ComfyMediaKind) -> String {
        switch kind {
        case .image: "png"
        case .video: "mp4"
        case .audio: "wav"
        }
    }

    private func extractFirstOutput(_ outputs: [String: Any]) -> (String, String, String)? {
        let keys = ["videos", "gifs", "images", "audio"]
        for (_, nodeVal) in outputs {
            guard let nodeDict = nodeVal as? [String: Any] else { continue }
            for key in keys {
                if let items = nodeDict[key] as? [[String: Any]], let first = items.first,
                   let filename = first["filename"] as? String, !filename.isEmpty {
                    let sub = (first["subfolder"] as? String) ?? ""
                    let type = (first["type"] as? String) ?? "output"
                    return (filename, sub, type)
                }
            }
        }
        return nil
    }

    static func parseWebSocketEvent(_ text: String) -> ComfyWSEvent? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }
        let payload = obj["data"] as? [String: Any]
        switch type {
        case "execution_start":
            return .executionStart(promptId: payload?["prompt_id"] as? String)
        case "executing":
            return .executing(node: payload?["node"] as? String)
        case "progress":
            guard let v = payload?["value"] as? Int, let m = payload?["max"] as? Int else { return nil }
            return .progress(value: v, max: m, node: payload?["node"] as? String)
        case "execution_error":
            let msg = (payload?["exception_message"] as? String)
                ?? (payload?["error"] as? String)
                ?? "ComfyUI execution failed"
            return .executionError(message: msg)
        default:
            return nil
        }
    }

    private func openProgressWebSocket(
        baseURL: URL,
        clientId: String,
        secrets: any SecretStore,
        onProgress: (@Sendable (String) -> Void)?
    ) -> URLSessionWebSocketTask? {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "clientId", value: clientId)]
        guard let wsURL = comps.url else { return nil }
        var req = URLRequest(url: wsURL)
        applyAuthHeaders(to: &req, secrets: secrets)
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        Task.detached {
            while task.state == .running {
                guard let msg = try? await task.receive() else { break }
                if case .string(let txt) = msg, let event = Self.parseWebSocketEvent(txt) {
                    await MainActor.run { ComfyProgressMonitor.shared.apply(event: event) }
                    if let onProgress {
                        switch event {
                        case .progress(let v, let m, _):
                            onProgress("ComfyUI step \(v)/\(m)")
                        case .executing(let node):
                            if let node, !node.isEmpty { onProgress("Executing ComfyUI node \(node)…") }
                        case .executionStart:
                            onProgress("ComfyUI execution started…")
                        case .executionError(let err):
                            onProgress("ComfyUI error: \(err)")
                        }
                    }
                }
            }
        }
        return task
    }

    private func appendProvenance(to folder: URL, filename: String, request: ComfyGenerationRequest, promptId: String, workflowName: String) {
        let note = folder.appendingPathComponent("Sources.txt")
        let entry = """
        \(filename)
          Generated: \(ISO8601DateFormatter().string(from: Date()))
          Workflow: \(workflowName)
          Prompt ID: \(promptId)
          Seed: \(request.seed)
          Prompt: \(request.prompt)


        """
        if let h = try? FileHandle(forWritingTo: note) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        } else {
            try? entry.write(to: note, atomically: true, encoding: .utf8)
        }
    }
}
