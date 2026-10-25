import XCTest
import CoreGraphics
import ImageIO
@testable import Storage

final class FrameImageEncoderTests: XCTestCase {

    /// Solid-color BGRA-ordered image like the ones the HEVC decoder hands back.
    private func makeImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // sRGB, not the deprecated Generic RGB initializer, so the stored pixels are exactly these values.
        context.setFillColor(CGColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func decode(_ data: Data) throws -> (image: CGImage, type: String) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image, CGImageSourceGetType(source) as String? ?? "")
    }

    private func centerPixel(_ image: CGImage) throws -> (r: Int, g: Int, b: Int) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    func testDownscalesLongestSideToMaxSidePreservingAspectRatio() throws {
        let image = try makeImage(width: 2560, height: 1601, red: 10, green: 20, blue: 30)
        let encoded = try FrameImageEncoder.encode(image, maxSide: 1280, format: .jpeg)

        XCTAssertEqual(encoded.width, 1280)
        XCTAssertEqual(encoded.height, 801, "1601 * 1280 / 2560 = 800.5, rounded")
        let decoded = try decode(encoded.data)
        XCTAssertEqual(decoded.image.width, 1280)
        XCTAssertEqual(decoded.image.height, 801)
    }

    func testPortraitImagesAreBoundedByTheirHeight() throws {
        let image = try makeImage(width: 800, height: 3200, red: 0, green: 0, blue: 0)
        let encoded = try FrameImageEncoder.encode(image, maxSide: 1280)
        XCTAssertEqual(encoded.height, 1280)
        XCTAssertEqual(encoded.width, 320)
    }

    func testNeverUpscalesAndNilMaxSideKeepsTheOriginalSize() throws {
        let image = try makeImage(width: 640, height: 400, red: 1, green: 2, blue: 3)
        let small = try FrameImageEncoder.encode(image, maxSide: 1280)
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 400)
        let original = try FrameImageEncoder.encode(image, maxSide: nil)
        XCTAssertEqual(original.width, 640)
    }

    func testJPEGOutputIsAJPEGWithCorrectColors() throws {
        let image = try makeImage(width: 400, height: 300, red: 220, green: 40, blue: 20)
        let encoded = try FrameImageEncoder.encode(image, maxSide: 200, format: .jpeg, quality: 0.9)

        XCTAssertEqual(Array(encoded.data.prefix(2)), [0xFF, 0xD8], "JPEG magic bytes")
        let decoded = try decode(encoded.data)
        XCTAssertEqual(decoded.type, "public.jpeg")
        let pixel = try centerPixel(decoded.image)
        XCTAssertEqual(pixel.r, 220, accuracy: 6, "red stays red: no BGR/RGB channel swap")
        XCTAssertEqual(pixel.g, 40, accuracy: 6)
        XCTAssertEqual(pixel.b, 20, accuracy: 6)
    }

    func testPNGOutputIsLossless() throws {
        let image = try makeImage(width: 64, height: 64, red: 12, green: 200, blue: 99)
        let encoded = try FrameImageEncoder.encode(image, format: .png)

        XCTAssertEqual(Array(encoded.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG magic bytes")
        let decoded = try decode(encoded.data)
        XCTAssertEqual(decoded.type, "public.png")
        let pixel = try centerPixel(decoded.image)
        XCTAssertEqual([pixel.r, pixel.g, pixel.b], [12, 200, 99])
    }

    func testLowerQualityProducesSmallerJPEGs() throws {
        // Noise so quality has something to compress.
        let width = 256, height = 256
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12345
        for index in 0..<pixels.count {
            seed = seed &* 1664525 &+ 1013904223
            pixels[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 24)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))

        let high = try FrameImageEncoder.encode(image, format: .jpeg, quality: 0.95)
        let low = try FrameImageEncoder.encode(image, format: .jpeg, quality: 0.2)
        XCTAssertLessThan(low.data.count, high.data.count)
    }

    func testInvalidMaxSideThrows() throws {
        let image = try makeImage(width: 10, height: 10, red: 0, green: 0, blue: 0)
        XCTAssertThrowsError(try FrameImageEncoder.encode(image, maxSide: 0)) {
            XCTAssertEqual($0 as? FrameImageEncoderError, .invalidMaxSide(0))
        }
        XCTAssertThrowsError(try FrameImageEncoder.encode(image, maxSide: -5))
    }

    func testScaledSizeNeverReturnsAZeroDimension() {
        let size = FrameImageEncoder.scaledSize(width: 10_000, height: 3, maxSide: 100)
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 1)
    }
}
