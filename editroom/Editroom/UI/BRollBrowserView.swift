import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// Decodes and caches keyframe thumbnails for indexed local B-roll segments off `@MainActor`.
actor BRollThumbnailLoader {
    static let shared = BRollThumbnailLoader()
    private var cache: [String: Data] = [:]

    func thumbnailTIFF(for hit: BRollSearchHit) async -> Data? {
        let key = "\(hit.assetPath)#\(Int((hit.startSec * 1000).rounded()))"
        if let cached = cache[key] { return cached }

        let url = URL(fileURLWithPath: hit.assetPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ext = url.pathExtension.lowercased()
        let img: CGImage?
        if BRollIndexer.imageExtensions.contains(ext) {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 192,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                    ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
            } else {
                img = nil
            }
        } else {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 192, height: 192)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            let sampleT = hit.startSec + min(0.4, max(0, (hit.endSec - hit.startSec) * 0.5))
            img = try? await gen.image(at: CMTime(seconds: sampleT, preferredTimescale: 600)).image
        }

        guard let img,
              let tiff = NSBitmapImageRep(cgImage: img).tiffRepresentation else { return nil }
        if cache.count > 240 { cache.removeAll() }
        cache[key] = tiff
        return tiff
    }
}

/// Visual B-roll context browser backed by `BRollFTSIndex` (`I5`, Tier 1), supporting accented & unaccented Vietnamese search.
struct BRollBrowserView: View {
    @ObservedObject var model: EditorModel
    var indexOverride: BRollFTSIndex? = nil

