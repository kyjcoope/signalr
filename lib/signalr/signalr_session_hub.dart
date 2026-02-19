import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../auth/auth.dart';
import '../utils/logger.dart';
import '../webrtc/webrtc_camera_session.dart';
import '../webrtc/webrtc_stats_monitor.dart';
import 'signalr_service.dart';

/// Singleton hub managing SignalR connection and WebRTC camera sessions.
///
/// Provides session and renderer persistence across page navigation,
/// track access for audio/video control, and textureId access.
///
/// Usage:
/// ```dart
/// // Initialize once at app startup
/// await SignalRSessionHub.instance.initialize(signalRUrl, authService);
///
/// // Connect to a camera (auto-creates renderer)
/// final session = await SignalRSessionHub.instance.connectToCamera(cameraId);
///
/// // Get texture ID for display
/// final textureId = SignalRSessionHub.instance.getTextureId(cameraId);
///
/// // Toggle audio
/// SignalRSessionHub.instance.toggleAudio(cameraId, enable: true);
///
/// // Disconnect (auto-disposes renderer)
/// await SignalRSessionHub.instance.disconnectCamera(cameraId);
/// ```
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

  /// Active renderers by camera ID.
  final Map<String, RTCVideoRenderer> _renderers = {};

  /// Active video track index per camera (0-based).
  final Map<String, int> _activeVideoTrack = {};

  /// Cameras currently in the async connect flow (prevents double-press).
  final Set<String> _connectingCameras = {};

  /// Cameras marked for disconnect while still in the async connect flow.
  /// Checked by `connectToCamera`'s finally-block to auto-cleanup.
  final Set<String> _pendingDisconnects = {};

  // ═══════════════════════════════════════════════════════════════════════════
  // Getters
  // ═══════════════════════════════════════════════════════════════════════════

  /// Whether the hub has been initialized.
  bool get isInitialized => _initialized;

  /// The SignalR service instance.
  SignalRService? get signalRService => _signalRService;

  /// The auth service instance.
  AuthService? get authService => _authService;

  /// Number of active sessions.
  int get activeSessionCount => activeSessions.length;

  // ═══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ═══════════════════════════════════════════════════════════════════════════

  /// Initialize the hub with SignalR URL and authentication.
  ///
  /// This should be called once at app startup after user authentication.
  Future<void> initialize(String signalRUrl, AuthService authService) async {
    if (_initialized) {
      Logger().info('SignalRSessionHub: Already initialized');
      return;
    }

    _authService = authService;
    _signalRService = SignalRService.instance;
    await _signalRService!.initService(signalRUrl);
    _initialized = true;

    Logger().info(
      'SignalRSessionHub: Initialized with ${authService.devices.length} cameras',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Session Management
  // ═══════════════════════════════════════════════════════════════════════════

  /// Connect to a camera and return its session.
  ///
  /// Automatically creates and initializes renderer, and wires it to receive
  /// tracks. Returns existing session if already connected.
  Future<WebRtcCameraSession?> connectToCamera(String cameraId) async {
    if (!_initialized || _signalRService == null) {
      Logger().warn('SignalRSessionHub: Not initialized');
      return null;
    }

    // Return existing session if already connected
    if (activeSessions.containsKey(cameraId)) {
      Logger().info(
        'SignalRSessionHub: Returning existing session for $cameraId',
      );
      return activeSessions[cameraId];
    }

    // Prevent double-press: if already in the async connect flow, bail out
    if (_connectingCameras.contains(cameraId)) {
      Logger().info(
        'SignalRSessionHub: Connect already in progress for $cameraId',
      );
      return null;
    }
    _connectingCameras.add(cameraId);

    try {
      // Create new session (renderer is created lazily on first track)
      final session = WebRtcCameraSession(
        cameraId: cameraId,
        signalRService: _signalRService,
      );

      // Wire renderer to receive tracks — bind to FIRST video track only.
      // Renderer is created lazily here to avoid exhausting EGL contexts
      // when many cameras connect simultaneously in a batch.
      bool rendererBound = false;
      session.onTrack = (event) async {
        if (event.track.kind == 'video' &&
            event.streams.isNotEmpty &&
            !rendererBound) {
          rendererBound = true;
          _activeVideoTrack[cameraId] = 0;
          try {
            final renderer = RTCVideoRenderer();
            await renderer.initialize();
            _renderers[cameraId] = renderer;
            renderer.srcObject = event.streams[0];
            Logger().info(
              'SignalRSessionHub: Renderer initialized & bound for $cameraId (track 1/${session.videoTrackCount})',
            );
          } catch (e) {
            Logger().error(
              'SignalRSessionHub: Failed to create renderer for $cameraId: $e',
            );
          }
        }
      };

      activeSessions[cameraId] = session;
      await session.connect();

      Logger().info('SignalRSessionHub: Connected to $cameraId');
      return session;
    } catch (e) {
      Logger().error('SignalRSessionHub: Failed to connect $cameraId: $e');
      // Clean up on failure
      activeSessions.remove(cameraId);
      final renderer = _renderers.remove(cameraId);
      if (renderer != null) {
        renderer.srcObject = null;
        await renderer.dispose();
      }
      return null;
    } finally {
      _connectingCameras.remove(cameraId);

      // If disconnect was requested while we were still connecting,
      // tear down the session we just created.
      if (_pendingDisconnects.remove(cameraId)) {
        Logger().info(
          'SignalRSessionHub: Deferred disconnect for $cameraId — cleaning up',
        );
        await disconnectCamera(cameraId);
      }
    }
  }

  /// Disconnect from a camera.
  ///
  /// Properly leaves the session on the server, closes the session,
  /// and disposes the renderer.
  Future<void> disconnectCamera(String cameraId) async {
    // If the camera is still in the async connect flow, mark it for
    // deferred disconnect — connectToCamera's finally-block will clean up.
    if (_connectingCameras.contains(cameraId)) {
      Logger().info(
        'SignalRSessionHub: $cameraId still connecting — marking for deferred disconnect',
      );
      _pendingDisconnects.add(cameraId);
      return;
    }

    final session = activeSessions.remove(cameraId);
    if (session != null) {
      // Leave session on server first (like old SignalRSessionHub)
      final sessionId = session.sessionId;
      if (sessionId != null) {
        await _signalRService?.leaveSession(sessionId, deviceId: cameraId);
      }
      await session.close();
    }

    // Dispose renderer
    final renderer = _renderers.remove(cameraId);
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }

    _activeVideoTrack.remove(cameraId);

    Logger().info('SignalRSessionHub: Disconnected $cameraId');
  }

  /// Get session for a camera (if connected).
  WebRtcCameraSession? getSession(String cameraId) => activeSessions[cameraId];

  /// Check if a camera is connected.
  bool isConnected(String cameraId) => activeSessions.containsKey(cameraId);

  /// Get list of connected camera IDs.
  List<String> get connectedCameraIds => activeSessions.keys.toList();

  // ═══════════════════════════════════════════════════════════════════════════
  // Renderer Access
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get the renderer for a camera (if connected).
  RTCVideoRenderer? getRenderer(String cameraId) => _renderers[cameraId];

  /// Get the texture ID for a camera (if connected and renderer initialized).
  ///
  /// This is the value needed for SetTextureId actions.
  int? getTextureId(String cameraId) => _renderers[cameraId]?.textureId;

  /// Get all active renderers.
  Map<String, RTCVideoRenderer> get renderers => Map.unmodifiable(_renderers);

  /// Get the live stats notifier for a camera (if connected).
  ValueNotifier<WebRtcVideoStats>? getStatsNotifier(String cameraId) =>
      activeSessions[cameraId]?.statsNotifier;

  // ═══════════════════════════════════════════════════════════════════════════
  // Track Info & Switching
  // ═══════════════════════════════════════════════════════════════════════════

  /// Number of video tracks for a camera.
  int getVideoTrackCount(String cameraId) =>
      activeSessions[cameraId]?.videoTrackCount ?? 0;

  /// Number of audio tracks for a camera.
  int getAudioTrackCount(String cameraId) =>
      activeSessions[cameraId]?.audioTrackCount ?? 0;

  /// Currently active video track index (0-based).
  int getActiveVideoTrack(String cameraId) => _activeVideoTrack[cameraId] ?? 0;

  /// Get codec for a specific video track index.
  String? getVideoTrackCodec(String cameraId, int trackIndex) =>
      activeSessions[cameraId]?.getVideoTrackCodec(trackIndex);

  /// Switch the displayed video track for a camera.
  ///
  /// Creates a new MediaStream containing only the target video track
  /// and assigns it to the renderer. Each video m-line in the SDP
  /// produces a separate track, so we select the track directly.
  ///
  /// Returns true if the switch was successful.
  bool switchVideoTrack(String cameraId, int trackIndex) {
    final session = activeSessions[cameraId];
    final renderer = _renderers[cameraId];
    if (session == null || renderer == null) return false;

    final tracks = session.videoTracks;
    if (trackIndex < 0 || trackIndex >= tracks.length) {
      Logger().warn(
        'SignalRSessionHub: Invalid track index $trackIndex for $cameraId (${tracks.length} video tracks)',
      );
      return false;
    }

    _activeVideoTrack[cameraId] = trackIndex;

    // Find the stream that contains this track, or use the first stream
    final targetTrack = tracks[trackIndex];
    final ownerStream = session.remoteStreams.firstWhere(
      (s) => s.getVideoTracks().any((t) => t.id == targetTrack.id),
      orElse: () => session.remoteStreams.first,
    );
    renderer.srcObject = ownerStream;

    final codec = session.getVideoTrackCodec(trackIndex) ?? '?';
    Logger().info(
      'SignalRSessionHub: Switched $cameraId to video track ${trackIndex + 1}/${tracks.length} (codec=$codec, streamId=${ownerStream.id})',
    );
    return true;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Track Control
  // ═══════════════════════════════════════════════════════════════════════════

  /// Toggle audio track for a camera.
  ///
  /// Returns the new enabled state, or null if no audio track exists.
  bool? toggleAudio(String cameraId, {bool? enable}) =>
      _toggleTrack(cameraId, isAudio: true, enable: enable);

  /// Toggle video track for a camera.
  ///
  /// Returns the new enabled state, or null if no video track exists.
  bool? toggleVideo(String cameraId, {bool? enable}) =>
      _toggleTrack(cameraId, isAudio: false, enable: enable);

  bool? _toggleTrack(String cameraId, {required bool isAudio, bool? enable}) {
    final session = activeSessions[cameraId];
    final track = isAudio ? session?.audioTrack : session?.videoTrack;
    final trackType = isAudio ? 'audio' : 'video';

    if (track == null) {
      Logger().warn('SignalRSessionHub: No $trackType track for $cameraId');
      return null;
    }

    final newEnabled = enable ?? !track.enabled;
    track.enabled = newEnabled;
    Logger().info(
      'SignalRSessionHub: ${trackType.substring(0, 1).toUpperCase()}${trackType.substring(1)} ${newEnabled ? "enabled" : "disabled"} for $cameraId',
    );
    return newEnabled;
  }

  /// Get audio enabled state for a camera.
  bool? isAudioEnabled(String cameraId) =>
      activeSessions[cameraId]?.audioTrack?.enabled;

  /// Get video enabled state for a camera.
  bool? isVideoEnabled(String cameraId) =>
      activeSessions[cameraId]?.videoTrack?.enabled;

  // ═══════════════════════════════════════════════════════════════════════════
  // Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  /// Shutdown the hub and close all sessions.
  Future<void> shutdown() async {
    Logger().info('SignalRSessionHub: Shutting down...');

    // Mark all in-flight connections for deferred disconnect so they
    // self-clean when their connectToCamera finally-block runs.
    _pendingDisconnects.addAll(_connectingCameras);

    for (final session in activeSessions.values) {
      await session.close();
    }
    activeSessions.clear();

    // Dispose all renderers
    for (final renderer in _renderers.values) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _renderers.clear();
    _activeVideoTrack.clear();

    await _signalRService?.closeConnection(closeAllSessions: true);
    _signalRService = null;
    _authService = null;
    _initialized = false;

    Logger().info('SignalRSessionHub: Shutdown complete');
  }
}
