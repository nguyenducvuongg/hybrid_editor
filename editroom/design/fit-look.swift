// Applies candidate Looks to frames: looks <srcDir> <outDir>
import AppKit
import CoreGraphics

typealias RGB = (r: Double, g: Double, b: Double)

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func luma(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
func map(_ c: RGB, _ f: (Double) -> Double) -> RGB { (f(c.r), f(c.g), f(c.b)) }
/// Positive adds an S-curve, negative flattens.
func contrast(_ c: RGB, _ k: Double) -> RGB { map(c) { x in let s = x * x * (3 - 2 * x); return clamp(x + k * (s - x) * 2) } }
func fade(_ c: RGB, _ f: Double) -> RGB { map(c) { f + (1 - f) * $0 } }
func saturate(_ c: RGB, _ s: Double) -> RGB { let l = luma(c); return map(c) { clamp(l + s * ($0 - l)) } }
func add(_ c: RGB, _ t: RGB, _ w: Double = 1) -> RGB { (clamp(c.r + t.r * w), clamp(c.g + t.g * w), clamp(c.b + t.b * w)) }
func split(_ c: RGB, shadows: RGB, highlights: RGB) -> RGB {
    let l = luma(c)
    return add(add(c, shadows, (1 - l) * (1 - l)), highlights, l * l)
}
func toHSV(_ c: RGB) -> (h: Double, s: Double, v: Double) {
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
    var h = 0.0
    if d > 1e-6 {
        if mx == c.r { h = 60 * (((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)) }
        else if mx == c.g { h = 60 * ((c.b - c.r) / d + 2) }
        else { h = 60 * ((c.r - c.g) / d + 4) }
    }
    if h < 0 { h += 360 }
    return (h, mx > 0 ? d / mx : 0, mx)
}
func fromHSV(_ h: Double, _ s: Double, _ v: Double) -> RGB {
    let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
    let (r, g, b): (Double, Double, Double)
    switch h { case ..<60: (r, g, b) = (c, x, 0); case ..<120: (r, g, b) = (x, c, 0); case ..<180: (r, g, b) = (0, c, x)
    case ..<240: (r, g, b) = (0, x, c); case ..<300: (r, g, b) = (x, 0, c); default: (r, g, b) = (c, 0, x) }
    return (r + m, g + m, b + m)
}
/// Shifts hue and scales saturation for colours near `center`, fading out over `width` degrees.
func hueBand(_ c: RGB, center: Double, width: Double, shift: Double, sat: Double, value: Double = 1) -> RGB {
    var (h, s, v) = toHSV(c)
    var d = abs(h - center); if d > 180 { d = 360 - d }
    guard d < width else { return c }
    // Weighted by how coloured the pixel already is, so greys and near-whites are left alone.
    let w = (0.5 + 0.5 * cos(d / width * .pi)) * min(1, s * 2.5)
    h = (h + shift * w + 360).truncatingRemainder(dividingBy: 360)
    s = clamp(s * (1 + (sat - 1) * w))
    v = clamp(v * (1 + (value - 1) * w))
    return fromHSV(h, s, v)
}

/// The app's existing Teal and orange recipe, for comparison.
func tealOrange(_ c: RGB) -> RGB {
    var (r, g, b) = c
    let l = min(1, max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)), sh = 1 - l
    r += -0.05 * sh + 0.06 * l; g += 0.01 * sh + 0.01 * l; b += 0.05 * sh - 0.05 * l
    let k = 1 + 12.0 / 50 * 0.6
    r = (r - 0.5) * k + 0.5; g = (g - 0.5) * k + 0.5; b = (b - 0.5) * k + 0.5
    let l2 = 0.2126 * r + 0.7152 * g + 0.0722 * b, s = 1.1
    return (clamp(l2 + (r - l2) * s), clamp(l2 + (g - l2) * s), clamp(l2 + (b - l2) * s))
}

/// Warm skin, teal-olive shadows and greens, milky blacks, soft highlight roll-off.
func cinematic(_ c: RGB) -> RGB {
    var c = add(c, (0.04, 0.015, -0.035))
    // Skin (orange) richer; kept clear of true reds so faces don't go pink.
    c = hueBand(c, center: 28, width: 22, shift: 2, sat: 1.12)
    c = hueBand(c, center: 110, width: 60, shift: 22, sat: 0.68)
    c = hueBand(c, center: 210, width: 45, shift: -12, sat: 0.82)
    c = split(c, shadows: (-0.06, 0.04, 0.065), highlights: (0.045, 0.024, -0.03))
    c = contrast(c, -0.1)
    c = map(c) { x in x <= 0.72 ? x : 0.72 + (1 - 0.72) * (1 - exp(-(x - 0.72) / (1 - 0.72) * 1.2)) / (1 - exp(-1.2)) }
    c = fade(c, 0.05)
    c = saturate(c, 0.88)
    // Deep, rich reds, as print film gives: more saturated and a little darker, after the
    // overall mute so they stand out against the quieter colours.
    return hueBand(c, center: 356, width: 20, shift: 0, sat: 1.35, value: 0.93)
}


/// A .cube file applied with trilinear interpolation, for comparing against real LUTs.
func cubeLook(_ path: String) -> (RGB) -> RGB {
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    var size = 0
    var table: [RGB] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("LUT_3D_SIZE") { size = Int(t.split(separator: " ").last!)! ; continue }
        let parts = t.split(separator: " ").compactMap { Double($0) }
        if parts.count == 3, !t.hasPrefix("DOMAIN") { table.append((parts[0], parts[1], parts[2])) }
    }
    let n = size
    return { c in
        func at(_ r: Int, _ g: Int, _ b: Int) -> RGB { table[(b * n + g) * n + r] }
        let f = [c.r, c.g, c.b].map { clamp($0) * Double(n - 1) }
        let i0 = f.map { min(n - 2, Int($0)) }, d = (0..<3).map { f[$0] - Double(i0[$0]) }
        func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t) }
        let c00 = lerp(at(i0[0], i0[1], i0[2]), at(i0[0] + 1, i0[1], i0[2]), d[0])
        let c10 = lerp(at(i0[0], i0[1] + 1, i0[2]), at(i0[0] + 1, i0[1] + 1, i0[2]), d[0])
        let c01 = lerp(at(i0[0], i0[1], i0[2] + 1), at(i0[0] + 1, i0[1], i0[2] + 1), d[0])
        let c11 = lerp(at(i0[0], i0[1] + 1, i0[2] + 1), at(i0[0] + 1, i0[1] + 1, i0[2] + 1), d[0])
        return lerp(lerp(c00, c10, d[1]), lerp(c01, c11, d[1]), d[2])
    }
}


