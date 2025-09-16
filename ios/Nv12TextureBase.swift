import Foundation
import CoreVideo
import Flutter

/// A FlutterTexture that exposes an NV12 CVPixelBuffer (no RGBA conversion).
/// Plane 0: Y (width x height, 8bpp)
/// Plane 1: interleaved UV (width/2 x height/2 texels, 2 bytes/texel → bytesPerRow = width)
final class Nv12TextureBase: NSObject, FlutterTexture {
    private(set) var pixelBuffer: CVPixelBuffer!
    let width: Int
    let height: Int

    // Optional: track for bookkeeping similar to your other textures
    var textureId: Int64 = -1

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        super.init()

        // Allocate an IOSurface-backed NV12 buffer the embedder can render directly.
        // Use FullRange; swap to VideoRange if that’s what your pipeline produces.
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferOpenGLESCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                         attrs as CFDictionary,
                                         &pb)
        precondition(status == kCVReturnSuccess, "Failed to create NV12 CVPixelBuffer")
        self.pixelBuffer = pb!
    }

    // MARK: - Rendering API (NV12)

    /// Copy NV12 planes into the pixel buffer.
    /// - Parameters:
    ///   - y:  pointer to Y plane bytes (stride yStride)
    ///   - yStride: bytes per row for Y
    ///   - uv: pointer to interleaved UV plane bytes (stride uvStride)
    ///   - uvStride: bytes per row for UV (usually == width)
    func renderNV12(y: UnsafePointer<UInt8>, yStride: Int,
                    uv: UnsafePointer<UInt8>, uvStride: Int)
    {
        CVPixelBufferLockBaseAddress(pixelBuffer, .init(rawValue: 0))

        // Plane 0 (Y)
        let dstY       = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            dstY.advanced(by: row * dstYStride)
                .assign(from: y.advanced(by: row * yStride), count: width)
        }

        // Plane 1 (UV, interleaved)
        let dstUV       = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvRows = height / 2
        let uvRowBytes = width // two channels interleaved → width bytes per row
        for row in 0..<uvRows {
            dstUV.advanced(by: row * dstUVStride)
                 .assign(from: uv.advanced(by: row * uvStride), count: uvRowBytes)
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .init(rawValue: 0))
    }

    /// Convenience: copy NV12 planes from Swift arrays.
    func renderNV12(yBytes: [UInt8], uvBytes: [UInt8]) {
        yBytes.withUnsafeBufferPointer { yBuf in
            uvBytes.withUnsafeBufferPointer { uvBuf in
                renderNV12(y: yBuf.baseAddress!, yStride: width,
                           uv: uvBuf.baseAddress!, uvStride: width)
            }
        }
    }

    /// Convenience: single contiguous NV12 buffer (Y then UV). Size must be width*height*3/2.
    func renderNV12Contiguous(_ bytes: [UInt8]) {
        let ySize = width * height
        let uvSize = ySize / 2
        precondition(bytes.count >= ySize + uvSize, "NV12 buffer too small")
        let y  = bytes[0..<ySize]
        let uv = bytes[ySize..<(ySize + uvSize)]
        renderNV12(yBytes: Array(y), uvBytes: Array(uv))
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        .passRetained(pixelBuffer)
    }

    func dispose() {
        pixelBuffer = nil
    }
}
