import Foundation

/// What the cut should be, before anything is put on the timeline: which moments, how long, in what
/// order, over which part of the song. The choreographer turns it into edits the cursors perform.
struct EditDecision {
    struct Shot {
        var asset: MediaAsset
        /// Where the shot starts in its file.
        var source: Double
        var duration: Double
        /// Brings the shot to a matching brightness.
        var exposure: Double
        /// Level for the shot's own sound; 0 leaves it alone.
        var gainDB: Double
        /// A dissolve into this shot.
        var dissolve: Bool
        var score: Double
    }
    struct Music {
        var asset: MediaAsset
        var source: Double
        var duration: Double
        var fadeOut: Double
    }
    var shots: [Shot]
    var music: Music?
    var title: String
    var look: String
    var bpm: Double?
    /// The title over the last seconds instead of the first.
    var titleAtEnd = false
}

/// Picks the best moments from each clip and cuts them to the music, with no network and no key.
///
/// Each frame sample is scored for focus, exposure, colour, faces and steadiness (and Apple's
/// aesthetics score where the system has it). Windows of the right length are scored by their
/// samples, and shots are taken round-robin across the clips in the order they were filmed, so the
/// cut tells things in order without two shots from one clip side by side. With music, every shot is
/// a whole number of beats, cuts land on beats, the cut ends on a bar, and the song starts on a bar
/// where it lifts.
enum AutoPlanner {
    static func decide(project: Project, clips: [(MediaAsset, ClipAnalysis)], music: (MediaAsset, MusicAnalysis)?,
                       today: Date = Date(), recipe: LocalRecipe = .plain) -> EditDecision? {
        let usable = clips.filter { !$0.1.samples.isEmpty }
        guard !usable.isEmpty else { return nil }

        let all = usable.flatMap(\.1.samples)
        let score = scorer(all)
        func pct(_ v: [Double], _ p: Double) -> Double { percentile(v, p) }

        struct Source {
            var asset: MediaAsset
            var analysis: ClipAnalysis
            var scores: [Double]
            var picked: [(Double, Double)] = []
        }
        // In the order things were filmed; undated files keep their library order, last.
        var sources = usable.enumerated().map { i, c in
            (i, Source(asset: c.0, analysis: c.1, scores: c.1.samples.map(score)))
        }
        .sorted { a, b in
            switch (a.1.analysis.created, b.1.analysis.created) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0 < b.0
            }
        }
        .map(\.1)
        let allScores = sources.flatMap(\.scores)
        let floor = pct(allScores, 0.3)

        // Shot lengths: whole beats with music, a natural rhythm without.
        var period = music.map { $0.1.period }
        // Every clip asked for: at least one shot from each. When that many won't fit the length on
        // whole beats, shots go to half beats.
        let wanted = recipe.every ? max(recipe.shots ?? 0, sources.count) : recipe.shots
        var sub = 1
        // Pace they asked for: shorter or longer shots.
        let pace = recipe.pace == .fast ? 0.55 : recipe.pace == .calm ? 1.7 : 1
        var longBeats = 4, shortBeats = 2
        if let p = period {
            longBeats = [2, 4, 8, 16].first { Double($0) * p >= 1.5 * pace } ?? 16
            shortBeats = Double(longBeats / 2) * p >= 0.8 ? longBeats / 2 : longBeats
        }
        // A number of shots they asked for sets the shot length: about the length over the count (whole beats
        // with music, rounded down), so there are at least that many.
        var perShot: Double?
        if let n = wanted {
            let length = recipe.seconds ?? Double(n) * (recipe.pace == .calm ? 2.5 : recipe.pace == .fast ? 0.9 : 1.5)
            perShot = max(recipe.every ? 0.2 : 0.35, length / Double(n))
            if recipe.every, let p = period, perShot! < p * 0.9 {
                sub = 2
                period = p / 2
            }
            if let p = period {
                let b = max(1, Int((perShot! / p).rounded(.down)))
                longBeats = b
                shortBeats = b
            }
        }
        let rhythm = [true, false, false, true, true, false]
        func beatsFor(_ k: Int) -> Int { rhythm[k % rhythm.count] ? longBeats : shortBeats }
        func lengthFor(_ k: Int) -> Double {
            if let p = period { return Double(beatsFor(k)) * p }
            if let perShot { return perShot * [1.08, 0.94, 1.0, 1.06, 0.92, 1.0][k % 6] }
            return [2.4, 1.8, 2.1, 2.8, 1.7, 2.2][k % 6] * pace
        }