// Fits a parametric look to a reference .cube on sample frames: fit <cube> <frames...>
func model(_ c: RGB, _ p: [Double]) -> RGB {
    var c = add(c, (p[0], p[1], p[2]))
    c = map(c) { pow(clamp($0), p[3]) }
    c = hueBand(c, center: 28, width: 22, shift: p[4], sat: p[5])
    c = hueBand(c, center: 110, width: 60, shift: p[6], sat: p[7])
    c = hueBand(c, center: 210, width: 45, shift: p[8], sat: p[9])
    c = split(c, shadows: (p[10], p[11], p[12]), highlights: (p[13], p[14], p[15]))
    c = contrast(c, p[16])
    c = saturate(c, p[17])
    return hueBand(c, center: 356, width: 20, shift: 0, sat: p[18], value: p[19])
}
let args = CommandLine.arguments
let ref = cubeLook(args[1])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
var samples: [RGB] = []
for f in args.dropFirst(2) {
    let img = NSImage(contentsOfFile: f)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = 160, h = Int(Double(img.height) * 160 / Double(img.width))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(w * h) { samples.append((Double(d[i * 4]) / 255, Double(d[i * 4 + 1]) / 255, Double(d[i * 4 + 2]) / 255)) }
}
// Plus an even spread of colours, so the fit holds for footage unlike these frames.
for r in stride(from: 0.0, through: 1.0, by: 0.125) { for g in stride(from: 0.0, through: 1.0, by: 0.125) { for b in stride(from: 0.0, through: 1.0, by: 0.125) { samples.append((r, g, b)) } } }
let targets: [RGB] = samples.map { ref($0) }
func err(_ p: [Double]) -> Double {
    var e = 0.0
    for (s, t) in zip(samples, targets) {
        let m = model(s, p)
        let dr = m.r - t.r, dg = m.g - t.g, db = m.b - t.b
        e += dr * dr + dg * dg + db * db
    }
    return e / Double(samples.count)
}
var p: [Double] = ProcessInfo.processInfo.environment["P0"].map { $0.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces))! } } ?? [0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1]
var steps: [Double] = [0.02, 0.02, 0.02, 0.05, 4, 0.1, 6, 0.1, 6, 0.1, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.1, 0.1, 0.1, 0.05]
var best = err(p)
print("start rms", sqrt(best / 3) * 255)
for round in 0..<(Int(ProcessInfo.processInfo.environment["ROUNDS"] ?? "14") ?? 14) {
    for i in p.indices {
        for dir in [1.0, -1.0] {
            var improved = true
            while improved {
                var q = p; q[i] += dir * steps[i]
                let e = err(q)
                if e < best { best = e; p = q } else { improved = false }
            }
        }
    }
    steps = steps.map { $0 * 0.8 }
    print("round", round, "rms", String(format: "%.2f", sqrt(best / 3) * 255))
}
print("P", p.map { String(format: "%.4f", $0) }.joined(separator: ", "))
