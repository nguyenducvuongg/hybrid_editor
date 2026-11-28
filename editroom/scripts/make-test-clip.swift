// Writes a test clip whose colours are known exactly: six flat patches (grey, white, red, green,
// blue, skin) plus a small moving square. Usage:
//   swiftc -O scripts/make-test-clip.swift -o /tmp/gen && /tmp/gen <out.mov> <sdr|hlg|pq|applelog> <hevc8|hevc10|h264|prores422hq> <w> <h> <fps> <seconds>
import AVFoundation
import CoreVideo
import VideoToolbox

let a = CommandLine.arguments
let out = URL(fileURLWithPath: a[1]), curve = a[2], codec = a[3]
let W = Int(a[4])!, H = Int(a[5])!, fps = Int(a[6])!, secs = Double(a[7])!

// Patches in sRGB 0...255.
let patches: [(Double, Double, Double)] = [(118, 118, 118), (235, 235, 235), (200, 40, 40), (40, 170, 60), (40, 60, 200), (224, 172, 105)]

func srgbToLinear(_ v: Double) -> Double { let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func mul(_ m: [[Double]], _ v: [Double]) -> [Double] { m.map { $0[0] * v[0] + $0[1] * v[1] + $0[2] * v[2] } }
let m709to2020 = [[0.6274, 0.3293, 0.0433], [0.0691, 0.9195, 0.0114], [0.0164, 0.0880, 0.8956]]

func oetf(_ e: Double) -> Double {
    switch curve {
    case "hlg":
        let x = max(0, e) * 0.2647 // SDR white sits at 75% HLG (BT.2408)
        return x <= 1.0 / 12 ? (3 * x).squareRoot() : 0.17883277 * log(12 * x - 0.28466892) + 0.55991073
    case "pq":
        let y = max(0, e) * 203 / 10000
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(y, m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    case "applelog":
        let r = e, R0 = -0.05641088, Rt = 0.01, c = 47.28711236, b = 0.00964052, g = 0.08550479, be = 0.69336945
        if r >= Rt { return g * log2(r + b) + be }
        if r >= R0 { return c * (r - R0) * (r - R0) }
        return 0
    default: // BT.709
        let x = max(0, e)
        return x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099
    }
}

let wide = curve != "sdr"
let tenBit = codec != "hevc8" && codec != "h264"
// R'G'B' -> Y'CbCr, BT.2020 or BT.709 non-constant luminance.
let (kr, kb) = wide ? (0.2627, 0.0593) : (0.2126, 0.0722)
func ycc(_ rgb: (Double, Double, Double)) -> (Int, Int, Int) {
    var lin = [srgbToLinear(rgb.0), srgbToLinear(rgb.1), srgbToLinear(rgb.2)]
    if wide { lin = mul(m709to2020, lin) }
    let r = oetf(lin[0]), g = oetf(lin[1]), b = oetf(lin[2])
    let y = kr * r + (1 - kr - kb) * g + kb * b
    let cb = (b - y) / (2 * (1 - kb)), cr = (r - y) / (2 * (1 - kr))
    let s = tenBit ? 4.0 : 1.0
    return (Int((16 * s + 219 * s * y).rounded()), Int((128 * s + 224 * s * cb).rounded()), Int((128 * s + 224 * s * cr).rounded()))
}
let codes = patches.map(ycc)
let whiteCode = ycc((255, 255, 255))

let settings: [String: Any] = {
    var s: [String: Any] = [AVVideoWidthKey: W, AVVideoHeightKey: H]
    switch codec {
    case "h264": s[AVVideoCodecKey] = AVVideoCodecType.h264
    case "prores422hq": s[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
    default:
        s[AVVideoCodecKey] = AVVideoCodecType.hevc
        s[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : kVTProfileLevel_HEVC_Main_AutoLevel as String,
                                              AVVideoQualityKey: 0.9]
    }
    var color: [String: Any] = [
        AVVideoColorPrimariesKey: wide ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: wide ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
    switch curve {
    case "hlg": color[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_2100_HLG
    case "pq": color[AVVideoTransferFunctionKey] = AVVideoTransferFunction_SMPTE_ST_2084_PQ
    case "applelog": color[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_709_2 // overridden by the log tag below
    default: color[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_709_2
    }
    s[AVVideoColorPropertiesKey] = color
    return s
}()

try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let fmt = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: fmt, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frames = Int(secs * Double(fps))
for f in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!, cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
    let sq = H / 8, sqX = (f * 7) % max(1, W - sq), sqY = H - sq - 4
    func code(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        if x >= sqX && x < sqX + sq && y >= sqY && y < sqY + sq { return whiteCode }
        return codes[min(5, x * 6 / W)]
    }
    for y in 0..<H {
        for x in 0..<W {
            let c = code(x, y).0
            if tenBit { (yBase + y * yStride).assumingMemoryBound(to: UInt16.self)[x] = UInt16(c << 6) }
            else { (yBase + y * yStride).assumingMemoryBound(to: UInt8.self)[x] = UInt8(clamping: c) }
        }
    }
    for y in 0..<(H / 2) {
        for x in 0..<(W / 2) {
            let c = code(x * 2, y * 2)
            if tenBit {
                let row = (cBase + y * cStride).assumingMemoryBound(to: UInt16.self)
                row[x * 2] = UInt16(c.1 << 6); row[x * 2 + 1] = UInt16(c.2 << 6)
            } else {
                let row = (cBase + y * cStride).assumingMemoryBound(to: UInt8.self)
                row[x * 2] = UInt8(clamping: c.1); row[x * 2 + 1] = UInt8(clamping: c.2)
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, (wide ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2), .shouldPropagate)
    CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, (wide ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2), .shouldPropagate)
    let tf: CFString = curve == "hlg" ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : curve == "pq" ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2
    CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, tf, .shouldPropagate)
    if curve == "applelog" { CVBufferSetAttachment(buf, kCVImageBufferLogTransferFunctionKey, kCVImageBufferLogTransferFunction_AppleLog, .shouldPropagate) }
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(out.lastPathComponent)" : "FAILED \(writer.error.map { "\($0)" } ?? "")")
