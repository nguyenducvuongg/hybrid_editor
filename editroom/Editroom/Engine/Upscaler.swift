import CoreImage
import Metal
import MetalFX

/// Enlarges a picture with MetalFX's spatial upscaler, which rebuilds edges and fine detail rather than
/// stretching pixels. Used on export, where a clip is drawn bigger than its own pixels (a 1080p sequence
/// exported at 4K, or a 1080p clip in a 4K sequence). Nil when it can't (no Metal, an unsupported Mac, a
/// size it doesn't take): the caller then resizes as before.
final class Upscaler: @unchecked Sendable {
    static let shared = Upscaler()

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private let lock = NSLock()
    /// One scaler per input and output size.
    private var scalers: [String: MTLFXSpatialScaler] = [:]
    /// Textures by layer and size, reused frame to frame. A layer's output is read when the frame is drawn,
    /// before the next frame asks for it again (frames are drawn one at a time).
    private var textures: [String: MTLTexture] = [:]

    /// Whether this Mac can do it at all.
    var available: Bool {
        guard let device else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    /// `image` (its extent at the origin) enlarged to `size`. `slot` keeps layers drawn in the same frame apart.
    func upscale(_ image: CIImage, to size: CGSize, slot: Int, context: CIContext) -> CIImage? {
        guard let device, let queue, available else { return nil }
        let e = image.extent
        let iw = Int(e.width.rounded()), ih = Int(e.height.rounded())
        let ow = Int(size.width.rounded()), oh = Int(size.height.rounded())
        guard iw > 1, ih > 1, ow > iw, oh > ih, ow <= 16384, oh <= 16384 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let key = "\(iw)x\(ih)>\(ow)x\(oh)"
        let scaler: MTLFXSpatialScaler
        if let s = scalers[key] {
            scaler = s
        } else {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = iw
            d.inputHeight = ih
            d.outputWidth = ow
            d.outputHeight = oh
            d.colorTextureFormat = .rgba16Float
            d.outputTextureFormat = .rgba16Float
            // The picture is gamma-encoded video, not linear light.
            d.colorProcessingMode = .perceptual
            guard let s = d.makeSpatialScaler(device: device) else { return nil }
            if scalers.count > 16 { scalers.removeAll() }
            scalers[key] = s
            scaler = s
        }
        guard let input = texture("\(slot)-in-\(iw)x\(ih)", iw, ih, usage: scaler.colorTextureUsage.union([.shaderWrite, .renderTarget])),
              let output = texture("\(slot)-out-\(ow)x\(oh)", ow, oh, usage: scaler.outputTextureUsage.union(.shaderRead)),
              let buffer = queue.makeCommandBuffer() else { return nil }

        // Into the input texture as it is (no colour conversion: the compositor works without colour management).
        let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        context.render(image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)), to: input,
                       commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: iw, height: ih), colorSpace: space)
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.inputContentWidth = iw
        scaler.inputContentHeight = ih
        scaler.encode(commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed,
              let out = CIImage(mtlTexture: output, options: [.colorSpace: NSNull()]) else { return nil }
        // Core Image writes and reads the texture the same way round, so it comes back the right way up.
        return out
    }

    /// Lets go of the textures and scalers (after an export).
    func purge() {
        lock.lock()
        textures.removeAll()
        scalers.removeAll()
        lock.unlock()
    }

    private func texture(_ key: String, _ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture? {
        if let t = textures[key] { return t }
        guard let device else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        if textures.count > 24 { textures.removeAll() }
        textures[key] = t
        return t
    }
}
