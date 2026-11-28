import AppKit
import CoreImage

/// One caption as it's drawn: its words, which one is lit (the one being said), and when. Drawn in the
/// output's own frame, after any crop to another shape, so captions stay whole and in place on a
/// vertical or square export of a wide sequence.
struct CaptionLayer {
    let start: Double
    let end: Double
    let words: [String]
    let lit: Int?
    let style: CaptionStyle

    /// The caption placed on a frame of this size.
    func image(output: CGSize) -> CIImage? {
        CaptionRenderer.image(words: words, lit: lit, style: style, output: output)
    }
}

enum CaptionRenderer {
    /// Each caption, split by word when the word being said lights up.
    static func layers(_ blocks: [CaptionBlock], style: CaptionStyle) -> [CaptionLayer] {
        var out: [CaptionLayer] = []
        for b in blocks {
            let words = b.words.map(\.text)
            guard style.highlight, words.count > 1 else {
                out.append(CaptionLayer(start: b.start, end: b.end, words: words, lit: style.highlight ? 0 : nil, style: style))
                continue
            }
            for (i, w) in b.words.enumerated() {
                let start = i == 0 ? b.start : w.start
                let end = i + 1 < b.words.count ? b.words[i + 1].start : b.end
                guard end > start else { continue }
                out.append(CaptionLayer(start: start, end: end, words: words, lit: i, style: style))
            }
        }
        return out
    }

    private struct Key: Hashable {
        let words: [String]
        let lit: Int?
        /// The style, less its height in the frame (placed after drawing).
        let style: CaptionStyle
        let w: Int
        let h: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: CIImage] = [:]

    /// The caption, centred across the frame at the style's height. Drawn once and kept.
    static func image(words: [String], lit: Int?, style: CaptionStyle, output: CGSize) -> CIImage? {
        guard !words.isEmpty, output.width > 0, output.height > 0 else { return nil }
        var look = style
        look.y = 0
        let key = Key(words: words, lit: lit, style: look, w: Int(output.width), h: Int(output.height))
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        let drawn = hit ?? draw(words: words, lit: lit, style: style, output: output)
        guard let drawn else { return nil }
        if hit == nil {
            lock.lock()
            if cache.count > 400 { cache.removeAll() }
            cache[key] = drawn
            lock.unlock()
        }
        // Centred, its middle at the style's height, kept inside the frame.
        let e = drawn.extent
        let cy = (1 - style.y) * output.height
        let y = min(max(cy - e.height / 2, 0), output.height - e.height)
        return drawn.transformed(by: CGAffineTransform(translationX: ((output.width - e.width) / 2).rounded(), y: y.rounded()))
    }

    /// Heavy words in the text colour, with an outline or active karaoke pill if enabled, the lit one highlighted.
    private static func draw(words: [String], lit: Int?, style: CaptionStyle, output: CGSize) -> CIImage? {
        let pt = CGFloat(style.size) * min(output.width, output.height) / 1080
        let activeScale = CGFloat(min(CaptionStyle.scaleRange.upperBound, max(CaptionStyle.scaleRange.lowerBound, style.activeScale)))
        let ns = { (c: RGBA) in NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        let baseFont = NSFont.systemFont(ofSize: pt, weight: .heavy)
        let litFont = activeScale > 1.001 ? NSFont.systemFont(ofSize: pt * activeScale, weight: .black) : baseFont
        let viLocale = Locale(identifier: "vi_VN")
        let renderedWords = style.uppercase ? words.map { $0.uppercased(with: viLocale) } : words
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping

        var litRange: NSRange?
        func text(fill: Bool) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for (i, w) in renderedWords.enumerated() {
                // A little wider than a plain space: the outline and active pill need breathing room.
                if i > 0 {
                    let spaceKern = style.pillHighlight ? pt * 0.14 : pt * 0.06
                    s.append(NSAttributedString(string: " ", attributes: [.font: baseFont, .kern: spaceKern]))
                }
                let isLit = (i == lit)
                let wordFont = isLit ? litFont : baseFont
                var attrs: [NSAttributedString.Key: Any] = [.font: wordFont, .paragraphStyle: para]
                if fill {
                    attrs[.foregroundColor] = ns(isLit ? style.highlightColor : style.textColor)
                } else if style.pillHighlight && isLit {
                    // Keep glyph metrics matching `fill` without drawing heavy outline inside the pill.
                    attrs[.foregroundColor] = NSColor.clear
                } else {
                    attrs[.foregroundColor] = ns(style.outlineColor)
                    attrs[.strokeColor] = ns(style.outlineColor)
                    attrs[.strokeWidth] = 22.0
                }
                let loc = s.length
                let part = NSAttributedString(string: w, attributes: attrs)
                s.append(part)
                if fill && isLit {
                    litRange = NSRange(location: loc, length: s.length - loc)
                }
            }
            s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
            return s
        }
        let fill = text(fill: true), outline = text(fill: false)
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let maxLayoutWidth = output.width * 0.86
        let bounds = fill.boundingRect(with: CGSize(width: maxLayoutWidth, height: .greatestFiniteMagnitude), options: opts)
        let padX = ceil(pt * 0.42)
        let padY = ceil(pt * 0.48)
        let tw = ceil(max(bounds.width, 1))
        let th = ceil(max(bounds.height, 1))
        let w = Int(tw + padX * 2), h = Int(th + padY * 2)
        guard w > 0, h > 0, w < 16384, h < 16384,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setLineJoin(.round)
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let r = CGRect(x: padX, y: padY, width: tw, height: th)

        if style.pillHighlight, let litRange, litRange.length > 0 {
            let storage = NSTextStorage(attributedString: fill)
            let lm = NSLayoutManager()
            let tc = NSTextContainer(size: CGSize(width: tw, height: th + padY))
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            storage.addLayoutManager(lm)
            lm.ensureLayout(for: tc)
            let glyphRange = lm.glyphRange(forCharacterRange: litRange, actualCharacterRange: nil)
            if glyphRange.length > 0 {
                let glyphRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                let flippedY = padY + th - glyphRect.maxY
                let pillRect = CGRect(x: padX + glyphRect.minX, y: flippedY, width: glyphRect.width, height: glyphRect.height)
                    .insetBy(dx: -pt * 0.18, dy: -pt * 0.08)
                    .intersection(CGRect(x: 2, y: 2, width: CGFloat(w - 4), height: CGFloat(h - 4)))
                if !pillRect.isNull && !pillRect.isEmpty {
                    let radius = min(pillRect.height * 0.35, pt * 0.24)
                    ns(style.pillColor).setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius).fill()
                }
            }
        }

        if style.outline { outline.draw(with: r, options: opts) }
        fill.draw(with: r, options: opts)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
