import Foundation
import QuartzCore

/// One meter's state: the level (with a falling release), the recent peak, and whether it has hit 0 dB.
struct MeterReading: Equatable {
    var level = MeterState.floor
    var peak = MeterState.floor
    /// Stays on once the signal reaches 0 dB, until the meter is clicked.
    var clipped = false

    func differs(from other: MeterReading) -> Bool {
        abs(level - other.level) > 0.2 || abs(peak - other.peak) > 0.2 || clipped != other.clipped
    }
}

/// Audio levels for the track and output meters, read from the waveform peaks at the playhead so
/// they need no hook into the audio itself. Values are dBFS.
@MainActor
final class MeterState: ObservableObject {
    static let floor = -60.0

    @Published private(set) var tracks: [UUID: MeterReading] = [:]
    /// The output, as one reading (the louder side) and per side.
    @Published private(set) var master = MeterReading()
    @Published private(set) var masterLeft = MeterReading()
    @Published private(set) var masterRight = MeterReading()

    /// How far the level may drop per display frame.
    private var release = 0.9
    /// How long a peak holds before it starts to fall, and how fast it falls after.
    private let peakHold = 0.5
    private var peakFall = 0.45
    private var holdUntil: [String: Double] = [:]


    /// `quickRelease` lets readings fall fast, for short bursts like scrubbing; levels also fall fast
    /// whenever nothing is playing.
    func update(project: Project, media: MediaStore, time t: Double, playing: Bool, quickRelease: Bool = false) {
        let now = CACurrentMediaTime()
        // Fast: a reading follows the sound almost at once and falls away in a few frames.
        release = 4
        peakFall = 2
        stopped = !playing
        var next: [UUID: MeterReading] = [:]
        var power = 0.0, powerL = 0.0, powerR = 0.0
        for track in project.audioTracks {
            var level = 0.0, levelL = 0.0, levelR = 0.0
            if playing, project.isAudible(track) {
                for c in project.clips where c.trackID == track.id && c.kind == .audio && t >= c.start && t < c.end {
                    guard let wf = media.waveform(c), !wf.peaks.isEmpty else { continue }
                    // The loudest peak over the last ~30ms of source.
                    let src = c.sourceTime(at: t)
                    let hi = min(wf.peaks.count - 1, Int(src * wf.peaksPerSecond))
                    let lo = max(0, Int((src - 0.03 * c.speed(atSource: src)) * wf.peaksPerSecond))
                    guard hi >= lo else { continue }
                    var peak: Float = 0, pl: Float = 0, pr: Float = 0
                    for i in lo...hi {
                        peak = max(peak, wf.peaks[i])
                        if i < wf.left.count { pl = max(pl, wf.left[i]) }
                        if i < wf.right.count { pr = max(pr, wf.right[i]) }
                    }
                    let g = dbToLinear(c.gainDB) * c.fadeGain(at: t)
                    level = max(level, Double(peak) * g)
                    levelL = max(levelL, Double(pl) * g)
                    levelR = max(levelR, Double(pr) * g)
                }
                let tg = dbToLinear(track.gainDB)
                level *= tg
                levelL *= tg
                levelR *= tg
            }
            power += level * level
            powerL += levelL * levelL
            powerR += levelR * levelR
            next[track.id] = advance(tracks[track.id] ?? MeterReading(), reading: Self.db(level), key: track.id.uuidString, now: now)
        }
        func sum(_ p: Double) -> Double { p > 0 ? 10 * log10(p) : Self.floor }
        let out = advance(master, reading: sum(power), key: "master", now: now)
        let outL = advance(masterLeft, reading: sum(powerL), key: "L", now: now)
        let outR = advance(masterRight, reading: sum(powerR), key: "R", now: now)
        if outL.differs(from: masterLeft) { masterLeft = outL }
        if outR.differs(from: masterRight) { masterRight = outR }
        // Skip publishing tiny changes so idle meters don't redraw every frame.
        if next.count != tracks.count || next.contains(where: { $0.value.differs(from: tracks[$0.key] ?? MeterReading()) }) {
            tracks = next
        }
        if out.differs(from: master) { master = out }
    }

    /// Nothing is playing: every meter drops straight to empty, peaks and clip lights included.
    private var stopped = false

    private func advance(_ old: MeterReading, reading: Double, key: String, now: Double) -> MeterReading {
        if stopped { return MeterReading() }
        var r = old
        r.level = max(reading, max(Self.floor, old.level - release))
        if reading >= old.peak {
            r.peak = reading
            holdUntil[key] = now + peakHold
        } else if now > holdUntil[key] ?? 0 {
            r.peak = max(Self.floor, old.peak - peakFall)
        }
        // Lit only while the signal is actually at full scale.
        r.clipped = reading >= -0.1
        return r
    }

    private static func db(_ linear: Double) -> Double {
        linear > 0 ? max(floor, 20 * log10(linear)) : floor
    }
}
