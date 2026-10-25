import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameImageFormat: String, Sendable, CaseIterable {
    case jpeg
    case png

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    var typeIdentifier: CFString {
        switch self {
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .png: return UTType.png.identifier as CFString
        }
    }
}

public struct EncodedFrameImage: Sendable {
    public let data: Data
    /// Pixel size of the encoded image (after any downscale).
    public let width: Int
    public let height: Int
}

public enum FrameImageEncoderError: Error, Equatable {
    case invalidMaxSide(Int)
    case contextCreationFailed
    case encodingFailed
}

/// Downscales a decoded frame to a maximum side length and encodes it for export.
///
/// Uses CoreGraphics/ImageIO only (no `NSImage.lockFocus`), so it is safe off the main thread.
/// Never upscales; the aspect ratio is preserved.
public enum FrameImageEncoder {

    /// Size that fits `maxSide` on its longer edge. Returns the input size when it already fits.
    public static func scaledSize(width: Int, height: Int, maxSide: Int?) -> (width: Int, height: Int) {
        guard let maxSide, maxSide > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > maxSide else { return (width, height) }
        let scale = Double(maxSide) / Double(longest)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    public static func encode(
        _ image: CGImage,
        maxSide: Int? = nil,
        format: FrameImageFormat = .jpeg,
        quality: Double = 0.8
    ) throws -> EncodedFrameImage {
        if let maxSide, maxSide <= 0 {
            throw FrameImageEncoderError.invalidMaxSide(maxSide)
        }

        let target = scaledSize(width: image.width, height: image.height, maxSide: maxSide)
        let source: CGImage
        if target.width == image.width && target.height == image.height && format == .png {
            source = image
        } else {
            source = try render(image, width: target.width, height: target.height, opaque: format == .jpeg)
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier, 1, nil) else {
            throw FrameImageEncoderError.encodingFailed
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.01), 1.0)
        }
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FrameImageEncoderError.encodingFailed
        }
        return EncodedFrameImage(data: output as Data, width: target.width, height: target.height)
    }

    /// Redraw into an sRGB bitmap of the exact target size. JPEG has no alpha, so draw onto opaque.
    private static func render(_ image: CGImage, width: Int, height: Int, opaque: Bool) throws -> CGImage {
        let bitmapInfo: UInt32 = opaque
            ? CGImageAlphaInfo.noneSkipLast.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw FrameImageEncoderError.contextCreationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else {
            throw FrameImageEncoderError.encodingFailed
        }
        return rendered
    }
}
