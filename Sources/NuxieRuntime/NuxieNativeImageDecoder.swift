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
        bitmap.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return Self(
            width: UInt32(image.width),
            height: UInt32(image.height),
            rowBytes: UInt32(rowBytes),
            pixels: pixels
        )
    }
}
#endif
