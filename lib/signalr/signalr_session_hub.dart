import 'dart:async';
import 'dart:developer' as dev;

import '../auth/auth.dart';
import '../webrtc/webrtc_camera_session.dart';
import 'signalr_service.dart';

/// Singleton hub managing SignalR connection and WebRTC camera sessions.
///
/// Provides session persistence across page navigation and track access
/// for audio/video control.
///
/// Usage:
/// ```dart
/// // Initialize once at app startup
/// await SignalRSessionHub.instance.initialize(signalRUrl, authService);
///
/// // Connect to a camera
/// final session = await SignalRSessionHub.instance.connectToCamera(cameraId);
///
/// // Toggle audio
/// SignalRSessionHub.instance.toggleAudio(cameraId, enable: true);
///
/// // Disconnect
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

  /// Connect to a camera and return its session.
  ///
  /// Returns existing session if already connected, otherwise creates a new one.
  Future<WebRtcCameraSession?> connectToCamera(String cameraId) async {
    if (!_initialized || _signalRService == null) {
      dev.log('SignalRSessionHub: Not initialized');
      return null;
    }

    // Return existing session if already connected
    if (activeSessions.containsKey(cameraId)) {
      dev.log('SignalRSessionHub: Returning existing session for $cameraId');
      return activeSessions[cameraId];
    }

    // Create new session
    final session = WebRtcCameraSession(
      cameraId: cameraId,
      signalRService: _signalRService,
    );

    activeSessions[cameraId] = session;
    await session.connect();

    dev.log('SignalRSessionHub: Connected to $cameraId');
    return session;
  }

  /// Disconnect from a camera.
  ///
  /// Properly leaves the session on the server before closing the local session.
  Future<void> disconnectCamera(String cameraId) async {
    final session = activeSessions.remove(cameraId);
    if (session != null) {
      // Leave session on server first (like old SignalRSessionHub)
      final sessionId = session.sessionId;
      if (sessionId != null) {
        await _signalRService?.leaveSession(sessionId, deviceId: cameraId);
      }
      await session.close();
      dev.log('SignalRSessionHub: Disconnected $cameraId');
    }
  }

  /// Get session for a camera (if connected).
  WebRtcCameraSession? getSession(String cameraId) => activeSessions[cameraId];

  /// Check if a camera is connected.
  bool isConnected(String cameraId) => activeSessions.containsKey(cameraId);

  /// Get list of connected camera IDs.
  List<String> get connectedCameraIds => activeSessions.keys.toList();

  // ═══════════════════════════════════════════════════════════════════════════
  // Track Control
  // ═══════════════════════════════════════════════════════════════════════════

  /// Toggle audio track for a camera.
  ///
  /// Returns the new enabled state, or null if no audio track exists.
  bool? toggleAudio(String cameraId, {bool? enable}) {
    final session = activeSessions[cameraId];
    final audioTrack = session?.audioTrack;
    if (audioTrack == null) {
      dev.log('SignalRSessionHub: No audio track for $cameraId');
      return null;
    }

    final newEnabled = enable ?? !audioTrack.enabled;
    audioTrack.enabled = newEnabled;
    dev.log(
      'SignalRSessionHub: Audio ${newEnabled ? "enabled" : "disabled"} for $cameraId',
    );
    return newEnabled;
  }

  /// Toggle video track for a camera.
  ///
  /// Returns the new enabled state, or null if no video track exists.
  bool? toggleVideo(String cameraId, {bool? enable}) {
    final session = activeSessions[cameraId];
    final videoTrack = session?.videoTrack;
    if (videoTrack == null) {
      dev.log('SignalRSessionHub: No video track for $cameraId');
      return null;
    }

    final newEnabled = enable ?? !videoTrack.enabled;
    videoTrack.enabled = newEnabled;
    dev.log(
      'SignalRSessionHub: Video ${newEnabled ? "enabled" : "disabled"} for $cameraId',
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
    dev.log('SignalRSessionHub: Shutting down...');

    for (final session in activeSessions.values) {
      await session.close();
    }
    activeSessions.clear();

    await _signalRService?.closeConnection(closeAllSessions: true);
    _signalRService = null;
    _authService = null;
    _initialized = false;

    dev.log('SignalRSessionHub: Shutdown complete');
  }
}
