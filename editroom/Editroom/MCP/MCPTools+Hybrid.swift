import AppKit
import AVFoundation
import CoreImage
import Foundation

extension MCPTools {
    static let hybridLifecycleTools: Set<String> = [
        "session_attach", "session_heartbeat", "session_release",
        "begin_agent_turn", "commit_agent_turn", "rollback_agent_turn",
    ]

    static let externalMutatingTools: Set<String> = [
        "import_media", "download_media", "add_clip", "add_title", "move_clip", "trim_clip",
        "set_speed", "set_speed_ramp", "set_captions", "split_clip", "delete_clips",
        "set_grade", "set_audio", "set_transition", "add_track", "set_sequence",
        "history", "auto_edit", "set_marker", "delete_markers", "set_in_out",
        "set_transform", "set_title_style", "freeze_frame", "reverse_clip",
        "detach_audio", "duplicate_clip", "set_track", "add_solid", "set_solid_color",
        "apply_edl_patch", "comfy_generate", "import_stock_media", "insert_broll_overlay",
        "generate_vietnamese_captions", "auto_duck_bgm", "beat_sync_cuts",
    ]

    static var hybridDefinitions: [[String: Any]] {
        [
            tool("session_attach", "Attach session lease",
                 "Acquires or refreshes the single-writer session lease (recovering expired or crashed clients automatically). Returns session_id, revision, and active_turn_id.",
                 ["session_id": str("Unique caller session identifier."),
                  "client_pid": ["type": "integer", "description": "OS PID of the client process (defaults to current process)."],
                  "grace_ms": ["type": "integer", "description": "Grace period in ms (clamped 5000...10000)."]]),
            tool("session_heartbeat", "Session heartbeat",
                 "Renews the active session lease before the grace period expires.",
                 ["session_id": str("Held session identifier."),
                  "client_pid": ["type": "integer", "description": "OS PID of the client process."]],
                 required: ["session_id"]),
            tool("session_release", "Release session lease",
                 "Releases the held write lease cleanly (rolling back any uncommitted AgentTurn owned by this session).",
                 ["session_id": str("Held session identifier.")],
                 required: ["session_id"]),
            tool("begin_agent_turn", "Begin AgentTurn",
                 "Opens a transactional AgentTurn so subsequent timeline edits group into a single Undo/Redo step (`I1`).",
                 ["turn_id": str("Unique turn identifier (1..64 bytes)."),
                  "summary": str("Short human-readable summary of the turn."),
                  "session_id": str("Optional held lease session_id.")],
                 required: ["turn_id", "summary"]),
            tool("commit_agent_turn", "Commit AgentTurn",
                 "Commits the active AgentTurn into 1 unified Undo step, increments project revision, and returns affected_clip_ids.",
                 ["turn_id": str("Active turn identifier."),
                  "session_id": str("Optional held lease session_id.")],
                 required: ["turn_id"]),
            tool("rollback_agent_turn", "Rollback AgentTurn",
                 "Discards the active uncommitted AgentTurn cleanly without pushing an Undo step or changing revision.",
                 ["turn_id": str("Active turn identifier."),
                  "session_id": str("Optional held lease session_id.")],
                 required: ["turn_id"]),
            tool("apply_edl_patch", "Apply EDL patch",
                 "Applies a batch of A-roll/B-roll EDL operations (`keep_ranges`, `delete_range`, `insert_overlay`) atomically.",
                 ["operations": ["type": "array", "description": "Ordered list of EDL operations.",
                                   "items": ["type": "object"]],
                  "session_id": str("Optional held lease session_id.")],
                 required: ["operations"]),
            tool("preview_timeline_strip", "Preview timeline strip",
                 "Renders a timestamp-labeled JPEG contact sheet across up to 12 timeline timestamps using the core compositor (`I3`, `P2`, zero UI chrome).",
                 ["timestamps": ["type": "array", "items": ["type": "number"], "description": "Timeline timestamps in seconds (1...12)."],
                  "width": ["type": "integer", "description": "Per-tile max width in pixels (160...640, default 320)."],
                  "grid_cols": ["type": "integer", "description": "Grid column count (1...4)."],
                  "output": str("Optional .jpg output path written atomically with size verification (`P7`).")],
                 required: ["timestamps"], readOnly: true),
            tool("list_skills", "List installed skills",
                 "Lists installed local and GitHub SKILL.md workflows with enabled status.",
                 readOnly: true),
            tool("list_plugins", "List installed plugins",
                 "Lists installed Tier A/B plugins with trust and enabled status plus active LUT/workflow paths.",
                 readOnly: true),
            tool("comfy_status", "ComfyUI Colab status",
                 "Checks ComfyUI connectivity over Cloudflare/Tailscale/SSH tunnel, returning GPU, VRAM, checkpoints, and available workflow templates.",
                 readOnly: true),
            tool("comfy_generate", "Generate media with ComfyUI",
                 "Generates an image, video, or audio asset on remote ComfyUI (optionally uploading a captured timeline frame for Image-to-Video) and imports it into the project returning asset_id.",
                 ["kind": str("Media kind: image, video, or audio."),
                  "prompt": str("Positive generation prompt."),
                  "negative_prompt": str("Optional negative prompt."),
                  "workflow": str("Optional saved workflow name, gallery preset (flux_schnell, flux_dev, wan21_i2v, stable_audio_sfx), or JSON path."),
                  "width": ["type": "integer", "description": "Output width in pixels."],
                  "height": ["type": "integer", "description": "Output height in pixels."],
                  "frames": ["type": "integer", "description": "Frame count for video workflows."],
                  "steps": ["type": "integer", "description": "Optional denoising step count (1...100)."],
                  "seed": ["type": "integer", "description": "Deterministic seed."],
                  "reference_clip_id": str("Optional clip_id whose frame at reference_time is uploaded for I2V."),
                  "reference_time": num("Timeline timestamp in seconds for reference_clip_id."),
                  "session_id": str("Optional held lease session_id.")],
                 required: ["kind", "prompt"]),
            tool("search_stock_media", "Search free stock media",
                 "Searches Pexels and Pixabay for free photos or videos, optionally returning a numbered JPEG contact sheet preview.",
                 ["query": str("Search keywords."),
                  "kind": str("Media kind: photos or videos (default videos)."),
                  "orientation": str("Optional orientation: any, landscape, portrait, square."),
                  "provider": str("Optional filter: pexels or pixabay."),
                  "per_page": ["type": "integer", "description": "Max items per provider (default 6)."],
                  "include_thumbnails": ["type": "boolean", "description": "Include numbered JPEG contact sheet of candidates (default true)."]],
                 required: ["query"], readOnly: true),
            tool("import_stock_media", "Import stock media item",
                 "Downloads and verifies a stock media candidate from Pexels/Pixabay, logs attribution in Sources.txt, and imports it into the project returning asset_id.",
                 ["stock_id": str("Optional cached stock_id from search_stock_media."),
                  "download_url": str("Direct https media URL if not passing stock_id."),
                  "kind": str("photos or videos (when using download_url)."),
                  "title": str("Title/filename label."),
                  "session_id": str("Optional held lease session_id.")]),
            tool("transcribe_aroll", "Transcribe A-roll with VAD",
                 "Detects active speech spans via AudioVAD (preventing silence hallucinations P6), runs Whisper.cpp or Apple Speech, and returns words plus suggested source keep_ranges.",
                 ["asset_id": str("Optional project asset UUID."),
                  "clip_id": str("Optional timeline clip UUID."),
                  "path": str("Optional local media file path."),
                  "language": str("Language code (default vi)."),
                  "min_silence_sec": num("Minimum silence gap to split cuts (default 0.7)."),
                  "pad_sec": num("Padding added around speech segments (default 0.1)."),
                  "vad_threshold_db": num("Optional VAD RMS threshold in dBFS (default -42).")],
                 readOnly: true),
            tool("index_broll_folder", "Index local B-roll folder",
                 "Extracts keyframes from a local B-roll folder off the main thread, describes them via Local VLM (or Apple Vision fallback), and updates the persistent SQLite3 FTS5 index.",
                 ["folder_path": str("Local directory path containing B-roll videos/images."),
                  "sample_interval_sec": num("Keyframe sampling interval in seconds (default 4.0)."),
                  "vlm_base_url": str("Optional OpenAI-compatible VLM base URL override."),
                  "vlm_model": str("Optional VLM model ID override."),
                  "use_apple_vision": ["type": "boolean", "description": "Use offline Apple Vision classifier directly (default false)."]],
                 required: ["folder_path"]),
            tool("search_broll", "Search local B-roll index",
                 "Searches the persistent SQLite3 FTS5 B-roll index (supports accented & unaccented Vietnamese + English) ranked by BM25, returning fallback_tier=2 when empty.",
                 ["query": str("Vietnamese or English scene/mood search query."),
                  "limit": ["type": "integer", "description": "Max hits to return (1...25, default 6)."]],
                 required: ["query"], readOnly: true),
            tool("insert_broll_overlay", "Insert B-roll overlay",
                 "Imports (if needed) and places a B-roll image/video overlay muted on V2+ inside the active AgentTurn (`I1`).",
                 ["asset_path": str("Local media path to import and overlay."),
                  "asset_id": str("Existing project asset UUID if already imported."),
                  "timeline_start": num("Timeline start position in seconds (default 0)."),
                  "source_start": num("Source in-point in seconds (default 0)."),
                  "duration": num("Overlay duration in seconds."),
                  "mute_audio": ["type": "boolean", "description": "Mute B-roll audio track (default true)."],
                  "track": str("Optional target video track name (defaults to free V2+)."),
                  "session_id": str("Optional held lease session_id.")]),
            tool("generate_vietnamese_captions", "Generate Vietnamese word-level captions",
                 "Generates or updates animated word-level Vietnamese captions with CapCut/Karaoke presets inside an AgentTurn (`I1`, `I3`).",
                 ["clip_ids": ["type": "array", "items": ["type": "string"], "description": "Target video/audio clip UUIDs (defaults to speaking clips)."],
                  "preset": ["type": "string", "enum": CaptionPreset.allCases.map(\.rawValue), "description": "Caption preset (capcut_yellow, karaoke_pill, neon_box, minimal_clean, classic)."],
                  "language": str("Transcript language code (default vi)."),
                  "max_words": ["type": "integer", "description": "Max words per caption block (1...8, overrides preset)."],
                  "size": num("Optional text size override (28...140)."),
                  "position": num("Optional vertical Y fraction (0.1...0.95)."),
                  "words": ["type": "array", "description": "Optional explicit [{start, end, text}] word array in file seconds.", "items": ["type": "object"]],
                  "session_id": str("Optional held lease session_id.")]),
            tool("auto_duck_bgm", "Auto-duck BGM under speech",
                 "Automatically lowers background music volume under detected speech spans using smooth 50ms gain ramps inside an AgentTurn (`I1`).",
                 ["bgm_track": str("Music audio track (e.g. A2; auto-selected if omitted)."),
                  "voice_track": str("Dialogue/speech track (e.g. A1; auto-selected if omitted)."),
                  "duck_db": num("Ducking attenuation in dB (-36...-1, default -14)."),
                  "disable": ["type": "boolean", "description": "Set true to disable ducking on bgm_track."],
                  "session_id": str("Optional held lease session_id.")]),
            tool("beat_sync_cuts", "Align cuts to music beats",
                 "Aligns B-roll/photo clip start & cut points onto detected beats from MediaAnalyzer.music (or explicit BPM) inside an AgentTurn (`I1`).",
                 ["clip_ids": ["type": "array", "items": ["type": "string"], "description": "Visual clips to beat-align (defaults to unlocked clips on `track` or V1)."],
                  "track": str("Track name when clip_ids omitted (e.g. V1, V2)."),
                  "music_clip_id": str("Optional audio clip UUID to analyze beats from."),
                  "music_asset_id": str("Optional audio asset UUID when music isn't on timeline."),
                  "beats_per_cut": ["type": "integer", "description": "Beats held per clip (1...16, default 2)."],
                  "bpm": num("Optional explicit BPM (40...240) to synthesize a strict beat grid."),
                  "start_time": num("Optional timeline anchor time in seconds."),
                  "session_id": str("Optional held lease session_id.")]),
            tool("analyze_reframe", "Analyze speaker face trajectory for auto-reframe",
                 "Runs Apple Vision face detection + EMA smoothing across the timeline to produce crop keyframes for vertical/square/portrait export.",
                 ["shape": ["type": "string", "enum": ["vertical", "square", "portrait"], "description": "Target cropped aspect shape (default vertical 9:16)."],
                  "sample_interval_sec": num("Analysis frame interval in seconds (0.25...2.0, default 0.5)."),
                  "include_preview": ["type": "boolean", "description": "Return a cropped JPEG contact sheet preview across 4 timestamps."]],
                 readOnly: true),
        ]
    }

