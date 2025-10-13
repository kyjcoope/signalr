package com.jci.mediaprocessor.media_processor;

import androidx.annotation.NonNull;

import android.graphics.SurfaceTexture;
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

  // JNI — returns a global ref to the Java Surface (you convert to ANativeWindow later in native)
  public static native long getANativeWindow(Surface surface);
  // Optional: lets us delete the global ref we created above (see dispose()).
  public static native void releaseNativeWindow(long globalSurfaceRef);

  private MethodChannel channel;
  private TextureRegistry textureRegistry;

  private static final LongSparseArray<BaseRenderer> RENDERERS = new LongSparseArray<>();
  private static final LongSparseArray<TextureRegistry.SurfaceTextureEntry> TEXTURES = new LongSparseArray<>();
  private static final LongSparseArray<TextureRegistry.SurfaceProducer> PRODUCERS = new LongSparseArray<>();
  // If you want to free the global ref in dispose(), track it here:
  private static final LongSparseArray<Long> NATIVE_SURFACES = new LongSparseArray<>();

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

    if (call.method.equals("createHW")) {
      // New API: SurfaceProducer (manual lifecycle, since we dispose explicitly)
      TextureRegistry.SurfaceProducer producer =
          textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.manual);

      // If width/height are supplied, set the size (recommended)
      if (arguments != null && arguments.containsKey("width") && arguments.containsKey("height")) {
        producer.setSize(arguments.get("width").intValue(), arguments.get("height").intValue());
      }

      // Get a Surface directly from the producer
      Surface surface = producer.getSurface();
      long nativeSurface = getANativeWindow(surface); // returns a global ref (jobject) as jlong

      PRODUCERS.put(producer.id(), producer);
      NATIVE_SURFACES.put(producer.id(), nativeSurface);

      HashMap<String, Long> values = new HashMap<>();
      values.put("textureId", producer.id());
      values.put("nativeSurface", nativeSurface);
      result.success(values);

    } else if (call.method.equals("create")) {
      // Keep your existing software GL path that uses SurfaceTextureEntry
      TextureRegistry.SurfaceTextureEntry entry = textureRegistry.createSurfaceTexture();
      SurfaceTexture surfaceTexture = entry.surfaceTexture();

      int width = arguments.get("width").intValue();
      int height = arguments.get("height").intValue();
      surfaceTexture.setDefaultBufferSize(width, height);

      BaseRenderer render = createTexture(surfaceTexture, width, height, true);
      render.initGL();
      render.initShaders();
      render.initBuffers();

      RENDERERS.put(entry.id(), render);
      TEXTURES.put(entry.id(), entry);
      result.success(entry.id());

    } else if (call.method.equals("passFramePtr")) {
      long ptr = call.argument("ptr");
      int size = call.argument("size");
      long textureId = arguments.get("textureId").longValue();
      BaseRenderer render = RENDERERS.get(textureId);
      if (render == null) return;
      render.setBufferPtr(ptr, size);
      result.success(textureId);

    } else if (call.method.equals("dispose")) {
      long textureId = arguments.get("textureId").longValue();

      // Dispose renderer if present (SW path)
      BaseRenderer render = RENDERERS.get(textureId);
      if (render != null) {
        render.onDispose();
        RENDERERS.delete(textureId);
      }

      // Dispose SurfaceTextureEntry if present (SW path)
      TextureRegistry.SurfaceTextureEntry entry = TEXTURES.get(textureId);
      if (entry != null) {
        entry.release();
        TEXTURES.delete(textureId);
      }

      // Dispose SurfaceProducer if present (HW path)
      TextureRegistry.SurfaceProducer producer = PRODUCERS.get(textureId);
      if (producer != null) {
        producer.release(); // manual lifecycle: you must call release()
        PRODUCERS.delete(textureId);
      }

      // Optional but recommended: free the global Surface ref if you made one
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

  BaseRenderer createTexture(SurfaceTexture surfaceTexture, int width, int height, boolean isRgb) {
    return isRgb ? new RgbRenderer(surfaceTexture, width, height)
                 : new YuvRenderer(surfaceTexture, width, height);
  }
}
