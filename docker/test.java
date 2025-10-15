package com.jci.mediaprocessor.media_processor;

import androidx.annotation.NonNull;

import android.util.LongSparseArray;
import android.view.Surface;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.view.TextureRegistry;

public class MediaProcessorPlugin implements FlutterPlugin, MethodCallHandler {
  static { System.loadLibrary("MediaProcessor"); }

  // HW path helper (global ref to a Java Surface; convert to ANativeWindow in C)
  public static native long getANativeWindow(Surface surface);
  public static native void releaseNativeWindow(long globalSurfaceRef);

  private MethodChannel channel;
  private TextureRegistry textureRegistry;

  private static final LongSparseArray<BaseRenderer> RENDERERS   = new LongSparseArray<>();
  private static final LongSparseArray<TextureRegistry.SurfaceProducer> PRODUCERS = new LongSparseArray<>();
  private static final LongSparseArray<Long> NATIVE_SURFACES = new LongSparseArray<>(); // HW only

  @Override
  public void onAttachedToEngine(@NonNull FlutterPlugin.FlutterPluginBinding binding) {
    channel = new MethodChannel(binding.getBinaryMessenger(), "media_processor");
    channel.setMethodCallHandler(this);
    textureRegistry = binding.getTextureRegistry();
  }

  @Override
  @SuppressWarnings("unchecked")
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    final Map<String, Number> arguments = (Map<String, Number>) call.arguments;

    if ("createHW".equals(call.method)) {
      // ---- Hardware path (MediaCodec) ----
      TextureRegistry.SurfaceProducer producer =
          textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.manual);

      if (arguments != null && arguments.containsKey("width") && arguments.containsKey("height")) {
        producer.setSize(arguments.get("width").intValue(), arguments.get("height").intValue());
      }

      Surface surface = producer.getSurface(); // per docs: do not cache long-term
      long nativeSurface = getANativeWindow(surface); // store global ref for C++

      long id = producer.id();
      PRODUCERS.put(id, producer);
      NATIVE_SURFACES.put(id, nativeSurface);

      // No renderer on HW path, but track callbacks so we can notify native side if needed later.
      producer.setCallback(new TextureRegistry.SurfaceProducer.Callback() {
        @Override public void onSurfaceCleanup() {
          // no-op for HW path here (your decoder should handle EOS / reconfigure)
        }
        @Override public void onSurfaceAvailable() {
          // HW path could re-acquire Surface with producer.getSurface() if needed.
        }
      });

      HashMap<String, Long> values = new HashMap<>();
      values.put("textureId", id);
      values.put("nativeSurface", nativeSurface);
      result.success(values);

    } else if ("create".equals(call.method)) {
      // ---- Software path (using SurfaceProducer) ----
      int width  = arguments.get("width").intValue();
      int height = arguments.get("height").intValue();

      TextureRegistry.SurfaceProducer producer =
          textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.manual);
      producer.setSize(width, height);

      Surface surface = producer.getSurface();
      BaseRenderer renderer = createTexture(surface, width, height, /*isRgb=*/true);
      renderer.initGL();
      renderer.initShaders();
      renderer.initBuffers();

      long id = producer.id();
      PRODUCERS.put(id, producer);
      RENDERERS.put(id, renderer);

      // Critically: listen for Surface replacement & cleanup and rebuild EGLSurface on renderer
      producer.setCallback(new TextureRegistry.SurfaceProducer.Callback() {
        @Override public void onSurfaceCleanup() {
          renderer.notifySurfaceCleanup();
        }
        @Override public void onSurfaceAvailable() {
          // Producer promises a new valid Surface now. Don't cache; pass it through.
          Surface s = producer.getSurface();
          renderer.notifySurfaceAvailable(s);
        }
      });

      result.success(id);

    } else if ("passFramePtr".equals(call.method)) {
      long ptr = call.argument("ptr");
      int size = call.argument("size");
      long textureId = arguments.get("textureId").longValue();

      BaseRenderer renderer = RENDERERS.get(textureId);
      if (renderer == null) { result.success(null); return; }

      renderer.setBufferPtr(ptr, size);
      result.success(textureId);

    } else if ("dispose".equals(call.method)) {
      long textureId = arguments.get("textureId").longValue();

      // SW renderer cleanup
      BaseRenderer renderer = RENDERERS.get(textureId);
      if (renderer != null) {
        renderer.onDispose();
        RENDERERS.delete(textureId);
      }

      // Producer cleanup (both HW & SW)
      TextureRegistry.SurfaceProducer producer = PRODUCERS.get(textureId);
      if (producer != null) {
        producer.setCallback(null);
        producer.release(); // manual lifecycle
        PRODUCERS.delete(textureId);
      }

      // HW global ref cleanup (if any)
      Long surfaceRef = NATIVE_SURFACES.get(textureId);
      if (surfaceRef != null) {
        releaseNativeWindow(surfaceRef);
        NATIVE_SURFACES.delete(textureId);
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

  // NOTE: SW path uses Surface from SurfaceProducer. (Legacy SurfaceTexture ctor is still supported.)
  BaseRenderer createTexture(Surface surface, int width, int height, boolean isRgb) {
    return isRgb ? new RgbRenderer(surface, width, height) : new YuvRenderer(surface, width, height);
  }
}