        // How long: about half the good footage, between 12 and 40 seconds, and no longer than the song allows.
        let good = sources.reduce(0.0) { sum, s in
            let step = s.analysis.samples.count > 1 ? s.analysis.duration / Double(s.analysis.samples.count) : 2.5
            return sum + Double(s.scores.filter { $0 >= floor }.count) * step
        }
        var target = recipe.seconds ?? perShot.map { $0 * Double(wanted ?? 1) } ?? min(40, max(12, good * 0.5))
        if let m = music?.1 { target = min(target, m.duration - 2) }

        /// The best window of `length` in a source that doesn't overlap what's already been taken from it.
        func bestWindow(_ s: Source, _ length: Double, apart: Double = 0.3) -> (start: Double, score: Double)? {
            let a = s.analysis
            if s.asset.kind == .image {
                return s.picked.isEmpty ? (0, s.scores.first ?? 0) : nil
            }
            // The project's idea of the file's length wins.
            let limit = min(a.duration, s.asset.duration)
            guard limit >= length + 0.1 else { return nil }
            var best: (Double, Double)?
            // Where what they asked for shows: the best window with one of those moments inside it
            // (not right at its edge) wins over any window without one.
            let wanted = recipe.moments[s.asset.id] ?? []
            var bestWanted: (Double, Double)?
            var start = 0.05
            while start + length <= limit - 0.05 {
                let end = start + length
                let clear = s.picked.allSatisfy { end + apart <= $0.0 || start >= $0.1 + apart }
                if clear {
                    let inside = a.samples.indices.filter { a.samples[$0].time >= start && a.samples[$0].time <= end }
                    if !inside.isEmpty {
                        let vals = inside.map { s.scores[$0] }
                        // The average, held down by the worst moment in it.
                        let v = vals.reduce(0, +) / Double(vals.count) * 0.75 + (vals.min() ?? 0) * 0.25
                        if best == nil || v > best!.1 { best = (start, v) }
                        if wanted.contains(where: { $0 >= start + min(0.3, length / 4) && $0 <= end - min(0.3, length / 4) }),
                           bestWanted == nil || v > bestWanted!.1 { bestWanted = (start, v) }
                    }
                }
                start += 0.25
            }
            return bestWanted ?? best
        }

        var shots: [EditDecision.Shot] = []
        var shotBeats: [Int] = []
        var total = 0.0
        var round = 0
        while total < target {
            var added = 0
            // Every clip asked for: the first round goes through them all, whatever the length so far.
            for i in sources.indices where total < target || (recipe.every && round == 0) {
                // A second shot from a clip only if it's long and the moment is well away from the first:
                // otherwise it reads as the same shot again.
                if round > 0, min(sources[i].analysis.duration, sources[i].asset.duration) < 12 { continue }
                let apart = round > 0 ? 4.0 : 0.3
                // A short clip that can't give a long shot can still give a short one.
                var length = lengthFor(shots.count)
                var beats = beatsFor(shots.count)
                var found = bestWindow(sources[i], length + 0.08, apart: apart)
                if found == nil, beats != shortBeats || period == nil {
                    beats = shortBeats
                    length = period.map { Double(shortBeats) * $0 } ?? min(1.6, perShot ?? 1.6)
                    found = bestWindow(sources[i], length + 0.08, apart: apart)
                }
                guard let w = found else { continue }
                // Everything gets a shot in the first round if it has anything decent; after that, only
                // good moments, unless the cut would be too short to be worth watching.
                guard (recipe.every && round == 0) || w.score >= (round == 0 || total < 18 ? pct(allScores, 0.12) : floor) else { continue }
                // Not two shots from one clip in a row.
                if shots.last?.asset.id == sources[i].asset.id, sources.count > 1 { continue }
                sources[i].picked.append((w.start, w.start + length))
                let luma = sources[i].analysis.samples.filter { $0.time >= w.start && $0.time <= w.start + length }.map(\.luma)
                let m = luma.isEmpty ? 0.45 : luma.reduce(0, +) / Double(luma.count)
                let exposure = ((log2(0.45 / max(0.05, m)) * 0.5).clamped(to: -0.5...0.5) * 10).rounded() / 10
                shots.append(EditDecision.Shot(asset: sources[i].asset, source: w.start, duration: length, exposure: exposure,
                                               gainDB: 0, dissolve: false, score: w.score))
                shotBeats.append(beats)
                total += length
                added += 1
            }
            if added == 0 { break }
            round += 1
            // Every clip asked for: once each, no repeats; the shots grow to fill the length below.
            if recipe.every { break }
        }
        // Short of the length (every clip once, or no more clips worth a second shot): shots grow a beat
        // (or a quarter second) at a time, in turn, as far as their clips allow, rather than repeating clips.
        do {
            let limit = target
            let unit = period ?? 0.25
            var grew = true
            while total + unit <= limit + 0.05, grew {
                grew = false
                for i in shots.indices where total + unit <= limit + 0.05 {
                    let s = shots[i]
                    guard s.asset.kind == .video, s.source + s.duration + unit <= min(s.asset.duration, sources.first { $0.asset.id == s.asset.id }?.analysis.duration ?? s.asset.duration) - 0.05 else { continue }
                    // Clear of any other shot from the same clip.
                    let end = s.source + s.duration + unit
                    guard shots.indices.allSatisfy({ j in
                        j == i || shots[j].asset.id != s.asset.id || end + 0.1 <= shots[j].source || shots[j].source + shots[j].duration <= s.source
                    }) else { continue }
                    shots[i].duration += unit
                    shotBeats[i] += 1
                    total += unit
                    grew = true
                }
            }
        }
        // Every clip in a length they gave: past it, extra shots come off the end, then the last shot is
        // cut down (a beat at a time with music), so it fits.
        if recipe.every, let limit = recipe.seconds {
            while total > limit + 0.15, shots.count > sources.count {
                total -= shots.removeLast().duration
                shotBeats.removeLast()
            }
            if total > limit + 0.15, let last = shots.indices.last {
                if let p = period {
                    while total > limit + 0.15, shotBeats[last] > 1 {
                        shotBeats[last] -= 1
                        shots[last].duration -= p
                        total -= p
                    }
                } else {
                    let cut = min(total - limit, shots[last].duration - 0.3)
                    shots[last].duration -= max(0, cut)
                    total -= max(0, cut)
                }
            }
        }
        guard !shots.isEmpty else { return nil }

