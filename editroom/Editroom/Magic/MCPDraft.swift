import Foundation

/// A hidden copy of the project that an AI agent edits during a Magic run. Its tool calls change the
/// draft, not the timeline, so nothing moves on screen while it thinks; when it's done, its edits are
/// played on the real timeline by the Magic swarm, as one undo step.
///
/// Found by a token in the MCP address the agent is given (`/mcp?draft=…`).
@MainActor
final class MCPDraft {
    private static var open: [String: MCPDraft] = [:]

    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private(set) var base: Project
    private(set) var project: Project
    /// One entry per tool call that changed something, so history can undo a whole call.
    private(set) var steps: [[MagicEdit]] = []
    private var undone: [[MagicEdit]] = []
    var playhead = 0.0
    /// The editor it's a draft of (for the library, and rendering frames).
    private(set) weak var model: EditorModel?
    /// Tool calls so far, and the last tool called.
    private(set) var calls = 0
    private(set) var lastTool: String?

    init(project: Project) {
        base = project
        self.project = project
    }

    static func open(_ project: Project, model: EditorModel? = nil) -> MCPDraft {
        let d = MCPDraft(project: project)
        d.model = model
        open[d.token] = d
        return d
    }

    static func find(_ token: String) -> MCPDraft? { open[token] }

    func close() { Self.open[token] = nil }

    func called(_ tool: String) {
        calls += 1
        lastTool = tool
    }