    @AppStorage("brollLastFolder") private var lastFolderPath = ""
    @State private var query = ""
    @State private var hits: [BRollSearchHit] = []
    @State private var totalFiles = 0
    @State private var totalSegments = 0
    @State private var indexing = false
    @State private var insertingKey: String?
    @State private var statusBanner: String?
    @State private var errorMessage: String?
    @State private var thumbs: [String: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(totalSegments > 0 ? Color(hex: 0x39B54A) : Theme.textFaint)
                        .frame(width: 6, height: 6)
                    Text("\(totalFiles) files · \(totalSegments) segs")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(totalSegments > 0 ? Theme.text : Theme.textFaint)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.field))
                .overlay(Capsule().strokeBorder(Theme.stroke))

                Spacer()

                if !lastFolderPath.isEmpty, !indexing {
                    IconButton(symbol: "arrow.clockwise", size: 24, help: "Re-index \(URL(fileURLWithPath: lastFolderPath).lastPathComponent)") {
                        startIndexing(folder: URL(fileURLWithPath: lastFolderPath, isDirectory: true))
                    }
                }
                PillButton(title: indexing ? "Indexing…" : "Index Folder…", prominent: totalSegments == 0) {
                    pickFolderAndIndex()
                }
                .disabled(indexing)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                TextField("Search Vietnamese/English B-roll…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .onChange(of: query) { _, _ in reloadHits() }
                if indexing {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        reloadHits()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xE5735C))
                    .lineLimit(2)
            } else if let statusBanner {
                Text(statusBanner)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x39B54A))
                    .lineLimit(1)
            }

            if hits.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(totalSegments == 0 ? "Local B-Roll Index is Empty" : "No Matching Scenes")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(totalSegments == 0
                         ? "Index a local footage folder once with Apple Vision / Local VLM to search scenes in Vietnamese or English and drop cuts onto V2."
                         : "Try another Vietnamese/English keyword (e.g. cà phê, đường phố, laptop) or clear the filter.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if totalSegments == 0 {
                        PillButton(title: "Index B-Roll Folder…", prominent: true) { pickFolderAndIndex() }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(hits, id: \.selfKey) { hit in
                            brollCard(hit)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onAppear { reloadHits() }
    }

    @ViewBuilder
    private func brollCard(_ hit: BRollSearchHit) -> some View {
        let key = hit.selfKey
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.bg)
                    .frame(width: 64, height: 36)
                if let thumb = thumbs[key] {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 64, height: 36)
                }
                Text(String(format: "%.0f–%.0fs", hit.startSec, hit.endSec))
                    .font(Theme.mono(8.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.65)))
                    .padding(2)
            }
            .task(id: key) {
                guard thumbs[key] == nil,
                      let tiff = await BRollThumbnailLoader.shared.thumbnailTIFF(for: hit),
                      let ns = NSImage(data: tiff) else { return }
                thumbs[key] = ns
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.description.isEmpty ? hit.assetName : hit.description)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                let meta = ([hit.assetName] + hit.tags.prefix(3)).joined(separator: " · ")
                Text(meta)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if insertingKey == key {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            } else {
                PillButton(title: "Add V2", prominent: true) { insertHitOnV2(hit) }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func openIndex() throws -> BRollFTSIndex {
        if let indexOverride { return indexOverride }
        return try BRollFTSIndex()
    }

    private func reloadHits() {
        do {
            let idx = try openIndex()
            let s = try idx.stats()
            totalFiles = s.files
            totalSegments = s.segments
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            hits = q.isEmpty ? try idx.listRecent(limit: 40) : try idx.search(query: q, limit: 30)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickFolderAndIndex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Index B-Roll"
        if panel.runModal() == .OK, let url = panel.url {
            lastFolderPath = url.path
            startIndexing(folder: url)
        }
    }

    private func startIndexing(folder: URL) {
        indexing = true
        errorMessage = nil
        statusBanner = nil
        let vlmPrefs = VLMIndexPrefs.load()
        let overrideIdx = indexOverride
        Task {
            do {
                let stats: (files: Int, segments: Int, usedProvider: String) = try await Task.detached(priority: .userInitiated) {
                    let idx = try overrideIdx ?? BRollFTSIndex()
                    let primary = LocalVLMVisionProvider(baseURL: vlmPrefs.vlmBaseURL, model: vlmPrefs.vlmModel)
                    return try await BRollIndexer().indexFolder(
                        folder,
                        index: idx,
                        provider: primary,
                        fallbackProvider: AppleVisionFallbackProvider(),
                        sampleIntervalSec: vlmPrefs.sampleIntervalSec
                    )
                }.value
                reloadHits()
                statusBanner = "Indexed \(stats.files) files (\(stats.segments) segs · \(stats.usedProvider))"
            } catch {
                errorMessage = SecretRedactor.redact(error.localizedDescription)
            }
            indexing = false
        }
    }

    private func insertHitOnV2(_ hit: BRollSearchHit) {
        let key = hit.selfKey
        insertingKey = key
        errorMessage = nil
        statusBanner = nil
        Task {
            do {
                let turnId = "broll-\(UUID().uuidString.prefix(8))"
                let at = max(0, model.playhead)
                let dur = max(0.5, hit.endSec - hit.startSec)
                try model.beginAgentTurn(turnId: turnId, summary: "Add B-roll \(hit.assetName)")
                do {
                    _ = try await MCPTools.call("insert_broll_overlay", [
                        "asset_path": hit.assetPath,
                        "timeline_start": at,
                        "source_start": hit.startSec,
                        "duration": dur,
                        "mute_audio": true,
                    ], model: model, client: nil, draft: model.activeAgentTurn?.draft, isExternal: false)
                    _ = try model.commitAgentTurn(turnId: turnId)
                    statusBanner = String(format: "Added %@ on V2 @ %.1fs", hit.assetName, at)
                } catch {
                    _ = try? model.rollbackAgentTurn(turnId: turnId)
                    throw error
                }
            } catch {
                errorMessage = SecretRedactor.redact(error.localizedDescription)
            }
            insertingKey = nil
        }
    }
}

private extension BRollSearchHit {
    var selfKey: String { "\(assetPath)#\(Int((startSec * 1000).rounded()))-\(Int((endSec * 1000).rounded()))" }
}
