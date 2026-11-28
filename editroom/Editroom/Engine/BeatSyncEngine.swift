import Foundation

struct BeatGrid: Codable, Equatable, Sendable {
    var bpm: Double
    var beats: [Double]
    var source: String
}

struct BeatPlacement: Equatable, Sendable {
    var clipID: UUID
    var start: Double
    var duration: Double
    var beatIndex: Int
}

enum BeatSyncError: LocalizedError {
    case noClips(String)
    case noMusic(String)
    case insufficientBeats(String)

    var errorDescription: String? {
        switch self {
        case .noClips(let msg), .noMusic(let msg), .insufficientBeats(let msg): msg
        }
    }
}

/// Computes beat grids via `MediaAnalyzer.music` (or explicit BPM) and aligns clip cuts onto musical beats (`I3`).
enum BeatSyncEngine {
    static func computeBeatGrid(
        musicURL: URL?,
        musicTimelineStart: Double = 0,
        musicSourceStart: Double = 0,
        maxDuration: Double = 60,
        explicitBPM: Double? = nil
    ) async -> BeatGrid? {
        if let rawBPM = explicitBPM {
            let bpm = min(240.0, max(40.0, rawBPM))
            let period = 60.0 / bpm
            let limit = musicTimelineStart + max(maxDuration, 30.0)
            var beats: [Double] = []
            var t = max(0, musicTimelineStart)
            while t <= limit + 1e-6 {
                beats.append(t)
                t += period
            }
            return BeatGrid(bpm: bpm, beats: beats, source: "manual_bpm")
        }
        guard let musicURL, let analyzed = await MediaAnalyzer.music(musicURL), !analyzed.beats.isEmpty else {
            return nil
        }
        let shift = musicTimelineStart - musicSourceStart
        let shifted = analyzed.beats
            .map { $0 + shift }
            .filter { $0 >= max(0, musicTimelineStart - 0.05) }
        guard shifted.count >= 2 else { return nil }
        return BeatGrid(bpm: analyzed.bpm, beats: shifted, source: "media_analyzer")
    }

    static func planBeatCuts(
        clipIDs: [UUID],
        project: Project,
        grid: BeatGrid,
        beatsPerCut: Int = 2,
        startAt: Double? = nil
    ) throws -> [BeatPlacement] {
        let clips = clipIDs.compactMap { project.clip($0) }.sorted { $0.start < $1.start }
        guard !clips.isEmpty else {
            throw BeatSyncError.noClips("No visual clips available to align to beats.")
        }
        guard grid.beats.count >= 2, grid.bpm > 0 else {
            throw BeatSyncError.insufficientBeats("Music track did not yield at least 2 beats.")
        }

        let step = max(1, min(16, beatsPerCut))
        let minFrame = 1.0 / max(1.0, project.fps)
        let anchor = startAt ?? clips[0].start
        let baseIdx = grid.beats.firstIndex(where: { $0 >= anchor - 0.02 }) ?? 0
        let period = 60.0 / grid.bpm

        func beatTime(at index: Int) -> Double {
            if index < grid.beats.count { return grid.beats[index] }
            let extra = index - (grid.beats.count - 1)
            return grid.beats.last! + Double(extra) * period
        }

        var placements: [BeatPlacement] = []
        var cursorBeatIdx = baseIdx
        var prevEnd = 0.0

        for (i, clip) in clips.enumerated() {
            let b0 = beatTime(at: cursorBeatIdx)
            let b1 = beatTime(at: cursorBeatIdx + step)
            let snappedStart = project.snapFrame(max(i == 0 ? b0 : prevEnd, b0))
            var targetDur = max(minFrame, project.snapFrame(b1 - snappedStart))

            if clip.playsSource, let asset = project.asset(clip.assetID), asset.duration > 0 {
                let speed = clip.isRamped ? 1.0 : max(0.05, clip.speed)
                let availSource = max(minFrame, asset.duration - clip.sourceStart)
                let maxTimelineDur = availSource / speed
                targetDur = max(minFrame, project.snapFrame(min(targetDur, maxTimelineDur)))
            }

            placements.append(BeatPlacement(clipID: clip.id, start: snappedStart, duration: targetDur, beatIndex: cursorBeatIdx))
            prevEnd = snappedStart + targetDur
            cursorBeatIdx += step
        }
        return placements
    }

    static func apply(_ placements: [BeatPlacement], to project: inout Project) {
        let map = Dictionary(uniqueKeysWithValues: placements.map { ($0.clipID, $0) })
        let touched = project.unlocked(Set(placements.map(\.clipID)))
        for i in project.clips.indices {
            let clip = project.clips[i]
            if touched.contains(clip.id), let p = map[clip.id] {
                project.clips[i].start = p.start
                project.clips[i].duration = p.duration
                continue
            }
            if let linkID = clip.linkID,
               let sibling = placements.first(where: { project.clip($0.clipID)?.linkID == linkID }),
               !project.isLocked(clip.trackID) {
                project.clips[i].start = sibling.start
                project.clips[i].duration = sibling.duration
            }
        }
    }
}
