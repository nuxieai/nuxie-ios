#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import ImageIO

/// Canonical pixels handed from the Apple decoder to configured native import.
package struct NuxieNativeDecodedImage {
    package let width: UInt32
    package let height: UInt32
    package let rowBytes: UInt32
    package let pixels: NSMutableData

    package static func decode(
        _ encoded: Data,
        maximumDimension: UInt32,
        maximumDecodedBytes: Int
    ) -> Self? {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0,
              image.width <= Int(maximumDimension),
              image.height <= Int(maximumDimension) else {
            return nil
        }
        let (rowBytes, rowOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = rowBytes.multipliedReportingOverflow(by: image.height)
        guard !rowOverflow, !countOverflow,
              byteCount <= maximumDecodedBytes,
              let colors = CGColorSpace(name: CGColorSpace.sRGB),
              let pixels = NSMutableData(length: byteCount),
              let bitmap = CGContext(
                data: pixels.mutableBytes,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colors,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return nil
        }
        let drawable = drawableImage(image, encoded: encoded)
        bitmap.draw(
            drawable,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return Self(
            width: UInt32(image.width),
            height: UInt32(image.height),
            rowBytes: UInt32(rowBytes),
            pixels: pixels
        )
    }

    // Swift initializes static lets once, with synchronization across callers.
    // Probe ImageIO itself: an OS name or alpha label cannot distinguish these bytes.
    package static let indexedPNGNeedsAlphaRelabeling: Bool = {
        // Four 2-bit palette entries share straight (255,64,32), at alpha 0,64,128,255.
        // Multiple alpha levels exercise ImageIO's palette expansion path.
        guard let encoded = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAQAAAABAgMAAACEUudeAAAAAXNSR0IArs4c6QAAAAxQTFRF/0Ag/0Ag/0Ag/0AgXACsbQAAAAR0Uk5TAECA/9WInJwAAAAKSURBVHicY5AGAAAdAByO9PUhAAAAAElFTkSuQmCC"
        ), let source = CGImageSourceCreateWithData(encoded as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           image.alphaInfo == .last,
           image.bitsPerComponent == 8,
           image.bitsPerPixel == 32,
           let data = image.dataProvider?.data,
           CFDataGetLength(data) >= 8,
           let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        return Array(UnsafeBufferPointer(start: bytes + 4, count: 4)) == [64, 16, 8, 64]
    }()

    package static func drawableImage(
        _ image: CGImage,
        encoded: Data,
        needsAlphaRelabeling: Bool = indexedPNGNeedsAlphaRelabeling,
        copyImage: (CGImage) -> CGImage? = copyWithPremultipliedAlpha
    ) -> CGImage {
        let header = Array(encoded.prefix(26))
        let indexedPNG = header.count == 26
            && header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            && Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82]
            && header[25] == 3 // PNG IHDR indexed-color type.
        guard needsAlphaRelabeling, indexedPNG,
              image.alphaInfo == .last,
              image.bitsPerComponent == 8,
              image.bitsPerPixel == 32 else {
            return image
        }
        // Failure to correct the description must still allow the original draw.
        return copyImage(image) ?? image
    }

    package static func copyWithPremultipliedAlpha(_ image: CGImage) -> CGImage? {
        guard let data = image.dataProvider?.data,
              let provider = CGDataProvider(data: data),
              let colors = image.colorSpace else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue:
            (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue)
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel,
            bytesPerRow: image.bytesPerRow,
            space: colors,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: image.decode,
            shouldInterpolate: image.shouldInterpolate,
            intent: image.renderingIntent
        )
    }
}
#endif
