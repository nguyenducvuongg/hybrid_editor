import AVFoundation
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import ImageIO
import Vision

/// What a clip or photo shows ("pool", "beach", "dog", "sunset"), seen on this Mac by Apple's Vision,
/// from a frame every couple of seconds. Made once per file in the background and kept on disk, for Media
/// search and Magic.
struct SceneTags: Codable, Equatable {
    struct Tag: Codable, Equatable {
        var name: String
        /// How sure Vision is, at the frame it was surest (0 to 1).
        var confidence: Double
        /// Times in the file where it shows.
        var times: [Double]
    }

    var tags: [Tag]

    /// Keywords from Apple Intelligence, each where it was said: tags of their own (a little less sure
    /// than Vision's surest), or more times on a tag Vision already has.
    mutating func add(_ described: [(Double, [String])]) {
        for (t, words) in described {
            for w in Set(words) {
                if let i = tags.firstIndex(where: { $0.name == w }) {
                    if !tags[i].times.contains(t) { tags[i].times.append(t) }
                } else {
                    tags.append(Tag(name: w, confidence: 0.6, times: [t]))
                }
            }
        }
    }

    /// The surest few, for a short summary.
    func top(_ n: Int) -> [String] { tags.sorted { $0.confidence > $1.confidence }.prefix(n).map(\.name) }

    /// Whether one of its tags is this word, or starts with it while it's being typed ("po" for "pool").
    /// Vision's own words count with the everyday ones people search for ("portal" is a door).
    func shows(_ word: String, typing: Bool = false) -> Bool {
        let w = Self.singular(word.lowercased())
        guard w.count >= 2 else { return false }
        return tags.contains { tag in
            (tag.name.split(separator: " ").map(String.init) + (Self.aliases[tag.name] ?? [])).contains { p in
                p == w || Self.singular(p) == w || (typing && p.hasPrefix(w)) || Self.sameStem(p, w)
            }
        }
    }

    /// The same word in another form ("laughing" and "laughter", "smile" and "smiling"), for longer words.
    static func sameStem(_ a: String, _ b: String) -> Bool {
        guard a.count >= 5, b.count >= 5 else { return false }
        func stem(_ w: String) -> String {
            var w = w
            for end in ["ing", "ter", "ers", "er", "ed", "es", "s"] where w.count > end.count + 3 && w.hasSuffix(end) {
                w = String(w.dropLast(end.count))
                break
            }
            if w.hasSuffix("e"), w.count > 4 { w.removeLast() }
            return w
        }
        return stem(a) == stem(b)
    }

    /// The tags that match a word (as `shows` does), for saying where in the file it shows.
    func matching(_ word: String) -> [Tag] {
        let w = Self.singular(word.lowercased())
        guard w.count >= 2 else { return [] }
        return tags.filter { tag in
            (tag.name.split(separator: " ").map(String.init) + (Self.aliases[tag.name] ?? [])).contains { $0 == w || Self.singular($0) == w || Self.sameStem($0, w) }
        }
    }