        // A title only when they asked for one: their words, or "Title" to type over (never a guess at what it says).
        let asked = recipe.title.map { $0.isEmpty ? "Title" : $0 } ?? ""
        var decision = EditDecision(shots: shots, music: nil, title: asked,
                                    look: recipe.look.map { $0 == "none" ? "" : $0 } ?? "", bpm: nil,
                                    titleAtEnd: recipe.titleAtEnd)

        if let (asset, m) = music, !m.beats.isEmpty {
            decision.bpm = m.bpm
            // The beats cut on: the song's own, or with half beats between them.
            var grid = m.beats, energy = m.energy
            if sub == 2 {
                grid = m.beats.indices.flatMap { i in i + 1 < m.beats.count ? [m.beats[i], (m.beats[i] + m.beats[i + 1]) / 2] : [m.beats[i]] }
                energy = m.energy.flatMap { [$0, $0] }
            }
            let bar = 4 * sub, phase = m.barPhase * sub
            let step = m.period / Double(sub)
            // End on a bar: lengthen the last shot to the bar line if its clip allows.
            let count = shotBeats.reduce(0, +)
            // (Not when every clip has to fit a length they gave: the length comes first.)
            let extra = recipe.every && recipe.seconds != nil ? 0 : (bar - count % bar) % bar
            if extra > 0, let last = shots.indices.last {
                let s = shots[last]
                let needed = s.duration + Double(extra) * step
                // Longer at either end, as long as it stays in the file and clear of the clip's other shots.
                func fits(_ start: Double) -> Bool {
                    guard s.asset.kind == .video else { return true }
                    guard start >= 0, start + needed <= s.asset.duration - 0.05 else { return false }
                    return shots.indices.allSatisfy { j in
                        j == last || shots[j].asset.id != s.asset.id
                            || start + needed + 0.1 <= shots[j].source || start >= shots[j].source + shots[j].duration + 0.1
                    }
                }
                if let start = [s.source, s.source - (needed - s.duration)].first(where: fits) {
                    shotBeats[last] += extra
                    decision.shots[last].source = start
                } else if shotBeats[last] > bar - extra {
                    shotBeats[last] -= bar - extra
                } else if shotBeats[last] == bar - extra, last > 0, !recipe.every {
                    // Exactly the overhang: leave it out.
                    shotBeats.removeLast()
                    decision.shots.removeLast()
                }
            }
            var totalBeats = shotBeats.reduce(0, +)
            // Drop shots from the end until the song is long enough.
            while totalBeats + 2 >= grid.count, shotBeats.count > 1 {
                totalBeats -= shotBeats.removeLast()
                decision.shots.removeLast()
            }
            // Start the song on a bar where it's lively and lifting.
            var best = (beat: phase, score: -Double.infinity)
            var b = phase
            let look = 8 * sub
            while b + totalBeats + 1 < grid.count, b + totalBeats <= energy.count {
                let window = energy[b..<(b + totalBeats)]
                let mean = Double(window.reduce(0, +)) / Double(max(1, window.count))
                let before = b >= look ? Double(energy[(b - look)..<b].reduce(0, +)) / Double(look) : mean
                let after = Double(energy[b..<min(energy.count, b + look)].reduce(0, +)) / Double(max(1, min(look, energy.count - b)))
                let s = mean + 0.5 * max(0, after - before) - (b == phase && b < bar ? 0.05 : 0)
                if s > best.score { best = (b, s) }
                b += bar
            }
            let b0 = best.beat
            // Cut exactly on the song's beats (they drift a little from a strict grid).
            var at = b0
            for i in decision.shots.indices {
                let next = at + shotBeats[i]
                decision.shots[i].duration = grid[next] - grid[at]
                // On the first beat of each four-bar phrase, dissolve rather than cut (not in a half-beat montage).
                decision.shots[i].dissolve = sub == 1 && i > 0 && (at - b0) % 16 == 0
                at = next
            }
            let length = grid[at] - grid[b0]
            let tail = min(1.2, max(0, m.duration - grid[at]))
            decision.music = EditDecision.Music(asset: asset, source: grid[b0], duration: length + tail, fadeOut: tail + 0.6)
            for i in decision.shots.indices where decision.shots[i].asset.hasAudio { decision.shots[i].gainDB = -16 }
        } else {
            for i in decision.shots.indices { decision.shots[i].dissolve = i > 0 && i % 4 == 0 }
        }
        // Keep shots inside their files after any lengthening.
        for i in decision.shots.indices where decision.shots[i].asset.kind == .video {
            let s = decision.shots[i]
            decision.shots[i].source = max(0, min(s.source, s.asset.duration - s.duration - 0.02))
        }
        return decision
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    /// How good each frame sample is, with focus, motion and colour measured against `all` the
    /// footage being considered.
    static func scorer(_ all: [ClipAnalysis.Sample]) -> (ClipAnalysis.Sample) -> Double {
        let sharpLog = all.map { log1p($0.sharpness) }
        let s10 = percentile(sharpLog, 0.1), s90 = max(percentile(sharpLog, 0.9), s10 + 1e-6)
        let m90 = max(percentile(all.map(\.motion), 0.9), 0.02)
        let c90 = max(percentile(all.map(\.color), 0.9), 0.05)
        return { s in
            let sharp = min(1, max(0, (log1p(s.sharpness) - s10) / (s90 - s10)))
            let exposure = 1 - min(1, abs(s.luma - 0.45) / 0.38)
            let color = min(1, s.color / c90)
            let motion = s.motion / m90
            var q = 0.36 * sharp + 0.2 * exposure + 0.14 * color
            q += s.faces > 0 ? 0.16 : 0
            q += s.aesthetic.map { 0.26 * ($0 + 1) / 2 } ?? 0.12
            if s.utility == true { q -= 0.35 }
            if motion > 1.1 { q -= min(0.3, (motion - 1.1) * 0.3) }
            return q
        }
    }

