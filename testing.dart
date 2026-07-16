/// WebCodecs-based video decoder for Flutter web.
///
/// Uses the browser's WebCodecs `VideoDecoder` API to hardware-decode
/// H.264, H.265, MJPEG, and MPEG-4 video, rendering decoded frames
/// to an `HTMLCanvasElement` that Flutter embeds via `HtmlElementView`.
///
/// For codecs unsupported by WebCodecs (MPEG-4 Part 2), falls back to
/// WASM FFmpeg software decoding.
///
/// Supports Chrome 94+, Edge 94+, and other WebCodecs-capable browsers.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'dart:ui_web' as ui_web;

import 'dewarp/dewarper_settings.dart';
import 'dewarp/dewarp_helpers.dart' as dewarp_helpers;
import 'dewarp/enum.dart';
import 'dewarp/webgpu/embedded_sources.dart';
import 'dewarp/webgpu/web_gpu_dewarper.dart';
import 'decoder_config.dart' as config;
import 'formats.dart';
import 'web_frame_pacer.dart';
import 'i_stream_info.dart';
import 'i_video_frame.dart';
import 'parser.dart';
import 'video_decoder.dart';
import 'mse_video_decoder.dart';
import 'wasm_video_decoder.dart';
import '../util/backoff_manager.dart';

// Static registries so canvas elements and view-factory registrations survive
// decoder reinit (which creates a new WebCodecDecoder for the same stream).
final _registeredViewTypes = <String>{};
final _canvasElements = <String, web.HTMLCanvasElement>{};
final _containerElements = <String, web.HTMLDivElement>{};

// Tracks which WebCodecDecoder instance currently owns the canvas/container
// registered for a viewType. A new decoder for the same stream adopts the
// existing elements (and takes ownership); release() only removes the
// registry entries while the releasing instance is still the owner. This
// prevents a released old instance from deleting the elements out from under
// a live new instance: during view switches Flutter inflates the new view's
// elements before unmounting the old ones, so the old decoder's release()
// runs AFTER the new decoder adopted the entries.
final _canvasOwners = <String, Object>{};

// — JS interop for WebCodecs API ————————————————————————————————

@JS('VideoDecoder')
extension type _JSVideoDecoder._(JSObject _) implements JSObject {
  external factory _JSVideoDecoder(_DecoderInit init);
  external void configure(_DecoderConfig config);
  external void decode(_JSEncodedVideoChunk chunk);
  external JSPromise flush();
  external void close();
  external void reset();
  external String get state;
  external int get decodeQueueSize;
}

@JS('EncodedVideoChunk')
extension type _JSEncodedVideoChunk._(JSObject _) implements JSObject {
  external factory _JSEncodedVideoChunk(_ChunkInit init);
}

extension type _DecoderInit._(JSObject _) implements JSObject {
  external factory _DecoderInit({JSFunction output, JSFunction error});
}

extension type _DecoderConfig._(JSObject _) implements JSObject {
  external factory _DecoderConfig({
    JSString codec,
    JSBoolean optimizeForLatency,
    JSString hardwareAcceleration,
    JSUint8Array? description,
    JSNumber? codedWidth,
    JSNumber? codedHeight,
  });
}

extension type _ChunkInit._(JSObject _) implements JSObject {
  external factory _ChunkInit({
    JSString type,
    JSNumber timestamp,
    JSUint8Array data,
  });
}

extension type _JSVideoFrame(JSObject _) implements JSObject {
  external int get codedWidth;
  external int get codedHeight;
  external int get displayWidth;
  external int get displayHeight;
  external num get timestamp;
  external void close();
}

extension type _CanvasCtx(JSObject _) implements JSObject {
  external void drawImage(JSObject image, int dx, int dy, int dw, int dh);
  external void putImageData(JSObject imageData, int dx, int dy);
}

@JS('ImageData')
extension type _JSImageData._(JSObject _) implements JSObject {
  external factory _JSImageData(
    JSUint8ClampedArray data,
    int width,
    int height,
  );
}

/// Minimal interop to call `.close()` on a VideoFrame JSObject.
@JS()
extension type _JSVideoFrameClose(JSObject _) implements JSObject {
  external void close();
}

/// Result of `VideoDecoder.isConfigSupported()` — tells us whether the
/// browser chose hardware or software decoding.
@JS()
extension type _ConfigSupportResult._(JSObject _) implements JSObject {
  external bool get supported;
  external _ResolvedConfig? get config;
}

@JS()
extension type _ResolvedConfig._(JSObject _) implements JSObject {
  external String get codec;
  external String get hardwareAcceleration;
}

@JS('VideoDecoder')
extension type _JSVideoDecoderStatic._(JSObject _) implements JSObject {
  external static JSPromise isConfigSupported(JSObject config);
}

@JS('OffscreenCanvas')
extension type _JSOffscreenCanvas._(JSObject _) implements JSObject {
  external factory _JSOffscreenCanvas(int width, int height);
  external set width(int value);
  external set height(int value);
  external int get width;
  external int get height;
  external JSObject? getContext(String contextId);
  external JSPromise convertToBlob(JSObject? options);
}

// — WebGL YUV Renderer interop ————————————————————————————————

@JS('WebGLYuvRenderer')
extension type _JSWebGLYuvRenderer._(JSObject _) implements JSObject {
  external factory _JSWebGLYuvRenderer(JSObject canvas);
  external bool init();
  external bool get isReady;
  external void drawYUV(
    JSUint8Array y,
    JSUint8Array u,
    JSUint8Array v,
    int yStride,
    int uStride,
    int vStride,
    int width,
    int height,
  );
  external void destroy();
}

// — Hardware decoder slot semaphore ————————————————————————————

/// Global admission control for WebCodecs decoder creation.
///
/// macOS VideoToolbox supports a limited number of concurrent hardware
/// decode sessions. During view switches the old view's decoders are torn
/// down asynchronously by Chrome's GPU process while the new view's decoders
/// configure, transiently overcommitting the session pool. Sessions created
/// in that window tend to die with kVTVideoDecoderBadDataErr (-12909)
/// shortly after configure and then cascade into recreate storms.
///
/// This gate does two things:
///  1. Caps how many decoders may be configured at once ([maxSlots]). A
///     decoder that cannot get a slot retries shortly afterwards — slots
///     free up within milliseconds once the old view's decoders dispose.
///     Frames arriving while waiting are buffered (bounded) by the decoder
///     so the triggering keyframe is not lost.
///  2. Spaces configure() calls at least [configureSpacing] apart so the
///     GPU process is not hit with 16 simultaneous session creations.
class _HwSlotGate {
  /// Maximum concurrently-configured WebCodecs decoders. Matches the
  /// steady-state VideoToolbox session budget the app is known to sustain
  /// (16 concurrent cameras).
  static const int maxSlots = 16;

  /// Minimum spacing between consecutive configure() calls.
  static const Duration configureSpacing = Duration(milliseconds: 40);

  /// Fail-open threshold: a decoder that has waited this long for a slot
  /// configures anyway (downgraded to 'no-preference') so a leaked slot
  /// cannot starve a stream forever.
  static const Duration maxAdmissionWait = Duration(seconds: 3);

  static int _slotsInUse = 0;
  static DateTime _lastConfigureAt = DateTime(0);

  static bool get hasFreeSlot => _slotsInUse < maxSlots;

  static int get slotsInUse => _slotsInUse;

  static void acquire() => _slotsInUse++;

  static void release() {
    if (_slotsInUse > 0) _slotsInUse--;
  }

  /// Time to wait before the next configure() is allowed (staggering).
  static Duration spacingDelay(DateTime now) {
    final since = now.difference(_lastConfigureAt);
    return since >= configureSpacing ? Duration.zero : configureSpacing - since;
  }

  static void markConfigured(DateTime now) => _lastConfigureAt = now;
}

/// A frame buffered while the decoder waits for hardware-slot admission.
class _PendingFrame {
  _PendingFrame(this.data, this.isKeyframe, this.dt);

  final Uint8List data;
  final bool isKeyframe;
  final DateTime dt;
}

// — WebCodecDecoder ————————————————————————————————————————————

/// A [VideoDecoder] implementation that uses the browser WebCodecs API.
///
/// Renders decoded frames to an [web.HTMLCanvasElement] which can be
/// embedded into Flutter's widget tree via `HtmlElementView`.
class WebCodecDecoder<T extends IVideoFrame> extends VideoDecoder<T> {
  _JSVideoDecoder? _decoder;
  bool _configured = false;
  int _frameCount = 0;
  String _codecString = '';
  bool _released = false;
  int _jpegInFlight = 0;
  static const _maxJpegInFlight = 2;

  // — WASM fallback decoder (for unsupported codecs like MPEG4) ——
  WasmVideoDecoder? _wasmDecoder;
  bool _useWasmFallback = false;
  bool _wasmInitializing = false;
  int _wasmConsecutiveNulls = 0;
  bool _wasmNeedsKeyframe = false;

  /// WebGL-based YUV→RGB renderer. When available, the WASM decoder outputs
  /// raw YUV planes and the GPU does color conversion (much faster than
  /// sws_scale + putImageData).
  _JSWebGLYuvRenderer? _webglYuvRenderer;
  bool _webglYuvFailed = false;

  /// Set `true` when the browser's WebCodecs API rejects the codec as
  /// permanently unsupported (e.g. H.265 on Firefox).  Once set, all
  /// subsequent frames are routed through the MSE fallback (for H.265).
  bool _codecUnsupported = false;

  /// Consecutive NotSupported failures (configure-time or decode-time).
  /// The codec is only latched as permanently unsupported
  /// ([_codecUnsupported]) after [_maxNotSupportedStrikes] consecutive
  /// failures — a single NotSupportedError can be a transient GPU-process
  /// failure during a view switch and must not permanently disable
  /// WebCodecs for the stream.
  int _notSupportedStrikes = 0;
  static const int _maxNotSupportedStrikes = 3;

  /// MSE-based fallback decoder for H.265 on browsers (Firefox) that don't
  /// support HEVC via WebCodecs but do support it via MediaSource Extensions.
  MseVideoDecoder<T>? _mseFallback;

  // — Frame presentation pacer ——————————————————————————————————

  /// When `true`, decoded frames are routed through a [WebFramePacer]
  /// jitter buffer that presents one frame per vsync via
  /// `requestAnimationFrame`, eliminating overdraw from bursty decode.
  /// Set `false` to revert to the legacy immediate-draw path.
  final bool usePresentationPacer;

  /// The presentation pacer instance (created during [_configureDecoder]).
  WebFramePacer? _framePacer;

  // — Dewarp state ————————————————————————————————————————————
  WebGpuDewarper? _dewarper;
  bool _dewarpInitializing = false;
  DewarpType _dewarpMode = DewarpType.none;
  DewarpMountPosition _dewarpMount = DewarpMountPosition.ceiling;
  int _dewarpX = 0;
  int _dewarpY = 0;
  int _dewarpR = 0;
  String? _shaderSource;

  // — Hardware-slot admission state ——————————————————————————————

  /// True while this instance holds one of the [_HwSlotGate] slots.
  bool _holdsHwSlot = false;

  /// Retry timer for deferred configure attempts (hardware-slot admission
  /// waits and transient NotSupportedError retries).
  Timer? _reconfigureTimer;

  /// When the current admission wait started (null when not waiting).
  DateTime? _admissionWaitStart;

  /// Frames buffered while waiting for hardware-slot admission, so the
  /// keyframe that triggered configure isn't lost.  Bounded by
  /// [_maxPendingFrames]; overflow clears the buffer and resynchronises on
  /// the next keyframe.
  final List<_PendingFrame> _pendingFrames = [];
  static const int _maxPendingFrames = 90;

  /// Signature (FNV-1a) of the parameter sets (VPS/SPS/PPS) that the
  /// current decoder description was built from.  Used to detect
  /// mid-stream parameter-set changes so the decoder can be reconfigured
  /// with a fresh description instead of failing with -12909 bad-data.
  String _activeParamsSignature = '';

  /// Returns `true` when the WebCodecs decode queue is too deep to accept
  /// more frames, or when too many JPEG decodes are in-flight.
  ///
  /// Unlike [droppedLast] this is a **live** check — it reflects the current
  /// queue state rather than a latched flag from the last decode attempt.
  /// Maximum decode queue depth before triggering back-pressure.
  ///
  /// Sized to hold ~0.5 seconds of frames based on the camera's configured
  /// FPS.  This keeps decode latency bounded while still absorbing normal
  /// jitter regardless of whether the stream is 15fps, 30fps, or 60fps.
  /// Falls back to a codec-based default when FPS is unknown (0).
  ///
  /// Clamped to [4, 16] to give the HW pipeline room during ramp-up while
  /// preventing unbounded latency growth.
  int get _maxDecodeQueueSize {
    final fps = pacer.camFPS;
    if (fps > 0) {
      return (fps * 0.5).ceil().clamp(4, 16);
    }
    // Fallback when FPS is unknown.
    return 8;
  }