    static func authorizeExternalWrite(model: EditorModel, sessionId: String?) throws {
        if let rec = model.leaseManager.reclaimIfExpired(), rec.uncommittedTurnId != nil {
            _ = model.rollbackAnyActiveAgentTurn()
        }
        do {
            if let rec = try model.leaseManager.checkWriter(sessionId: sessionId), rec.uncommittedTurnId != nil {
                _ = model.rollbackAnyActiveAgentTurn()
            }
        } catch {
            throw MCPToolError(error.localizedDescription)
        }
    }

    static func callHybrid(_ name: String, _ args: [String: Any], model: EditorModel, client: MCPServer.Client?,
                           draft: MCPDraft?, sessionId: String?) async throws -> [[String: Any]]? {
        func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
        func json(_ v: Any) -> [[String: Any]] {
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return text(String(data: d, encoding: .utf8) ?? "{}")
        }
        let who = client?.name ?? "Agent"
        let callerSession = (args["session_id"] as? String) ?? sessionId

        switch name {
        case "session_attach":
            if let grace = args["grace_ms"] as? Int, grace > 0 {
                model.resetLeaseManager(gracePeriodMs: UInt64(grace))
            }
            let sid = callerSession ?? UUID().uuidString
            let pid = Int32((args["client_pid"] as? Int) ?? Int(ProcessInfo.processInfo.processIdentifier))
            let (lease, recovered): (SessionLease, RecoveredLease?)
            do {
                (lease, recovered) = try model.leaseManager.acquire(sessionId: sid, clientPid: pid, role: .liveAgent)
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            var rolledBackTurn: String?
            if let rec = recovered, rec.uncommittedTurnId != nil {
                rolledBackTurn = model.rollbackAnyActiveAgentTurn()
            }
            var out: [String: Any] = [
                "session_id": lease.sessionId,
                "client_pid": Int(lease.clientPid),
                "grace_period_ms": Int(lease.gracePeriodMs),
                "revision": Int(model.revision),
                "active_turn_id": model.activeAgentTurn?.turnId ?? NSNull(),
            ]
            if let rolledBackTurn { out["recovered_rolled_back_turn_id"] = rolledBackTurn }
            return json(out)

        case "session_heartbeat":
            guard let sid = callerSession, !sid.isEmpty else { throw MCPToolError("session_id is required.") }
            let pid = Int32((args["client_pid"] as? Int) ?? Int(ProcessInfo.processInfo.processIdentifier))
            do {
                let lease = try model.leaseManager.heartbeat(sessionId: sid, clientPid: pid)
                return json([
                    "session_id": lease.sessionId,
                    "last_heartbeat_at_ms": lease.lastHeartbeatAtMs,
                    "revision": Int(model.revision),
                ])
            } catch {
                throw MCPToolError(error.localizedDescription)
            }

        case "session_release":
            guard let sid = callerSession, !sid.isEmpty else { throw MCPToolError("session_id is required.") }
            if let active = model.activeAgentTurn, active.sessionId == sid {
                _ = try? model.rollbackAgentTurn(turnId: active.turnId)
            }
            do {
                try model.leaseManager.release(sessionId: sid)
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            return json(["released": sid, "revision": Int(model.revision)])

        case "begin_agent_turn":
            if draft != nil && model.activeAgentTurn == nil {
                throw MCPToolError("begin_agent_turn is not available inside a Magic run.")
            }
            guard let turnId = args["turn_id"] as? String else { throw MCPToolError("turn_id is required.") }
            guard let summary = args["summary"] as? String else { throw MCPToolError("summary is required.") }
            try authorizeExternalWrite(model: model, sessionId: callerSession)
            do {
                try model.beginAgentTurn(turnId: turnId, summary: summary, sessionId: callerSession)
                if let sid = callerSession, model.leaseManager.current?.sessionId == sid {
                    try model.leaseManager.setActiveTurn(sessionId: sid, turnId: turnId)
                }
            } catch {
                _ = try? model.rollbackAgentTurn(turnId: turnId)
                throw MCPToolError(error.localizedDescription)
            }
            return json(["turn_id": turnId, "revision": Int(model.revision), "status": "active"])

        case "commit_agent_turn":
            guard let turnId = args["turn_id"] as? String else { throw MCPToolError("turn_id is required.") }
            try authorizeExternalWrite(model: model, sessionId: callerSession)
            let commit: TurnCommit
            do {
                commit = try model.commitAgentTurn(turnId: turnId)
                if let sid = callerSession, model.leaseManager.current?.sessionId == sid {
                    try? model.leaseManager.setActiveTurn(sessionId: sid, turnId: nil)
                }
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            return json([
                "turn_id": commit.turnId,
                "summary": commit.summary,
                "revision": Int(commit.revision),
                "affected_clip_ids": commit.affectedClipIds.map(\.uuidString),
                "pushed_undo_step": commit.pushedUndoStep,
            ])

        case "rollback_agent_turn":
            guard let turnId = args["turn_id"] as? String else { throw MCPToolError("turn_id is required.") }
            try authorizeExternalWrite(model: model, sessionId: callerSession)
            let rev: UInt64
            do {
                rev = try model.rollbackAgentTurn(turnId: turnId)
                if let sid = callerSession, model.leaseManager.current?.sessionId == sid {
                    try? model.leaseManager.setActiveTurn(sessionId: sid, turnId: nil)
                }
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            return json(["turn_id": turnId, "revision": Int(rev), "status": "rolled_back"])

        case "apply_edl_patch":
            guard let ops = args["operations"] as? [[String: Any]], !ops.isEmpty else {
                throw MCPToolError("operations array must be non-empty.")
            }
            let p0 = draft?.project ?? model.project
            // Validate operations against a copy first so the patch is strictly all-or-nothing.
            var previewProject = p0
            var touchedIds: [UUID] = []
            try Self.applyEDLOperations(ops, to: &previewProject, model: model, touchedIds: &touchedIds)
            try await perform([.change(nil, "EDL patch") { q in
                var dummy: [UUID] = []
                try? Self.applyEDLOperations(ops, to: &q, model: model, touchedIds: &dummy)
            }], model, who, draft)
            let after = draft?.project ?? model.project
            return json([
                "revision": Int(model.revision),
                "clip_count": after.clips.count,
                "touched_clip_ids": touchedIds.map(\.uuidString),
                "clips": clipsJSON(touchedIds, after),
            ])

        case "preview_timeline_strip":
            let p = draft?.project ?? model.project
            guard !p.clips.isEmpty else { throw MCPToolError("The timeline is empty.") }
            let rawTimes = (args["timestamps"] as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) } ?? []
            guard !rawTimes.isEmpty else { throw MCPToolError("timestamps array (1...12) is required.") }
            let times = Array(rawTimes.prefix(12))
            let tileMaxW = max(160, min(640, (args["width"] as? Int) ?? 320))
            let gridCols = args["grid_cols"] as? Int
            guard let sheet = await Self.renderTimelineStrip(project: p, media: model.media, timestamps: times, tileWidth: tileMaxW, gridCols: gridCols) else {
                throw MCPToolError("Couldn't render timeline strip.")
            }
            if let outputPath = args["output"] as? String, !outputPath.isEmpty {
                do {
                    try HybridStorage.writeAtomicVerified(sheet.jpeg, to: URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath))
                } catch {
                    throw MCPToolError("Failed to write preview_timeline_strip output: \(error.localizedDescription)")
                }
            }
            let meta: [String: Any] = [
                "revision": Int(model.revision),
                "timestamps": sheet.times.map { round3($0) },
                "width": sheet.pixelWidth,
                "height": sheet.pixelHeight,
            ]
            let metaText = (try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return [
                ["type": "image", "data": sheet.jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": metaText],
            ]

        case "list_skills":
            let rows: [[String: Any]] = SkillRegistry.shared.skills.map { s in
                let srcDesc: String
                switch s.source {
                case .builtIn: srcDesc = "built_in"
                case .local(let p): srcDesc = "local:\(p)"
                case .github(let repo, let ref, let sub, let sha):
                    srcDesc = "github:\(repo)@\(sha.prefix(8))" + (ref.map { "(\($0))" } ?? "") + (sub.map { "/\($0)" } ?? "")
                }
                return [
                    "id": s.id,
                    "name": s.name,
                    "description": s.description,
                    "enabled": s.enabled,
                    "source": srcDesc,
                ]
            }
            return json(["skills": rows])

        case "list_plugins":
            let rows: [[String: Any]] = PluginHost.shared.plugins.map { p in
                [
                    "id": p.id,
                    "name": p.manifest.name,
                    "version": p.manifest.version,
                    "description": p.manifest.description,
                    "enabled": p.enabled,
                    "trusted_for_execution": p.trustedForExecution,
                    "has_mcp": p.manifest.mcp != nil,
                    "luts": p.manifest.luts ?? [],
                    "workflows": p.manifest.workflows ?? [],
                    "skills": p.manifest.skills ?? [],
                ]
            }
            return json(["plugins": rows])

        case "comfy_status":
            let status = await ComfyUIClient.shared.status(prefs: ComfyConnectionPrefs.load())
            let galleryRows: [[String: Any]] = status.galleryPresets.map { p in
                [
                    "id": p.id,
                    "name": p.name,
                    "kind": p.kind.rawValue,
                    "badge": p.badge,
                    "steps": p.defaultSteps,
                    "width": p.defaultWidth,
                    "height": p.defaultHeight,
                    "vram_gb": p.recommendedVRAMGB,
                ]
            }
            return json([
                "endpoint": status.endpoint,
                "mode": status.mode,
                "online": status.online,
                "gpu_name": status.gpuName ?? NSNull(),
                "vram_total_mb": status.vramTotalMB ?? NSNull(),
                "vram_free_mb": status.vramFreeMB ?? NSNull(),
                "available_workflows": status.availableWorkflows,
                "gallery_presets": galleryRows,
                "checkpoints": status.checkpoints,
                "error": status.errorMessage ?? NSNull(),
            ])

        case "comfy_generate":
            let kindStr = ((args["kind"] as? String) ?? "image").lowercased()
            guard let kind = ComfyMediaKind(rawValue: kindStr) else {
                throw MCPToolError("Unsupported kind '\(kindStr)'; use image, video, or audio.")
            }
            guard let promptText = args["prompt"] as? String, !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPToolError("prompt is required.")
            }

            let p = draft?.project ?? model.project
            var refPNG: Data?
            if let refClipStr = args["reference_clip_id"] as? String, let refUUID = UUID(uuidString: refClipStr),
               let clip = p.clip(refUUID),
               let built = CompositionBuilder.build(project: p, media: model.media,
                                                    renderSize: CompositionBuilder.previewSize(for: p), includeAudio: false) {
                let targetT = double(args["reference_time"]) ?? ((clip.start + clip.end) * 0.5)
                let clampedT = min(max(0, targetT), max(0, built.duration - 1 / max(1, p.fps)))
                let gen = AVAssetImageGenerator(asset: built.composition)
                gen.videoComposition = built.videoComposition
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter = .zero
                if let cg = try? await gen.image(at: CompositionBuilder.time(clampedT)).image {
                    refPNG = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                }
            }

            let request = ComfyGenerationRequest(
                kind: kind,
                prompt: promptText,
                negativePrompt: (args["negative_prompt"] as? String) ?? "blurry, low quality, distorted",
                workflowNameOrPath: args["workflow"] as? String,
                width: max(64, (args["width"] as? Int) ?? p.width),
                height: max(64, (args["height"] as? Int) ?? p.height),
                frames: max(1, (args["frames"] as? Int) ?? 25),
                steps: (args["steps"] as? Int).map { max(1, min(100, $0)) },
                seed: (args["seed"] as? Int) ?? Int.random(in: 1...Int(Int32.max)),
                referenceImagePNG: refPNG
            )
            let outFolder = model.fileURL?.deletingLastPathComponent().appendingPathComponent("Generated Media", isDirectory: true)
                ?? HybridStorage.subdir("Generated Media")
            let generated = try await ComfyUIClient.shared.generate(request, prefs: ComfyConnectionPrefs.load(), outputFolder: outFolder)
            let asset = try await importExternalMediaFile(generated.localURL, into: model, draft: draft)
            return json([
                "asset_id": asset.id.uuidString,
                "name": asset.name,
                "kind": "\(asset.kind)",
                "path": generated.localURL.path,
                "prompt_id": generated.promptId,
                "seed": generated.seed,
                "workflow": generated.workflowName,
            ])

        case "search_stock_media":
            guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPToolError("query is required.")
            }
            let rawKind = ((args["kind"] as? String) ?? "videos").lowercased()
            let kind: StockMediaKind = (rawKind == "photos" || rawKind == "photo" || rawKind == "image") ? .photos : .videos
            let rawOrient = ((args["orientation"] as? String) ?? "any").lowercased()
            let orientation = StockOrientation(rawValue: rawOrient) ?? .any
            let items = try await StockMediaManager.shared.search(
                query: query,
                kind: kind,
                orientation: orientation,
                providerFilter: args["provider"] as? String,
                perPage: max(1, min(15, (args["per_page"] as? Int) ?? 6))
            )
            let mapped: [[String: Any]] = items.enumerated().map { idx, it in
                [
                    "index": idx + 1,
                    "stock_id": it.id,
                    "provider": it.provider,
                    "kind": it.kind.rawValue,
                    "title": it.title,
                    "author": it.author,
                    "width": it.width,
                    "height": it.height,
                    "duration": it.durationSeconds.map { round3($0) } ?? NSNull(),
                    "licence": it.licence,
                    "download_url": it.downloadURL.absoluteString,
                ]
            }
            var out = json(["items": mapped, "count": mapped.count])
            let wantThumbs = (args["include_thumbnails"] as? Bool) ?? true
            if wantThumbs, !items.isEmpty, let sheet = await StockMediaManager.shared.renderContactSheet(for: items) {
                out.insert(["type": "image", "data": sheet.base64EncodedString(), "mimeType": "image/jpeg"], at: 0)
            }
            return out

        case "import_stock_media":
            let item: StockSearchItem
            if let sid = args["stock_id"] as? String, let cached = StockMediaManager.shared.item(for: sid) {
                item = cached
            } else if let urlStr = args["download_url"] as? String, let url = URL(string: urlStr) {
                let rawKind = ((args["kind"] as? String) ?? "videos").lowercased()
                let kind: StockMediaKind = (rawKind == "photos" || rawKind == "photo" || rawKind == "image") ? .photos : .videos
                item = StockSearchItem(
                    id: "direct-\(HybridStorage.sha256Hex16(urlStr))",
                    provider: (args["provider"] as? String) ?? "Stock",
                    kind: kind,
                    title: (args["title"] as? String) ?? url.deletingPathExtension().lastPathComponent,
                    author: (args["author"] as? String) ?? "Unknown",
                    sourcePageURL: (args["source_page"] as? String) ?? urlStr,
                    licence: (args["licence"] as? String) ?? "Royalty-free stock licence",
                    width: 0,
                    height: 0,
                    durationSeconds: nil,
                    previewURL: nil,
                    downloadURL: url
                )
            } else {
                throw MCPToolError("Provide either stock_id from search_stock_media or download_url.")
            }
            let outFolder = model.fileURL?.deletingLastPathComponent().appendingPathComponent("Stock Media", isDirectory: true)
                ?? HybridStorage.subdir("Stock Media")
            let localURL = try await StockMediaManager.shared.downloadAndVerify(item, into: outFolder)
            let asset = try await importExternalMediaFile(localURL, into: model, draft: draft)
            return json([
                "asset_id": asset.id.uuidString,
                "name": asset.name,
                "kind": "\(asset.kind)",
                "path": localURL.path,
                "provider": item.provider,
                "licence": item.licence,
            ])

        case "transcribe_aroll":
            let p0 = draft?.project ?? model.project
            let resolvedURL: URL
            if let path = args["path"] as? String, !path.isEmpty {
                resolvedURL = URL(fileURLWithPath: path)
            } else if let cidStr = args["clip_id"] as? String,
                      let cid = UUID(uuidString: cidStr),
                      let clip = p0.clips.first(where: { $0.id == cid }),
                      let aid = clip.assetID,
                      let asset = p0.assets.first(where: { $0.id == aid }) {
                resolvedURL = URL(fileURLWithPath: asset.path)
            } else if let aidStr = args["asset_id"] as? String,
                      let aid = UUID(uuidString: aidStr),
                      let asset = p0.assets.first(where: { $0.id == aid }) {
                resolvedURL = URL(fileURLWithPath: asset.path)
            } else {
                throw MCPToolError("Provide `path`, `clip_id`, or `asset_id` pointing to a valid media file.")
            }
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                throw MCPToolError("Media file does not exist: \(resolvedURL.path)")
            }

            let prefs = SpeechPrefs.load()
            let lang = ((args["language"] as? String)?.isEmpty == false ? (args["language"] as? String) : nil) ?? prefs.whisperLanguage
            let minSilence = max(0.2, double(args["min_silence_sec"]) ?? prefs.minSilenceSec)
            let padSec = max(0.0, double(args["pad_sec"]) ?? 0.1)
            let thresholdDB = double(args["vad_threshold_db"]) ?? prefs.vadThresholdDB

            let vad = try await AudioVAD.analyze(url: resolvedURL, thresholdDB: thresholdDB)
            let whisper = WhisperCPPProvider.fromPrefs(prefs)
            var providerName = "vad-only"
            var transcript = Transcript(words: [], language: lang)

            if !vad.spans.isEmpty {
                if prefs.preferWhisper, whisper.isConfigured {
                    let configured = WhisperCPPProvider(
                        binaryURL: whisper.binaryURL,
                        modelURL: whisper.modelURL,
                        vadThresholdDB: thresholdDB
                    )
                    transcript = try await configured.transcribe(audioURL: resolvedURL, language: lang)
                    providerName = "whisper.cpp"
                } else if let apple = await Transcripts.shared.ready(resolvedURL, limit: 60) {
                    let filteredWords = apple.words.filter { w in
                        !AudioVAD.isHallucination(w.text)
                            && vad.spans.contains { $0.end >= w.start - 0.25 && $0.start <= w.end + 0.25 }
                    }
                    transcript = Transcript(words: filteredWords, language: apple.language)
                    providerName = "apple-speech"
                }
            }

            let keepRanges = AudioVAD.suggestKeepRanges(
                words: transcript.words,
                spans: vad.spans,
                duration: vad.duration,
                minSilenceSec: minSilence,
                padSec: padSec
            )
            if !transcript.isEmpty {
                Transcripts.shared.storeTranscript(transcript, for: resolvedURL)
            }
            return json([
                "provider": providerName,
                "language": transcript.language,
                "duration": round(vad.duration * 1000) / 1000,
                "vad_peak_db": round(vad.peakDB * 10) / 10,
                "speech_spans": vad.spans.map { ["start": round($0.start * 1000) / 1000, "end": round($0.end * 1000) / 1000] },
                "word_count": transcript.words.count,
                "text": transcript.text,
                "words": transcript.words.map { [
                    "start": round($0.start * 1000) / 1000,
                    "end": round($0.end * 1000) / 1000,
                    "text": $0.text,
                ] },
                "suggested_keep_ranges": keepRanges.map { [
                    "start": round($0.start * 1000) / 1000,
                    "end": round($0.end * 1000) / 1000,
                ] },
            ])

        case "index_broll_folder":
            guard let folderPath = args["folder_path"] as? String, !folderPath.isEmpty else {
                throw MCPToolError("folder_path is required.")
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
                throw MCPToolError("Folder does not exist: \(folderPath)")
            }
            let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            let vlmPrefs = VLMIndexPrefs.load()
            let interval = double(args["sample_interval_sec"]) ?? vlmPrefs.sampleIntervalSec
            let useApple = (args["use_apple_vision"] as? Bool) ?? false
            let baseURL = (args["vlm_base_url"] as? String) ?? vlmPrefs.vlmBaseURL
            let modelID = (args["vlm_model"] as? String) ?? vlmPrefs.vlmModel

            let primary: any VisualIndexProvider = useApple
                ? AppleVisionFallbackProvider()
                : LocalVLMVisionProvider(baseURL: baseURL, model: modelID)
            let fallback: (any VisualIndexProvider)? = useApple ? nil : AppleVisionFallbackProvider()

            let index = try BRollFTSIndex()
            let stats = try await BRollIndexer().indexFolder(
                folderURL,
                index: index,
                provider: primary,
                fallbackProvider: fallback,
                sampleIntervalSec: interval
            )
            let total = try index.count()
            return json([
                "folder_path": folderURL.path,
                "indexed_files": stats.files,
                "indexed_segments": stats.segments,
                "total_segments": total,
                "provider": stats.usedProvider,
            ])

        case "search_broll":
            guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPToolError("query is required.")
            }
            let limit = max(1, min(25, (args["limit"] as? Int) ?? 6))
            let index = try BRollFTSIndex()
            let hits = try index.search(query: query, limit: limit)
            let fallbackTier = hits.isEmpty ? 2 : 1
            let hint = hits.isEmpty
                ? "No local B-roll matched '\(query)'. Proceed to Tier 2 (search_stock_media + import_stock_media) or Tier 3 (comfy_generate)."
                : "Local B-roll match found (Tier 1). Place best candidate via insert_broll_overlay."
            return json([
                "query": query,
                "count": hits.count,
                "fallback_tier": fallbackTier,
                "fallback_hint": hint,
                "hits": hits.map { hit in
                    [
                        "asset_path": hit.assetPath,
                        "asset_name": hit.assetName,
                        "start_sec": hit.startSec,
                        "end_sec": hit.endSec,
                        "description": hit.description,
                        "tags": hit.tags,
                        "mood": hit.mood,
                        "score": hit.score,
                    ] as [String: Any]
                },
            ])

        case "insert_broll_overlay":
            let p0 = draft?.project ?? model.project
            let resolvedAsset: MediaAsset
            if let aidStr = args["asset_id"] as? String, !aidStr.isEmpty {
                guard let aid = UUID(uuidString: aidStr),
                      let existing = p0.assets.first(where: { $0.id == aid }) else {
                    throw MCPToolError("Unknown asset_id '\(aidStr)'.")
                }
                resolvedAsset = existing
            } else if let rawPath = args["asset_path"] as? String, !rawPath.isEmpty {
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw MCPToolError("asset_path does not exist: \(rawPath)")
                }
                if let existing = p0.assets.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL == url }) {
                    resolvedAsset = existing
                } else {
                    resolvedAsset = try await importExternalMediaFile(url, into: model, draft: draft)
                }
            } else {
                throw MCPToolError("Provide either `asset_path` or `asset_id`.")
            }

            var previewProject = draft?.project ?? model.project
            var previewTouched: [UUID] = []
            let placement = try Self.insertOverlayClip(asset: resolvedAsset, opDict: args, in: &previewProject, touchedIds: &previewTouched)

            var committedTouched: [UUID] = []
            try await perform([.change(nil, "Insert B-roll overlay") { q in
                var ids: [UUID] = []
                _ = try? Self.insertOverlayClip(asset: resolvedAsset, opDict: args, in: &q, touchedIds: &ids)
                committedTouched = ids
            }], model, who, draft)
            let after = draft?.project ?? model.project
            let insertedIds = committedTouched.isEmpty ? previewTouched : committedTouched
            return json([
                "inserted_clip_ids": insertedIds.map(\.uuidString),
                "asset_id": resolvedAsset.id.uuidString,
                "track": placement.trackName,
                "timeline_start": placement.start,
                "duration": placement.duration,
                "mute_audio": (args["mute_audio"] as? Bool) ?? true,
                "revision": Int(model.revision),
                "duration_total": round(after.duration * 1000) / 1000,
            ])

        case "generate_vietnamese_captions":
            let p0 = draft?.project ?? model.project
            let rawGiven = args["clip_ids"] as? [String] ?? []
            let given = Set(rawGiven.compactMap(UUID.init(uuidString:)))
            if !rawGiven.isEmpty, given.isEmpty {
                throw MCPToolError("clip_ids must contain valid clip UUIDs from get_project.")
            }
            var targets = p0.unlocked(given.isEmpty ? p0.defaultCaptionTargets : p0.captionTargets(given))
            if targets.isEmpty, given.isEmpty, let a1 = p0.audioTracks.first(where: { !$0.locked }) {
                targets = Set(p0.clips.filter { $0.trackID == a1.id && $0.kind == .audio && $0.playsSource }.map(\.id))
            }
            guard !targets.isEmpty else {
                throw MCPToolError("No unlocked speaking clips found to caption. Pass clip_ids or add an A-roll clip.")
            }

            let lang = ((args["language"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "vi"
            var preset: CaptionPreset? = nil
            if let rawPreset = args["preset"] as? String {
                guard let resolved = CaptionPreset.from(rawPreset) else {
                    throw MCPToolError("Unknown caption preset '\(rawPreset)'.")
                }
                preset = resolved
            }

            // Optional explicit word-level timing payload (or cached/transcribed speech).
            let rawWords = args["words"] as? [[String: Any]]
            var explicitTranscript: Transcript? = nil
            if let rawWords {
                var parsedWords: [Transcript.Word] = []
                for item in rawWords {
                    guard let txt = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !txt.isEmpty,
                          let wStart = double(item["start"]), let wEnd = double(item["end"]), wEnd > wStart else { continue }
                    parsedWords.append(Transcript.Word(start: wStart, end: wEnd, text: txt))
                }
                guard !parsedWords.isEmpty else {
                    throw MCPToolError("words array contained no valid {start, end, text} items.")
                }
                explicitTranscript = Transcript(words: parsedWords.sorted { $0.start < $1.start }, language: lang)
            }

            let targetAssetIDs = Array(Set(p0.clips.filter { targets.contains($0.id) }.compactMap(\.assetID)))
            let prefs = SpeechPrefs.load()
            let whisper = WhisperCPPProvider.fromPrefs(prefs)
            for assetID in targetAssetIDs {
                guard let asset = p0.asset(assetID) else { continue }
                let fileURL = model.media.soundURL(assetID) ?? URL(fileURLWithPath: asset.path)
                if let explicitTranscript {
                    Transcripts.shared.storeTranscript(explicitTranscript, for: fileURL)
                    continue
                }
                if Transcripts.shared.transcript(for: fileURL) == nil {
                    let vad = try? await AudioVAD.analyze(url: fileURL, thresholdDB: prefs.vadThresholdDB)
                    if let vad, !vad.spans.isEmpty {
                        if prefs.preferWhisper, whisper.isConfigured,
                           let wt = try? await whisper.transcribe(audioURL: fileURL, language: lang), !wt.isEmpty {
                            Transcripts.shared.storeTranscript(wt, for: fileURL)
                        } else if let apple = await Transcripts.shared.ready(fileURL, limit: 60) {
                            let filtered = apple.words.filter { w in
                                !AudioVAD.isHallucination(w.text)
                                    && vad.spans.contains { $0.end >= w.start - 0.25 && $0.start <= w.end + 0.25 }
                            }
                            if !filtered.isEmpty {
                                Transcripts.shared.storeTranscript(Transcript(words: filtered, language: apple.language), for: fileURL)
                            }
                        }
                    }
                }
            }

            let maxWordsOverride = (args["max_words"] as? Int).map { max(1, min(8, $0)) }
            let sizeOverride = double(args["size"]).map { min(CaptionStyle.sizeRange.upperBound, max(CaptionStyle.sizeRange.lowerBound, $0)) }
            let posOverride = double(args["position"]).map { min(0.95, max(0.1, $0)) }

            try await perform([.change(targets.first, "Vietnamese Captions") { proj in
                proj.addCaptions(targets)
                if let preset { proj.captions?.style.apply(preset: preset) }
                if let maxWordsOverride { proj.captions?.style.maxWordsPerLine = maxWordsOverride }
                if let sizeOverride { proj.captions?.style.size = sizeOverride }
                if let posOverride { proj.captions?.style.y = posOverride }
            }], model, who, draft)

            let after = draft?.project ?? model.project
            let blocks = CaptionLayout.blocks(after) { model.media.transcript($0.id) }
            let totalWords = blocks.reduce(0) { $0 + $1.words.count }
            return json([
                "preset": (preset ?? .classic).rawValue,
                "language": lang,
                "clip_ids": after.captionedClips.map(\.id.uuidString),
                "block_count": blocks.count,
                "word_count": totalWords,
                "max_words": after.captions?.style.maxWordsPerLine ?? 0,
                "pill_highlight": after.captions?.style.pillHighlight ?? false,
                "blocks": blocks.prefix(60).map { ["start": round3($0.start), "end": round3($0.end), "text": $0.text, "words": $0.words.count] },
                "revision": Int(model.revision),
            ])

        case "auto_duck_bgm":
            let p0 = draft?.project ?? model.project
            guard p0.audioTracks.count >= 2 else {
                throw MCPToolError("auto_duck_bgm requires at least 2 audio tracks (e.g. A1 dialogue + A2 BGM).")
            }

            let linkedTrackIDs = Set(p0.clips.filter { $0.kind == .audio && $0.linkID != nil }.map(\.trackID))
            let voiceTrackID: UUID
            if let vn = args["voice_track"] as? String, !vn.isEmpty {
                voiceTrackID = try trackArg(vn, p0, kind: .audio)
            } else if let candidate = p0.audioTracks.first(where: { linkedTrackIDs.contains($0.id) && !$0.muted }) ?? p0.audioTracks.first(where: { !$0.muted }) {
                voiceTrackID = candidate.id
            } else {
                voiceTrackID = p0.audioTracks[0].id
            }

            let bgmTrackID: UUID
            if let bn = args["bgm_track"] as? String, !bn.isEmpty {
                bgmTrackID = try trackArg(bn, p0, kind: .audio)
            } else if let candidate = p0.audioTracks.first(where: { t in
                t.id != voiceTrackID && !t.locked && p0.clips.contains { $0.trackID == t.id && $0.kind == .audio && $0.linkID == nil }
            }) ?? p0.audioTracks.first(where: { $0.id != voiceTrackID && !$0.locked }) {
                bgmTrackID = candidate.id
            } else {
                throw MCPToolError("No unlocked BGM track found distinct from voice track.")
            }

            guard bgmTrackID != voiceTrackID else {
                throw MCPToolError("bgm_track and voice_track must be distinct audio tracks.")
            }

            let disable = (args["disable"] as? Bool) ?? false
            let duckDB = min(-1.0, max(-36.0, double(args["duck_db"]) ?? -14.0))

            await model.media.ensureWaveforms(for: p0, trackID: voiceTrackID)
            let spans = AudioLevels.activity(on: voiceTrackID, project: p0, media: model.media)

            try await perform([.change(nil, disable ? "Disable BGM Ducking" : "Auto-Duck BGM") { proj in
                proj.updateTrack(bgmTrackID) { t in
                    t.duckUnder = disable ? nil : voiceTrackID
                    if !disable { t.duckDB = duckDB }
                }
            }], model, who, draft)

            let after = draft?.project ?? model.project
            return json([
                "bgm_track": trackName(bgmTrackID, after),
                "voice_track": trackName(voiceTrackID, after),
                "enabled": !disable,
                "duck_db": round3(duckDB),
                "speech_spans_count": spans.count,
                "speech_spans": spans.prefix(40).map { ["start": round3($0.start), "end": round3($0.end)] },
                "revision": Int(model.revision),
            ])

        case "beat_sync_cuts":
            let p0 = draft?.project ?? model.project
            let rawClipIDs = args["clip_ids"] as? [String] ?? []
            let targetClipIDs: [UUID]
            if !rawClipIDs.isEmpty {
                let parsed = try rawClipIDs.map { s -> UUID in
                    guard let id = UUID(uuidString: s), let clip = p0.clip(id) else {
                        throw MCPToolError("No clip with id \(s).")
                    }
                    guard !p0.isLocked(clip.trackID) else { throw MCPToolError("Clip \(s) is on a locked track.") }
                    guard clip.kind != .audio else { throw MCPToolError("clip_ids for beat_sync_cuts must be visual clips.") }
                    return id
                }
                targetClipIDs = parsed
            } else {
                let trackID = try trackArg((args["track"] as? String) ?? "V1", p0, kind: .video)
                targetClipIDs = p0.clips
                    .filter { $0.trackID == trackID && $0.kind != .audio }
                    .sorted { $0.start < $1.start }
                    .map(\.id)
            }
            guard !targetClipIDs.isEmpty else {
                throw MCPToolError("No visual clips found on target track to align with beats.")
            }

            var musicURL: URL? = nil
            var musicStart = 0.0
            var musicSourceStart = 0.0
            if let mClipStr = args["music_clip_id"] as? String, !mClipStr.isEmpty {
                guard let mUUID = UUID(uuidString: mClipStr),
                      let mClip = p0.clip(mUUID), mClip.kind == .audio,
                      let aid = mClip.assetID, let asset = p0.asset(aid) else {
                    throw MCPToolError("Invalid music_clip_id '\(mClipStr)'.")
                }
                musicURL = URL(fileURLWithPath: asset.path)
                musicStart = mClip.start
                musicSourceStart = mClip.sourceStart
            } else if let mAssetStr = args["music_asset_id"] as? String, !mAssetStr.isEmpty {
                guard let aUUID = UUID(uuidString: mAssetStr), let asset = p0.asset(aUUID) else {
                    throw MCPToolError("Invalid music_asset_id '\(mAssetStr)'.")
                }
                musicURL = URL(fileURLWithPath: asset.path)
            } else if let mClip = p0.clips.first(where: { $0.kind == .audio && $0.linkID == nil }) ?? p0.clips.first(where: { $0.kind == .audio }),
                      let asset = p0.asset(mClip.assetID) {
                musicURL = URL(fileURLWithPath: asset.path)
                musicStart = mClip.start
                musicSourceStart = mClip.sourceStart
            }

            let explicitBPM = double(args["bpm"])
            let maxSpan = max(30.0, targetClipIDs.compactMap { p0.clip($0)?.end }.max() ?? 30.0)
            guard let grid = await BeatSyncEngine.computeBeatGrid(
                musicURL: musicURL,
                musicTimelineStart: musicStart,
                musicSourceStart: musicSourceStart,
                maxDuration: maxSpan + 20.0,
                explicitBPM: explicitBPM
            ) else {
                throw BeatSyncError.noMusic("Could not detect musical beats. Import a longer music track (>6s) or specify explicit `bpm`.")
            }

            let beatsPerCut = max(1, min(16, (args["beats_per_cut"] as? Int) ?? 2))
            let startAnchor = double(args["start_time"])
            let placements = try BeatSyncEngine.planBeatCuts(
                clipIDs: targetClipIDs,
                project: p0,
                grid: grid,
                beatsPerCut: beatsPerCut,
                startAt: startAnchor
            )

            try await perform([.change(nil, "Beat-Sync Cuts") { proj in
                BeatSyncEngine.apply(placements, to: &proj)
            }], model, who, draft)

            let after = draft?.project ?? model.project
            return json([
                "bpm": round3(grid.bpm),
                "beat_source": grid.source,
                "beats_per_cut": beatsPerCut,
                "cut_points": placements.map { round3($0.start) },
                "updated_clip_ids": placements.map(\.clipID.uuidString),
                "clips": clipsJSON(placements.map(\.clipID), after),
                "revision": Int(model.revision),
            ])

        case "analyze_reframe":
            let p = draft?.project ?? model.project
            guard p.duration > 0 else { throw MCPToolError("The timeline is empty.") }
            let shapeStr = ((args["shape"] as? String) ?? "vertical").lowercased()
            let shape: ExportSettings.Shape
            switch shapeStr {
            case "vertical": shape = .vertical
            case "square": shape = .square
            case "portrait": shape = .portrait
            default: throw MCPToolError("Unsupported shape '\(shapeStr)'; use vertical, square, or portrait.")
            }
            let interval = min(2.0, max(0.25, double(args["sample_interval_sec"]) ?? 0.5))
            let path = await AutoReframeEngine.analyze(project: p, media: model.media, sampleIntervalSec: interval)
            let kfJSON: [[String: Any]] = path.keyframes.map { kf in
                ["time": round3(kf.time), "x": round3(kf.x), "y": round3(kf.y)]
            }
            var out = json([
                "shape": shape.rawValue,
                "duration": round3(p.duration),
                "keyframe_count": path.keyframes.count,
                "keyframes": kfJSON,
            ])
            if (args["include_preview"] as? Bool) == true {
                var s = ExportSettings()
                s.shape = shape
                s.height = 360
                let size = s.renderSize(for: p)
                let dur = max(0.1, p.duration)
                let times = stride(from: 0.0, through: max(0.0, dur - 0.05), by: max(0.25, dur / 3.9)).prefix(4).map { $0 }
                if let sheet = await Self.renderTimelineStrip(project: p, media: model.media, timestamps: Array(times),
                                                              tileWidth: Int(size.width), gridCols: 4,
                                                              renderSizeOverride: size, reframePath: path) {
                    out.insert(["type": "image", "data": sheet.jpeg.base64EncodedString(), "mimeType": "image/jpeg"], at: 0)
                }
            }
            return out

        default:
            return nil
        }
    }

    private static func importExternalMediaFile(_ fileURL: URL, into model: EditorModel, draft: MCPDraft?) async throws -> MediaAsset {
        let assets: [MediaAsset] = await withCheckedContinuation { cont in
            model.importFiles([fileURL], offerMatch: false) { cont.resume(returning: $0) }
        }
        guard let asset = assets.first else {
            throw MCPToolError("Downloaded \(fileURL.lastPathComponent), but failed to import into MediaStore.")
        }
        draft?.addAsset(asset)
        return asset
    }

    // MARK: EDL Patch Execution

    private static func applyEDLOperations(_ ops: [[String: Any]], to q: inout Project, model: EditorModel,
                                           touchedIds: inout [UUID]) throws {
        for opDict in ops {
            guard let op = opDict["op"] as? String else { throw MCPToolError("Each EDL operation requires `op`.") }
            switch op {
            case "keep_ranges":
                let c = try clipArg(opDict, q)
                let coord = (opDict["coord"] as? String) ?? "timeline"
                let ripple = (opDict["ripple"] as? Bool) ?? true
                guard let rawRanges = opDict["ranges"] as? [[String: Any]], !rawRanges.isEmpty else {
                    throw MCPToolError("keep_ranges requires non-empty `ranges`.")
                }
                var spans: [(start: Double, end: Double)] = try rawRanges.map { r in
                    let s = try numArg(r, "start")
                    let e = try numArg(r, "end")
                    guard e > s + 1 / q.fps else { throw MCPToolError("Each range must have end > start.") }
                    return (s, e)
                }.sorted { $0.start < $1.start }
                if coord == "source" {
                    spans = try spans.map { r in
                        guard c.playsSource else { throw MCPToolError("source coord requires a video or audio clip.") }
                        let s0 = max(c.sourceStart, r.start)
                        let s1 = min(c.sourceStart + c.sourceLength, r.end)
                        let t0 = c.start + c.timelineSpan(from: c.sourceStart, to: s0)
                        let t1 = c.start + c.timelineSpan(from: c.sourceStart, to: s1)
                        guard t1 > t0 + 1 / q.fps else { throw MCPToolError("Source range falls outside clip bounds.") }
                        return (t0, t1)
                    }
                }
                for i in 1..<spans.count where spans[i].start < spans[i - 1].end - 1e-6 {
                    throw MCPToolError("keep_ranges must not overlap.")
                }
                let created = try applyKeepRanges(spans, on: c, in: &q, ripple: ripple)
                touchedIds.append(contentsOf: created)

            case "delete_range":
                let c = try clipArg(opDict, q)
                let delStart = max(c.start, try numArg(opDict, "start"))
                let delEnd = min(c.end, try numArg(opDict, "end"))
                let ripple = (opDict["ripple"] as? Bool) ?? true
                guard delEnd > delStart + 1 / q.fps else { throw MCPToolError("delete_range has no duration inside clip.") }
                let minDur = 1 / q.fps
                var kept: [(start: Double, end: Double)] = []
                if delStart - c.start >= minDur { kept.append((c.start, delStart)) }
                if c.end - delEnd >= minDur { kept.append((delEnd, c.end)) }
                if kept.isEmpty {
                    let group = q.unlocked(q.linked([c.id]))
                    q.remove(ids: group, ripple: ripple)
                } else {
                    let created = try applyKeepRanges(kept, on: c, in: &q, ripple: ripple)
                    touchedIds.append(contentsOf: created)
                }

            case "insert_overlay":
                let asset = try assetArg(opDict, q)
                _ = try Self.insertOverlayClip(asset: asset, opDict: opDict, in: &q, touchedIds: &touchedIds)

            default:
                throw MCPToolError("Unsupported EDL operation '\(op)'.")
            }
        }
    }

    @discardableResult
    private static func insertOverlayClip(asset: MediaAsset, opDict: [String: Any], in q: inout Project,
                                          touchedIds: inout [UUID]) throws -> (trackName: String, start: Double, duration: Double) {
        let tStart = q.snapFrame(max(0, (double(opDict["timeline_start"]) ?? double(opDict["start"]) ?? 0)))
        let srcStart = max(0, double(opDict["source_start"]) ?? 0)
        guard asset.kind == .image || srcStart < asset.duration - 0.05 else {
            throw MCPToolError("source_start is past end of \(asset.name).")
        }
        let rest = asset.kind == .image ? 5.0 : asset.duration - srcStart
        let len = q.snapFrame(max(1 / q.fps, min(double(opDict["duration"]) ?? rest, asset.kind == .image ? 3600 : rest)))
        let muteAudio = (opDict["mute_audio"] as? Bool) ?? true

        if asset.kind == .audio {
            let trackId: UUID
            if let tn = opDict["track"] as? String {
                trackId = try trackArg(tn, q, kind: .audio)
            } else if let free = q.freeTrack(.audio, start: tStart, duration: len) {
                trackId = free
            } else {
                trackId = q.addTrack(.audio)
            }
            var clip = Clip(trackID: trackId, kind: .audio, assetID: asset.id, start: tStart, duration: len, sourceStart: srcStart)
            if muteAudio { clip.gainDB = -60 }
            q.clips.append(clip)
            q.resolveOverlaps(keeping: [clip.id])
            touchedIds.append(clip.id)
            let aIdx = q.audioTracks.firstIndex { $0.id == trackId } ?? 0
            return ("A\(aIdx + 1)", tStart, len)
        } else {
            let trackId: UUID
            if let tn = opDict["track"] as? String {
                trackId = try trackArg(tn, q, kind: .video)
            } else if let free = q.videoTracks.dropFirst().first(where: { t in
                !t.locked && !q.clips.contains { $0.trackID == t.id && $0.start < tStart + len - 1e-6 && $0.end > tStart + 1e-6 }
            }) {
                trackId = free.id
            } else {
                trackId = q.addTrack(.video)
            }
            var vClip = Clip(trackID: trackId, kind: asset.kind == .image ? .image : .video, assetID: asset.id,
                             start: tStart, duration: len, sourceStart: asset.kind == .image ? 0 : srcStart)
            var keeping: Set<UUID> = [vClip.id]
            if !muteAudio, asset.kind == .video, asset.hasAudio {
                let aTrack = q.freeTrack(.audio, start: tStart, duration: len) ?? q.addTrack(.audio)
                let link = UUID()
                vClip.linkID = link
                var aClip = Clip(trackID: aTrack, kind: .audio, assetID: asset.id,
                                 start: tStart, duration: len, sourceStart: srcStart)
                aClip.linkID = link
                q.clips.append(aClip)
                keeping.insert(aClip.id)
                touchedIds.append(aClip.id)
            }
            q.clips.append(vClip)
            q.resolveOverlaps(keeping: keeping)
            touchedIds.append(vClip.id)
            let vIdx = q.videoTracks.firstIndex { $0.id == trackId } ?? 1
            return ("V\(vIdx + 1)", tStart, len)
        }
    }

    private static func applyKeepRanges(_ ranges: [(start: Double, end: Double)], on primary: Clip,
                                        in q: inout Project, ripple: Bool) throws -> [UUID] {
        let groupIDs = q.unlocked(q.linked([primary.id]))
        let originals = q.clips.filter { groupIDs.contains($0.id) }
        guard !originals.isEmpty else { throw MCPToolError("Clip track is locked.") }

        let clamped: [(start: Double, end: Double)] = ranges.compactMap { r in
            let s = q.snapFrame(max(primary.start, r.start))
            let e = q.snapFrame(min(primary.end, r.end))
            return e - s >= 1 / q.fps ? (s, e) : nil
        }
        guard !clamped.isEmpty else { throw MCPToolError("No valid ranges within clip bounds.") }

        var newClips: [Clip] = []
        var createdPrimaryIDs: [UUID] = []
        let segmentLinks: [UUID?] = clamped.enumerated().map { idx, _ in
            if idx == 0 { return primary.linkID }
            return originals.count > 1 ? UUID() : nil
        }

        for orig in originals {
            var cursor = orig.start
            for (idx, span) in clamped.enumerated() {
                var piece = orig
                if idx > 0 { piece.id = UUID() }
                piece.linkID = segmentLinks[idx]
                if idx > 0 { piece.fadeIn = 0 }
                if idx < clamped.count - 1 { piece.fadeOut = 0 }
                piece.trimTail(to: span.end)
                piece.trimHead(to: span.start)
                if ripple {
                    piece.start = cursor
                    cursor = q.snapFrame(cursor + piece.duration)
                }
                newClips.append(piece)
                if orig.id == primary.id { createdPrimaryIDs.append(piece.id) }
            }
        }

        let affectedTracks = Set(originals.map(\.trackID))
        let totalKept = clamped.reduce(0.0) { $0 + ($1.end - $1.start) }
        let removedDuration = max(0, primary.duration - totalKept)
        q.clips.removeAll { groupIDs.contains($0.id) }
        if ripple, removedDuration > 1e-6 {
            for i in q.clips.indices where affectedTracks.contains(q.clips[i].trackID) && q.clips[i].start >= primary.end - 1e-6 {
                q.clips[i].start = max(0, q.snapFrame(q.clips[i].start - removedDuration))
            }
        }
        q.clips.append(contentsOf: newClips)
        return createdPrimaryIDs
    }

    // MARK: Core-Renderer Timeline Strip (`I3`, `P2`)

    private static func renderTimelineStrip(project p: Project, media: MediaStore, timestamps: [Double],
                                            tileWidth: Int, gridCols: Int?,
                                            renderSizeOverride: CGSize? = nil,
                                            reframePath: ReframePath? = nil) async -> (jpeg: Data, times: [Double], pixelWidth: Int, pixelHeight: Int)? {
        let tileSize: CGSize
        if let override = renderSizeOverride {
            tileSize = override
        } else {
            let aspect = max(0.1, Double(p.width) / Double(max(1, p.height)))
            let w = max(2, ((Double(tileWidth) / 2).rounded()) * 2)
            let h = max(2, ((w / aspect / 2).rounded()) * 2)
            tileSize = CGSize(width: w, height: h)
        }

        guard let built = CompositionBuilder.build(project: p, media: media, renderSize: tileSize,
                                                   includeAudio: false, reframePath: reframePath) else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if p.isHDR, #available(macOS 15, *) { generator.dynamicRangePolicy = .forceSDR }

        let maxT = max(0, built.duration - 1 / max(1, p.fps))
        var rendered: [(Double, CGImage)] = []
        for rawT in timestamps {
            let t = min(max(0, rawT), maxT)
            if let cg = try? await generator.image(at: CompositionBuilder.time(t)).image {
                rendered.append((t, cg))
            }
        }
        guard !rendered.isEmpty else { return nil }

        let columns = max(1, min(4, gridCols ?? (rendered.count <= 4 ? rendered.count : rendered.count <= 6 ? 3 : 4)))
        let rows = (rendered.count + columns - 1) / columns
        let cellW = Int(tileSize.width), cellH = Int(tileSize.height)
        let gap = 4
        let sheetW = columns * cellW + (columns - 1) * gap
        let sheetH = rows * cellH + (rows - 1) * gap

        guard let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        for (i, (t, img)) in rendered.enumerated() {
            let x = (i % columns) * (cellW + gap)
            let y = sheetH - (i / columns + 1) * cellH - (i / columns) * gap
            let cell = CGRect(x: x, y: y, width: cellW, height: cellH)
            ctx.draw(img, in: cell)
            let label = String(format: "%.2fs", t) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let ls = label.size(withAttributes: attrs)
            let box = CGRect(x: cell.minX + 4, y: cell.maxY - ls.height - 8, width: ls.width + 8, height: ls.height + 4)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
            ctx.fill(box)
            label.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let sheet = ctx.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: sheet).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return nil
        }
        return (jpeg, rendered.map(\.0), sheetW, sheetH)
    }
}
