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
        guard let drawable = drawableImage(image, encoded: encoded) else { return nil }
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

    private static func drawableImage(_ image: CGImage, encoded: Data) -> CGImage? {
        #if os(iOS)
        // ImageIO expands indexed PNGs to premultiplied RGBA on iOS but
        // labels that buffer as straight alpha. Drawing it multiplies twice.
        // Preserve the decoded bytes and color space with the correct label.
        let header = Array(encoded.prefix(26))
        let indexedPNG = header.count == 26
            && header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            && Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82]
            && header[25] == 3 // PNG IHDR indexed-color type.
        guard indexedPNG,
              image.alphaInfo == .last,
              image.bitsPerComponent == 8,
              image.bitsPerPixel == 32 else {
            return image
        }
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
        #else
        return image
        #endif
    }
}
#endif