    var edits: [MagicEdit] { steps.flatMap { $0 } }
    var canUndo: Bool { !steps.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    /// Something added to the library during the run (music it downloaded): in the draft, from the start.
    func addAsset(_ asset: MediaAsset) {
        guard !project.assets.contains(where: { $0.id == asset.id }) else { return }
        base.assets.append(asset)
        project.assets.append(asset)
    }

    func apply(_ edits: [MagicEdit]) {
        guard !edits.isEmpty else { return }
        for e in edits { e.apply(&project, 1) }
        steps.append(edits)
        undone.removeAll()
    }

    func undo() {
        guard let last = steps.popLast() else { return }
        undone.append(last)
        rebuild()
    }

    func redo() {
        guard let next = undone.popLast() else { return }
        steps.append(next)
        rebuild()
    }

    private func rebuild() {
        var p = base
        for e in edits { e.apply(&p, 1) }
        project = p
    }

    // MARK: Playing it back

    /// The edits in the steps a person would take. Several ripple deletes in a row each wait for the one
    /// before (each moves everything after it), so one cursor would do them one by one. A person
    /// deletes them all, then closes the gaps: so each becomes a plain delete, with its own cursor, side
    /// by side, and one "Close gaps" step after them slides the rest along to exactly where the ripple
    /// deletes would have left it.
    static func inSteps(base: Project, edits: [MagicEdit]) -> [MagicEdit] {
        var out: [MagicEdit] = []
        var p = base
        var i = 0
        while i < edits.count {
            var run: [[UUID]] = []
            var j = i
            while j < edits.count, case .remove(let ids, true) = edits[j] { run.append(ids); j += 1 }
            guard run.count >= 2 else {
                edits[i].apply(&p, 1)
                out.append(edits[i])
                i += 1
                continue
            }
            // Where everything ends up after the ripple deletes, and what's left after plain ones.
            var rippled = p
            for ids in run { rippled.remove(ids: Set(ids), ripple: true) }
            var lifted = p
            for ids in run { lifted.remove(ids: Set(ids), ripple: false) }
            let landing = Dictionary(rippled.clips.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
            let moving = lifted.clips.filter { c in landing[c.id].map { abs($0 - c.start) > 1e-9 } ?? false }
            for ids in run { out.append(.remove(ids, ripple: false)) }
            // The first clip to slide is the one it clicks on.
            if let first = moving.min(by: { ($0.start, $0.trackID.uuidString) < ($1.start, $1.trackID.uuidString) }) {
                out.append(.change(first.id, "Close gaps") { project in
                    for k in project.clips.indices {
                        if let start = landing[project.clips[k].id] { project.clips[k].start = start }
                    }
                })
            }
            p = rippled
            i = j
        }
        return out
    }

    /// An AI's finished edit as a show of its result, not of its working: the AI built the cut one step
    /// on top of another (add a clip, trim it, add the next where the last one was), and played back in
    /// that order the swarm waits in a line. Here the show is worked out from the timeline before and
    /// after, like Local's: what goes is lifted out, every new clip flies straight to where it ends up
    /// (all at once), and moves, trims, levels, fades, grades and transitions each get their own cursor.
    /// It ends exactly where the AI's edits do; if it couldn't, the AI's own steps are played instead.
    static func resultPlan(base: Project, edits: [MagicEdit]) -> MagicPlan {
        var final = base
        for e in edits { e.apply(&final, 1) }
        let was = Dictionary(base.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Dictionary(final.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func order(_ a: Clip, _ b: Clip) -> Bool { (a.start, final.trackOrder(a.trackID)) < (b.start, final.trackOrder(b.trackID)) }
        /// Linked clips together (a video and its sound), each group once.
        func groups(_ clips: [Clip]) -> [[Clip]] {
            var seen = Set<UUID>(), out: [[Clip]] = []
            for c in clips.sorted(by: order) where !seen.contains(c.id) {
                let g = c.linkID.map { l in clips.filter { $0.linkID == l } } ?? [c]
                g.forEach { seen.insert($0.id) }
                out.append(g)
            }
            return out
        }
        var out: [MagicEdit] = []

        // 1. What goes: lifted out first, so new clips have room.
        for g in groups(base.clips.filter { now[$0.id] == nil }) { out.append(.remove(g.map(\.id))) }

        // 2. The sequence, tracks, markers and library, if they changed (all at once, between).
        var baseRest = base, finalRest = final
        baseRest.clips = []
        finalRest.clips = []
        if baseRest != finalRest {
            out.append(.change(nil, "Sequence") { q in
                let clips = q.clips
                q = finalRest
                q.clips = clips
            })
        }

        /// Level, fades, grade, transition and words, from how a clip is now to how it ends up.
        func settings(_ from: Clip, _ to: Clip) -> [MagicEdit] {
            var e: [MagicEdit] = []
            if abs(from.gainDB - to.gainDB) > 0.05 { e.append(.gain(to.id, from: from.gainDB, to: to.gainDB)) }
            if abs(from.fadeIn - to.fadeIn) > 1e-6 { e.append(.fadeIn(to.id, to: to.fadeIn)) }
            if abs(from.fadeOut - to.fadeOut) > 1e-6 { e.append(.fadeOut(to.id, to: to.fadeOut)) }
            if from.grade != to.grade {
                var lookOnly = from.grade ?? ColorGrade()
                lookOnly.look = to.grade?.look
                if let look = to.grade?.look, lookOnly == to.grade { e.append(.look(to.id, name: look)) }
                else { e.append(.change(to.id, "Grade") { q in if let i = q.index(of: to.id) { q.clips[i].grade = to.grade } }) }
            }
            if from.transitionIn != to.transitionIn {
                if let t = to.transitionIn { e.append(.transition(to.id, t)) }
                else { e.append(.change(to.id, "No transition") { q in if let i = q.index(of: to.id) { q.clips[i].transitionIn = nil } }) }
            }
            if from.text.string != to.text.string, to.kind == .text { e.append(.type(to.id, to.text.string)) }
            return e
        }
        /// Anything else that's different (speed, a ramp, position, a title's style, a solid's colour),
        /// made in one click so the clip ends up exactly as the AI left it.
        func rest(_ id: UUID) -> MagicEdit {
            .change(id, "Edit") { q in if let i = q.index(of: id), let f = now[id] { q.clips[i] = f } }
        }
        /// A clip as it is after `e` is applied to it alone.
        func applied(_ c: Clip, _ e: [MagicEdit]) -> Clip {
            var q = Project()
            q.clips = [c]
            for x in e { x.apply(&q, 1) }
            return q.clips.first ?? c
        }

        // 3. Clips that stay but change: a move or a trim (with their linked clip), then their settings.
        var after: [MagicEdit] = []
        for g in groups(base.clips.filter { c in now[c.id].map { $0 != c } ?? false }) {
            let ids = g.map(\.id)
            let b = g[0], f = now[b.id]!
            let sameShape = g.allSatisfy { c in
                let n = now[c.id]!
                return abs((n.start - c.start) - (f.start - b.start)) < 1e-6 && abs(n.duration - c.duration - (f.duration - b.duration)) < 1e-6
            }
            var geometry: [MagicEdit] = []
            if b.speed == f.speed, b.ramp == f.ramp, sameShape {
                let movedOnly = abs(f.duration - b.duration) < 1e-6 && abs(f.sourceStart - b.sourceStart) < 1e-6
                if movedOnly, abs(f.start - b.start) > 1e-6 || g.contains(where: { now[$0.id]!.trackID != $0.trackID }) {
                    var tracks: [UUID: UUID] = [:]
                    for c in g where now[c.id]!.trackID != c.trackID { tracks[c.id] = now[c.id]!.trackID }
                    geometry = [.move(ids, from: b.start, to: f.start, tracks: tracks)]
                } else if abs(f.end - b.end) < 1e-6, abs(f.start - b.start) > 1e-6 {
                    geometry = [.trimHead(ids, from: b.start, to: f.start)]
                } else if abs(f.start - b.start) < 1e-6, abs(f.end - b.end) > 1e-6 {
                    geometry = [.trimTail(ids, from: b.end, to: f.end)]
                }
            }
            out += geometry
            for c in g {
                let shaped = applied(c, geometry)
                let s = settings(shaped, now[c.id]!)
                after += s
                if applied(shaped, s) != now[c.id]! { after.append(rest(c.id)) }
            }
        }

        // 4. New clips: each group flies straight to where it ends up, then gets its settings.
        for g in groups(final.clips.filter { was[$0.id] == nil }) {
            let bare = g.map { c -> Clip in
                var c = c
                c.gainDB = 0
                c.fadeIn = 0
                c.fadeOut = 0
                c.grade = nil
                c.transitionIn = nil
                if c.kind == .text { c.text.string = "" }
                return c
            }
            out.append(.place(bare, asset: g.first { $0.assetID != nil }?.assetID))
            for (c, f) in zip(bare, g) {
                let s = settings(c, f)
                after += s
                if applied(c, s) != f { after.append(rest(f.id)) }
            }
        }
        out += after

        // It has to land exactly where the AI's edits do.
        var check = base
        for e in out { e.apply(&check, 1) }
        let landed = Dictionary(check.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var checkRest = check
        checkRest.clips = []
        guard landed == now, checkRest == finalRest else { return plan(base: base, edits: edits) }
        return plan(base: base, edits: out)
    }

    /// The draft's edits as a Magic plan on `base`. Each edit waits for the earlier ones it depends on:
    /// ones that touched the same clips, or the same stretch of the same track. Changes to the
    /// sequence or its tracks wait for everything before and hold up everything after.
    static func plan(base: Project, edits: [MagicEdit]) -> MagicPlan {
        let edits = inSteps(base: base, edits: edits)
        struct Footprint {
            var ids: Set<UUID> = []
            var spans: [(track: UUID, from: Double, to: Double)] = []
            var barrier = false
            /// A plain delete: two of them only clash over the same clip.
            var lift = false
            /// Only a clip's own setting (level, fades, look, grade): two of them only clash over the same clip.
            var setting = false
            /// A transition: it needs the clip that touches it in place.
            var transition = false
        }
        var p = base
        var prints: [Footprint] = []
        for e in edits {
            let before = p
            e.apply(&p, 1)
            var f = Footprint()
            if case .change(nil, _, _) = e { f.barrier = true }
            if case .remove(_, false) = e { f.lift = true }
            switch e {
            case .gain, .fadeIn, .fadeOut, .look, .grade: f.setting = true
            case .transition: f.transition = true
            default: break
            }
            if before.videoTracks.map(\.id) != p.videoTracks.map(\.id) || before.audioTracks.map(\.id) != p.audioTracks.map(\.id)
                || before.width != p.width || before.height != p.height || before.fps != p.fps { f.barrier = true }
            // Every clip the edit changed, added or removed, including ones it overwrote or rippled.
            let was = Dictionary(before.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let now = Dictionary(p.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, c) in was where now[id] != c {
                f.ids.insert(id)
                f.spans.append((c.trackID, c.start, c.end))
            }
            for (id, c) in now where was[id] != c {
                f.ids.insert(id)
                f.spans.append((c.trackID, c.start, c.end))
            }
            f.ids.formUnion(e.clipIDs)
            prints.append(f)
        }
        func overlaps(_ a: Footprint, _ b: Footprint) -> Bool {
            if a.barrier || b.barrier || !a.ids.isDisjoint(with: b.ids) { return true }
            // Deleting clips side by side: one doesn't need the other gone first.
            if a.lift, b.lift { return false }
            // Setting one clip's level, fades or colour doesn't wait on another's.
            if a.setting, b.setting { return false }
            // Clips side by side don't wait on each other; for a transition, touching counts (it needs
            // the clip before it in place).
            let slack = a.transition || b.transition ? 1e-3 : -1e-6
            for x in a.spans {
                for y in b.spans where x.track == y.track && x.from < y.to + slack && y.from < x.to + slack { return true }
            }
            return false
        }
        var tasks: [MagicTask] = []
        // Everything each edit waits for, directly or not.
        var ancestors: [Set<Int>] = []
        for (i, e) in edits.enumerated() {
            var after: [Int] = []
            var covered = Set<Int>()
            // Nearest first, skipping edits already waited for through another dependency.
            for j in stride(from: i - 1, through: 0, by: -1) where !covered.contains(j) && overlaps(prints[i], prints[j]) {
                after.append(j)
                covered.insert(j)
                covered.formUnion(ancestors[j])
            }
            ancestors.append(covered)
            tasks.append(MagicTask(edit: e, after: after.reversed()))
        }
        return MagicPlan(base: base, tasks: tasks)
    }
}