    /// A clip's best moments of about `length` seconds, best first, not overlapping.
    static func moments(_ a: ClipAnalysis, limit: Double, length: Double = 2, count: Int = 5,
                        score: (ClipAnalysis.Sample) -> Double) -> [(start: Double, end: Double, score: Double, faces: Int)] {
        let scores = a.samples.map(score)
        var windows: [(Double, Double, Int)] = []
        var start = 0.0
        let end = min(a.duration, limit)
        let len = min(length, end)
        while start + len <= end + 1e-6 {
            let inside = a.samples.indices.filter { a.samples[$0].time >= start && a.samples[$0].time <= start + len }
            if !inside.isEmpty {
                let vals = inside.map { scores[$0] }
                let v = vals.reduce(0, +) / Double(vals.count) * 0.75 + (vals.min() ?? 0) * 0.25
                windows.append((start, v, inside.map { a.samples[$0].faces }.max() ?? 0))
            }
            start += 0.25
        }
        var picked: [(start: Double, end: Double, score: Double, faces: Int)] = []
        for w in windows.sorted(by: { $0.1 > $1.1 }) where picked.count < count {
            if picked.allSatisfy({ w.0 + len <= $0.start || w.0 >= $0.end }) {
                picked.append((w.0, w.0 + len, w.1, w.2))
            }
        }
        return picked
    }

    /// The title: when it was filmed. "November 14, 2026", "November 2026" or "October – November 2026".
    static func title(for dates: [Date], today: Date) -> String {
        let f = DateFormatter()
        guard let first = dates.min(), let last = dates.max() else {
            f.dateFormat = "MMMM yyyy"
            return f.string(from: today)
        }
        let cal = Calendar.current
        if cal.isDate(first, inSameDayAs: last) {
            f.dateFormat = "MMMM d, yyyy"
            return f.string(from: first)
        }
        if cal.isDate(first, equalTo: last, toGranularity: .month) {
            f.dateFormat = "MMMM yyyy"
            return f.string(from: first)
        }
        f.dateFormat = "MMMM"
        let a = f.string(from: first)
        f.dateFormat = "MMMM yyyy"
        return a + " – " + f.string(from: last)
    }
}