  @override
  bool get isQueueFull {
    if (_decoder == null || _decoder!.state == 'closed') return false;
    // Suppress back-pressure during the initial HW pipeline ramp-up.
    // The decode queue will be artificially deep while the GPU initialises.
    if (DateTime.now().difference(_configuredAt) < _startupGrace) return false;
    // Pacer back-pressure: if the presentation buffer is ≥75% full,
    // stop feeding the decoder so decoded frames don't pile up faster
    // than the rAF loop can consume them.
    if (_framePacer != null &&
        _framePacer!.bufferDepth >=
            (_framePacer!.maxBufferFrames * 0.75).ceil()) {
      return true;
    }
    // H.264/H.265 path
    if (_decoder!.decodeQueueSize > _maxDecodeQueueSize) return true;
    // JPEG path
    if (_jpegInFlight >= _maxJpegInFlight) return true;
    return false;
  }

  /// Running count of frames dropped due to decoder back-pressure
  /// or JPEG in-flight limit.
  /// Reset to zero each time a warning is emitted.
  int _droppedFrameCount = 0;

  /// Whether HW acceleration was confirmed by `isConfigSupported`.
  String _hwAccelStatus = 'unknown';

  /// Hardware-acceleration preference used when configuring the decoder.
  /// Starts as `'prefer-hardware'` but is downgraded to `'no-preference'`
  /// after a decode error to avoid HW resource contention (e.g. macOS
  /// VideoToolbox limits on concurrent H.265 sessions).
  String _hwAccelPreference = 'prefer-hardware';

  /// Manages exponential backoff on repeated decode errors to avoid rapid
  /// error→recreate cascades when Chrome's HW H.265 decoder pool is exhausted.
  final _errorBackoff = BackoffManager(
    strategy: const StepBackoffStrategy(),
  ); // BackoffManager

  /// True while a recovery attempt is in progress or scheduled.
  /// Prevents cascading concurrent recoveries when multiple errors fire
  /// in quick succession (e.g. queued frames before the decoder closes).
  bool _recovering = false;

  /// Consecutive recovery failures — counts how many times the decoder has
  /// errored again shortly after a "successful" recovery (keyframe accepted
  /// then immediate -12909).  Unlike [_errorBackoff.consecutiveErrors] which
  /// resets on keyframe, this only resets after sustained healthy decoding.
  int _recoveryFailures = 0;

  /// When > 0, the decoder is in VT-throttled mode: all frames are dropped
  /// and the decoder is closed.  The value is the number of seconds to wait
  /// before attempting to decode again (exponential: 2, 4, 8, 16 … 60s cap).
  /// Cleared when the cooldown expires or when the stream is released.
  int _throttleCooldownSecs = 0;

  /// Timer that manages the VT-throttle cooldown period.
  Timer? _throttleTimer;

  /// Timestamp of the last successful frame decode.  Used to distinguish
  /// "recovered then immediately failed" from "recovered and ran fine for a
  /// while before a new transient error".
  DateTime _lastSuccessfulDecode = DateTime(0);

  /// Timestamp of the last [_emitFrameAvailable] capture.
  /// Used to throttle GPU readbacks to at most once per second.
  DateTime _lastFrameAvailableTime = DateTime(0);

  /// Emit a [VideoDecoderCallbacks.onWarning] every this many dropped frames
  /// (~1 second at 30 fps).  The warning value is the total accumulated since
  /// the last warning emission.
  static const _dropWarningInterval = 30;

  /// When true, uses an [OffscreenCanvas] instead of a DOM canvas.
  /// This allows decoding frames (H264/H265) without a visible element,
  /// which is exactly what the thumbnail pipeline needs.
  final bool headless;
  _JSOffscreenCanvas? _offscreenCanvas;
  _CanvasCtx? _offscreenCtx;

  /// When `true`, the decoder will skip all delta frames until a keyframe
  /// arrives.  Set after a decode error to avoid feeding un-decodable deltas.
  bool _needsKeyframe = false;

  /// Time when the decoder was last configured.  Used to suppress
  /// back-pressure during the initial HW pipeline ramp-up.
  DateTime _configuredAt = DateTime(0);

  /// Grace period after configure during which back-pressure is suppressed.
  /// H.265 HW decoders need extra time to initialise their reference-frame
  /// buffers, so this is set to 750ms (up from 500ms) to avoid premature
  /// frame drops during the initial pipeline ramp-up.
  static const _startupGrace = Duration(milliseconds: 750);

  JSFunction? _outputCallback;
  JSFunction? _errorCallback;

  /// The canvas element that decoded frames are drawn to.
  /// Uses a static registry so the element survives decoder reinit.
  web.HTMLCanvasElement get canvas => _canvasElements[viewType]!;

  /// Cached 2D rendering context — avoids calling getContext on every frame.
  _CanvasCtx? _ctx;

  // ignore: library_private_types_in_public_api
  _CanvasCtx get ctx => _ctx ??= _CanvasCtx(canvas.getContext('2d')!);

  /// Unique view type ID for [HtmlElementView] registration.
  final String viewType;

  /// Stream info reference for creating fallback decoders.
  final IStreamInfo _streamInfo;

  /// Called after every decoded frame is drawn to the canvas.
  void Function(int width, int height)? onFrameRendered;

  int get frameCount => _frameCount;
  String get codecString => _codecString;

  /// Whether the WebCodecs decoder should optimise for low latency.
  ///
  /// Set `true` for live streams (minimal decode delay).
  /// Set `false` for search/clip playback (better quality, slightly higher
  /// latency acceptable).
  /// Defaults to `true` to preserve historical behaviour.
  final bool optimizeForLatency;

