import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../auth/auth.dart';
import '../utils/logger.dart';
import '../webrtc/webrtc_camera_session.dart';
import '../webrtc/session_state.dart';
import '../webrtc/webrtc_stats_monitor.dart';
import 'signalr_service.dart';

class SignalRSessionHub {
  SignalRSessionHub._();

  static SignalRSessionHub? _instance;
  static SignalRSessionHub get instance => _instance ??= SignalRSessionHub._();

  static void resetInstance() {
    _instance?.shutdown();
    _instance = null;
  }

  SignalRService? _signalRService;
  AuthService? _authService;
  bool _initialized = false;

  final Map<String, WebRtcCameraSession> activeSessions = {};
  final Map<String, RTCVideoRenderer> _renderers = {};
  final Map<String, int> _activeVideoTrack = {};
  final Map<String, int> _activeAudioTrack = {};
  final Set<String> _connectingCameras = {};
  final Set<String> _pendingDisconnects = {};

  bool get isInitialized => _initialized;
  SignalRService? get signalRService => _signalRService;
  AuthService? get authService => _authService;
  int get activeSessionCount => activeSessions.length;
  List<String> get connectedCameraIds => activeSessions.keys.toList();
  Map<String, RTCVideoRenderer> get renderers => Map.unmodifiable(_renderers);

  Future<void> initialize(String signalRUrl, AuthService authService) async {
    if (_initialized) {
      Logger().info('SignalRSessionHub: Already initialized');
      return;
    }

    _authService = authService;
    _signalRService = SignalRService.instance;
    _initialized = true;
    await _signalRService!.initService(signalRUrl);
    Logger().info('SignalRSessionHub: Initialized');
  }

  Future<WebRtcCameraSession?> connectToCamera(String cameraId) async {
    if (_signalRService == null) {
      Logger().warn('SignalRSessionHub: Not initialized — cannot connect');
      return null;
    }
    if (activeSessions.containsKey(cameraId)) {
      Logger().info(
        'SignalRSessionHub: Returning existing session for $cameraId',
      );
      return activeSessions[cameraId];
    }
    if (_connectingCameras.contains(cameraId)) {
      Logger().info(
        'SignalRSessionHub: Connect already in progress for $cameraId',
      );
      return null;
    }
    _connectingCameras.add(cameraId);

    try {
      Logger().info(
        'SignalRSessionHub: Waiting for SignalR readiness ($cameraId)',
      );
      await _signalRService!.ready;
      Logger().info(
        'SignalRSessionHub: SignalR ready — creating session for $cameraId',
      );

      final session = WebRtcCameraSession(
        cameraId: cameraId,
        signalRService: _signalRService,
      );

      bool rendererBound = false;
      session.onTrack = (event) async {
        if (event.track.kind == 'video' &&
            event.streams.isNotEmpty &&
            !rendererBound) {
          rendererBound = true;
          _activeVideoTrack[cameraId] = 0;
          _activeAudioTrack[cameraId] = 0;
          // Defer renderer init so it doesn't block the SDP negotiation
          // critical path. The renderer will be ready well before the
          // first decoded video frame arrives.
          final stream = event.streams[0];
          Future.delayed(const Duration(milliseconds: 100), () async {
            if (!activeSessions.containsKey(cameraId)) return;
            try {
              final renderer = RTCVideoRenderer();
              await renderer.initialize();
              if (!activeSessions.containsKey(cameraId)) {
                await renderer.dispose();
                return;
              }
              _renderers[cameraId] = renderer;
              renderer.srcObject = stream;
              Logger().info(
                'SignalRSessionHub: Renderer initialized & bound for $cameraId (track 1/${session.videoTrackCount})',
              );
            } catch (e) {
              Logger().error(
                'SignalRSessionHub: Failed to create renderer for $cameraId: $e',
              );
            }
          });
        }
      };

      activeSessions[cameraId] = session;
      await session.connect();
      Logger().info('SignalRSessionHub: Connected to $cameraId');
      return session;
    } catch (e) {
      Logger().error('SignalRSessionHub: Failed to connect $cameraId: $e');
      activeSessions.remove(cameraId);
      final renderer = _renderers.remove(cameraId);
      if (renderer != null) {
        renderer.srcObject = null;
        await renderer.dispose();
      }
      return null;
    } finally {
      _connectingCameras.remove(cameraId);
      if (_pendingDisconnects.remove(cameraId)) {
        Logger().info(
          'SignalRSessionHub: Deferred disconnect for $cameraId — cleaning up',
        );
        await disconnectCamera(cameraId);
      }
    }
  }

  Future<void> disconnectCamera(String cameraId) async {
    if (_connectingCameras.contains(cameraId)) {
      Logger().info(
        'SignalRSessionHub: $cameraId still connecting — marking for deferred disconnect',
      );
      _pendingDisconnects.add(cameraId);
      return;
    }

    final session = activeSessions.remove(cameraId);
    if (session != null) {
      await session.close();
    }

    final renderer = _renderers.remove(cameraId);
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }

