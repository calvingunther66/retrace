import CoreVideo
import CoreGraphics
import Foundation
import Shared

/// Converts CapturedFrame raw BGRA bytes into CVPixelBuffer.
enum FrameConverter {
    static func createPixelBuffer(from frame: CapturedFrame) throws -> CVPixelBuffer {
        try createPixelBuffer(from: frame, pool: nil)
    }

    static func createPixelBuffer(
        from frame: CapturedFrame,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        guard frame.width > 0, frame.height > 0 else {
            throw StorageModuleError.encodingFailed(underlying: "Invalid frame dimensions: \(frame.width)x\(frame.height)")
        }

        let (pixelDataPerRow, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else {
            throw StorageModuleError.encodingFailed(underlying: "Frame width overflow when computing BGRA bytesPerRow")
        }

        guard frame.bytesPerRow >= pixelDataPerRow else {
            throw StorageModuleError.encodingFailed(
                underlying: "Invalid source stride: \(frame.bytesPerRow) < required \(pixelDataPerRow)"
            )
        }

        let (requiredSourceBytes, sourceOverflow) = frame.bytesPerRow.multipliedReportingOverflow(by: frame.height)
        guard !sourceOverflow, frame.imageData.count >= requiredSourceBytes else {
            throw StorageModuleError.encodingFailed(
                underlying: "Frame data too small: \(frame.imageData.count) < required \(requiredSourceBytes)"
            )
        }

        // Drain any autoreleased CoreFoundation temporaries per conversion so a
        // sustained capture tick does not accumulate them until the thread's pool drains.
        return try autoreleasepool {
            let buffer: CVPixelBuffer
            if let pool, let pooledBuffer = try makePixelBuffer(from: pool) {
                buffer = pooledBuffer
            } else {
                var pixelBuffer: CVPixelBuffer?
                let attrs: [String: Any] = [
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                ]

                let status = CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    frame.width,
                    frame.height,
                    kCVPixelFormatType_32BGRA,
                    attrs as CFDictionary,
                    &pixelBuffer
                )
                guard status == kCVReturnSuccess, let createdBuffer = pixelBuffer else {
                    throw StorageModuleError.encodingFailed(underlying: "CVPixelBufferCreate failed: \(status)")
                }
                buffer = createdBuffer
            }

            // Read-only buffer properties do not require the base-address lock,
            // so validate everything possible before locking to minimize the window.
            guard !CVPixelBufferIsPlanar(buffer) else {
                throw StorageModuleError.encodingFailed(underlying: "Unexpected planar pixel buffer for BGRA frame")
            }

            // Get the actual bytesPerRow of the CVPixelBuffer (may differ from frame.bytesPerRow due to alignment)
            let destBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let srcBytesPerRow = frame.bytesPerRow

            guard destBytesPerRow >= pixelDataPerRow else {
                throw StorageModuleError.encodingFailed(
                    underlying: "Invalid destination stride: \(destBytesPerRow) < required \(pixelDataPerRow)"
                )
            }

            let (requiredDestBytes, destOverflow) = destBytesPerRow.multipliedReportingOverflow(by: frame.height)
            if !destOverflow {
                let destCapacity = CVPixelBufferGetDataSize(buffer)
                if destCapacity > 0 {
                    guard destCapacity >= requiredDestBytes else {
                        throw StorageModuleError.encodingFailed(
                            underlying: "Destination buffer too small: \(destCapacity) < required \(requiredDestBytes)"
                        )
                    }
                }
            }

            // Minimal lock window: held only for the row memcpy, released explicitly
            // before returning instead of via defer to function end.
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw StorageModuleError.encodingFailed(underlying: "PixelBuffer base address nil")
            }

            do {
                try frame.imageData.withUnsafeBytes { srcPtr in
                    guard let srcBase = srcPtr.baseAddress else {
                        throw StorageModuleError.encodingFailed(underlying: "Frame data base address is nil")
                    }
                    // Copy row-by-row to avoid stride/padding assumptions.
                    for row in 0..<frame.height {
                        let srcOffset = row * srcBytesPerRow
                        let destOffset = row * destBytesPerRow

                        guard srcOffset + pixelDataPerRow <= frame.imageData.count else {
                            throw StorageModuleError.encodingFailed(
                                underlying: "Source row \(row) out of bounds during pixel copy"
                            )
                        }

                        memcpy(
                            baseAddress.advanced(by: destOffset),
                            srcBase.advanced(by: srcOffset),
                            pixelDataPerRow
                        )
                    }
                }
            } catch {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw error
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            return buffer
        }
    }

    /// Pre-warm a CVPixelBufferPool by allocating (then releasing) buffers up front,
    /// so steady-state capture ticks reuse pooled memory instead of faulting new pages.
    /// Released buffers return to the pool for reuse; behavior of later conversions is unchanged.
    static func prewarm(_ pool: CVPixelBufferPool?, bufferCount: Int = 3) {
        guard let pool, bufferCount > 0 else { return }
        autoreleasepool {
            var spares: [CVPixelBuffer] = []
            spares.reserveCapacity(bufferCount)
            for _ in 0..<bufferCount {
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
                guard status == kCVReturnSuccess, let created = pixelBuffer else { break }
                spares.append(created)
            }
            CVPixelBufferPoolFlush(pool, [])
            // `spares` deallocates here, returning buffers to the pool.
        }
    }

    private static func makePixelBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        switch status {
        case kCVReturnSuccess:
            return pixelBuffer
        case kCVReturnWouldExceedAllocationThreshold:
            return nil
        default:
            throw StorageModuleError.encodingFailed(underlying: "CVPixelBufferPoolCreatePixelBuffer failed: \(status)")
        }
    }
}
