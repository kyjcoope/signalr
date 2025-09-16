public class MediaProcessorPlugin: NSObject, FlutterPlugin {
  private var textureRegistry: FlutterTextureRegistry
  private var registeredTextures = [Int64: DewarpTextureBase]() // BGRA pipeline
  private var nv12Textures      = [Int64: Nv12Texture]()        // NEW: NV12 directly

  // ... (register(...) and init(...) unchanged)

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]

    if (call.method == "create") {
      var width  = DEF_WIDTH
      var height = DEF_HEIGHT
      // Backward compatible: if "format" is absent, use legacy 'rgba' Bool.
      let format = (args?["format"] as? String) ??
                   ((args?["rgba"] as? Bool) == false ? "nv12" : "rgba")

      if let w = args?["width"] as? Int { width = w }
      if let h = args?["height"] as? Int { height = h }

      switch format.lowercased() {
      case "nv12":
        let tex = Nv12Texture(width: width, height: height)
        let id  = textureRegistry.register(tex)
        tex.textureId = id
        nv12Textures[id] = tex
        result(id)

      case "yuv420p", "i420":
        // Keep your old YuvTexture path if you still need it.
        let tex = YuvTexture(width: width, height: height)
        let id  = textureRegistry.register(tex)
        tex.textureId = id
        registeredTextures[id] = tex
        result(id)

      default: // "rgba"
        let tex = RgbTexture(width: width, height: height)
        let id  = textureRegistry.register(tex)
        tex.textureId = id
        registeredTextures[id] = tex
        result(id)
      }

    } else if (call.method == "dispose") {
      if let textureId = args?["textureId"] as? Int64 {
        if let t = registeredTextures.removeValue(forKey: textureId) {
          t.dispose()
        }
        if let t = nv12Textures.removeValue(forKey: textureId) {
          t.dispose()
        }
        textureRegistry.unregisterTexture(textureId)
        result(textureId)
      } else {
        result(-1)
      }

    } else if (call.method == "passFramePtr") {
      guard let ptr64 = args?["ptr"] as? Int64,
            let size  = args?["size"] as? Int,
            let textureId = args?["textureId"] as? Int64
      else { result(-1); return }

      // If this is an NV12 texture, feed it directly (no conversion).
      if let nv12 = nv12Textures[textureId] {
        guard let raw = UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: ptr64)) else {
          result(-2); return
        }
        nv12.renderNV12(ptr: raw, size: size)
        textureRegistry.textureFrameAvailable(textureId)
        result(textureId)
        return
      }

      // Otherwise keep your existing BGRA/I420 behavior:
      if let renderer = registeredTextures[textureId] {
        guard let raw = UnsafeMutablePointer<UInt8>(bitPattern: UInt(truncatingIfNeeded: ptr64)) else {
          result(-2); return
        }
        let buf = UnsafeBufferPointer<UInt8>(start: raw, count: size)
        let bytes = Array(buf)
        renderer.render(yData: bytes, uData: [], vData: [])
        textureRegistry.textureFrameAvailable(textureId)
        result(textureId)
        return
      }

      result(-1)

    } else {
      // other methods unchanged (createIOS/renderIOS/etc.)
      result(FlutterMethodNotImplemented)
    }
  }
}
