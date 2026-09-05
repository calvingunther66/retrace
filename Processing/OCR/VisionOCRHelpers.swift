import Foundation
import Vision
import CoreGraphics
import Shared

struct VisionRecognitionOutput {
    let regions: [TextRegion]
    let attributedBytes: Int64
}

struct EnvelopeRecognitionOutput {
    let regions: [TextRegion]
    let blindResidualClaim: MemoryLedger.ResidualClaim?
}

extension VisionOCR {
    /// Shared colorspace reused for every OCR bridge (avoids per-call create).
    static let sharedOCRColorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    static let sharedOCRBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
    )
    /// Downscale before BGRA bridging so oversized frames never pay
    /// full-surface cost. Identity below the cap (no resizing, so normal
    /// displays are unaffected); above it, Vision sees a downscaled image,
    /// trading a memory/cost win for lower recognition resolution on very
    /// large or ultra-wide displays.
    static let ocrBridgeMaxDimension = 2560
    static func recognitionLevel(for config: ProcessingConfig) -> VNRequestTextRecognitionLevel {
        switch config.ocrAccuracyLevel {
        case .fast:
            return .fast
        case .accurate:
            return .accurate
        }
    }

    func boundsOverlapSignificantly(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.isNull || intersection.isEmpty {
            return false
        }

        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(a.width * a.height, b.width * b.height)

        guard smallerArea > 0 else { return false }
        return intersectionArea / smallerArea > 0.3
    }

    func calculateBoundingBox(for tiles: [TileInfo]) -> CGRect {
        guard !tiles.isEmpty else { return .zero }

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = CGFloat.zero
        var maxY = CGFloat.zero

        for tile in tiles {
            minX = min(minX, tile.pixelBounds.minX)
            minY = min(minY, tile.pixelBounds.minY)
            maxX = max(maxX, tile.pixelBounds.maxX)
            maxY = max(maxY, tile.pixelBounds.maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func expandReOCRTiles(
        changedTiles: [TileInfo],
        affectedRegions: [TextRegion],
        frameWidth: Int,
        frameHeight: Int,
        changeDetector: TileChangeDetector
    ) -> [TileInfo] {
        guard !affectedRegions.isEmpty else { return changedTiles }

        var tilesByKey: [String: TileInfo] = Dictionary(
            uniqueKeysWithValues: changedTiles.map { ($0.cacheKey, $0) }
        )

        for tile in changeDetector.createTileGrid(frameWidth: frameWidth, frameHeight: frameHeight) {
            guard tilesByKey[tile.cacheKey] == nil else { continue }
            if affectedRegions.contains(where: { $0.bounds.intersects(tile.pixelBounds) }) {
                tilesByKey[tile.cacheKey] = tile
            }
        }

        return Array(tilesByKey.values)
    }

    func createCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        // Single CGImage per tick: shared colorspace/bitmap-info, provider
        // holds the caller's buffer only for this bridge; the CGImage is
        // released by the caller immediately after performRecognition.
        // Downscale before BGRA bridging when oversized.
        let targetWidth: Int
        let targetHeight: Int
        let targetBytesPerRow: Int
        let bridgeData: Data
        let longest = max(width, height)
        if longest > Self.ocrBridgeMaxDimension, longest > 0 {
            let scale = Double(Self.ocrBridgeMaxDimension) / Double(longest)
            targetWidth = max(1, Int(Double(width) * scale))
            targetHeight = max(1, Int(Double(height) * scale))
            targetBytesPerRow = targetWidth * 4
            guard let full = bridgeCGImage(
                from: data, width: width, height: height, bytesPerRow: bytesPerRow
            ) else { return nil }
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetBytesPerRow,
                space: Self.sharedOCRColorSpace,
                bitmapInfo: Self.sharedOCRBitmapInfo.rawValue
            ) else { return full }
            context.interpolationQuality = .medium
            context.draw(full, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let downscaled = context.makeImage() else { return full }
            // Release the full-size bridge immediately; only one live CGImage survives.
            return downscaled
        } else {
            targetWidth = width
            targetHeight = height
            targetBytesPerRow = bytesPerRow
            bridgeData = data
            return bridgeCGImage(
                from: bridgeData, width: targetWidth, height: targetHeight, bytesPerRow: targetBytesPerRow
            )
        }
    }

    private func bridgeCGImage(from data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: Self.sharedOCRColorSpace,
            bitmapInfo: Self.sharedOCRBitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
