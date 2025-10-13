package com.jci.mediaprocessor.media_processor;

import androidx.annotation.NonNull;

import android.view.Surface;
import android.util.LongSparseArray;
import java.util.Map;
import java.util.HashMap;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.view.TextureRegistry;

public class MediaProcessorPlugin implements FlutterPlugin, MethodCallHandler {
  static { System.loadLibrary("MediaProcessor"); }

  // NDK helpers: acquire/release a real ANativeWindow* for AMediaCodec_configure.
  private static native long nativeAcquireNativeWindow(Surface surface);
  private static native void nativeReleaseNativeWindow(long nativeWindowPtr);

  private MethodChannel channel;
  private TextureRegistry textureRegistry;

  private static final LongSparseArray<BaseRenderer> _renderers = new LongSparseArray<>();
  // Store SurfaceProducer instead of SurfaceTextureEntry for HW path.
  private static final LongSparseArray<TextureRegistry.SurfaceProducer> _textures = new LongSparseArray<>();
  // Track NativeWindow pointers so we can release them.
  private static final LongSparseArray<Long> _nativeWindows = new LongSparseArray<>();

  @Override
  public void onAttachedToEngine(@NonNull FlutterPlugin.FlutterPluginBinding binding) {
    channel = new MethodChannel(binding.getBinaryMessenger(), "media_processor");
    channel.setMethodCallHandler(this);
    textureRegistry = binding.getTextureRegistry();
  }

  @Override
  @SuppressWarnings("unchecked")
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    Map<String, Number> arguments = (Map<String, Number>) call.arguments;

    if ("createHW".equals(call.method)) {
      // Prefer automatic lifecycle so the engine clears/recycles frames
      // when they’re consumed on the Flutter side.
      TextureRegistry.SurfaceProducer entry =
          textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.automatic);

      Surface surface = entry.getSurface(); // Producer-owned Surface (not a SurfaceTexture)
      long nativeWindow = nativeAcquireNativeWindow(surface);

      _textures.put(entry.id(), entry);
      _nativeWindows.put(entry.id(), nativeWindow);

      HashMap<String, Long> values = new HashMap<>();
      values.put("textureId", entry.id());
      values.put("nativeSurface", nativeWindow);
      result.success(values);

    } else if ("create".equals(call.method)) {
      // Your software/GL path can keep using SurfaceTextureEntry if you like,
      // or you can migrate it later. Keeping it unchanged here:
      TextureRegistry.SurfaceTextureEntry entry = textureRegistry.createSurfaceTexture();
      int width = arguments.get("width").intValue();
      int height = arguments.get("height").intValue();
      entry.surfaceTexture().setDefaultBufferSize(width, height);

      BaseRenderer render = createTexture(entry.surfaceTexture(), width, height, true);
      render.initGL();
      render.initShaders();
      render.initBuffers();

      _renderers.put(entry.id(), render);
      // Note: _textures is a SurfaceProducer store; if you keep SW path,
      // either create a parallel map for SurfaceTexture entries or migrate
      // SW path to SurfaceProducer too.
      result.success(entry.id());

    } else if ("passFramePtr".equals(call.method)) {
      long ptr = call.argument("ptr");
      int size = call.argument("size");
      long textureId = arguments.get("textureId").longValue();
      BaseRenderer render = _renderers.get(textureId);
      if (render == null) return;
      render.setBufferPtr(ptr, size);
      result.success(textureId);

    } else if ("dispose".equals(call.method)) {
      long textureId = arguments.get("textureId").longValue();

      BaseRenderer render = _renderers.get(textureId);
      if (render != null) {
        render.onDispose();
        _renderers.delete(textureId);
      }

      // Release the ANativeWindow* first so MediaCodec lets go of hardware resources.
      Long winPtr = _nativeWindows.get(textureId);
      if (winPtr != null) {
        nativeReleaseNativeWindow(winPtr);
        _nativeWindows.delete(textureId);
      }

      TextureRegistry.SurfaceProducer producer = _textures.get(textureId);
      if (producer != null) {
        producer.release(); // Important: gives the buffer back to Flutter/engine.
        _textures.delete(textureId);
      }

      result.success(null);
    } else {
      result.notImplemented();
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPlugin.FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
  }

  BaseRenderer createTexture(android.graphics.SurfaceTexture tex, int w, int h, boolean isRgb) {
    return isRgb ? new RgbRenderer(tex, w, h) : new YuvRenderer(tex, w, h);
  }
}
