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
        "apply_edl_patch",
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

        default:
            return nil
        }
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
                }

            default:
                throw MCPToolError("Unsupported EDL operation '\(op)'.")
            }
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
                                            tileWidth: Int, gridCols: Int?) async -> (jpeg: Data, times: [Double], pixelWidth: Int, pixelHeight: Int)? {
        let aspect = max(0.1, Double(p.width) / Double(max(1, p.height)))
        let w = max(2, ((Double(tileWidth) / 2).rounded()) * 2)
        let h = max(2, ((w / aspect / 2).rounded()) * 2)
        let tileSize = CGSize(width: w, height: h)

        guard let built = CompositionBuilder.build(project: p, media: media, renderSize: tileSize, includeAudio: false) else {
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