    /// Everyday words for Vision's labels, so a search for "door" finds a "portal".
    static let aliases: [String: [String]] = [
        "portal": ["door", "doorway", "entrance", "gate"],
        "conveyance": ["vehicle", "transport"],
        "people": ["person", "man", "woman", "guy", "girl", "friends", "crowd"],
        "adult": ["person", "man", "woman", "guy", "girl"],
        "child": ["kid", "kids", "boy", "girl", "baby"],
        "structure": ["building", "architecture"],
        "housing": ["house", "home", "building"],
        "building": ["house"],
        "sky": ["clouds"],
        "water body": ["water", "lake", "sea", "ocean"],
        "swimming pool": ["pool", "swim"],
        "automobile": ["car", "vehicle"],
        "vehicle": ["car"],
        "aircraft": ["plane", "airplane", "helicopter", "vehicle"],
        "rotorcraft": ["helicopter", "vehicle"],
        "foliage": ["plants", "leaves", "trees"],
        "plant": ["plants", "greenery"],
        "food": ["meal", "eating", "dinner", "lunch", "breakfast"],
        "drink": ["drinks", "cocktail", "bar"],
        "nightclub": ["club", "party"],
        "concert": ["gig", "show", "music", "festival"],
        "selfie": ["vlog", "talking"],
        "sunset sunrise": ["sunset", "sunrise", "golden hour"],
        "snow": ["winter"],
        "beach": ["sand", "ocean", "sea"],
        "dog": ["puppy"],
        "cat": ["kitten"],
        // Everyday words for what people search ("ride", "party", "city"), onto the labels Apple's
        // recognition actually gives (rollercoaster, celebration, cityscape).
        "rollercoaster": ["ride", "roller", "coaster", "theme park", "amusement"],
        "carousel": ["ride", "merry"],
        "ferris wheel": ["ride"],
        "amusement park": ["ride", "theme", "fair", "funfair", "carnival", "amusement"],
        "fairground": ["ride", "fair", "funfair", "carnival"],
        "go kart": ["ride", "karting", "racing", "vehicle"],
        "trampoline": ["jumping", "bounce"],
        "celebration": ["party", "birthday", "celebrate", "festival"],
        "cake": ["birthday", "dessert"],
        "fireworks": ["celebration", "festival"],
        "wedding": ["marriage", "ceremony"],
        "bride": ["wedding"],
        "graduation": ["ceremony"],
        "crowd": ["audience", "festival"],
        "dancing": ["dance", "dancer", "party"],
        "breakdancing": ["dance", "dancing"],
        "ballet dancer": ["dance", "dancing"],
        "karaoke": ["singing", "sing"],
        "microphone": ["singing", "speech", "podcast"],
        "musical instrument": ["music", "band"],
        "guitar": ["music", "band"],
        "piano": ["music"],
        "drum": ["music", "band"],
        "sport": ["sports", "game", "match"],
        "soccer": ["football", "sports", "game"],
        "football": ["sports", "game"],
        "basketball": ["sports", "game"],
        "tennis": ["sports"],
        "golf": ["sports"],
        "stadium": ["arena", "game", "match"],
        "skateboarding": ["skate", "skating", "skateboard"],
        "cycling": ["bike", "biking", "bicycle", "riding"],
        "bicycle": ["bike", "vehicle"],
        "motorcycle": ["motorbike", "bike", "riding", "vehicle"],
        "hiking": ["hike", "trail", "walk"],
        "mountain": ["hills"],
        "forest": ["woods", "trees"],
        "park": ["outdoors"],
        "cityscape": ["city", "skyline", "downtown", "urban"],
        "skyscraper": ["city", "tower", "downtown"],
        "street": ["city", "road"],
        "night sky": ["stars"],
        "waterfall": ["falls"],
        "ocean": ["sea", "water"],
        "lake": ["water"],
        "river": ["water", "stream"],
        "surfing": ["surf", "waves"],
        "diving": ["scuba", "underwater"],
        "snorkeling": ["snorkel", "underwater"],
        "swimming": ["swim"],
        "skiing": ["ski", "winter"],
        "snowboarding": ["snowboard", "snow", "winter"],
        "jetski": ["jet", "water", "vehicle"],
        "boat": ["boating", "sailing", "vehicle"],
        "sailboat": ["sailing", "boat", "vehicle"],
        "yacht": ["boat", "sailing", "vehicle"],
        "cruise ship": ["cruise", "boat", "vehicle"],
        "kayak": ["kayaking", "paddling", "vehicle"],
        "canoe": ["paddling", "boat", "vehicle"],
        "camping": ["camp", "tent", "outdoors"],
        "tent": ["camping"],
        "fire": ["campfire", "bonfire"],
        "airplane": ["plane", "flight", "flying", "vehicle"],
        "airport": ["flight", "travel"],
        "train": ["railway", "travel", "vehicle"],
        "restaurant": ["dinner", "eating", "dining"],
        "coffee": ["cafe"],
        "cocktail": ["drinks", "bar"],
        "wine": ["drinks"],
        "beer": ["drinks", "bar"],
        "museum": ["gallery", "art"],
        "painting": ["art"],
        "monument": ["landmark", "sightseeing"],
        "statue": ["landmark", "sculpture"],
        "castle": ["landmark"],
        "ruins": ["landmark", "history"],
        "zoo": ["animals"],
        "aquarium": ["fish", "animals"],
        "horse": ["riding"],
        "baby": ["newborn", "infant"],
        "teen": ["teenager"],
        "yoga": ["workout", "exercise", "stretching"],
        "screenshot": ["screen", "recording"],
        "laptop": ["computer", "screen"],
        "playground": ["kids"],
        "garden": ["flowers", "plants"],
        "car": ["vehicle"],
        "laughter": ["laughing", "laugh", "funny"],
        "smiles": ["smiling", "smile", "happy"],
        "smile": ["smiling", "happy"],
        "excitement": ["excited", "happy"],
        "fun": ["happy", "funny"],
        "bus": ["vehicle"],
        "truck": ["vehicle"],
        "semi truck": ["vehicle"],
        "police car": ["vehicle"],
        "formula one car": ["vehicle"],
        "helicopter": ["vehicle"],
    ]