    _activeVideoTrack.remove(cameraId);
    _activeAudioTrack.remove(cameraId);
    Logger().info('SignalRSessionHub: Disconnected $cameraId');
  }

  Future<void> reconnectAllSessions() async {
    final staleIds = activeSessions.entries
        .where((e) => e.value.state != SessionConnectionState.connected)
        .map((e) => e.key)
        .toList();

    if (staleIds.isEmpty) {
      Logger().info(
        'SignalRSessionHub: All sessions healthy, nothing to reconnect',
      );
      return;
    }

    Logger().info(
      'SignalRSessionHub: Reconnecting ${staleIds.length} stale sessions',
    );
    for (final cameraId in staleIds) {
      try {
        await disconnectCamera(cameraId);
        await connectToCamera(cameraId);
      } catch (e) {
        Logger().error('SignalRSessionHub: Failed to reconnect $cameraId: $e');
      }
    }
  }

  WebRtcCameraSession? getSession(String cameraId) => activeSessions[cameraId];
  bool isConnected(String cameraId) => activeSessions.containsKey(cameraId);
  RTCVideoRenderer? getRenderer(String cameraId) => _renderers[cameraId];
  int? getTextureId(String cameraId) => _renderers[cameraId]?.textureId;

  ValueNotifier<WebRtcVideoStats>? getStatsNotifier(String cameraId) =>
      activeSessions[cameraId]?.statsNotifier;

  int getVideoTrackCount(String cameraId) =>
      activeSessions[cameraId]?.videoTrackCount ?? 0;

  int getAudioTrackCount(String cameraId) =>
      activeSessions[cameraId]?.audioTrackCount ?? 0;

  int getActiveVideoTrack(String cameraId) => _activeVideoTrack[cameraId] ?? 0;
  int getActiveAudioTrack(String cameraId) => _activeAudioTrack[cameraId] ?? 0;

  String? getVideoTrackCodec(String cameraId, int trackIndex) =>
      activeSessions[cameraId]?.getVideoTrackCodec(trackIndex);

  Future<bool> switchVideoTrack(String cameraId, int trackIndex) async {
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
    final targetTrack = tracks[trackIndex];
    final isolatedStream = await createLocalMediaStream(
      'isolated_${cameraId}_$trackIndex',
    );
    isolatedStream.addTrack(targetTrack);
    renderer.srcObject = isolatedStream;

    final codec = session.getVideoTrackCodec(trackIndex) ?? '?';
    Logger().info(
      'SignalRSessionHub: Switched $cameraId to video track ${trackIndex + 1}/${tracks.length} (codec=$codec)',
    );
    return true;
  }

  bool switchAudioTrack(String cameraId, int trackIndex) {
    final session = activeSessions[cameraId];
    if (session == null) return false;

    final tracks = session.audioTracks;
    if (trackIndex < 0 || trackIndex >= tracks.length) {
      Logger().warn(
        'SignalRSessionHub: Invalid audio track index $trackIndex for $cameraId (${tracks.length} audio tracks)',
      );
      return false;
    }

    final oldIndex = _activeAudioTrack[cameraId] ?? 0;
    final wasMuted = oldIndex < tracks.length && !tracks[oldIndex].enabled;
    if (oldIndex < tracks.length) {
      tracks[oldIndex].enabled = false;
    }

    _activeAudioTrack[cameraId] = trackIndex;
    tracks[trackIndex].enabled = !wasMuted;
    session.updateAudioEnabledCache();

    Logger().info(
      'SignalRSessionHub: Switched $cameraId to audio track ${trackIndex + 1}/${tracks.length} (muted=$wasMuted)',
    );
    return true;
  }

  bool? toggleAudio(String cameraId, {bool? enable}) =>
      _toggleTrack(cameraId, isAudio: true, enable: enable);

  bool? toggleVideo(String cameraId, {bool? enable}) =>
      _toggleTrack(cameraId, isAudio: false, enable: enable);

  bool? _toggleTrack(String cameraId, {required bool isAudio, bool? enable}) {
    final session = activeSessions[cameraId];
    final trackType = isAudio ? 'audio' : 'video';

    MediaStreamTrack? track;
    if (isAudio) {
      final idx = _activeAudioTrack[cameraId] ?? 0;
      final tracks = session?.audioTracks ?? [];
      track = idx < tracks.length ? tracks[idx] : null;
    } else {
      track = session?.videoTrack;
    }

    if (track == null) {
      Logger().warn('SignalRSessionHub: No $trackType track for $cameraId');
      return null;
    }

    final newEnabled = enable ?? !track.enabled;
    track.enabled = newEnabled;
    if (isAudio) {
      session?.updateAudioEnabledCache();
    }

    Logger().info(
      'SignalRSessionHub: ${trackType.substring(0, 1).toUpperCase()}${trackType.substring(1)} ${newEnabled ? "enabled" : "disabled"} for $cameraId',
    );
    return newEnabled;
  }

  bool? isAudioEnabled(String cameraId) {
    final session = activeSessions[cameraId];
    if (session == null) return null;
    final idx = _activeAudioTrack[cameraId] ?? 0;
    final tracks = session.audioTracks;
    if (idx >= tracks.length) return null;
    return tracks[idx].enabled;
  }

  bool? isVideoEnabled(String cameraId) =>
      activeSessions[cameraId]?.videoTrack?.enabled;

  Future<void> shutdown() async {
    Logger().info('SignalRSessionHub: Shutting down...');
    _pendingDisconnects.addAll(_connectingCameras);

    for (final session in activeSessions.values) {
      await session.close();
    }
    activeSessions.clear();

    for (final renderer in _renderers.values) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _renderers.clear();
    _activeVideoTrack.clear();
    _activeAudioTrack.clear();

    await _signalRService?.closeConnection(closeAllSessions: true);
    _signalRService = null;
    _authService = null;
    _initialized = false;
    Logger().info('SignalRSessionHub: Shutdown complete');
  }
}
