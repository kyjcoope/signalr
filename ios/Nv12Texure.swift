import Foundation

/// Thin convenience subclass (mirrors how you have RgbTexture/YuvTexture types).
final class Nv12Texture: Nv12TextureBase {
    // Inherit everything; add any app-specific helpers here if you want.
    // Example: a “ptr+size” helper matching your passFramePtr pattern:

    func renderNV12(ptr: UnsafeRawPointer, size: Int) {
        let ySize = width * height
        let uvSize = ySize / 2
        precondition(size >= ySize + uvSize, "NV12 buffer too small")

        let yPtr  = ptr.bindMemory(to: UInt8.self, capacity: ySize + uvSize)
        let uvPtr = yPtr.advanced(by: ySize)

        renderNV12(y: yPtr, yStride: width,
                   uv: uvPtr, uvStride: width)
    }
}
