import Foundation

/// Several of Local's edits in one request ("add @Beach to the end, add captions and a title at the end"):
/// each made in turn on the edit as the one before leaves it (clips first, then the title, then captions, so the
/// title lands at the new end and the new clip is captioned too), played and undone as one.
@MainActor
enum LocalCombined {
    enum Part { case add, title, captions }

    /// What the request asks for, when it's more than one thing.
    static func parts(_ request: String, project p: Project) -> [Part] {
        var out: [Part] = []
        if LocalAdd.asks(request, project: p) { out.append(.add) }
        if LocalTitle.asks(request, project: p) { out.append(.title) }
        if LocalCaptions.asks(request, project: p) { out.append(.captions) }
        return out
    }

    static func plan(_ parts: [Part], request: String, typed: String, pointers: MagicPointers, model: EditorModel,
                     onListening: () -> Void) async -> LocalPointed.Outcome {
        let base = model.project
        var now = base
        var edits: [MagicEdit] = []
        var said: [String] = []
        for part in parts {
            let outcome: LocalPointed.Outcome
            switch part {
            case .add:
                outcome = LocalAdd.plan(request: request, typed: typed, pointers: pointers, project: now)
            case .title:
                outcome = LocalTitle.plan(request: request, playhead: pointers.playhead, project: now)
            case .captions:
                if !LocalCaptions.removes(request) {
                    // What's said in the clips to caption, the new ones too, heard first.
                    onListening()
                    for c in now.clips where LocalCaptions.targets(pointers: pointers, project: now).contains(c.id) {
                        if let id = c.assetID, let url = model.media.soundURL(id) { _ = await Transcripts.shared.ready(url, limit: 60) }
                    }
                }
                outcome = LocalCaptions.plan(request: request, pointers: pointers, project: now) { model.media.transcript($0.id) }
            }
            said.append(outcome.said)
            guard let plan = outcome.plan else { continue }
            for task in plan.tasks {
                task.edit.apply(&now, 1)
                edits.append(task.edit)
            }
        }
        let text = said.joined(separator: " ")
        guard !edits.isEmpty else { return LocalPointed.Outcome(said: text) }
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: base, edits: edits), said: text)
    }
}