    static func singular(_ w: String) -> String {
        w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? String(w.dropLast()) : w
    }
}

@MainActor
final class SceneTagStore: ObservableObject {
    static let shared = SceneTagStore()

    @Published private(set) var version = 0
    private var made: [String: SceneTags] = [:]
    private var queue: [(URL, Bool, Double)] = []
    private var working: URL?
    /// Being looked at from a file that has since changed: thrown away when done, and looked at again.
    private var stale = Set<String>()
    private var again: [String: (URL, Bool, Double)] = [:]

    /// A file changed on disk: what was seen in it goes (its saved tags are named for the old file).
    func forget(_ url: URL) {
        made[url.path] = nil
        queue.removeAll { $0.0 == url }
        if working == url { stale.insert(url.path) }
        version += 1
    }

    func tags(for url: URL) -> SceneTags? { made[url.path] ?? load(url) }

    /// Queues a file: a video (`isVideo`, with its length) or a photo.
    func make(_ url: URL, isVideo: Bool, duration: Double) {
        if working == url, stale.contains(url.path) { again[url.path] = (url, isVideo, duration); return }
        guard made[url.path] == nil, working != url, !queue.contains(where: { $0.0 == url }) else { return }
        if load(url) != nil { return }
        queue.append((url, isVideo, duration))
        next()
    }

    private func next() {
        guard working == nil, !queue.isEmpty else { return }
        let (url, isVideo, duration) = queue.removeFirst()
        working = url
        Task.detached(priority: .utility) {
            let result = isVideo ? await Self.seeVideo(url, duration: duration) : await Self.seePhotoDescribed(url)
            await MainActor.run {
                let store = SceneTagStore.shared
                store.working = nil
                if store.stale.remove(url.path) != nil {
                    if let job = store.again.removeValue(forKey: url.path) { store.queue.append(job) }
                } else if let result {
                    store.made[url.path] = result
                    store.save(result, for: url)
                    store.version += 1
                }
                store.next()
            }
        }
    }