  // ignore: use_super_parameters
  WebCodecDecoder({
    required IStreamInfo streamInfo,
    required super.videoFormat,
    required super.logger,
    required super.renderManager,
    required super.pacer,
    String? viewId,
    this.headless = false,
    this.optimizeForLatency = true,
    this.usePresentationPacer = true,
  }) : _streamInfo = streamInfo,
       viewType =
           viewId ?? 'web-codec-canvas-${streamInfo.id}-${streamInfo.slug}',
       super(streamInfo: streamInfo) {
    if (!headless) {
      // Create the canvas element only once per viewType.
      if (!_canvasElements.containsKey(viewType)) {
        _canvasElements[viewType] =
            web.document.createElement('canvas') as web.HTMLCanvasElement
              ..style.width = '100%'
              ..style.height = '100%'
              ..style.objectFit = 'contain'
              ..style.pointerEvents = 'none';
      }

      // Create a container div that holds both the 2D and WebGPU canvases.
      // Flutter's platform view factory caches the returned element, so we
      // can't swap it later. Instead we toggle child visibility.
      if (!_containerElements.containsKey(viewType)) {
        final container =
            web.document.createElement('div') as web.HTMLDivElement
              ..style.width = '100%'
              ..style.height = '100%'
              ..style.position = 'relative'
              ..style.overflow = 'hidden';
        container.appendChild(_canvasElements[viewType]!);
        _containerElements[viewType] = container;
      }

      // Take (or adopt) ownership of the registry entries for this
      // viewType.  See [_canvasOwners].
      _canvasOwners[viewType] = this;

      // Register the platform-view factory exactly once per viewType.
      if (!_registeredViewTypes.contains(viewType)) {
        _registeredViewTypes.add(viewType);
        ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
          // Guard: the container may have been removed by release() if
          // Flutter invokes this factory after the decoder was torn down
          // (race during view switches).  Return the container if it
          // still exists, otherwise create a temporary placeholder div.
          final existing = _containerElements[viewType];
          if (existing != null) return existing;
          final placeholder =
              web.document.createElement('div') as web.HTMLDivElement
                ..style.width = '100%'
                ..style.height = '100%';
          return placeholder;
        });
      }
    }

    _setParserForFormat(videoFormat);
  }

  void _setParserForFormat(VideoFormat format) {
    switch (format) {
      case VideoFormat.h264:
        parser = H264Parser();
      case VideoFormat.h265:
        parser = H265Parser();
      case VideoFormat.jpeg:
        parser = JPEGParser();
      case VideoFormat.mpeg4:
        parser = MPEG4Parser();
      default:
        parser = NullParser();
    }
  }

  // — VideoDecoder overrides ————————————————————————————————————

  @override
  Future<void> init() async {
    logger.info('[WebCodec] init format=$videoFormat');
  }

  @override
  void setFormat(
    VideoFormat format,
    VideoParser Function(VideoFormat) createParser,
  ) {
    super.setFormat(format, createParser);
    // Reset decoder when format changes
    _disposeDecoder();
    _configured = false;
    _codecString = '';
    _codecUnsupported = false;
    _notSupportedStrikes = 0;
    _activeParamsSignature = '';
    _pendingFrames.clear();
  }

  @override
  bool supportsFormat(VideoFormat format, IStreamInfo streamInfo) {
    switch (format) {
      case VideoFormat.h264:
      case VideoFormat.h265:
      case VideoFormat.jpeg:
      case VideoFormat.mpeg4:
        return true;
      default:
        return false;
    }
  }

  @override
  void onSendFrame(T frame) {
    if (_released) {
      return;
    }

    final data = frame.data;
    if (data.isEmpty) {
      return;
    }

    // Parse key-frames to extract codec params (SPS/PPS/VPS etc.).
    // Delta frames never contain SPS/PPS, so parsing them is a no-op — skip.
    // Before the first configure, prefer the pre-parsed codec config from
    // the web worker (avoids redundant NAL scanning during startup).  Once
    // configured, always parse the real frame bytes: a worker-cached config
    // can be stale across re-subscription, and mid-stream parameter-set
    // changes must be detected from the live bitstream (see
    // [_checkParamSetChange]).
    if (frame.isIframe) {
      final config = frame.codecConfig;
      if (!_configured && config != null && config.isNotEmpty) {
        parser.parseFrame(config);
      } else {
        parser.parseFrame(data);
      }
    }

    if (videoFormat == VideoFormat.jpeg) {
      _decodeJpeg(data, frame.dt);
      return;
    }

    // MPEG-4 Part 2 is not supported by WebCodecs — use WASM FFmpeg fallback.
    // Note: H.265 is NOT routed to WASM because distributing an HEVC software
    // decoder would require a Via LA patent license.  If WebCodecs can't decode
    // H.265 on this browser, we simply cannot play the stream.
    if (videoFormat == VideoFormat.mpeg4) {
      _decodeWasmFallback(data, frame.isIframe, frame.dt);
      return;
    }

    if (_codecUnsupported) {
      // WebCodecs cannot decode this codec — try MSE fallback for H.265.
      if (videoFormat == VideoFormat.h265) {
        _decodeMseFallback(frame);
        return;
      }
      // For other codecs, drop silently.
      return;
    }

    // Reconfigure when the stream's parameter sets change mid-stream.
    // Without this the decoder keeps its stale description record, and
    // _stripParamNals removes the only in-band copy of the new params —
    // VideoToolbox then fails with kVTVideoDecoderBadDataErr (-12909).
    if (frame.isIframe) {
      _checkParamSetChange();
    }

    // Configure decoder once we have codec data
    if (!_configured && parser.isReady()) {
      _configureDecoder();
    }

    if (_configured) {
      _drainPendingFrames();
      _decodeVideoFrame(data, isKeyframe: frame.isIframe, dt: frame.dt);
    } else if (_reconfigureTimer != null) {
      // Waiting for hardware-slot admission — buffer this frame (bounded)
      // so the keyframe that triggered configure isn't lost.
      _queuePendingFrame(data, frame.isIframe, frame.dt);
    }
  }

  /// Buffer a frame while waiting for hardware-slot admission.
  void _queuePendingFrame(Uint8List data, bool isKeyframe, DateTime dt) {
    if (_pendingFrames.length >= _maxPendingFrames) {
      // Overflow: drop the buffer and resynchronise on the next keyframe.
      _pendingFrames.clear();
      _needsKeyframe = true;
      logger.warn(
        '[WebCodec] Admission buffer overflow — waiting for next keyframe',
      );
      return;
    }
    _pendingFrames.add(_PendingFrame(data, isKeyframe, dt));
  }

  /// Feed frames buffered during an admission wait into the decoder,
  /// oldest first (the first entry is the keyframe that triggered
  /// configure, satisfying the key-chunk-after-configure requirement).
  void _drainPendingFrames() {
    if (_pendingFrames.isEmpty) return;
    final pending = List<_PendingFrame>.of(_pendingFrames);
    _pendingFrames.clear();
    for (final f in pending) {
      _decodeVideoFrame(f.data, isKeyframe: f.isKeyframe, dt: f.dt);
    }
  }

  /// Detect mid-stream VPS/SPS/PPS changes and reconfigure the decoder
  /// with a freshly built description record.
  ///
  /// Called on every keyframe after the parser has ingested the frame's
  /// parameter sets.  Cheap: one FNV-1a hash over the cached param sets
  /// per GOP.
  void _checkParamSetChange() {
    if (!_configured || _decoder == null) return;
    final sig = _computeParamsSignature();
    if (sig.isEmpty || _activeParamsSignature.isEmpty) return;
    if (sig == _activeParamsSignature) return;

    logger.warn(
      '[WebCodec] Parameter sets changed mid-stream '
      '($_activeParamsSignature -> $sig) — reconfiguring decoder',
    );
    _decoderDescription = _buildDecoderDescription() ?? _decoderDescription;
    _codecString = _buildCodecString();
    _activeParamsSignature = sig;
    if (_decoder != null && _decoder!.state != 'closed') {
      try {
        _decoder!.reset();
        _decoder!.configure(_decoderConfig());
        _configuredAt = DateTime.now();
      } catch (e) {
        logger.error('[WebCodec] param-change reconfigure failed: $e');
        // Fall back to flush; the keyframe gate resynchronises decode.
        sendFlush();
      }
    }
  }

  /// Cheap FNV-1a signature over the parser's parameter sets
  /// (VPS for H.265, plus SPS and PPS).  Returns '' when the parser has
  /// no parameter sets (wrong codec or not yet ready).
  String _computeParamsSignature() {
    final p = parser;
    if (p is! H264Parser) return '';
    var hash = 0x811c9dc5;
    var total = 0;
    void mix(Uint8List bytes) {
      for (final b in bytes) {
        hash ^= b;
        hash = (hash * 0x01000193) & 0xFFFFFFFF;
      }
      // Separator so (A, B) and (AB, ∅) hash differently.
      hash ^= 0x2e;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
      total += bytes.length;
    }

    if (p is H265Parser) mix(p.vps);
    mix(p.sps);
    mix(p.pps);
    if (total == 0) return '';
    return '${hash.toRadixString(16)}-$total';
  }

  @override
  void sendFlush() {
    _needsKeyframe = true;
    _framePacer?.flush();
    pacer.cancelNoFramesTimer();
    if (_decoder != null && _decoder!.state != 'closed') {
      _decoder!.flush().toDart.catchError((Object e) {
        logger.error('[WebCodec] flush error: $e');
        return null;
      });
    }
  }

  @override
  void resetForKeyframe() {
    // Discard all queued frames via reset() instead of flush().
    // flush() tries to decode all pending frames — if they reference
    // dropped pictures (common during back-pressure), the decoder
    // hits "EncodingError: Decoding error" and closes.
    // reset() discards the queue without processing, then we
    // reconfigure for a clean keyframe start.
    //
    // Require the keyframe to actually arrive before decode resumes:
    // after reset()+configure() the next chunk fed MUST be a key chunk,
    // and stale delta frames can still be in flight from the worker.
    // The keyframe gate in [_decodeVideoFrame] admits the keyframe and
    // clears this flag.
    _needsKeyframe = true;
    _framePacer?.flush();
    // The stream is alive (keyframe just arrived) — cancel any pending
    // no-video timer so it doesn't fire during the reset/recovery window.
    pacer.cancelNoFramesTimer();
    if (_decoder != null && _decoder!.state != 'closed') {
      try {
        _decoder!.reset();
        // Rebuild the description from the parser's current parameter
        // sets — reusing the cached record risks configuring against
        // stale SPS/PPS after a mid-stream change.
        _decoderDescription = _buildDecoderDescription() ?? _decoderDescription;
        _activeParamsSignature = _computeParamsSignature();
        _decoder!.configure(_decoderConfig());
        _configuredAt = DateTime.now();
      } catch (e) {
        logger.error('[WebCodec] resetForKeyframe failed: $e');
        // Fall back to flush on platforms where reset() isn't supported.
        sendFlush();
      }
    }
  }

  @override
  Future<void> release() async {
    _released = true;
    _reconfigureTimer?.cancel();
    _reconfigureTimer = null;
    _pendingFrames.clear();
    _disposeDecoder();
    await _mseFallback?.release();
    _mseFallback = null;
    // Remove canvas/container entries to free DOM elements — but only if
    // this instance still owns them.  A newer decoder for the same stream
    // may have adopted the elements while this one was being torn down
    // (view switches dispose the old instance after the new one is
    // created); deleting the entries here would kill the live instance's
    // rendering.
    if (identical(_canvasOwners[viewType], this)) {
      _canvasOwners.remove(viewType);
      _canvasElements.remove(viewType);
      _containerElements.remove(viewType);
    }
  }

  @override
  Future<Uint8List?> retrieveSnapshot() async {
    if (_released) return null;

    if (headless) {
      // Headless mode: render to OffscreenCanvas, export via convertToBlob.
      final offscreen = _offscreenCanvas;
      if (offscreen == null) return null;
      try {
        final options = {'type': 'image/jpeg', 'quality': 0.90}.jsify();
        final blobAny = await offscreen
            .convertToBlob(options as JSObject?)
            .toDart;
        final blob = blobAny as web.Blob;
        final reader = web.FileReader();
        final completer = Completer<Uint8List?>();
        reader.onload = ((web.Event _) {
          final result = reader.result;
          if (result == null) {
            completer.complete(null);
            return;
          }
          final buffer = (result as JSArrayBuffer).toDart;
          completer.complete(buffer.asUint8List());
        }).toJS;
        reader.onerror = ((web.Event _) => completer.complete(null)).toJS;
        reader.readAsArrayBuffer(blob);
        return completer.future;
      } catch (e) {
        logger.error('[WebCodec] retrieveSnapshot (headless) error: $e');
        return null;
      }
    }

    // Normal (DOM canvas) mode: use async toBlob to avoid blocking the
    // main thread with a synchronous JPEG encode + base64 round-trip.
    if (!_canvasElements.containsKey(viewType)) return null;
    try {
      final completer = Completer<Uint8List?>();
      canvas.toBlob(
        ((web.Blob? blob) {
          if (blob == null) {
            completer.complete(null);
            return;
          }
          final reader = web.FileReader();
          reader.onload = ((web.Event _) {
            final result = reader.result;
            if (result == null) {
              completer.complete(null);
              return;
            }
            final buffer = (result as JSArrayBuffer).toDart;
            completer.complete(buffer.asUint8List());
          }).toJS;
          reader.onerror = ((web.Event _) => completer.complete(null)).toJS;
          reader.readAsArrayBuffer(blob);
        }).toJS,
        'image/jpeg',
        0.90.toJS,
      );
      return completer.future;
    } catch (e) {
      logger.error('[WebCodec] retrieveSnapshot error: $e');
      return null;
    }
  }

  @override
  bool get dewarping => _dewarper?.isActive ?? false;

  @override
  int? get dewarpTextureId => null; // Web uses canvas, not texture IDs

  @override
  Future<void> setDewarpMode(DewarpType? mode) async {
    logger.info('[WebCodec] setDewarpMode called: $mode (was: $_dewarpMode)');
    _dewarpMode = mode ?? DewarpType.none;
    if (_dewarpMode == DewarpType.none) {
      logger.info('[WebCodec] Dewarp disabled');
      _dewarper?.setDewarpMode(DewarpType.none);
      _swapTo2dCanvas();
      return;
    }
    // Lazily initialize WebGPU dewarper
    if (_dewarper == null && !_dewarpInitializing) {
      logger.info('[WebCodec] Lazily initializing WebGPU dewarper...');
      await _initDewarper();
    }
    if (_dewarper != null) {
      logger.info(
        '[WebCodec] Setting dewarper mode to $_dewarpMode (isReady=${_dewarper!.isReady})',
      );
      _dewarper!.setDewarpMode(_dewarpMode);
      _dewarpFrameCount = 0; // reset so we get fresh logging
      _swapToWebGpuCanvas(); // ensure WebGPU canvas is visible
    } else {
      logger.error('[WebCodec] Dewarper is null after init attempt!');
    }
  }

  @override
  Future<void> updateParams(
    int x,
    int y,
    int r,
    DewarpMountPosition mount,
  ) async {
    logger.info(
      '[WebCodec] updateParams: x=$x y=$y r=$r mount=$mount (dewarper=${_dewarper != null})',
    );
    _dewarpX = x;
    _dewarpY = y;
    _dewarpR = r;
    _dewarpMount = mount;
    _dewarper?.updateParams(x, y, r, mount);
  }

  @override
  Future<void> setPosition(double pan, double tilt, double zoom) async {
    _dewarper?.setPosition(pan, tilt, zoom);
  }

  @override
  Future<void> pan(int dir, int speed) async {
    _dewarper?.pan(dir, speed);
  }

  @override
  Future<void> tilt(int dir, int speed) async {
    _dewarper?.tilt(dir, speed);
  }

  @override
  Future<void> zoom(int dir, int speed) async {
    _dewarper?.zoom(dir, speed);
  }

  /// The WebGPU canvas that renders dewarped frames.
  web.HTMLCanvasElement? _dewarpCanvas;

  /// Initialize the WebGPU dewarper by creating a new canvas for WebGPU
  /// and adding it to the container div (hidden). When dewarping starts
  /// we show it and hide the 2D canvas.
  Future<void> _initDewarper() async {
    _dewarpInitializing = true;
    try {
      // Create a fresh canvas for WebGPU (can't share with 2D context).
      if (_dewarpCanvas == null) {
        _dewarpCanvas =
            web.document.createElement('canvas') as web.HTMLCanvasElement
              ..style.width = '100%'
              ..style.height = '100%'
              ..style.objectFit = 'contain'
              ..style.pointerEvents = 'none'
              ..style.position = 'absolute'
              ..style.top = '0'
              ..style.left = '0'
              ..style.display = 'none'; // hidden until dewarping
        // Also make the 2D canvas absolutely positioned so they overlap
        canvas.style.position = 'absolute';
        canvas.style.top = '0';
        canvas.style.left = '0';
        // Add to container
        final container = _containerElements[viewType];
        container?.appendChild(_dewarpCanvas!);
      }

      // Load WGSL shader source
      logger.info('[WebCodec] Loading WGSL shader...');
      _shaderSource ??= _loadShaderSource();
      if (_shaderSource == null) {
        logger.error('[WebCodec] Failed to load dewarp shader');
        return;
      }
      logger.info('[WebCodec] Shader loaded (${_shaderSource!.length} chars)');

      // Ensure JS module is loaded BEFORE checking isSupported,
      // since _webGpuDewarperIsSupported is defined by the JS module.
      logger.info('[WebCodec] Loading webgpu_dewarper.js...');
      _loadDewarperScript();
      logger.info('[WebCodec] JS module loaded');

      // Now check WebGPU support (requires JS module to be loaded first)
      logger.info('[WebCodec] Checking WebGPU support...');
      final supported = await WebGpuDewarper.isSupported();
      if (!supported) {
        logger.warn(
          '[WebCodec] WebGPU not supported in this browser, dewarping disabled',
        );
        return;
      }
      logger.info('[WebCodec] WebGPU is supported');

      _dewarper = WebGpuDewarper(canvas: _dewarpCanvas!);
      logger.info('[WebCodec] Initializing WebGpuDewarper...');
      final ok = await _dewarper!.init(_shaderSource!);
      if (!ok) {
        logger.error('[WebCodec] WebGPU dewarper init returned false');
        _dewarper = null;
      } else {
        logger.info('[WebCodec] ✅ WebGPU dewarper initialized successfully');
        // Re-apply stored params that may have arrived before init completed
        _dewarper!.updateParams(_dewarpX, _dewarpY, _dewarpR, _dewarpMount);
        // Swap the visible canvas: replace 2D canvas with WebGPU canvas
        _swapToWebGpuCanvas();
      }
    } catch (e, st) {
      logger.error('[WebCodec] WebGPU dewarper init error: $e\n$st');
      _dewarper = null;
    } finally {
      _dewarpInitializing = false;
    }
  }

  /// Show the WebGPU canvas and hide the 2D canvas.
  void _swapToWebGpuCanvas() {
    if (_dewarpCanvas == null) return;
    canvas.style.display = 'none';
    _dewarpCanvas!.style.display = 'block';
    logger.info('[WebCodec] Swapped visible canvas to WebGPU canvas');
  }

  /// Show the 2D canvas and hide the WebGPU canvas.
  void _swapTo2dCanvas() {
    if (_dewarpCanvas == null) return;
    _dewarpCanvas!.style.display = 'none';
    canvas.style.display = 'block';
    _dewarpFrameCount = 0;
    logger.info('[WebCodec] Swapped visible canvas back to 2D canvas');
  }

  /// Return the embedded WGSL shader source.
  String? _loadShaderSource() => kDewarpShaderSource;

  /// Inject the WebGPU dewarper JS module inline if not already loaded.
  /// Uses the shared [dewarperJsInjected] flag from mse_video_decoder.dart.
  void _loadDewarperScript() {
    if (dewarperJsInjected) return;
    final script = web.document.createElement('script') as web.HTMLScriptElement
      ..type = 'text/javascript'
      ..text = kDewarperJsSource;
    web.document.head!.appendChild(script);
    dewarperJsInjected = true;
  }

  /// Cached decoder description (HEVCDecoderConfigurationRecord or
  /// AVCDecoderConfigurationRecord) built during configure and rebuilt
  /// whenever the stream's parameter sets change (see
  /// [_checkParamSetChange]) or a reset/reconfigure cycle runs.
  Uint8List? _decoderDescription;

  // — WebCodecs decoder lifecycle ————————————————————————————————

  /// Build the [_DecoderConfig] from the current codec string, description
  /// and parser state.  Shared by every configure()/reconfigure site so no
  /// path can drift out of sync (previously each site duplicated this
  /// block inline).
  _DecoderConfig _decoderConfig({String? hardwareAcceleration}) =>
      _DecoderConfig(
        codec: _codecString.toJS,
        optimizeForLatency: optimizeForLatency.toJS,
        hardwareAcceleration: (hardwareAcceleration ?? _hwAccelPreference).toJS,
        description: _decoderDescription?.toJS,
        codedWidth: parser.resolution.width > 0
            ? parser.resolution.width.toJS
            : null,
        codedHeight: parser.resolution.height > 0
            ? parser.resolution.height.toJS
            : null,
      );

  void _configureDecoder() {
    _reconfigureTimer?.cancel();
    _reconfigureTimer = null;
    _disposeDecoder();
    if (_released || _codecUnsupported) return;

    _codecString = _buildCodecString();
    if (_codecString.isEmpty) {
      logger.error('[WebCodec] Could not build codec string');
      return;
    }

    // — Hardware-slot admission (see _HwSlotGate) ——————————————
    // Defer configure while the pool is full or while staggering spacing
    // applies.  Frames arriving meanwhile are buffered by onSendFrame so
    // the triggering keyframe isn't lost.  Fail open after
    // maxAdmissionWait so a leaked slot cannot starve the stream.
    final now = DateTime.now();
    _admissionWaitStart ??= now;
    final waited = now.difference(_admissionWaitStart!);
    final spacing = _HwSlotGate.spacingDelay(now);
    if ((!_HwSlotGate.hasFreeSlot || spacing > Duration.zero) &&
        waited < _HwSlotGate.maxAdmissionWait) {
      final retryIn = spacing > Duration.zero
          ? spacing
          : const Duration(milliseconds: 100);
      _reconfigureTimer = Timer(retryIn, () {
        _reconfigureTimer = null;
        if (!_released && !_configured && parser.isReady()) {
          _configureDecoder();
        }
      });
      if (!_HwSlotGate.hasFreeSlot) {
        logger.info(
          '[WebCodec] Waiting for HW decoder slot '
          '(${_HwSlotGate.slotsInUse}/${_HwSlotGate.maxSlots} in use, '
          'waited ${waited.inMilliseconds}ms)',
        );
      }
      return;
    }
    if (_HwSlotGate.hasFreeSlot) {
      _HwSlotGate.acquire();
      _holdsHwSlot = true;
    } else {
      // Waited too long — configure anyway, but let the browser pick the
      // decoder so we don't pile onto a saturated VideoToolbox pool.
      logger.warn(
        '[WebCodec] No HW slot after ${waited.inMilliseconds}ms — '
        'configuring with no-preference',
      );
      _hwAccelPreference = 'no-preference';
    }
    _HwSlotGate.markConfigured(now);
    _admissionWaitStart = null;

    // Build the decoder description (required by Firefox and Safari for
    // H.265, and by Safari for H.264).  Without this, those browsers
    // reject the codec with NotSupportedError at decode time.
    _decoderDescription = _buildDecoderDescription();
    _activeParamsSignature = _computeParamsSignature();

    _outputCallback = ((JSObject frame) {
      _onDecodedFrame(_JSVideoFrame(frame));
    }).toJS;

    _errorCallback = ((JSObject error) {
      _onDecoderError(error);
    }).toJS;

    try {
      _decoder = _JSVideoDecoder(
        _DecoderInit(output: _outputCallback!, error: _errorCallback!),
      ); // _JSVideoDecoder

      _decoder!.configure(_decoderConfig());

      _configured = true;
      _configuredAt = DateTime.now();
      logger.info(
        '[WebCodec] Decoder configured: $_codecString '
        'format=$videoFormat res=${parser.resolution.width}x${parser.resolution.height} '
        'maxQueue=$_maxDecodeQueueSize hwAccel=$_hwAccelPreference '
        'slots=${_HwSlotGate.slotsInUse}/${_HwSlotGate.maxSlots} '
        'description=${_decoderDescription != null ? '${_decoderDescription!.length}B' : 'none'}',
      );

      // Probe the browser to see if it actually chose HW or SW decoding.
      _probeHardwareAcceleration();

      // Create the presentation pacer for vsync-aligned frame display.
      // The pacer only needs enough frames for smooth vsync delivery —
      // cap at ~0.5s of frames (much smaller than the decode queue).
      if (usePresentationPacer && !headless) {
        final pacerFps = pacer.camFPS > 0 ? pacer.camFPS : 30;
        _framePacer?.dispose();
        _framePacer = WebFramePacer(
          logger: logger,
          // Keep the presentation buffer small (~0.25 s) so that:
          //  1. Back-pressure kicks in sooner, preventing large burst evictions.
          //  2. GPU VideoFrame memory stays bounded with many concurrent streams.
          //  3. Live latency is minimised (stale frames are dropped quickly).
          // Old value was (fps * 1.0).clamp(15, 60) = up to 1 s of buffer.
          maxBufferFrames: (pacerFps * 0.33).ceil().clamp(3, 8),
          startupFrameThreshold: 3,
          label: viewType,
        );
        _framePacer!.onPresent = _onPacerPresent;
      }

      // Feed any frames buffered while waiting for admission.
      _drainPendingFrames();
    } catch (e) {
      final msg = e.toString();
      logger.error('[WebCodec] configure error: $msg');
      // If configure itself throws NotSupportedError (browser lacks a
      // hardware HEVC decoder), retry with backoff — the codec is only
      // marked permanently unsupported after repeated strikes, because a
      // transient GPU-process failure during a view switch can also
      // surface as NotSupported.
      if (msg.contains('NotSupportedError') || msg.contains('NotSupported')) {
        _handleConfigureNotSupported(msg);
      } else {
        try {
          _decoder?.close();
        } catch (_) {}
        _decoder = null;
        _configured = false;
        if (_holdsHwSlot) {
          _HwSlotGate.release();
          _holdsHwSlot = false;
        }
      }
      callbacks?.onInitError?.call(e);
    }
  }

  /// Handle a configure-time NotSupportedError.  Latch the codec as
  /// permanently unsupported only after [_maxNotSupportedStrikes]
  /// consecutive failures; earlier strikes schedule a delayed retry.
  void _handleConfigureNotSupported(String msg) {
    try {
      _decoder?.close();
    } catch (_) {}
    _decoder = null;
    _configured = false;
    _admissionWaitStart = null;
    if (_holdsHwSlot) {
      _HwSlotGate.release();
      _holdsHwSlot = false;
    }
    _notSupportedStrikes++;
    if (_notSupportedStrikes >= _maxNotSupportedStrikes) {
      logger.warn(
        '[WebCodec] Codec "$_codecString" not supported at configure time '
        '($_notSupportedStrikes consecutive failures) — stream cannot be '
        'decoded',
      );
      _codecUnsupported = true;
      return;
    }
    logger.warn(
      '[WebCodec] configure NotSupported '
      '(strike $_notSupportedStrikes/$_maxNotSupportedStrikes) — retrying',
    );
    _reconfigureTimer?.cancel();
    _reconfigureTimer = Timer(Duration(seconds: _notSupportedStrikes), () {
      _reconfigureTimer = null;
      if (!_released && !_configured && parser.isReady()) {
        _configureDecoder();
      }
    });
  }

  void _disposeDecoder() {
    // Cancel any in-progress or scheduled recovery so it cannot fire
    // after the decoder has been disposed / replaced.
    _recovering = false;
    // Cancel VT-throttle cooldown.
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _throttleCooldownSecs = 0;

    // Release this instance's hardware-slot claim.
    if (_holdsHwSlot) {
      _HwSlotGate.release();
      _holdsHwSlot = false;
    }

    // — Critical: null instance fields BEFORE close() ——————————
    // close() can trigger synchronous VT error callbacks (-12909) if the
    // decoder has pending frames.  By nulling _decoder first, those
    // callbacks see _decoder == null and bail without attempting recovery.
    // This prevents: (a) recovery creating a new decoder that immediately
    // gets overwritten by the null below, leaking VT sessions, and
    // (b) cascade errors from a dying decoder triggering new decode attempts.
    final decoder = _decoder;
    _decoder = null;
    _configured = false;
    _outputCallback = null;
    _errorCallback = null;

    if (decoder != null && decoder.state != 'closed') {
      try {
        // reset() discards all pending frames from the VT decode queue,
        // making the session idle.  Closing an idle VT session is clean
        // and doesn't trigger -12909 errors from pending frame callbacks.
        decoder.reset();
      } catch (_) {
        // reset() may throw if the decoder is in an error state — that's
        // fine, we'll close it anyway.
      }
      try {
        decoder.close();
      } catch (_) {}
    }

    _ctx = null;
    _offscreenCanvas = null;
    _offscreenCtx = null;
    _droppedFrameCount = 0;
    // Dispose WASM fallback decoder
    _wasmDecoder?.free();
    _wasmDecoder = null;
    _useWasmFallback = false;
    _wasmInitializing = false;
    // Dispose WebGL YUV renderer
    _webglYuvRenderer?.destroy();
    _webglYuvRenderer = null;
    _webglYuvFailed = false;
    // Dispose presentation pacer
    _framePacer?.dispose();
    _framePacer = null;
    // Cancel the DecoderPacer no-frames timer so it doesn't fire during
    // stream close/restart and produce a false Video Loss overlay.
    pacer.cancelNoFramesTimer();
    // Dispose WebGPU dewarper
    _dewarper?.dispose();
    _dewarper = null;
    // Remove the (hidden) WebGPU canvas from the shared container so
    // reinit cycles don't accumulate stale canvas nodes, and restore the
    // 2D canvas visibility in case the WebGPU canvas was the live one.
    if (_dewarpCanvas != null) {
      _dewarpCanvas!.remove();
      _dewarpCanvas = null;
      if (!headless && _canvasElements.containsKey(viewType)) {
        canvas.style.display = 'block';
      }
    }
    _dewarpMode = DewarpType.none;
  }

  // — Decode a video frame via WebCodecs ————————————————————————

  void _decodeVideoFrame(
    Uint8List data, {
    required bool isKeyframe,
    required DateTime dt,
  }) {
    if (_decoder == null || _decoder!.state == 'closed') {
      logger.warn(
        '[WebCodec][DBG] _decodeVideoFrame: SKIPPED — '
        'decoder=${_decoder == null ? "null" : "state=${_decoder!.state}"} '
        'configured=$_configured isKeyframe=$isKeyframe',
      );
      return;
    }

    // VT-throttled: drop all frames until cooldown expires.
    if (_throttleCooldownSecs > 0) return;

    // After a decode error, skip delta frames until a keyframe arrives
    // so the decoder can resynchronise (critical for H.265 long-GOP streams).
    if (_needsKeyframe) {
      if (!isKeyframe) {
        return;
      }
      logger.info(
        '[WebCodec] keyframe received — resuming decode '
        '(decoderState=${_decoder!.state} configured=$_configured)',
      );
      _needsKeyframe = false;
      _errorBackoff.reset(); // successful keyframe — reset error streak
    }

    // Stall detection: if the decode queue has grown to 3× the maximum
    // without any frames being output, the VT session is effectively dead
    // (accepts decode() calls but never fires the output callback).
    // Proactively reset to free the stalled GPU memory before it causes OOM.
    if (_decoder!.decodeQueueSize > _maxDecodeQueueSize * 3) {
      logger.warn(
        '[WebCodec] Decode queue stalled at ${_decoder!.decodeQueueSize} '
        '(max=$_maxDecodeQueueSize) — resetting decoder to free GPU memory',
      );
      _needsKeyframe = true;
      _framePacer?.flush();
      try {
        if (_decoder!.state != 'closed') {
          _decoder!.reset();
          // Rebuild the description — the stall may have been caused by a
          // parameter-set change the cached record doesn't reflect.
          _decoderDescription =
              _buildDecoderDescription() ?? _decoderDescription;
          _activeParamsSignature = _computeParamsSignature();
          _decoder!.configure(_decoderConfig());
          _configuredAt = DateTime.now();
        }
      } catch (e) {
        logger.error('[WebCodec] stall-reset failed: $e');
      }
      return;
    }

    // Back-pressure: skip if queue is too deep (but never skip keyframes).
    // Also skip back-pressure during initial startup grace period.
    if (!isKeyframe &&
        _decoder!.decodeQueueSize > _maxDecodeQueueSize &&
        DateTime.now().difference(_configuredAt) >= _startupGrace) {
      droppedLast = true;
      _droppedFrameCount++;
      if (_droppedFrameCount % _dropWarningInterval == 0) {
        logger.warn(
          '[WebCodec] back-pressure: $_droppedFrameCount frames dropped '
          '(decodeQueueSize=${_decoder!.decodeQueueSize})',
        );
        callbacks?.onWarning?.call(
          0,
        ); // Pass 0 (no degraded state) instead of frame count to avoid false Video Loss
        _droppedFrameCount = 0;
      }
      return;
    }

    // Only record feedFrame for frames that will actually enter the decode
    // pipeline — dropped frames can never trigger renderFrame() and would
    // cause the 5-second noVideo timer to fire falsely.
    pacer.feedFrame(dt);

    final timestampUs = dt.microsecondsSinceEpoch;
    try {
      // For avc3/hev1 (in-band param sets), prepend VPS/SPS/PPS to keyframes.
      // For hvc1/avc1 (out-of-band via description), params are already in
      // the description record — do NOT duplicate them in the bitstream.
      // Additionally, strip any in-band param NALs from keyframes when using
      // hvc1 to avoid confusing decoders that strictly follow the spec.
      final useInBandParams = _decoderDescription == null;
      Uint8List frameData;
      if (isKeyframe && useInBandParams) {
        frameData = _ensureParamsInBand(data);
      } else if (isKeyframe && !useInBandParams) {
        frameData = _stripParamNals(data);
      } else {
        frameData = data;
      }
      final avccData = _toAvcc(frameData);
      final chunk = _JSEncodedVideoChunk(
        _ChunkInit(
          type: (isKeyframe ? 'key' : 'delta').toJS,
          timestamp: timestampUs.toJS,
          data: avccData.toJS,
        ), // _ChunkInit
      ); // _JSEncodedVideoChunk
      _decoder!.decode(chunk);
      droppedLast = false;
    } catch (e) {
      logger.error(
        '[WebCodec][DBG] decode() threw: $e '
        '(decoderState=${_decoder?.state} isKey=$isKeyframe ts=${timestampUs}us)',
      );
      // After a decode error, require a keyframe before resuming decode.
      _needsKeyframe = true;
      callbacks?.onDecodeError?.call(e.toString());
    }
  }

  /// Ensure parameter sets (SPS/PPS for H.264; VPS/SPS/PPS for H.265) are
  /// present in the key frame data.  The `avc3`/`hev1` codec strings tell
  /// VideoDecoder that params are in-band, but NVRs often send them as
  /// separate packets.  If the key frame doesn't already contain them,
  /// prepend the cached params so the decoder can initialize.
  Uint8List _ensureParamsInBand(Uint8List frame) {
    if (parser is! H264Parser) return frame;
    final h264 = parser as H264Parser;

    // Check if frame already contains SPS
    if (h264.hasNalUnitType(frame, h264.nalTypeSPS)) return frame;

    // No cached params available — nothing to prepend.
    if (h264.sps.isEmpty || h264.pps.isEmpty) return frame;

    final buf = BytesBuilder(copy: false);

    // For H.265, prepend VPS before SPS/PPS.
    if (h264 is H265Parser && h264.vps.isNotEmpty) {
      buf.add(h264.vps);
    }

    buf.add(h264.sps);
    buf.add(h264.pps);
    buf.add(frame);

    return buf.toBytes();
  }

  /// Strip VPS/SPS/PPS NAL units from frame data when using hvc1/avc1
  /// (out-of-band parameter sets via description).  Some NVRs include
  /// parameter sets in every keyframe regardless; Firefox's WebCodecs
  /// implementation may reject frames with redundant parameter NALs
  /// when the description was already provided.
  Uint8List _stripParamNals(Uint8List frame) {
    if (parser is! H264Parser) return frame;
    final h264 = parser as H264Parser;

    // Identify NAL unit boundaries.
    final boundaries = <int>[];
    final startCodeLens = <int>[];
    int pos = 0;
    while (pos < frame.length - 2) {
      final startLen = h264.isNalStart(frame, pos);
      if (startLen > 0) {
        boundaries.add(pos);
        startCodeLens.add(startLen);
        pos += startLen;
      } else {
        pos++;
      }
    }
    if (boundaries.isEmpty) return frame;

    // NAL types to strip: VPS(32), SPS(33/7), PPS(34/8), AUD(35/9).
    final isH265 = parser is H265Parser;

    final buf = BytesBuilder(copy: false);
    bool stripped = false;
    for (int i = 0; i < boundaries.length; i++) {
      final nalDataStart = boundaries[i] + startCodeLens[i];
      final nalDataEnd = (i + 1 < boundaries.length)
          ? boundaries[i + 1]
          : frame.length;
      if (nalDataStart >= frame.length) continue;

      final nalHeader = frame[nalDataStart];
      bool isParamNal;
      if (isH265) {
        // H.265 NAL type is bits 1-6 of the first byte.
        final nalType = (nalHeader >> 1) & 0x3F;
        // VPS=32, SPS=33, PPS=34, AUD=35
        isParamNal = nalType >= 32 && nalType <= 35;
      } else {
        // H.264 NAL type is bits 0-4 of the first byte.
        final nalType = nalHeader & 0x1F;
        // SPS=7, PPS=8, AUD=9
        isParamNal = nalType == 7 || nalType == 8 || nalType == 9;
      }

      if (isParamNal) {
        stripped = true;
      } else {
        // Keep this NAL unit (with its original start code).
        buf.add(frame.sublist(boundaries[i], nalDataEnd));
      }
    }

    return stripped ? buf.toBytes() : frame;
  }

  /// Convert Annex B format (start codes) to AVCC/HVCC format (length prefixes).
  ///
  /// The WebCodecs spec requires EncodedVideoChunk data to use 4-byte
  /// big-endian NAL unit length prefixes, NOT Annex B start codes.
  /// Chrome is lenient and accepts Annex B, but Safari strictly requires
  /// the length-prefixed format.
  Uint8List _toAvcc(Uint8List frame) {
    if (parser is! H264Parser) return frame;
    final h264 = parser as H264Parser;

    // Find all NAL unit boundaries (start code positions and lengths).
    final boundaries = <int>[];
    final startCodeLens = <int>[];

    int pos = 0;
    while (pos < frame.length - 2) {
      final startLen = h264.isNalStart(frame, pos);
      if (startLen > 0) {
        boundaries.add(pos);
        startCodeLens.add(startLen);
        pos += startLen;
      } else {
        pos++;
      }
    }

    if (boundaries.isEmpty) return frame;

    // Build output with 4-byte length prefixes replacing start codes.
    final buf = BytesBuilder(copy: false);
    for (int i = 0; i < boundaries.length; i++) {
      final nalDataStart = boundaries[i] + startCodeLens[i];
      final nalDataEnd = (i + 1 < boundaries.length)
          ? boundaries[i + 1]
          : frame.length;
      final nalLength = nalDataEnd - nalDataStart;

      // 4-byte big-endian length prefix
      buf.addByte((nalLength >> 24) & 0xFF);
      buf.addByte((nalLength >> 16) & 0xFF);
      buf.addByte((nalLength >> 8) & 0xFF);
      buf.addByte(nalLength & 0xFF);
      // NAL unit data
      buf.add(frame.sublist(nalDataStart, nalDataEnd));
    }

    return buf.toBytes();
  }

  // — Decode JPEG frame using ImageDecoder or canvas ——————————————

  void _decodeJpeg(Uint8List data, DateTime dt) {
    // Back-pressure: skip frame if too many JPEG decodes are in flight.
    if (_jpegInFlight >= _maxJpegInFlight) {
      droppedLast = true;
      _droppedFrameCount++;
      if (_droppedFrameCount % _dropWarningInterval == 0) {
        logger.warn(
          '[WebCodec] back-pressure: $_droppedFrameCount frames dropped '
          '(jpegInFlight=$_jpegInFlight)',
        );
        callbacks?.onWarning?.call(
          0,
        ); // Pass 0 (no degraded state) instead of frame count to avoid false Video Loss
        _droppedFrameCount = 0;
      }
      return;
    }

    // Use the frame's own timestamp (matches the H.264/H.265 path) so
    // pacer statistics aren't skewed by decode latency.
    pacer.feedFrame(dt);

    try {
      _jpegInFlight++;
      final blob = web.Blob(
        [data.toJS].toJS,
        web.BlobPropertyBag(type: 'image/jpeg'),
      ); // web.Blob

      web.window
          .createImageBitmap(blob)
          .toDart
          .then((web.ImageBitmap bitmap) {
            _jpegInFlight--;

            // Guard: decoder was released while the async decode was in-flight.
            if (_released || !_canvasElements.containsKey(viewType)) {
              bitmap.close();
              return;
            }

            final w = bitmap.width;
            final h = bitmap.height;

            if (headless) {
              // In headless mode, skip canvas rendering — just deliver raw JPEG.
              bitmap.close();
              _frameCount++;
              renderedFrame = true;
              pixelResolution = VideoDecoderSize(w, h);
              callbacks?.onFrameAvailable?.call(data);
              return;
            }

            // Route through WebGPU dewarper when active.
            if (_dewarper != null && _dewarper!.isActive) {
              _dewarpJpegFrame(bitmap as JSObject, w, h, dt);
              return;
            }

            if (canvas.width != w) canvas.width = w;
            if (canvas.height != h) canvas.height = h;

            ctx.drawImage(bitmap as JSObject, 0, 0, w, h);
            bitmap.close();

            _frameCount++;
            renderedFrame = true;
            pixelResolution = VideoDecoderSize(w, h);

            pacer.renderFrame(dt, renderManager.pbTime, true);
            callbacks?.onFrameDecoded?.call((dt, null));
            callbacks?.onFrameAvailable?.call(data);
            onFrameRendered?.call(w, h);
          })
          .catchError((Object e) {
            _jpegInFlight--;
            logger.error('[WebCodec] JPEG decode error: $e');
          });
    } catch (e) {
      _jpegInFlight--;
      logger.error('[WebCodec] JPEG feed error: $e');
    }
  }

  // — WASM MPEG-4 Part 2 decoder (WebCodecs does not support mp4v) —

  _JSImageData _createImageData(Uint8List rgba, int width, int height) {
    final clamped = Uint8ClampedList.fromList(rgba);
    return _JSImageData(clamped.toJS, width, height);
  }

  void _putImageData(_JSImageData imageData, int dx, int dy) {
    ctx.putImageData(imageData as JSObject, dx, dy);
  }

  // — MSE fallback for H.265 on Firefox ————————————————————————

  void _decodeMseFallback(T frame) {
    if (_mseFallback == null) {
      // Get the container div that holds the canvas (already in the widget tree).
      final container = _containerElements[viewType];
      if (container == null) {
        logger.error('[WebCodec] Cannot create MSE fallback: no container');
        return;
      }

      logger.info('[WebCodec] Creating MSE fallback for H.265');
      _mseFallback = MseVideoDecoder<T>(
        streamInfo: _streamInfo,
        videoFormat: VideoFormat.h265,
        logger: logger,
        renderManager: renderManager,
        pacer: pacer,
        container: container,
      );
      _mseFallback!.callbacks = callbacks;
      _mseFallback!.init();

      // Seed the MSE decoder with VPS/SPS/PPS that the WebCodec parser
      // already extracted from the keyframe that triggered the error.
      if (parser is H265Parser) {
        final h265 = parser as H265Parser;
        if (h265.vps.isNotEmpty && h265.sps.isNotEmpty && h265.pps.isNotEmpty) {
          _mseFallback!.seedCodecData(h265.vps, h265.sps, h265.pps);
        }
      }
    }
    _mseFallback!.onSendFrame(frame);
  }

  void _decodeWasmFallback(Uint8List data, bool isKeyframe, DateTime dt) {
    if (_wasmInitializing) return;

    if (_wasmDecoder == null || !_wasmDecoder!.isReady) {
      if (!_useWasmFallback) {
        _useWasmFallback = true;
        _wasmInitializing = true;
        final codecName = _wasmCodecName;
        logger.info(
          '[WebCodec] $codecName: using WASM FFmpeg fallback decoder',
        );
        _initWasmDecoder().then((_) {
          _wasmInitializing = false;
          // Retry this frame if it was a keyframe (needed to start decoding).
          // Clear _wasmNeedsKeyframe since we already have the keyframe.
          if (isKeyframe && _wasmDecoder != null) {
            _wasmNeedsKeyframe = false;
            _decodeWasmFrame(data, dt);
          }
        });
      }
      return;
    }

    // Flush decoder on keyframes if we've been getting consecutive nulls,
    // or if we flagged that we need a keyframe to recover.
    if (isKeyframe && _wasmNeedsKeyframe) {
      logger.info('[WebCodec] WASM: flushing decoder on keyframe (recovery)');
      _wasmDecoder!.flush();
      _wasmConsecutiveNulls = 0;
      _wasmNeedsKeyframe = false;
    }

    // Skip non-keyframes if we're waiting for recovery
    if (_wasmNeedsKeyframe && !isKeyframe) return;

    _decodeWasmFrame(data, dt);
  }

  /// FFmpeg codec name corresponding to the current [videoFormat].
  String get _wasmCodecName {
    switch (videoFormat) {
      case VideoFormat.h265:
        return 'hevc';
      case VideoFormat.h264:
        return 'h264';
      case VideoFormat.mpeg4:
        return 'mpeg4';
      default:
        return 'mpeg4';
    }
  }

  Future<void> _initWasmDecoder() async {
    final codecName = _wasmCodecName;
    try {
      _wasmDecoder = WasmVideoDecoder();
      final ok = await _wasmDecoder!.initialize(codecName);
      if (!ok) {
        logger.error('[WebCodec] WASM $codecName decoder init failed');
        _wasmDecoder = null;
        return;
      }
      _wasmConsecutiveNulls = 0;
      // H.264/H.265 must start from a keyframe so FFmpeg receives parameter
      // sets (SPS/PPS or VPS/SPS/PPS).  Without them, delta frames produce
      // "PPS id out of range" errors and green/grey artefacts.
      // MPEG-4 is exempt: FFmpeg's MPEG-4 parser resynchronises internally
      // and does not require a keyframe to start decoding.
      _wasmNeedsKeyframe =
          videoFormat != VideoFormat.mpeg4 && videoFormat != VideoFormat.jpeg;
      logger.info('[WebCodec] WASM $codecName decoder ready');
    } catch (e) {
      logger.error('[WebCodec] WASM $codecName decoder init error: $e');
      _wasmDecoder = null;
    }
  }

  void _decodeWasmFrame(Uint8List data, DateTime dt) {
    if (_wasmDecoder == null || !_wasmDecoder!.isReady) return;

    // Only count frames that actually enter the WASM decode pipeline —
    // frames dropped during decoder init must not suppress the
    // no-video timer (matches the H.264/H.265 feedFrame policy).
    pacer.feedFrame(dt);

    // Try WebGL YUV path first (GPU color conversion, much faster)
    if (!headless && !_webglYuvFailed && _dewarper?.isActive != true) {
      final yuvFrame = _wasmDecoder!.decodeYuv(data);
      if (yuvFrame != null) {
        _wasmConsecutiveNulls = 0;
        _renderYuvFrame(yuvFrame, dt, data);
        return;
      }
      // null = no frame produced yet (buffering), fall through to track nulls
      if (yuvFrame == null) {
        _wasmConsecutiveNulls++;
        if (_wasmConsecutiveNulls == 30) {
          logger.warn(
            '[WebCodec] WASM: 30 consecutive null frames — '
            'decoder may be stuck, waiting for keyframe to flush',
          );
          _wasmNeedsKeyframe = true;
        } else if (_wasmConsecutiveNulls % 100 == 0) {
          logger.warn(
            '[WebCodec] WASM: $_wasmConsecutiveNulls consecutive '
            'null frames (waiting for keyframe)',
          );
        }
        return;
      }
    }

    // Fallback: RGBA decode path (CPU sws_scale + putImageData)
    final frame = _wasmDecoder!.decode(data);
    if (frame == null) {
      _wasmConsecutiveNulls++;
      if (_wasmConsecutiveNulls == 30) {
        logger.warn(
          '[WebCodec] MPEG4 WASM: 30 consecutive null frames — '
          'decoder may be stuck, waiting for keyframe to flush',
        );
        _wasmNeedsKeyframe = true;
      } else if (_wasmConsecutiveNulls % 100 == 0) {
        logger.warn(
          '[WebCodec] MPEG4 WASM: $_wasmConsecutiveNulls consecutive '
          'null frames (waiting for keyframe)',
        );
      }
      return;
    }

    _wasmConsecutiveNulls = 0;
    final w = frame.width;
    final h = frame.height;

    if (headless) {
      _frameCount++;
      renderedFrame = true;
      pixelResolution = VideoDecoderSize(w, h);

      if (callbacks?.onFrameAvailable == null) return;

      // Render decoded RGBA to an offscreen canvas and export as JPEG,
      // matching the H264/H265 headless capture path.
      if (_offscreenCanvas == null ||
          _offscreenCanvas!.width != w ||
          _offscreenCanvas!.height != h) {
        _offscreenCanvas = _JSOffscreenCanvas(w, h);
        _offscreenCtx = null;
      }
      _offscreenCtx ??= _CanvasCtx(_offscreenCanvas!.getContext('2d')!);
      final imageData = _createImageData(frame.rgba, w, h);
      _offscreenCtx!.putImageData(imageData as JSObject, 0, 0);

      final options = {'type': 'image/jpeg', 'quality': 0.85}.jsify();
      _offscreenCanvas!.convertToBlob(options as JSObject?).toDart.then((
        JSAny? blobAny,
      ) {
        final blob = blobAny as web.Blob;
        final reader = web.FileReader();
        reader.onload = ((web.Event _) {
          final result = reader.result;
          if (result == null) return;
          final buffer = (result as JSArrayBuffer).toDart;
          callbacks?.onFrameAvailable?.call(buffer.asUint8List());
        }).toJS;
        reader.readAsArrayBuffer(blob);
      });
      return;
    }

    // Route through WebGPU dewarper when active.
    if (_dewarper != null && _dewarper!.isActive) {
      final imageData = _createImageData(frame.rgba, w, h);
      web.window
          .createImageBitmap(imageData as JSObject)
          .toDart
          .then((web.ImageBitmap bitmap) {
            if (_released || !_canvasElements.containsKey(viewType)) {
              bitmap.close();
              return;
            }
            _dewarpJpegFrame(bitmap as JSObject, w, h, dt);
          })
          .catchError((Object e) {
            logger.error('[WebCodec] MPEG4 dewarp bitmap creation failed: $e');
          });
      return;
    }

    // Draw RGBA pixels to canvas via ImageData + putImageData
    if (canvas.width != w) canvas.width = w;
    if (canvas.height != h) canvas.height = h;

    final imageData = _createImageData(frame.rgba, w, h);
    _putImageData(imageData, 0, 0);

    _frameCount++;
    renderedFrame = true;
    pixelResolution = VideoDecoderSize(w, h);

    pacer.renderFrame(dt, renderManager.pbTime, true);
    callbacks?.onFrameDecoded?.call((dt, null));
    callbacks?.onFrameAvailable?.call(data);
    onFrameRendered?.call(w, h);
  }

  /// Render a YUV420P frame via WebGL (GPU-accelerated color conversion).
  void _renderYuvFrame(DecodedYuvFrame yuvFrame, DateTime dt, Uint8List data) {
    final w = yuvFrame.width;
    final h = yuvFrame.height;

    // Lazily initialize WebGL renderer on first YUV frame
    if (_webglYuvRenderer == null) {
      try {
        _webglYuvRenderer = _JSWebGLYuvRenderer(canvas as JSObject);
        if (!_webglYuvRenderer!.init()) {
          logger.warn(
            '[WebCodec] WebGL YUV renderer init failed, '
            'falling back to RGBA path',
          );
          _webglYuvRenderer = null;
          _webglYuvFailed = true;
          return;
        }
        logger.info(
          '[WebCodec] WebGL YUV renderer active — '
          'GPU color conversion enabled',
        );
      } catch (e) {
        logger.warn(
          '[WebCodec] WebGL YUV renderer error: $e, '
          'falling back to RGBA path',
        );
        _webglYuvFailed = true;
        return;
      }
    }

    // Upload YUV planes to GPU and draw
    _webglYuvRenderer!.drawYUV(
      yuvFrame.y.toJS,
      yuvFrame.u.toJS,
      yuvFrame.v.toJS,
      yuvFrame.yStride,
      yuvFrame.uStride,
      yuvFrame.vStride,
      w,
      h,
    );

    _frameCount++;
    renderedFrame = true;
    pixelResolution = VideoDecoderSize(w, h);

    pacer.renderFrame(dt, renderManager.pbTime, true);
    callbacks?.onFrameDecoded?.call((dt, null));
    callbacks?.onFrameAvailable?.call(data);
    onFrameRendered?.call(w, h);
  }

  // — Decoded frame callback ————————————————————————————————————

  void _onDecodedFrame(_JSVideoFrame frame) {
    // If _decoder is null, this frame is arriving from a decoder we are
    // disposing.  Close the VideoFrame immediately to free GPU memory.
    if (_decoder == null) {
      try {
        frame.close();
      } catch (_) {}
      return;
    }

    try {
      final ts = frame.timestamp.toInt();
      final w = frame.displayWidth;
      final h = frame.displayHeight;

      if (headless) {
        _captureFrameHeadless(frame, w, h);
        return;
      }

      // Canvas not yet in DOM (e.g. VideoPanel vis=false) — drop frame silently
      if (!_canvasElements.containsKey(viewType)) {
        frame.close();
        return;
      }

      // Route through WebGPU dewarper when active (bypasses pacer —
      // dewarper has its own GPU-submit presentation path).
      if (_dewarper != null && _dewarper!.isActive) {
        if (_dewarpFrameCount == 0) {
          logger.info(
            '[WebCodec] Routing frame to dewarper (mode=$_dewarpMode, ${w}x$h)',
          );
        }
        _dewarpAndRender(frame, w, h);
        return;
      }

      // Route through the presentation pacer when enabled.
      // The pacer buffers frames and presents one per vsync via rAF.
      if (_framePacer != null) {
        _framePacer!.enqueueFrame(frame as JSObject, ts, w, h);
        return;
      }

      // Legacy immediate-draw path (pacer disabled or headless).
      _drawFrameToCanvas(frame, w, h);
    } catch (e, st) {
      logger.error('[WebCodec] render error: $e\n$st');
      // The frame did not reach a rendering path that owns it — close it
      // so GPU/IOSurface memory can't leak (closing twice is a no-op).
      try {
        frame.close();
      } catch (_) {}
      callbacks?.onRuntimeError?.call(e);
    }
  }

  /// Callback from [WebFramePacer.onPresent] — draws the frame to canvas
  /// and fires all the post-render hooks.
  void _onPacerPresent(JSObject frame, int w, int h) {
    try {
      _drawFrameToCanvas(_JSVideoFrame(frame), w, h);
    } catch (e, st) {
      logger.error('[WebCodec] pacer present error: $e\n$st');
      try {
        _JSVideoFrameClose(frame).close();
      } catch (_) {}
      callbacks?.onRuntimeError?.call(e);
    }
  }

  /// Draw a decoded VideoFrame to the 2D canvas and fire post-render hooks.
  void _drawFrameToCanvas(_JSVideoFrame frame, int w, int h) {
    if (canvas.width != w) canvas.width = w;
    if (canvas.height != h) canvas.height = h;

    // Capture timestamp BEFORE close() — accessing a closed VideoFrame's
    // properties is undefined behavior and may retain GPU texture backing.
    final contentDt = DateTime.fromMicrosecondsSinceEpoch(
      frame.timestamp.toInt(),
    );

    ctx.drawImage(frame as JSObject, 0, 0, w, h);
    frame.close();

    _frameCount++;
    renderedFrame = true;
    pixelResolution = VideoDecoderSize(w, h);
    _markDecodeSuccess();
    pacer.renderFrame(contentDt, renderManager.pbTime, true);
    callbacks?.onFrameDecoded?.call((contentDt, null));
    _emitFrameAvailable();
    onFrameRendered?.call(w, h);
  }

  /// Record a successfully rendered frame for the recovery heuristics:
  /// liveness timestamp for the VT-throttle logic, decay of the recovery
  /// failure counter, and reset of the NotSupported strike counter.
  ///
  /// Called from every successful VideoFrame render path (2D canvas,
  /// WebGPU dewarp, headless capture) — previously only the 2D canvas
  /// path updated [_lastSuccessfulDecode], which left dewarped and
  /// headless streams permanently outside the VT-throttle protection.
  void _markDecodeSuccess() {
    _lastSuccessfulDecode = DateTime.now();
    _notSupportedStrikes = 0;
    // If we've been decoding successfully for a while, clear the recovery
    // failure counter so the next transient error doesn't immediately throttle.
    if (_recoveryFailures > 0 &&
        DateTime.now().difference(_configuredAt) > const Duration(seconds: 5)) {
      _recoveryFailures = 0;
    }
  }

  /// Dewarp the decoded frame using WebGPU and render directly to the
  /// visible WebGPU canvas. The VideoFrame is uploaded to the GPU (zero-copy
  /// via `copyExternalImageToTexture`), the WGSL shader runs the fisheye
  /// remap, and WebGPU auto-presents the result — no blit needed.
  int _dewarpFrameCount = 0;
  void _dewarpAndRender(_JSVideoFrame frame, int w, int h) {
    try {
      final dCanvas = _dewarpCanvas;
      if (dCanvas == null) {
        logger.error('[WebCodec] _dewarpAndRender: dewarp canvas is null!');
        frame.close();
        return;
      }
      // Compute output canvas size from the dewarp target aspect ratio
      // so the shader maps the correct horizontal FoV and the Flutter
      // AspectRatio widget doesn't clip the rendered content.
      final targetAspect = dewarp_helpers.aspectRatio(
        _dewarpMode,
        _dewarpMount,
      );
      final outH = h;
      final outW = (h * targetAspect).round();

      if (dCanvas.width != outW) dCanvas.width = outW;
      if (dCanvas.height != outH) dCanvas.height = outH;
      _dewarper!.setOutputSize(outW, outH);

      // Synchronous: upload frame to GPU, submit render, close frame.
      // WebGPU auto-presents to the visible canvas after submit().
      final contentDt = DateTime.fromMicrosecondsSinceEpoch(
        frame.timestamp.toInt(),
      );
      final ok = _dewarper!.dewarpFrame(frame as JSObject, w, h);
      frame.close();

      if (!ok) {
        if (_dewarpFrameCount < 5) {
          logger.warn(
            '[WebCodec] dewarpFrame returned false (frame #$_dewarpFrameCount)',
          );
        }
        _dewarpFrameCount++;
        return;
      }

      if (_dewarpFrameCount < 10) {
        logger.info('[WebCodec] dewarpFrame OK (frame #$_dewarpFrameCount)');
      }
      _dewarpFrameCount++;
      if (_dewarpFrameCount == 1) {
        logger.info(
          '[WebCodec] ✅ First dewarped frame rendered (${outW}x$outH from ${w}x$h)',
        );
      } else if (_dewarpFrameCount % 300 == 0) {
        logger.info('[WebCodec] Dewarp frame #$_dewarpFrameCount rendered');
      }

      _frameCount++;
      renderedFrame = true;
      pixelResolution = VideoDecoderSize(outW, outH);
      _markDecodeSuccess();

      pacer.renderFrame(contentDt, renderManager.pbTime, true);
      callbacks?.onFrameDecoded?.call((contentDt, null));
      onFrameRendered?.call(w, h);
    } catch (e) {
      logger.error('[WebCodec] dewarp render error: $e');
      try {
        frame.close();
      } catch (_) {}
      callbacks?.onRuntimeError?.call(e);
    }
  }

  /// Dewarp a JPEG-decoded ImageBitmap using WebGPU. Same pipeline as
  /// [_dewarpAndRender] but takes an ImageBitmap (valid source for
  /// `copyExternalImageToTexture`) instead of a VideoFrame.
  void _dewarpJpegFrame(JSObject bitmap, int w, int h, DateTime dt) {
    try {
      final dCanvas = _dewarpCanvas;
      if (dCanvas == null) {
        logger.error('[WebCodec] _dewarpJpegFrame: dewarp canvas is null!');
        _closeBitmap(bitmap);
        return;
      }
      // Compute output canvas size from the dewarp target aspect ratio.
      final targetAspect = dewarp_helpers.aspectRatio(
        _dewarpMode,
        _dewarpMount,
      );
      final outH = h;
      final outW = (h * targetAspect).round();

      if (dCanvas.width != outW) dCanvas.width = outW;
      if (dCanvas.height != outH) dCanvas.height = outH;
      _dewarper!.setOutputSize(outW, outH);

      final ok = _dewarper!.dewarpFrame(bitmap, w, h);
      _closeBitmap(bitmap);

      if (!ok) {
        if (_dewarpFrameCount < 5) {
          logger.warn(
            '[WebCodec] JPEG dewarpFrame returned false (frame #$_dewarpFrameCount)',
          );
        }
        _dewarpFrameCount++;
        return;
      }

      if (_dewarpFrameCount < 10) {
        logger.info(
          '[WebCodec] JPEG dewarpFrame OK (frame #$_dewarpFrameCount)',
        );
      }
      _dewarpFrameCount++;
      if (_dewarpFrameCount == 1) {
        logger.info(
          '[WebCodec] ✅ First dewarped JPEG frame rendered (${outW}x$outH from ${w}x$h)',
        );
      } else if (_dewarpFrameCount % 300 == 0) {
        logger.info('[WebCodec] Dewarp frame #$_dewarpFrameCount rendered');
      }

      _frameCount++;
      renderedFrame = true;
      pixelResolution = VideoDecoderSize(outW, outH);

      pacer.renderFrame(dt, renderManager.pbTime, true);
      callbacks?.onFrameDecoded?.call((dt, null));
      onFrameRendered?.call(w, h);
    } catch (e) {
      logger.error('[WebCodec] JPEG dewarp render error: $e');
      try {
        _closeBitmap(bitmap);
      } catch (_) {}
      callbacks?.onRuntimeError?.call(e);
    }
  }

  /// Close an ImageBitmap (cast to web.ImageBitmap).
  void _closeBitmap(JSObject bitmap) {
    (bitmap as web.ImageBitmap).close();
  }

  /// Headless capture: draw the decoded [VideoFrame] to an [OffscreenCanvas],
  /// then export as JPEG and fire [onFrameAvailable]. No DOM element needed.
  void _captureFrameHeadless(_JSVideoFrame frame, int w, int h) {
    try {
      // Lazily create the offscreen canvas at the frame's resolution.
      if (_offscreenCanvas == null ||
          _offscreenCanvas!.width != w ||
          _offscreenCanvas!.height != h) {
        _offscreenCanvas = _JSOffscreenCanvas(w, h);
        _offscreenCtx = null;
      }
      _offscreenCtx ??= _CanvasCtx(_offscreenCanvas!.getContext('2d')!);
      _offscreenCtx!.drawImage(frame as JSObject, 0, 0, w, h);
      frame.close();

      _frameCount++;
      renderedFrame = true;
      pixelResolution = VideoDecoderSize(w, h);
      _markDecodeSuccess();

      if (callbacks?.onFrameAvailable == null) return;

      // Export offscreen canvas to JPEG blob, then read as bytes.
      final options = {'type': 'image/jpeg', 'quality': 0.85}.jsify();
      _offscreenCanvas!.convertToBlob(options as JSObject?).toDart.then((
        JSAny? blobAny,
      ) {
        final blob = blobAny as web.Blob;
        final reader = web.FileReader();
        reader.onload = ((web.Event _) {
          final result = reader.result;
          if (result == null) return;
          final buffer = (result as JSArrayBuffer).toDart;
          callbacks?.onFrameAvailable?.call(buffer.asUint8List());
        }).toJS;
        reader.readAsArrayBuffer(blob);
      });
    } catch (e) {
      logger.error('[WebCodec] headless capture error: $e');
      try {
        frame.close();
      } catch (_) {}
    }
  }

  /// Captures the current canvas contents as JPEG bytes and fires
  /// [VideoDecoderCallbacks.onFrameAvailable]. Used by the thumbnail
  /// pipeline to extract a still frame from video codecs (H264/H265).
  void _emitFrameAvailable() {
    if (callbacks?.onFrameAvailable == null) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameAvailableTime).inMilliseconds < 1000) return;
    _lastFrameAvailableTime = now;
    try {
      canvas.toBlob(
        ((web.Blob? blob) {
          if (blob == null) return;
          final reader = web.FileReader();
          reader.onload = ((web.Event _) {
            final result = reader.result;
            if (result == null) return;
            final buffer = (result as JSArrayBuffer).toDart;
            callbacks?.onFrameAvailable?.call(buffer.asUint8List());
          }).toJS;
          reader.readAsArrayBuffer(blob);
        }).toJS,
        'image/jpeg',
        0.85.toJS,
      );
    } catch (e) {
      logger.error('[WebCodec] canvas capture error: $e');
    }
  }

  // — Diagnostics ————————————————————————————————————————————————

  /// Ask the browser whether the current codec config is supported and
  /// whether it resolved to hardware or software decoding.
  ///
  /// If the browser reports the codec as unsupported (e.g. H.265 on
  /// Firefox without system HEVC decoder), immediately falls back to
  /// the WASM decoder rather than waiting for a decode-time error.
  void _probeHardwareAcceleration() {
    try {
      // Build a config object matching what we passed to configure(),
      // including the description and dimensions if available.
      final probeConfig = <String, dynamic>{
        'codec': _codecString,
        'hardwareAcceleration': _hwAccelPreference,
        if (_decoderDescription != null)
          'description': _decoderDescription!.toJS,
        if (parser.resolution.width > 0) 'codedWidth': parser.resolution.width,
        if (parser.resolution.height > 0)
          'codedHeight': parser.resolution.height,
      }.jsify();
      _JSVideoDecoderStatic.isConfigSupported(probeConfig as JSObject).toDart
          .then((result) {
            final r = result as _ConfigSupportResult;
            if (r.supported && r.config != null) {
              _hwAccelStatus = r.config!.hardwareAcceleration;
              logger.info(
                '[WebCodec] HW accel probe: $_hwAccelStatus '
                '(codec=$_codecString format=$videoFormat)',
              );
            } else if (!r.supported) {
              _hwAccelStatus = 'unsupported';
              // Don't dispose an already-configured decoder based solely on
              // isConfigSupported — configure() is authoritative.  Some browsers
              // (Firefox) return false from isConfigSupported for HEVC but still
              // decode successfully once configured.  Let actual decode errors
              // trigger the WASM fallback instead.
              logger.warn(
                '[WebCodec] isConfigSupported returned false for '
                '"$_codecString" — decoder already configured, will attempt '
                'decoding and fall back on actual error',
              );
            } else {
              _hwAccelStatus = 'supported (detail N/A)';
              logger.info(
                '[WebCodec] HW accel probe: $_hwAccelStatus '
                '(codec=$_codecString format=$videoFormat)',
              );
            }
          })
          .catchError((Object e) {
            _hwAccelStatus = 'probe-failed';
            logger.warn('[WebCodec] HW accel probe failed: $e');
          });
    } catch (e) {
      _hwAccelStatus = 'probe-error';
      logger.warn('[WebCodec] HW accel probe error: $e');
    }
  }

  void _onDecoderError(JSObject error) {
    // If _decoder is null, this error is firing from a decoder we are
    // already disposing (close() triggers VT error callbacks for pending
    // frames).  Ignore it — recovery would create a zombie decoder.
    if (_decoder == null) return;

    final msg = error.toString();
    logger.error('[WebCodec] Decoder error: $msg');

    // NotSupportedError means the browser cannot decode this codec (e.g.
    // H.265 on a browser without hardware HEVC support) — but it can also
    // surface transiently from a GPU process under teardown pressure
    // during view switches.  Latch as permanently unsupported only after
    // repeated consecutive strikes; earlier strikes retry configure.
    if (msg.contains('NotSupportedError')) {
      _notSupportedStrikes++;
      if (_notSupportedStrikes >= _maxNotSupportedStrikes) {
        logger.warn(
          '[WebCodec] Codec "$_codecString" is not supported by this '
          'browser — stream cannot be decoded '
          '(format=$videoFormat)',
        );
        _codecUnsupported = true;
        _disposeDecoder();
        _configured = false;
        // For H.265 we have an MSE fallback — don't propagate the error to
        // MTFC (which would apply a cooldown and starve the fallback path).
        if (videoFormat != VideoFormat.h265) {
          callbacks?.onDecodeError?.call(msg);
        }
        return;
      }
      logger.warn(
        '[WebCodec] NotSupportedError '
        '(strike $_notSupportedStrikes/$_maxNotSupportedStrikes) — '
        'retrying configure shortly',
      );
      _disposeDecoder();
      _configured = false;
      _reconfigureTimer?.cancel();
      _reconfigureTimer = Timer(Duration(seconds: _notSupportedStrikes), () {
        _reconfigureTimer = null;
        if (!_released && !_configured && parser.isReady()) {
          _configureDecoder();
        }
      });
      return;
    }

    // Reset and reconfigure the decoder so the next keyframe can start
    // a clean decode sequence.  A simple flush isn't enough because the
    // queued delta frames will each trigger another error.
    _needsKeyframe = true;
    // Flush the presentation pacer so stale frames don't block new ones.
    _framePacer?.flush();
    // Cancel the no-frames timer — the decoder is recovering, not truly lost.
    // Without this, the 5-second timer fires during the keyframe wait window
    // and triggers a false Video Loss overlay in the UI.
    pacer.cancelNoFramesTimer();

    // Track recovery failures: if the last successful decode was < 3s ago,
    // the decoder recovered but immediately failed again (VT pool pressure).
    // After 3 consecutive rapid failures, enter VT-throttled mode with
    // exponential cooldown to prevent crash-inducing error storms.
    final sinceLastSuccess = DateTime.now().difference(_lastSuccessfulDecode);
    if (sinceLastSuccess < const Duration(seconds: 3)) {
      _recoveryFailures++;
    } else {
      _recoveryFailures = 1;
    }

    if (_recoveryFailures >= 3) {
      // Exponential cooldown: 2s, 4s, 8s, 16s … capped at 60s.
      _throttleCooldownSecs = (2 * (1 << (_recoveryFailures - 3))).clamp(2, 60);
      logger.warn(
        '[WebCodec] VT-throttled: $_recoveryFailures consecutive recovery '
        'failures — pausing decode for ${_throttleCooldownSecs}s '
        '(codec=$_codecString)',
      );
      // Close the decoder to free the VT session for other streams.
      try {
        if (_decoder != null && _decoder!.state != 'closed') {
          _decoder!.close();
        }
      } catch (_) {}
      _decoder = null;
      _configured = false;
      _framePacer?.flush();
      _recovering = false;
      // Release the hardware slot for the duration of the cooldown so
      // other streams aren't starved by a decoder that isn't decoding.
      if (_holdsHwSlot) {
        _HwSlotGate.release();
        _holdsHwSlot = false;
      }

      // Schedule retry after cooldown.
      _throttleTimer?.cancel();
      _throttleTimer = Timer(
        Duration(seconds: _throttleCooldownSecs),
        _exitThrottle,
      ); // Timer
      callbacks?.onDecodeError?.call(
        'VT-throttled: pausing decode for ${_throttleCooldownSecs}s',
      );
      return;
    }

    // Guard against concurrent/cascading recovery attempts.  Multiple errors
    // can fire in quick succession when queued frames are decoded after the
    // decoder auto-closes, but only one recovery should run at a time.
    if (!_recovering) {
      _recovering = true;
      _errorBackoff.recordAndRecover(_recoverDecoder);
    }
    logger.warn(
      '[WebCodec][DBG] _onDecoderError: msg=$msg '
      'decoderState=${_decoder?.state} '
      'needsKeyframe=$_needsKeyframe '
      'pacerRunning=${_framePacer?.isRunning ?? false} '
      'consecutiveErrors=${_errorBackoff.consecutiveErrors} '
      'recoveryFailures=$_recoveryFailures',
    );
    callbacks?.onDecodeError?.call(msg);
  }

  /// Exit VT-throttled mode and attempt to reconfigure the decoder.
  void _exitThrottle() {
    _throttleCooldownSecs = 0;
    _throttleTimer = null;
    if (_released || _outputCallback == null) return;
    logger.info(
      '[WebCodec] VT-throttle cooldown expired — attempting to resume '
      '(codec=$_codecString recoveryFailures=$_recoveryFailures)',
    );
    // Reconfigure from scratch. _configureDecoder will create new callbacks,
    // claim a new HW slot, etc.
    if (parser.isReady()) {
      _configureDecoder();
    } else {
      // Parser state lost — need a keyframe to re-parse codec params.
      _configured = false;
      _needsKeyframe = true;
    }
  }

  /// Reconstruct and reconfigure the WebCodecs decoder after a fatal error.
  /// Called either immediately or after a backoff delay from [_onDecoderError].
  ///
  /// When the decoder was auto-closed by the browser (fatal error per the
  /// WebCodecs spec), tries software decoding first so that recovering streams
  /// do not consume a VideoToolbox hardware session. If software is unavailable
  /// (e.g. H.265 on macOS), creates a new hardware decoder directly.
  Future<void> _recoverDecoder() async {
    if (_outputCallback == null) {
      _recovering = false;
      return; // stream was closed during backoff
    }
    try {
      _hwAccelPreference = 'no-preference';

      // Rebuild the description from the parser's current parameter sets —
      // recovering with the stale cached record reproduces the original
      // failure when the error was caused by a parameter-set change.
      _decoderDescription = _buildDecoderDescription() ?? _decoderDescription;
      _activeParamsSignature = _computeParamsSignature();

      if (_decoder != null && _decoder!.state != 'closed') {
        // Decoder is still open — reset and reconfigure in place.
        // The underlying VT session is preserved; no slot change needed.
        _decoder!.reset();
        _decoder!.configure(_decoderConfig());
        _configuredAt = DateTime.now();
        logger.info(
          '[WebCodec] Decoder reset after error, awaiting keyframe '
          '(newState=${_decoder!.state} hwAccel=$_hwAccelPreference)',
        );
        return;
      }

      // — Decoder was auto-closed by the browser (fatal error per spec) —

      try {
        _decoder?.close();
      } catch (_) {}
      _decoder = null;
      _configured = false;

      if (_outputCallback == null) {
        _recovering = false;
        return;
      }

      // — Try software decoding first ————————————————————————————
      // H.264 has a software path in Chrome (FFmpeg) that does not consume a
      // VT slot, so recovering H.264 streams immediately free up hardware
      // capacity for H.265 and other codecs that require VT.
      // H.265 on macOS typically has no software fallback — isConfigSupported
      // will either return supported:false or resolve to hardware, and we fall
      // through to the slot-gated hardware path below.
      bool recoveredViaSoftware = false;
      try {
        final probeConfig = <String, dynamic>{
          'codec': _codecString,
          'hardwareAcceleration': 'prefer-software',
        }.jsify();
        final result = await _JSVideoDecoderStatic.isConfigSupported(
          probeConfig as JSObject,
        ).toDart;
        final r = result as _ConfigSupportResult;
        final resolvedAccel = r.config?.hardwareAcceleration ?? '';

        if (_outputCallback == null) {
          _recovering = false;
          return; // released while awaiting probe
        }

        if (r.supported && resolvedAccel == 'prefer-software') {
          // Browser confirmed a true software decoder is available.
          _decoder = _JSVideoDecoder(
            _DecoderInit(output: _outputCallback!, error: _errorCallback!),
          ); // _JSVideoDecoder
          _decoder!.configure(
            _decoderConfig(hardwareAcceleration: 'prefer-software'),
          );
          _hwAccelPreference = 'prefer-software';
          _configured = true;
          _configuredAt = DateTime.now();
          recoveredViaSoftware = true;
          logger.info(
            '[WebCodec] Recovering via software decoder — VT slot released '
            '(codec=$_codecString)',
          );
        } else {
          logger.info(
            '[WebCodec] Software decode unavailable '
            '(codec=$_codecString supported=${r.supported} accel=$resolvedAccel) '
            '— waiting for a hardware slot',
          );
        }
      } catch (e) {
        logger.warn(
          '[WebCodec] Software decode probe failed: $e — falling back to hardware',
        );
        try {
          _decoder?.close();
        } catch (_) {}
        _decoder = null;
        _configured = false;
      }

      if (recoveredViaSoftware || _outputCallback == null) return;

      // — Hardware path: recreate hardware decoder ——————————————
      if (_outputCallback == null) {
        _recovering = false;
        return;
      }

      try {
        _decoder = _JSVideoDecoder(
          _DecoderInit(output: _outputCallback!, error: _errorCallback!),
        ); // _JSVideoDecoder
        _decoder!.configure(_decoderConfig());
        _configured = true;
        _configuredAt = DateTime.now();
        logger.info(
          '[WebCodec] Decoder recreated after fatal error, '
          'awaiting keyframe (newState=${_decoder!.state} hwAccel=$_hwAccelPreference)',
        );
      } catch (e) {
        logger.error('[WebCodec] Decoder recreate failed: $e');
      }
    } catch (e) {
      logger.error('[WebCodec] _recoverDecoder error: $e');
    } finally {
      _recovering = false;
    }
  }

  // — Codec string builders ——————————————————————————————————————

  String _buildCodecString() {
    switch (videoFormat) {
      case VideoFormat.h264:
        return _buildH264CodecString();
      case VideoFormat.h265:
        return _buildH265CodecString();
      case VideoFormat.mpeg4:
        return _buildMpeg4CodecString();
      default:
        return '';
    }
  }

  String _buildMpeg4CodecString() {
    if (parser is MPEG4Parser) {
      return config.buildMpeg4CodecString(parser as MPEG4Parser);
    }
    return 'mp4v.20.5';
  }

  String _buildH264CodecString() {
    if (parser is! H264Parser) return 'avc1.640028';
    final h264 = parser as H264Parser;
    // Use avc1 (out-of-band params via description) when SPS+PPS are
    // available — Safari only supports avc1, not avc3.
    // Fall back to avc3 (in-band) when params are missing.
    final hasFullParams = h264.sps.isNotEmpty && h264.pps.isNotEmpty;
    final fourcc = hasFullParams ? 'avc1' : 'avc3';
    return config.buildH264CodecString(h264, fourcc: fourcc);
  }

  /// Build hvc1/hev1 codec string from VPS/SPS.
  ///
  /// Uses `hvc1` (out-of-band parameter sets via `description`) when a
  /// valid HEVCDecoderConfigurationRecord can be built.  Firefox and Safari
  /// require `hvc1` + description for H.265 WebCodecs decoding.
  /// Falls back to `hev1` (in-band parameter sets) only when description
  /// data is unavailable, which works on Chrome.
  String _buildH265CodecString() {
    if (parser is! H265Parser) return 'hev1.1.6.L120.B0';
    final h265 = parser as H265Parser;
    if (h265.sps.isEmpty) return 'hev1.1.6.L120.B0';

    // Prefer hvc1 when full params are available for the description record.
    final hasFullParams =
        h265.vps.isNotEmpty && h265.sps.isNotEmpty && h265.pps.isNotEmpty;
    final fourcc = hasFullParams ? 'hvc1' : 'hev1';
    return config.buildH265CodecString(h265, fourcc: fourcc);
  }

  // — Decoder Configuration Record builders ————————————————————

  /// Build the `description` bytes for the VideoDecoder.configure() call.
  /// Returns null for JPEG/MPEG4 or if codec data is not yet available.
  Uint8List? _buildDecoderDescription() {
    switch (videoFormat) {
      case VideoFormat.h265:
        if (parser is! H265Parser) return null;
        return config.buildHEVCDecoderConfigurationRecord(parser as H265Parser);
      case VideoFormat.h264:
        if (parser is! H264Parser) return null;
        return config.buildAVCDecoderConfigurationRecord(parser as H264Parser);
      default:
        return null;
    }
  }
}
