import AppKit
import AVFoundation

/// One picture of a library item for an agent to look at: a photo as it is, or frames from across a
/// video laid out in a grid, each marked with its time in the file.
enum ContactSheet {
    /// The sheet as JPEG, with the times (in the file) of the frames on it, in reading order.
    static func make(_ asset: MediaAsset, frames: Int, around times: [Double]? = nil) async -> (jpeg: Data, times: [Double])? {
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 768,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary),
                  let jpeg = jpeg(img) else { return nil }
            return (jpeg, [])
        }
        guard asset.kind == .video, asset.duration > 0 else { return nil }
        let wanted: [Double]
        if let times, !times.isEmpty {
            wanted = Array(times.map { min(max(0, $0), max(0, asset.duration - 0.05)) }.prefix(12))
        } else {
            let n = max(1, min(12, frames))
            wanted = (0..<n).map { (Double($0) + 0.5) * asset.duration / Double(n) }
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        var got: [(Double, CGImage)] = []
        for await result in gen.images(for: wanted.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if let img = try? result.image { got.append((result.requestedTime.seconds, img)) }
        }
        got.sort { $0.0 < $1.0 }
        guard let first = got.first?.1 else { return nil }

        // A grid of up to four across, each cell the frame's shape, with its time in the corner.
        let columns = min(4, got.count <= 4 ? got.count : got.count <= 6 ? 3 : 4)
        let rows = (got.count + columns - 1) / columns
        let cellW = CGFloat(first.width), cellH = CGFloat(first.height)
        let gap: CGFloat = 4
        let size = CGSize(width: CGFloat(columns) * cellW + CGFloat(columns - 1) * gap,
                          height: CGFloat(rows) * cellH + CGFloat(rows - 1) * gap)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        for (i, (t, img)) in got.enumerated() {
            let x = CGFloat(i % columns) * (cellW + gap)
            let y = size.height - CGFloat(i / columns + 1) * cellH - CGFloat(i / columns) * gap
            let cell = CGRect(x: x, y: y, width: cellW, height: cellH)
            // Frames of another shape (a rotated clip) fit inside the cell.
            let s = min(cellW / CGFloat(img.width), cellH / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.draw(img, in: CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h))
            let label = String(format: "%.1fs", t) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let ls = label.size(withAttributes: attrs)
            let box = CGRect(x: cell.minX + 4, y: cell.maxY - ls.height - 8, width: ls.width + 8, height: ls.height + 4)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.fill(box)
            label.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let sheet = ctx.makeImage(), let jpeg = jpeg(sheet) else { return nil }
        return (jpeg, got.map(\.0))
    }

    private static func jpeg(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
