import 'dart:async';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../auth/auth.dart';
import '../webrtc/webrtc_camera_session.dart';
import 'signalr_service.dart';

/// Singleton hub managing SignalR connection and WebRTC camera sessions.
class SignalRSessionHub {
  SignalRSessionHub._();

  static SignalRSessionHub? _instance;

  /// Get the singleton instance.
  static SignalRSessionHub get instance => _instance ??= SignalRSessionHub._();

  /// Reset the singleton (for testing or full cleanup).
  static void resetInstance() {
    _instance?.shutdown();
    _instance = null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // State
  // ═══════════════════════════════════════════════════════════════════════════

  SignalRService? _signalRService;
  AuthService? _authService;
  bool _initialized = false;

  /// Active WebRTC sessions by camera ID.
  final Map<String, WebRtcCameraSession> activeSessions = {};

  // ═══════════════════════════════════════════════════════════════════════════
  // Getters
  // ═══════════════════════════════════════════════════════════════════════════

  bool get isInitialized => _initialized;
  SignalRService? get signalRService => _signalRService;
  AuthService? get authService => _authService;
  int get activeSessionCount => activeSessions.length;

  // ═══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> initialize(String signalRUrl, AuthService authService) async {
    if (_initialized) {
      dev.log('SignalRSessionHub: Already initialized');
      return;
    }

    _authService = authService;
    _signalRService = SignalRService.instance;
    await _signalRService!.initService(signalRUrl);
    _initialized = true;

    dev.log(
      'SignalRSessionHub: Initialized with ${authService.devices.length} cameras',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Session Management
  // ═══════════════════════════════════════════════════════════════════════════

  Future<WebRtcCameraSession?> connectToCamera(String cameraId) async {
    if (!_initialized || _signalRService == null) {
      dev.log('SignalRSessionHub: Not initialized');
      return null;
    }

    if (activeSessions.containsKey(cameraId)) {
      return activeSessions[cameraId];
    }

    final session = WebRtcCameraSession(
      cameraId: cameraId,
      signalRService: _signalRService,
    );

    session.onTrack = (event) async {
      if (event.track.kind == 'video' && event.track.id != null) {
        dev.log(
          'SignalRSessionHub: Video track received for $cameraId. ID: ${event.track.id}',
        );

        // 1. Enable Raw Frame Capture on the track
        try {
          await event.track.startFrameCapture();
          dev.log(
            'SignalRSessionHub: Started raw frame capture for ${event.track.id}',
          );
          final RTCVideoRenderer renderer = RTCVideoRenderer();
          await renderer.initialize();
          renderer.srcObject = event.streams.isNotEmpty
              ? event.streams.first
              : null;
          session.renderer = renderer;
          session.onRendererCreated?.call();
          dev.log('SignalRSessionHub: Renderer attached for $cameraId');
        } catch (e) {
          dev.log(
            'SignalRSessionHub: Failed to start frame capture or attach renderer: $e',
          );
        }

        // 2. Subscribe to the raw frame stream for verification
        WebRTCMediaStreamer()
            .videoFramesFrom(event.track.id!)
            .then((stream) {
              stream.listen(
                (frame) => _processDebugFrame(frame, cameraId),
                onError: (e) => print('Error receiving raw frames: $e'),
              );
            })
            .catchError((e) {
              print('Failed to initialize streamer for $cameraId: $e');
            });
      }
    };

    activeSessions[cameraId] = session;
    await session.connect();

    dev.log('SignalRSessionHub: Connected to $cameraId');
    return session;
  }

  Future<void> disconnectCamera(String cameraId) async {
    final session = activeSessions.remove(cameraId);
    if (session != null) {
      final sessionId = session.sessionId;
      if (sessionId != null) {
        await _signalRService?.leaveSession(sessionId, deviceId: cameraId);
      }

      if (session.videoTrack?.id != null) {
        // Stop capture and dispose stream
        try {
          await session.videoTrack!.stopFrameCapture();
        } catch (e) {
          print('Error stopping frame capture: $e');
        }
        WebRTCMediaStreamer().disposeVideoStream(session.videoTrack!.id!);
      }

      await session.close();
    }
    dev.log('SignalRSessionHub: Disconnected $cameraId');
  }

  WebRtcCameraSession? getSession(String cameraId) => activeSessions[cameraId];
  bool isConnected(String cameraId) => activeSessions.containsKey(cameraId);
  List<String> get connectedCameraIds => activeSessions.keys.toList();

  // ═══════════════════════════════════════════════════════════════════════════
  // Debug / Visualization
  // ═══════════════════════════════════════════════════════════════════════════

  void _processDebugFrame(EncodedVideoFrame frame, String cameraId) {
    final session = activeSessions[cameraId];
    if (session == null) return;

    final now = DateTime.now();
    if (now.difference(session.lastDebugFrameTime).inSeconds >= 5) {
      session.lastDebugFrameTime = now;
      print(
        'SignalRSessionHub: capturing debug frame for $cameraId (5s throttle). Size: ${frame.width}x${frame.height}',
      );

      try {
        // Generate a grayscale BMP from the Y-plane (first width*height bytes)
        final bmp = _createGrayscaleBmp(
          frame.buffer,
          frame.width,
          frame.height,
        );
        session.debugFrame.value = bmp;
      } catch (e) {
        print('Error processing debug frame: $e');
      }
    }
  }

  /// Creates a BMP image from the Y-plane (grayscale) of I420 buffer
  Uint8List _createGrayscaleBmp(Uint8List i420Buffer, int width, int height) {
    // I420: Y plane is first, size = width * height
    final ySize = width * height;
    if (i420Buffer.length < ySize) return Uint8List(0);

    // BMP Header Size = 14 + 40 + 1024 (Palette) = 1078 bytes
    // Row padding: rows must be multiple of 4 bytes
    final rowPadding = (4 - (width % 4)) % 4;
    final rowSize = width + rowPadding;
    final pixelDataSize = rowSize * height;
    final fileSize = 54 + 1024 + pixelDataSize; // 54 header, 1024 palette

    final bmp = Uint8List(fileSize);
    final view = ByteData.view(bmp.buffer);

    // BITMAPFILEHEADER (14 bytes)
    bmp[0] = 0x42; // B
    bmp[1] = 0x4D; // M
    view.setUint32(2, fileSize, Endian.little);
    view.setUint32(10, 54 + 1024, Endian.little); // Offset to pixel data

    // BITMAPINFOHEADER (40 bytes)
    view.setUint32(14, 40, Endian.little); // Header size
    view.setInt32(18, width, Endian.little);
    view.setInt32(22, -height, Endian.little); // Top-down
    view.setUint16(26, 1, Endian.little); // Planes
    view.setUint16(28, 8, Endian.little); // 8-bit (indexed color)
    view.setUint32(30, 0, Endian.little); // Compression (BI_RGB)
    view.setUint32(34, pixelDataSize, Endian.little);
    view.setUint32(46, 256, Endian.little); // Colors used
    view.setUint32(50, 256, Endian.little); // Important colors

    // Palette (1024 bytes) - Grayscale
    int paletteOffset = 54;
    for (int i = 0; i < 256; i++) {
      bmp[paletteOffset + i * 4] = i; // Blue
      bmp[paletteOffset + i * 4 + 1] = i; // Green
      bmp[paletteOffset + i * 4 + 2] = i; // Red
      bmp[paletteOffset + i * 4 + 3] = 0; // Reserved
    }

    // Pixel Data (Y plane copy)
    int pixelOffset = 54 + 1024;
    int srcOffset = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        bmp[pixelOffset + x] = i420Buffer[srcOffset + x];
      }
      // Zero padding
      for (int p = 0; p < rowPadding; p++) {
        bmp[pixelOffset + width + p] = 0;
      }
      pixelOffset += rowSize;
      srcOffset +=
          width; // I420 stride is typically width (tightly packed in our capturer)
    }

    return bmp;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Track Control
  // ═══════════════════════════════════════════════════════════════════════════

  bool? toggleAudio(String cameraId, {bool? enable}) =>
      _toggleTrack(cameraId, isAudio: true, enable: enable);

  bool? toggleVideo(String cameraId, {bool? enable}) =>
      _toggleTrack(cameraId, isAudio: false, enable: enable);

  bool? _toggleTrack(String cameraId, {required bool isAudio, bool? enable}) {
    final session = activeSessions[cameraId];
    final track = isAudio ? session?.audioTrack : session?.videoTrack;
    final trackType = isAudio ? 'audio' : 'video';

    if (track == null) {
      dev.log('SignalRSessionHub: No $trackType track for $cameraId');
      return null;
    }

    final newEnabled = enable ?? !track.enabled;
    track.enabled = newEnabled;
    dev.log(
      'SignalRSessionHub: ${trackType.substring(0, 1).toUpperCase()}${trackType.substring(1)} ${newEnabled ? "enabled" : "disabled"} for $cameraId',
    );
    return newEnabled;
  }

  bool? isAudioEnabled(String cameraId) =>
      activeSessions[cameraId]?.audioTrack?.enabled;

  bool? isVideoEnabled(String cameraId) =>
      activeSessions[cameraId]?.videoTrack?.enabled;

  // ═══════════════════════════════════════════════════════════════════════════
  // Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> shutdown() async {
    dev.log('SignalRSessionHub: Shutting down...');

    for (final session in activeSessions.values) {
      if (session.videoTrack?.id != null) {
        // stop capture
        try {
          await session.videoTrack!.stopFrameCapture();
        } catch (_) {}
        WebRTCMediaStreamer().disposeVideoStream(session.videoTrack!.id!);
      }
      await session.close();
    }
    activeSessions.clear();
    WebRTCMediaStreamer().dispose();

    await _signalRService?.closeConnection(closeAllSessions: true);
    _signalRService = null;
    _authService = null;
    _initialized = false;

    dev.log('SignalRSessionHub: Shutdown complete');
  }
}