    // MARK: On disk

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Named with the version of how tags are chosen, so a change makes them again (3: with Apple
    /// Intelligence's keywords).
    private func file(for url: URL) -> URL { Self.folder.appendingPathComponent(ReverseAudio.cacheName(for: url) + "-3.json") }

    private func load(_ url: URL) -> SceneTags? {
        guard let data = try? Data(contentsOf: file(for: url)), let t = try? JSONDecoder().decode(SceneTags.self, from: data) else { return nil }
        made[url.path] = t
        return t
    }

    private func save(_ t: SceneTags, for url: URL) {
        if let data = try? JSONEncoder().encode(t) { try? data.write(to: file(for: url), options: .atomic) }
    }

    // MARK: Looking

    /// Kept: tags Vision is fairly sure of somewhere in the clip.
    nonisolated static let sure = 0.35

    nonisolated static func seeVideo(_ url: URL, duration: Double) async -> SceneTags? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let n = min(20, max(8, Int(duration.rounded())))
        var seen: [(Double, [(String, Double)])] = []
        for i in 0..<n {
            let t = duration * (Double(i) + 0.5) / Double(n)
            guard let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            seen.append((t, classify(image)))
        }
        guard !seen.isEmpty else { return nil }
        var tags = gather(seen)
        // What Apple Intelligence sees in a few frames: vehicles, expressions, actions and moods that
        // Vision's fixed labels miss, especially in close-ups ("car", "laughter", "jumping").
        let picks = Array(Set((0..<min(6, max(2, Int(duration / 3)))).map { i in
            duration * (Double(i) + 0.5) / Double(min(6, max(2, Int(duration / 3))))
        })).sorted()
        var described: [(Double, [String])] = []
        for t in picks {
            guard let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                  let words = await describe(image) else { continue }
            described.append(((t * 100).rounded() / 100, words))
        }
        tags.add(described)
        return tags
    }

    /// Up to a dozen keywords for a frame from Apple's on-device model (macOS 27 with Apple Intelligence
    /// that can see images); nil where it can't.
    nonisolated static func describe(_ image: CGImage) async -> [String]? {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable, model.capabilities.contains(.vision) else { return nil }
            let session = LanguageModelSession(instructions: """
                You label video frames for search. Reply with one line: up to 12 short comma-separated keywords \
                for the place, vehicles, objects, activity and people's expressions. Plain words, no sentences.
                """)
            guard let reply = try? await session.respond(to: Prompt { "Keywords for this frame:"; Attachment(image) }) else { return nil }
            let words = reply.content.lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }.filter { !$0.isEmpty && $0.count <= 30 && $0.split(separator: " ").count <= 3 }
            return words.isEmpty ? nil : Array(words.prefix(12))
        }
        #endif
        return nil
    }

    /// Every label Vision gives anywhere in a video at 0.2 or more, surest first (for testing).
    nonisolated static func allLabels(_ url: URL, duration: Double) async -> String {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        var best: [String: Double] = [:]
        let n = min(20, max(8, Int(duration.rounded())))
        for i in 0..<n {
            guard let image = try? await gen.image(at: CMTime(seconds: duration * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)).image else { continue }
            for (name, c) in classify(image) { best[name] = max(best[name] ?? 0, c) }
        }
        return best.sorted { $0.value > $1.value }.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
    }

    nonisolated static func seePhoto(_ url: URL) -> SceneTags? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
              ] as CFDictionary) else { return nil }
        return gather([(0, classify(image))])
    }

    /// A photo with Apple Intelligence's keywords too.
    nonisolated static func seePhotoDescribed(_ url: URL) async -> SceneTags? {
        guard var tags = seePhoto(url) else { return nil }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 768,
           ] as CFDictionary), let words = await describe(image) {
            tags.add([(0, words)])
        }
        return tags
    }

    nonisolated private static func classify(_ image: CGImage) -> [(String, Double)] {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { Double($0.confidence) >= 0.2 }
            .map { ($0.identifier.replacingOccurrences(of: "_", with: " "), Double($0.confidence)) }
    }

    nonisolated private static func gather(_ seen: [(Double, [(String, Double)])]) -> SceneTags {
        var best: [String: (Double, [Double])] = [:]
        for (t, labels) in seen {
            for (name, c) in labels {
                var e = best[name] ?? (0, [])
                e.0 = max(e.0, c)
                if c >= sure { e.1.append((t * 100).rounded() / 100) }
                best[name] = e
            }
        }
        let tags = best.filter { $0.value.0 >= sure }
            .map { SceneTags.Tag(name: $0.key, confidence: ($0.value.0 * 100).rounded() / 100, times: $0.value.1) }
            .sorted { $0.confidence > $1.confidence }
        return SceneTags(tags: tags)
    }
}
