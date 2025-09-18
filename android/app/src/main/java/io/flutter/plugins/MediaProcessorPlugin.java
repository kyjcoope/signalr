package com.jci.mediaprocessor.media_processor;

import androidx.annotation.NonNull;

import android.graphics.SurfaceTexture;
import android.view.Surface;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.view.TextureRegistry;

import java.util.HashMap;
import android.util.LongSparseArray;

/** MediaProcessorPlugin */
public class MediaProcessorPlugin implements FlutterPlugin, MethodCallHandler {
  static {
    System.loadLibrary("MediaProcessor");
  }

  public static native long getNativeWindow(Surface surface);

  private MethodChannel channel;
  private TextureRegistry textureRegistry;

  private static final LongSparseArray<BaseRenderer> _renderers = new LongSparseArray<>();
  private static final LongSparseArray<TextureRegistry.SurfaceTextureEntry> _textures = new LongSparseArray<>();

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
    channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "media_processor");
    channel.setMethodCallHandler(this);
    textureRegistry = flutterPluginBinding.getTextureRegistry();
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "getNativeWindow": {
        HashMap<String, Long> values = new HashMap<>();
        TextureRegistry.SurfaceTextureEntry entry = textureRegistry.createSurfaceTexture();
        SurfaceTexture surfaceTexture = entry.surfaceTexture();

        int width  = ((Number) call.argument("width")).intValue();
        int height = ((Number) call.argument("height")).intValue();
        surfaceTexture.setDefaultBufferSize(width, height);

        long entryId = entry.id();
        _textures.put(entryId, entry);

        Surface surface = new Surface(surfaceTexture);
        long nativeSurface = getNativeWindow(surface);

        values.put("textureId", entryId);
        values.put("nativeSurface", nativeSurface);
        result.success(values);
        break;
      }

      case "create": {
        TextureRegistry.SurfaceTextureEntry entry = textureRegistry.createSurfaceTexture();
        SurfaceTexture surfaceTexture = entry.surfaceTexture();

        int width  = ((Number) call.argument("width")).intValue();
        int height = ((Number) call.argument("height")).intValue();
        surfaceTexture.setDefaultBufferSize(width, height);

        // RGB path only in this renderer set
        BaseRenderer render = createTexture(surfaceTexture, width, height, /*isRgb=*/true);
        render.initGL();
        render.initShaders();
        render.initBuffers();

        _renderers.put(entry.id(), render);
        _textures.put(entry.id(), entry);

        result.success(entry.id());
        break;
      }

      case "passFramePtr": {
        Number pArg = (Number) call.argument("ptr");
        Number sArg = (Number) call.argument("size");
        Number tArg = (Number) call.argument("textureId");

        if (pArg == null || sArg == null || tArg == null) {
          result.error("BAD_ARGS", "Missing ptr/size/textureId", null);
          return;
        }

        long ptr = pArg.longValue();
        int  size = sArg.intValue();
        long textureId = tArg.longValue();

        BaseRenderer render = _renderers.get(textureId);
        if (render == null || render.isDisposed()) {
          result.error("DISPOSED", "Renderer not found or already disposed", null);
          return;
        }

        try {
          render.setBufferPtr(ptr, size);
          result.success(textureId);
        } catch (Throwable t) {
          result.error("GL_ERROR", "Failed to render frame: " + t.getMessage(), null);
        }
        break;
      }

      case "dispose": {
        Number tArg = (Number) call.argument("textureId");
        if (tArg == null) {
          result.error("BAD_ARGS", "Missing textureId", null);
          return;
        }
        long textureId = tArg.longValue();

        BaseRenderer render = _renderers.get(textureId);
        if (render != null) {
          render.onDispose();
          _renderers.delete(textureId);
        }
        TextureRegistry.SurfaceTextureEntry entry = _textures.get(textureId);
        if (entry != null) {
          entry.release();
          _textures.delete(textureId);
        }
        result.success(textureId); // <- success, not notImplemented
        break;
      }

      default:
        result.notImplemented();
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
  }

  BaseRenderer createTexture(SurfaceTexture surfaceTexture, int width, int height, boolean isRgb) {
    if (isRgb) {
      return new RgbRenderer(surfaceTexture, width, height);
    } else {
      return new YuvRenderer(surfaceTexture, width, height); // keep if you still have it
    }
  }
}
