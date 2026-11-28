import Foundation

/// Metadata describing a committed transactional `AgentTurn` on the Undo stack (`I1`).
struct TurnMeta: Codable, Equatable {
    var turnId: String
    var summary: String
    var affectedClipIds: [UUID]
    var revision: UInt64
}

/// Summary returned when an `AgentTurn` commits into 1 unified Undo/Redo entry.
struct TurnCommit: Codable, Equatable {
    var turnId: String
    var summary: String
    var revision: UInt64
    var affectedClipIds: [UUID]
    var pushedUndoStep: Bool
}

enum AgentTurnError: Error, Equatable, LocalizedError {
    case alreadyActive(activeTurnId: String)
    case notActive
    case turnMismatch(expected: String, actual: String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .alreadyActive(let active):
            return "Agent turn '\(active)' is already active."
        case .notActive:
            return "No agent turn is currently active."
        case .turnMismatch(let expected, let actual):
            return "Active agent turn is '\(expected)', got '\(actual)'."
        case .invalid(let message):
            return message
        }
    }
}

/// Holds an in-flight external agent transaction backed by `MCPDraft`.
@MainActor
final class ActiveAgentTurn {
    let turnId: String
    let summary: String
    let sessionId: String?
    let baselineProject: Project
    let draft: MCPDraft

    init(turnId: String, summary: String, sessionId: String?, baselineProject: Project, model: EditorModel) {
        self.turnId = turnId
        self.summary = summary
        self.sessionId = sessionId
        self.baselineProject = baselineProject
        self.draft = MCPDraft.open(baselineProject, model: model)
    }
}

/// Returns deduplicated clip UUIDs added or modified between `before` and `after`.
func diffAffectedClipIds(before: Project, after: Project) -> [UUID] {
    let oldById = Dictionary(before.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var seen = Set<UUID>()
    var out: [UUID] = []
    for clip in after.clips {
        if oldById[clip.id] != clip, seen.insert(clip.id).inserted {
            out.append(clip.id)
        }
    }
    return out
}
