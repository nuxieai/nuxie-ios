#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Metal
import QuartzCore

enum NativePixelReadbackError {
    case unexpectedPixelFormat(MTLPixelFormat)
    case resourceCreationFailed
    case commandFailed(String)
}

extension NativePixelReadbackError: Error {}

final class NativeOwnedMetalDrawable: NSObject {
    let texture: any MTLTexture
    let layer: CAMetalLayer

    private let lock = NSLock()
    private var presented = false

    var wasPresented: Bool {
        lock.lock()
        defer { lock.unlock() }
        return presented
    }

    init(texture: any MTLTexture, layer: CAMetalLayer) {
        self.texture = texture
        self.layer = layer
        super.init()
    }

    private func markPresented() {
        lock.lock()
        presented = true
        lock.unlock()
    }
}

extension NativeOwnedMetalDrawable: CAMetalDrawable {
    func present() {
        markPresented()
    }

    func present(at presentationTime: CFTimeInterval) {
        markPresented()
    }
}

struct NativeBGRA8Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func changedPixelCount(comparedTo other: NativeBGRA8Pixels) -> Int {
        precondition(width == other.width && height == other.height)
        precondition(bytes.count == other.bytes.count)
        return stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) {
            count, offset in
            if bytes[offset..<(offset + 4)]
                != other.bytes[offset..<(offset + 4)] {
                count += 1
            }
        }
    }

    func alphaChangedPixelCount(comparedTo other: NativeBGRA8Pixels) -> Int {
        precondition(width == other.width && height == other.height)
        precondition(bytes.count == other.bytes.count)
        return stride(from: 3, to: bytes.count, by: 4).reduce(into: 0) {
            count, alphaOffset in
            if bytes[alphaOffset] != other.bytes[alphaOffset] {
                count += 1
            }
        }
    }

    /// Projects the signed quarter-frame alpha delta onto the exact authored
    /// start-to-end alpha mask. RGB-only changes cannot satisfy this oracle.
    func alphaProgress(
        from start: NativeBGRA8Pixels,
        to end: NativeBGRA8Pixels
    ) -> Double {
        precondition(width == start.width && height == start.height)
        precondition(width == end.width && height == end.height)
        precondition(bytes.count == start.bytes.count)
        precondition(bytes.count == end.bytes.count)

        var numerator = 0.0
        var denominator = 0.0
        for alphaOffset in stride(from: 3, to: bytes.count, by: 4) {
            let startAlpha = Double(start.bytes[alphaOffset])
            let endVector = Double(end.bytes[alphaOffset]) - startAlpha
            guard endVector != 0 else { continue }
            let quarterVector = Double(bytes[alphaOffset]) - startAlpha
            numerator += quarterVector * endVector
            denominator += endVector * endVector
        }
        guard denominator > 0 else { return .nan }
        return numerator / denominator
    }
}

enum NativePixelCapture {
    /// Vends a caller-owned drawable whose `present` is intentionally a no-op.
    /// A CAMetalLayer may recycle or discard a real drawable's texture as soon
    /// as it is presented, so reading one afterward is undefined. Retaining
    /// this texture gives the fixture an exact post-completion view of the
    /// pixels the runtime submitted without changing the production render
    /// path or introducing an unrelated composited background.
    static func makeOwnedReadbackDrawable(
        layer: CAMetalLayer
    ) throws -> NativeOwnedMetalDrawable {
        let width = Int(layer.drawableSize.width)
        let height = Int(layer.drawableSize.height)
        guard width > 0,
              height > 0,
              let device = layer.device else {
            throw NativePixelReadbackError.resourceCreationFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NativePixelReadbackError.resourceCreationFailed
        }
        return NativeOwnedMetalDrawable(texture: texture, layer: layer)
    }

    static func readbackBGRA8(
        _ texture: any MTLTexture
    ) throws -> NativeBGRA8Pixels {
        guard texture.pixelFormat == .bgra8Unorm else {
            throw NativePixelReadbackError.unexpectedPixelFormat(
                texture.pixelFormat
            )
        }
        let tightBytesPerRow = texture.width * 4
        let alignedBytesPerRow = ((tightBytesPerRow + 255) / 256) * 256
        let byteCount = alignedBytesPerRow * texture.height
        guard let queue = texture.device.makeCommandQueue(),
              let buffer = texture.device.makeBuffer(
                length: byteCount,
                options: .storageModeShared
              ),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw NativePixelReadbackError.resourceCreationFailed
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: texture.width,
                height: texture.height,
                depth: 1
            ),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: alignedBytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw NativePixelReadbackError.commandFailed(
                commandBuffer.error.map(String.init(describing:))
                    ?? "unknown Metal readback failure"
            )
        }

        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tightBytesPerRow * texture.height)
        for row in 0..<texture.height {
            bytes.append(
                contentsOf: UnsafeBufferPointer(
                    start: source + row * alignedBytesPerRow,
                    count: tightBytesPerRow
                )
            )
        }
        return NativeBGRA8Pixels(
            width: texture.width,
            height: texture.height,
            bytes: bytes
        )
    }
}
#endif
