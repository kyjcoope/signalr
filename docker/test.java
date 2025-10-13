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

  // JNI: Java Surface global-ref helpers for HW path
  public static native long getANativeWindow(Surface surface);
  public static native void releaseNativeWindow(long globalSurfaceRef);

  private MethodChannel channel;
  private TextureRegistry textureRegistry;

  private static final LongSparseArray<BaseRenderer> RENDERERS = new LongSparseArray<>();
  private static final LongSparseArray<TextureRegistry.SurfaceProducer> PRODUCERS = new LongSparseArray<>();
  private static final LongSparseArray<Long> NATIVE_SURFACES = new LongSparseArray<>(); // HW path only

  @Override
  public void onAttachedToEngine(@NonNull FlutterPlugin.FlutterPluginBinding binding) {
    channel = new MethodChannel(binding.getBinaryMessenger(), "media_processor");
    channel.setMethodCallHandler(this);
    textureRegistry = binding.getTextureRegistry();
  }

  @Override
  @SuppressWarnings("unchecked")
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    final Map<String, Number> args = (Map<String, Number>) call.arguments;

    switch (call.method) {
      case "createHW": {
        // One producer == one Flutter texture id (don’t reuse for concurrent streams).
        TextureRegistry.SurfaceProducer producer =
            textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.manual); // default is manual too

        if (args != null && args.containsKey("width") && args.containsKey("height")) {
          producer.setSize(args.get("width").intValue(), args.get("height").intValue());
        }

        Surface surface = producer.getSurface(); // do not cache long-term; can change on resize
        long nativeSurface = getANativeWindow(surface); // global ref for native

        PRODUCERS.put(producer.id(), producer);
        NATIVE_SURFACES.put(producer.id(), nativeSurface);

        HashMap<String, Long> out = new HashMap<>();
        out.put("textureId", producer.id());
        out.put("nativeSurface", nativeSurface);
        result.success(out);
        return;
      }

      case "create": { // SW path now also uses SurfaceProducer
        int width = args.get("width").intValue();
        int height = args.get("height").intValue();

        TextureRegistry.SurfaceProducer producer =
            textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.manual);
        producer.setSize(width, height);

        Surface surface = producer.getSurface();
        BaseRenderer renderer = new RgbRenderer(surface, width, height); // or YuvRenderer if that’s your format
        renderer.initGL();
        renderer.initShaders();
        renderer.initBuffers();

        long id = producer.id();
        PRODUCERS.put(id, producer);
        RENDERERS.put(id, renderer);

        result.success(id);
        return;
      }

      case "passFramePtr": {
        long ptr = call.argument("ptr");
        int size = call.argument("size");
        long textureId = args.get("textureId").longValue();

        BaseRenderer renderer = RENDERERS.get(textureId);
        if (renderer != null) {
          renderer.setBufferPtr(ptr, size);
          result.success(textureId);
        } else {
          result.error("NO_RENDERER", "Renderer not found for textureId=" + textureId, null);
        }
        return;
      }

      case "dispose": {
        long textureId = args.get("textureId").longValue();

        BaseRenderer renderer = RENDERERS.get(textureId);
        if (renderer != null) {
          renderer.onDispose();
          RENDERERS.delete(textureId);
        }

        TextureRegistry.SurfaceProducer producer = PRODUCERS.get(textureId);
        if (producer != null) {
          producer.release(); // unregister from Flutter; returns buffers
          PRODUCERS.delete(textureId);
        }

        Long surfaceRef = NATIVE_SURFACES.get(textureId);
        if (surfaceRef != null) {
          releaseNativeWindow(surfaceRef);
          NATIVE_SURFACES.delete(textureId);
        }

        result.success(null);
        return;
      }

      default:
        result.notImplemented();
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPlugin.FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
  }
}
