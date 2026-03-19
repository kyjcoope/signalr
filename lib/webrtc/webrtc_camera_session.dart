import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../signalr/signalr_messages.dart';
import '../signalr/signalr_service.dart';
import '../utils/logger.dart';
import 'codec_detector.dart';
import 'connection_error.dart';
import 'ice_candidate_manager.dart';
import 'peer_connection_factory.dart';
import 'session_state.dart';
import 'session_timers.dart';
import 'webrtc_player.dart';
import 'sdp_utils.dart';
import 'signaling_message.dart';
import 'webrtc_stats_monitor.dart';

/// Default timeout for negotiation operations.
const Duration _negotiationTimeout = Duration(seconds: 30);

/// WebRTC camera session implementing the VideoWebRTCPlayer interface.
///
/// Uses composition with [IceCandidateManager] and [CodecDetector] for cleaner code.
/// Tracks connection state via [SessionConnectionState] for reliable operation.
class WebRtcCameraSession implements VideoWebRTCPlayer {
  WebRtcCameraSession({
    required this.cameraId,
    SignalRService? signalRService,
    this.turnTcpOnly = false,
    this.restartOnDisconnect = true,
    this.negotiationTimeout = _negotiationTimeout,
    this.iceCandidatePoolSize = 0,
  }) : _signalRService = signalRService ?? SignalRService.instance,
       _playerId = 'player_${DateTime.now().millisecondsSinceEpoch}_$cameraId' {
    _initManagers();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Configuration
  // ═══════════════════════════════════════════════════════════════════════════

  final String cameraId;
  final SignalRService _signalRService;
  final bool turnTcpOnly;
  final bool restartOnDisconnect;
  final String _playerId;
  final Duration negotiationTimeout;
  final int iceCandidatePoolSize;

  // ═══════════════════════════════════════════════════════════════════════════
  // Callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  VoidCallback? onConnectionComplete;
  VoidCallback? onDataChannelReady;
  void Function(RTCTrackEvent)? onTrack;
  void Function(Uint8List)? onDataFrame;
  VoidCallback? onLocalIceCandidate;
  VoidCallback? onRemoteIceCandidate;
  void Function(String codec)? onVideoCodecResolved;
  void Function(SessionConnectionState state)? onStateChanged;
  void Function(ConnectionError error)? onSessionFailed;

  // ═══════════════════════════════════════════════════════════════════════════
  // Player Interface
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  String get playerId => _playerId;

  @override
  String get deviceId => cameraId;

  String? _sessionId;

  @override
  String? get sessionId => _sessionId;

  @override
  set sessionId(String? value) => _sessionId = value;

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal State
  // ═══════════════════════════════════════════════════════════════════════════

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _lastInviteId;
  bool _isNegotiating = false;
  bool _isClosing = false;
  bool _reconnectInFlight = false;

  /// True once the session has been connected at least once.
  /// Used to distinguish "never connected" from "was connected, then dropped".
  bool _hadConnected = false;
  int _connectionGeneration = 0;
  Timer? _disconnectRecoveryTimer;

  /// Completer that resolves when peer connection initialization finishes.
  /// Used to defer invite handling until the PC is ready.
  Completer<void>? _peerConnectionReady;

  // Connection timing
  DateTime? _connectStartedAt;
  DateTime? _inviteReceivedAt;
  DateTime? _answerSentAt;

  // Track storage for external access (e.g., mute/unmute)
  final List<MediaStream> _remoteStreams = [];
  final List<MediaStreamTrack> _videoTracks = [];
  final List<MediaStreamTrack> _audioTracks = [];

  /// Cached audio track enabled state (by track ID).
  /// Persists across reconnects so the user's mute/unmute choice is preserved
  /// when the peer connection is rebuilt. Keyed by track.id rather than array
  /// index so the mapping survives track reordering across reconnects.
  final Map<String, bool> _audioEnabledState = {};
  final List<String> _videoTrackCodecs = [];

  /// All remote media streams from the camera.
  List<MediaStream> get remoteStreams => List.unmodifiable(_remoteStreams);

  /// The first remote media stream (backward compat).
  MediaStream? get remoteStream =>
      _remoteStreams.isNotEmpty ? _remoteStreams.first : null;

  /// All video tracks from the remote streams.
  List<MediaStreamTrack> get videoTracks => List.unmodifiable(_videoTracks);

  /// All audio tracks from the remote streams.
  List<MediaStreamTrack> get audioTracks => List.unmodifiable(_audioTracks);

  /// The first video track (backward compat).
  MediaStreamTrack? get videoTrack =>
      _videoTracks.isNotEmpty ? _videoTracks.first : null;

  /// The first audio track (backward compat).
  MediaStreamTrack? get audioTrack =>
      _audioTracks.isNotEmpty ? _audioTracks.first : null;

  /// Number of video tracks received.
  int get videoTrackCount => _videoTracks.length;

  /// Number of audio tracks received.
  int get audioTrackCount => _audioTracks.length;

  /// Snapshot the current audio track enabled states into the cache.
  ///
  /// Called by [SignalRSessionHub] after toggling or switching audio tracks
  /// so the user's mute/unmute choice is preserved across reconnects.
  void updateAudioEnabledCache() {
    for (final track in _audioTracks) {
      final id = track.id;
      if (id != null) _audioEnabledState[id] = track.enabled;
    }
  }

  /// Codec names per video track (parallel to videoTracks).
  List<String> get videoTrackCodecs => List.unmodifiable(_videoTrackCodecs);

  /// Get codec for a specific video track index.
  String? getVideoTrackCodec(int index) {
    if (index < 0 || index >= _videoTrackCodecs.length) return null;
    return _videoTrackCodecs[index];
  }

  int _iceRestartAttempts = 0;

  late final SessionTimers _timers;

  late final IceCandidateManager _iceManager;
  late final CodecDetector _codecDetector;
  final WebRtcStatsMonitor _statsMonitor = WebRtcStatsMonitor(
    interval: Duration(seconds: 5),
  );
  StreamController<String>? _messageController;

  /// Current connection state.
  SessionConnectionState _state = SessionConnectionState.idle;

  /// Completer that resolves when the session reaches `connected` (true)
  /// or a terminal state like `failed`/`closed` (false).
  /// Used by [CameraConnectionQueue] to await the real WebRTC outcome.
  Completer<bool> _connectionCompleter = Completer<bool>();

  /// Get the current connection state.
  SessionConnectionState get state => _state;

  /// Future that completes when the session reaches a definitive state.
  ///
  /// - Completes with `true` when WebRTC is fully connected.
  /// - Completes with `false` when the session fails or is closed.
  ///
  /// Callers should apply their own timeout.
  Future<bool> get connectionResult => _connectionCompleter.future;

  /// The reason for the most recent failure, or `null` if healthy.
  ///
  /// Set whenever the session transitions to [SessionConnectionState.failed].
  /// Cleared on connect/reconnect. Read by `syncSessionToRedux` to expose
  /// the error to the UI layer.
  ConnectionError? lastError;

  String get _tag => '[$cameraId]';

  /// Get the SignalR service.
  SignalRService get signalRService => _signalRService;

  /// Get negotiated video codec.
  String? get negotiatedVideoCodec => _codecDetector.codec;

  /// Live video stats notifier (received FPS, decoded FPS, etc.).
  ValueNotifier<WebRtcVideoStats> get statsNotifier =>
      _statsMonitor.statsNotifier;

  /// Stream of data channel text messages.
  Stream<String> get messageStream => _ensureMessageController.stream;

  /// Lazily create the message controller so it can be recreated after close.
  StreamController<String> get _ensureMessageController {
    if (_messageController == null || _messageController!.isClosed) {
      _messageController = StreamController<String>.broadcast();
    }
    return _messageController!;
  }

  /// Maximum ICE restart attempts before giving up.
  static const int _maxIceRestartAttempts = 3;

  void _setState(SessionConnectionState newState) {
    if (_state == newState) return;
    final oldState = _state;
    _state = newState;
    Logger().info('$_tag State: $oldState -> $newState');
    onStateChanged?.call(newState);

    // Resolve the connection future for external waiters (queue).
    if (!_connectionCompleter.isCompleted) {
      if (newState == SessionConnectionState.connected) {
        _connectionCompleter.complete(true);
      } else if (newState.isTerminal) {
        _connectionCompleter.complete(false);
      }
    }

    // Track that we reached connected at least once.
    if (newState == SessionConnectionState.connected) {
      _hadConnected = true;
    }
  }

  /// Transition to [SessionConnectionState.failed] with a specific error.
  ///
  /// Performs full teardown: cancels timers, unregisters from the SignalR
  /// service, and cleans up peer connection + data channel resources.
  /// Re-entrancy safe — early-returns if already closing.
  Future<void> _fail(ConnectionError error) async {
    if (_isClosing) return;
    _isClosing = true;
    lastError = error;
    Logger().error('$_tag Failed: ${error.displayMessage}');

    _cancelNegotiationTimer();
    _cancelConnectTimeout();
    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _statsMonitor.statsNotifier.removeListener(_checkCodecFromStats);
    _statsMonitor.dispose();
    _signalRService.unregisterPlayer(this);

    await _cleanupDataChannel();
    await _cleanupPeerConnection();

    _setState(SessionConnectionState.failed);
    _isClosing = false; // Reset so retry/close can work

    // Notify external listeners (queue) so they can auto-reconnect
    // when a previously-connected camera drops with a recoverable error.
    if (_hadConnected && error.isRecoverable) {
      onSessionFailed?.call(error);
    }
  }

  void _initManagers() {
    _iceManager = IceCandidateManager(
      tag: _tag,
      onSendCandidate: _sendCandidate,
      onLocalIceStarted: () => onLocalIceCandidate?.call(),
      onRemoteIceStarted: () => onRemoteIceCandidate?.call(),
    );

    _codecDetector = CodecDetector(
      tag: _tag,
      onCodecResolved: (codec) => onVideoCodecResolved?.call(codec),
    );

    _timers = SessionTimers(
      tag: _tag,
      negotiationDuration: negotiationTimeout,
      onNegotiationTimeout: () => _fail(ConnectionError.negotiationTimeout),
      onConnectTimeout: () {
        // Send disconnect for the stale session so the server cleans up
        // (prevents error 101: Active Session Limit Exceeded)
        final staleSession = _sessionId;
        _sessionId = null;
        if (staleSession != null) {
          _signalRService
              .sendCloseMessage(staleSession, cameraId)
              .catchError(
                (e) => Logger().warn('$_tag Disconnect on timeout failed: $e'),
              );
        }
        _signalRService.unregisterPlayer(this);
        _fail(ConnectionError.connectTimeout);
      },
    );
  }

  void _sendCandidate(RTCIceCandidate candidate) {
    if (_sessionId == null) return;
    _signalRService.sendSignalTrickleMessage(_sessionId!, candidate);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Player Interface - Message Handling
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void onSignalRMessage(SignalRMessage message) {
    // Drop messages in terminal/closing states to avoid re-processing on
    // sessions that have already been torn down (e.g., stale server errors
    // for sessions disconnected during bulk "Cancel All").
    if (_isClosing || _state.isTerminal) {
      Logger().info(
        '$_tag Ignoring ${message.method} — state=$_state, closing=$_isClosing',
      );
      return;
    }

    Logger().info('$_tag onSignalRMessage: ${message.method}');

    switch (message.method) {
      case SignalRMessageType.onSignalReady:
        Logger().info('$_tag SignalR is ready');
        break;
      case SignalRMessageType.onSignalInvite:
        // Async — must catch errors to prevent unhandled zone exceptions.
        unawaited(
          _handleInvite(message.detail).catchError((e) {
            Logger().error('$_tag Unhandled error in _handleInvite: $e');
            _fail(ConnectionError.negotiationFailed);
          }),
        );
      case SignalRMessageType.onSignalTrickle:
        _handleTrickle(message.detail);
      case SignalRMessageType.onSignalIceServers:
        // Async — must catch errors to prevent unhandled zone exceptions.
        unawaited(
          _handleIceServers(message.detail).catchError((e) {
            Logger().error('$_tag Unhandled error in _handleIceServers: $e');
            _fail(ConnectionError.negotiationFailed);
          }),
        );
      case SignalRMessageType.onSignalClosed:
        Logger().warn('$_tag Server closed session — attempting reconnect');
        // The server-side session is gone (e.g. peerdisconnected).
        // Don't just die — try to reconnect if we were previously connected.
        if (_state == SessionConnectionState.connected ||
            _state == SessionConnectionState.exchangingIce) {
          _attemptReconnect();
        } else {
          _setState(SessionConnectionState.closed);
        }
      case SignalRMessageType.onSignalTimeout:
        Logger().warn('$_tag SignalR connection timeout');
        _fail(ConnectionError.connectTimeout);
      case SignalRMessageType.onSignalError:
        _handleError(message.detail);
    }
  }

  /// Handle a signaling error.
  void _handleError(dynamic detail) {
    final error = detail as ErrorMessage;
    final connectionError = ConnectionError.fromServerCode(error.code);

    Logger().error(
      '$_tag SignalR error: code=${error.code}, message="${error.message}"',
    );

    switch (connectionError) {
      case ConnectionError.sessionAlreadyExists:
        _recoverFromSessionAlreadyExists();
      case ConnectionError.sessionLimitExceeded:
        _recoverFromSessionLimitExceeded();
      case ConnectionError.invalidSessionId:
        // The server already cleaned up this session — nothing to recover.
        // Just clear the stale session ID so we don't keep sending to it.
        Logger().info('$_tag Ignoring invalid session id (server cleaned up)');
        _sessionId = null;
      default:
        _sessionId = null;
        _fail(connectionError);
    }
  }

  /// Recover from error 100 (Session Already Exist).
  ///
  /// Tells the server to clean up the stale session via LeaveSession,
  /// then waits briefly and retries with a fresh connectConsumerSession.
  Future<void> _recoverFromSessionAlreadyExists() async {
    Logger().warn(
      '$_tag Session already exists on server — cleaning up and retrying',
    );

    // Tell the server to clean up the stale session via disconnect message
    final staleSession = _sessionId;
    _sessionId = null;
    if (staleSession != null) {
      try {
        await _signalRService.sendCloseMessage(staleSession, cameraId);
      } catch (e) {
        Logger().warn('$_tag Failed to disconnect stale session: $e');
      }
    }

    // Brief delay to let the server finish cleanup
    await Future.delayed(const Duration(milliseconds: 300));

    if (_isClosing || _state == SessionConnectionState.connected) return;

    // Retry with a fresh session
    _startConnectTimeout();
    try {
      await _signalRService.connectConsumerSession(cameraId);
      Logger().info('$_tag Recovery: connect request sent, awaiting invite');
    } catch (e) {
      Logger().error('$_tag Recovery connect failed: $e');
      _fail(ConnectionError.sessionAlreadyExists);
    }
  }

  /// Recover from error 101 (Active Session Limit Exceeded).
  ///
  /// The server has too many active sessions. Send disconnect for ours,
  /// wait for sessions to expire, then retry.
  Future<void> _recoverFromSessionLimitExceeded() async {
    Logger().warn(
      '$_tag Active session limit exceeded — disconnecting and waiting',
    );

    // Disconnect our session so the server can free a slot
    final staleSession = _sessionId;
    _sessionId = null;
    if (staleSession != null) {
      try {
        await _signalRService.sendCloseMessage(staleSession, cameraId);
      } catch (e) {
        Logger().warn('$_tag Failed to disconnect session: $e');
      }
    }

    // Wait 5s + random jitter to avoid thundering herd when the server
    // drops many clients simultaneously.
    final jitterMs = math.Random().nextInt(2000);
    await Future.delayed(Duration(seconds: 5, milliseconds: jitterMs));

    if (_isClosing || _state == SessionConnectionState.connected) return;

    // Retry
    _startConnectTimeout();
    try {
      await _signalRService.connectConsumerSession(cameraId);
      Logger().info('$_tag Retry after session limit: connect request sent');
    } catch (e) {
      Logger().error('$_tag Retry after session limit failed: $e');
      _fail(ConnectionError.sessionLimitExceeded);
    }
  }

  Future<void> _handleIceServers(dynamic detail) async {
    // Don't cancel connect timeout here — it should cover the entire
    // connect-to-invite phase. It's cancelled in _handleInvite instead.

    if (_isClosing) return;

    final session = detail['session'] as String?;
    if (session != null) {
      _sessionId = session;
      Logger().info('$_tag Session started: $_sessionId');
      _setState(SessionConnectionState.initializingPeer);

      // Signal that PC init is in progress — invites will wait on this.
      _peerConnectionReady ??= Completer<void>();
      try {
        await _initializePeerConnection();
        // Abort if session was closed during the async PC init
        if (_isClosing) {
          Logger().info('$_tag Session closed during PC init — aborting');
          return;
        }
        if (!_peerConnectionReady!.isCompleted) {
          _peerConnectionReady!.complete();
        }
      } catch (e) {
        if (_peerConnectionReady != null &&
            !_peerConnectionReady!.isCompleted) {
          _peerConnectionReady!.completeError(e);
        }
        rethrow;
      }
      Logger().info('$_tag Peer connection ready, awaiting invite');
    }
  }

  Future<void> _handleInvite(dynamic detail) async {
    if (_state.isTerminal || _isClosing) {
      Logger().info('$_tag Ignoring invite in terminal/closing state');
      return;
    }

    // Session-scope validation: drop stale invites from old sessions
    // (same check that _handleTrickle already performs).
    final inviteSession =
        detail['params']?['session'] as String? ?? detail['session'] as String?;
    if (inviteSession != null &&
        _sessionId != null &&
        inviteSession != _sessionId) {
      Logger().info(
        '$_tag Ignoring stale invite for session $inviteSession (current=$_sessionId)',
      );
      return;
    }

    // Gate invites when _sessionId is null during reconnect/retry.
    // A late invite from an old session can slip through during the window
    // when _sessionId is cleared but a new session is not yet installed.
    if (_sessionId == null &&
        _state != SessionConnectionState.idle &&
        _state != SessionConnectionState.waitingForSession &&
        _state != SessionConnectionState.initializingPeer) {
      Logger().info(
        '$_tag Ignoring invite — no active session (reconnect in progress)',
      );
      return;
    }

    // Validation passed — NOW cancel timers (not before, so a malformed
    // or stale invite doesn't disable the recovery paths).
    _cancelConnectTimeout();

    try {
      // Wait for peer connection init to finish if it's still in progress.
      // This prevents a race where the invite arrives before
      // _initializePeerConnection() completes (common on Android where
      // the first PC load also loads the native JNI library).
      // If the invite arrives even before ICE servers, initialize the completer.
      _peerConnectionReady ??= Completer<void>();
      if (!_peerConnectionReady!.isCompleted) {
        Logger().info('$_tag Invite arrived early — waiting for PC init');
        try {
          await _peerConnectionReady!.future.timeout(negotiationTimeout);
        } on TimeoutException {
          Logger().error(
            '$_tag Timed out waiting for peer connection to be ready while handling invite',
          );
          _fail(ConnectionError.connectTimeout);
          return;
        }
      }

      final params = detail['params'] as Map<String, dynamic>?;
      final offer = params?['offer'] as Map<String, dynamic>?;
      if (offer == null) return;

      final inviteId = detail['id']?.toString();

      // Guard 1: ignore duplicate invites (same ID)
      if (_lastInviteId != null && inviteId == _lastInviteId) {
        Logger().info(
          '$_tag Ignoring duplicate invite (id=$inviteId, state=$_state)',
        );
        return;
      }

      // Guard 2: if we're mid-negotiation, don't re-enter
      if (_isNegotiating) {
        Logger().info(
          '$_tag Ignoring invite while negotiating (id=$inviteId, state=$_state)',
        );
        return;
      }

      // Guard 3: if we're already connected and streaming, ignore
      // spurious invites from the server — don't tear down a working
      // connection.
      if (_state == SessionConnectionState.connected) {
        Logger().info('$_tag Ignoring invite while connected (id=$inviteId)');
        return;
      }

      // SDP dump — only visible when log level is set to debug.
      final rawSdp = offer['sdp'] as String? ?? '';
      Logger().debug('$_tag ──────── Remote SDP Offer ────────');
      Logger().debug(rawSdp);
      Logger().debug('$_tag ──────── End SDP ────────');

      final sdpWrapper = SdpWrapper.fromJson(offer);

      // If we're mid-setup (have a peer connection but aren't connected yet)
      // and receive a *new* invite, restart fresh instead of attempting
      // renegotiation. IoT cameras don't always support renegotiation cleanly.
      if (_lastInviteId != null && _peerConnection != null) {
        Logger().info(
          '$_tag New invite during setup — restarting peer connection',
        );
        _restartPeerConnection(sdpWrapper, inviteId);
        return;
      }

      _lastInviteId = inviteId;

      if (sdpWrapper.type == 'offer') {
        _negotiate(sdpWrapper);
      }
    } catch (e) {
      Logger().error('$_tag Error handling invite: $e');
      _fail(ConnectionError.negotiationFailed);
    }
  }

  /// Restart the peer connection for a fresh negotiation.
  ///
  /// Tears down the existing peer connection and data channel,
  /// re-initializes a new one, then negotiates with the new offer.
  /// The SignalR session is kept alive.
  Future<void> _restartPeerConnection(
    SdpWrapper offer,
    String? inviteId,
  ) async {
    // _negotiate owns the _isNegotiating flag — don't double-set here
    try {
      _iceManager.reset();
      await _cleanupDataChannel();
      await _cleanupPeerConnection();
      _remoteStreams.clear();
      _videoTracks.clear();
      _audioTracks.clear();
      _videoTrackCodecs.clear();

      _setState(SessionConnectionState.initializingPeer);
      await _initializePeerConnection();

      _lastInviteId = inviteId;
      await _negotiate(offer);
    } catch (e) {
      Logger().error('$_tag Restart failed: $e');
      _fail(ConnectionError.negotiationFailed);
    }
  }

  void _handleTrickle(dynamic detail) {
    try {
      final session = detail['session'] as String?;
      if (session != _sessionId) return;

      // Normalize: support both single candidate and batched candidates
      final List<Map<String, dynamic>> candidates = [];

      // Check for batched format first (params.candidates: [...])
      final candidatesList = detail['candidates'];
      if (candidatesList is List) {
        for (final item in candidatesList) {
          if (item is Map<String, dynamic>) {
            candidates.add(item);
          }
        }
      }

      // Fallback to single candidate (params.candidate: {...})
      final singleCandidate = detail['candidate'];
      if (singleCandidate is Map<String, dynamic>) {
        candidates.add(singleCandidate);
      }

      if (candidates.isEmpty) {
        Logger().warn('$_tag No valid candidates in trickle message');
        return;
      }

      for (final candidateData in candidates) {
        _processCandidate(candidateData);
      }
    } catch (e) {
      Logger().error('$_tag Error handling trickle: $e');
    }
  }

  /// Parse and process a single ICE candidate from raw data.
  ///
  /// Handles both string candidate values and nested objects.
  /// Tolerates missing sdpMid/sdpMLineIndex with fallback defaults.
  void _processCandidate(Map<String, dynamic> candidateData) {
    try {
      // Support both 'candidate' as string or nested object
      String? candidateStr;
      final rawCandidate = candidateData['candidate'];
      if (rawCandidate is String) {
        candidateStr = rawCandidate;
      } else if (rawCandidate is Map<String, dynamic>) {
        candidateStr = rawCandidate['candidate'] as String?;
      }

      // Empty candidate = end-of-candidates signal.
      // Relay it to the peer connection so ICE can transition to
      // completed/failed — dropping it can stall ICE progression.
      if (candidateStr == null || candidateStr.isEmpty) {
        Logger().info('$_tag Received end-of-candidates marker');
        final sdpMid = candidateData['sdpMid'] as String?;
        final eoc = RTCIceCandidate('', sdpMid, null);
        _iceManager.handleRemoteCandidate(eoc, _peerConnection);
        return;
      }

      // Extract sdpMid and sdpMLineIndex with fallback
      final sdpMid = candidateData['sdpMid'] as String?;
      // Parse sdpMLineIndex safely — may arrive as String, double, or int
      // from different signaling implementations.
      final rawIndex = candidateData['sdpMLineIndex'];
      final sdpMLineIndex = rawIndex is int
          ? rawIndex
          : rawIndex is num
          ? rawIndex.toInt()
          : rawIndex is String
          ? int.tryParse(rawIndex)
          : null;

      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);
      Logger().debug('✅ $_tag ICE candidate -> $candidateStr');
      _iceManager.handleRemoteCandidate(candidate, _peerConnection);
    } catch (e) {
      Logger().error('$_tag Error processing candidate: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Start connecting to the camera.
  ///
  /// Allows retry from [SessionConnectionState.failed] or
  /// [SessionConnectionState.closed]. Rejects if already connecting or
  /// connected.
  Future<void> connect() async {
    // Allow connect from idle, failed, or closed (retry)
    if (_state != SessionConnectionState.idle &&
        _state != SessionConnectionState.failed &&
        _state != SessionConnectionState.closed) {
      Logger().warn('$_tag Cannot connect: state is $_state');
      return;
    }

    // Full teardown for retry — don't reuse stale internals
    if (_state != SessionConnectionState.idle) {
      _iceManager.reset();
      _statsMonitor.statsNotifier.removeListener(_checkCodecFromStats);
      _statsMonitor.dispose();
      _codecDetector.reset();
      await _cleanupDataChannel();
      await _cleanupPeerConnection();
      _resetState();
    }
    _isClosing = false;
    _reconnectInFlight = false;
    _hadConnected = false;
    _connectionGeneration++;

    // Reset the connection completer for this new attempt.
    if (_connectionCompleter.isCompleted) {
      _connectionCompleter = Completer<bool>();
    }

    _connectStartedAt = DateTime.now();
    Logger().info('$_tag Connecting...');
    _setState(SessionConnectionState.waitingForSession);
    _signalRService.registerPlayer(this);

    // Start timeout for connect phase - if no session received, fail
    _startConnectTimeout();

    await _signalRService.connectConsumerSession(cameraId);
  }

  /// Send a message on the data channel.
  void sendDataChannelMessage(String text) {
    if (_dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen ||
        text.isEmpty) {
      return;
    }
    _dataChannel!.send(RTCDataChannelMessage(text));
  }

  /// Close the session.
  ///
  /// Guarded against re-entrant calls (e.g. close during close,
  /// or close triggered by a state callback while already closing).
  Future<void> close() async {
    if (_isClosing) {
      Logger().info('$_tag Close already in progress, ignoring');
      return;
    }
    _isClosing = true;
    _connectionGeneration++;

    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _cancelNegotiationTimer();
    _cancelConnectTimeout();
    _statsMonitor.statsNotifier.removeListener(_checkCodecFromStats);
    _statsMonitor.dispose();

    // Send disconnect message to the server.
    // The web client only sends a 'disconnect' via SendMessage — it never
    // invokes the LeaveSession hub method (which errors on this server).
    if (_sessionId != null) {
      try {
        await _signalRService.sendCloseMessage(_sessionId!, cameraId);
      } catch (e) {
        Logger().warn('$_tag Error sending disconnect: $e');
      }
    }

    _signalRService.unregisterPlayer(this);
    _codecDetector.dispose();
    _iceManager.reset();

    await _cleanupDataChannel();
    await _cleanupPeerConnection();
    _resetState();
    _setState(SessionConnectionState.closed);

    try {
      await _messageController?.close();
    } catch (e) {
      Logger().warn('$_tag Error closing message controller: $e');
    }

    Logger().info('$_tag Session closed');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Peer Connection Setup
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _initializePeerConnection() async {
    if (_peerConnection != null) return;

    Logger().info('$_tag Initializing peer connection');

    final pc = await createPeerConnection(_buildConfig());

    // Fix 1A: If close() was called while awaiting createPeerConnection,
    // the returned pc is an orphan. Dispose it immediately.
    if (_isClosing) {
      Logger().info('$_tag Session closed during PC init — discarding orphan');
      await pc.close();
      return;
    }

    _bindPeerConnectionHandlers(pc);
    _peerConnection = pc;

    // Add transceivers for audio and video.
    // Some cameras expect audio transceiver even for video-only streams.
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    Logger().info('$_tag Added audio and video transceivers');
  }

  Map<String, dynamic> _buildConfig() {
    final config = PeerConnectionFactory.buildConfig(
      iceServers: _signalRService.iceServers,
      turnTcpOnly: turnTcpOnly,
      iceCandidatePoolSize: iceCandidatePoolSize,
    );

    Logger().info(
      '$_tag ICE config: ${_signalRService.iceServers.length} servers, turnTcpOnly=$turnTcpOnly',
    );
    return config;
  }

  void _bindPeerConnectionHandlers(RTCPeerConnection pc) {
    pc.onTrack = (event) {
      final track = event.track;
      final streamIds = event.streams.map((s) => s.id).join(', ');
      final mid = event.transceiver?.mid ?? '?';

      Logger().info('$_tag ──────────── Track Received ────────────');
      Logger().info('$_tag   kind      : ${track.kind}');
      Logger().info('$_tag   id        : ${track.id}');
      Logger().info('$_tag   label     : ${track.label}');
      Logger().info('$_tag   mid       : $mid');
      Logger().info('$_tag   enabled   : ${track.enabled}');
      Logger().info('$_tag   muted     : ${track.muted}');
      Logger().info('$_tag   streamIds : $streamIds');

      // Collect all streams
      if (event.streams.isNotEmpty) {
        final stream = event.streams[0];
        if (!_remoteStreams.any((s) => s.id == stream.id)) {
          _remoteStreams.add(stream);
        }
      }

      if (track.kind == 'video') {
        final trackIdx = _videoTracks.length;
        _videoTracks.add(track);
        // Assign codec from pre-parsed SDP codecs if available
        final codec = trackIdx < _videoTrackCodecs.length
            ? _videoTrackCodecs[trackIdx]
            : '?';
        Logger().info('$_tag   codec     : $codec');
        Logger().info('$_tag   → Video track #${trackIdx + 1} added');
      } else if (track.kind == 'audio') {
        final audioIdx = _audioTracks.length;
        // Restore cached mute state from before reconnect, or default muted.
        // Keyed by track.id so the mapping survives track reordering.
        final trackId = track.id;
        final restored = (trackId != null)
            ? (_audioEnabledState[trackId] ?? false)
            : false;
        track.enabled = restored;
        _audioTracks.add(track);
        Logger().info(
          '$_tag   → Audio track #${audioIdx + 1} added (enabled=$restored)',
        );
      }

      Logger().info(
        '$_tag ──────────── Totals: V:${_videoTracks.length} A:${_audioTracks.length} ────────────',
      );

      onTrack?.call(event);
    };

    pc.onIceConnectionState = _handleIceConnectionState;
    pc.onConnectionState = _handleConnectionState;
    pc.onIceGatheringState = _handleIceGatheringState;
    pc.onIceCandidate = (c) => _iceManager.handleLocalCandidate(c, _sessionId);
    pc.onDataChannel = _handleDataChannel;
    pc.onSignalingState = (s) => Logger().info('$_tag Signaling state: $s');
    pc.onRenegotiationNeeded = () =>
        Logger().info('$_tag Renegotiation needed');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Negotiation
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _negotiate(SdpWrapper offer) async {
    if (_isClosing) {
      Logger().info('$_tag Skipping negotiate — session is closing');
      return;
    }
    _isNegotiating = true;
    _inviteReceivedAt = DateTime.now();
    final waitMs = _connectStartedAt != null
        ? _inviteReceivedAt!.difference(_connectStartedAt!).inMilliseconds
        : 0;
    Logger().info('$_tag ⏱ Invite received after ${waitMs}ms');
    _startNegotiationTimer();
    _setState(SessionConnectionState.settingRemoteDescription);

    try {
      _iceManager.createGatheringCompleter();

      // Apply compatibility fixes
      final offerSdp = offer.sdp.withCompatibilityFixes;

      // Extract per-track codecs from the same offer SDP used for negotiation
      _videoTrackCodecs.clear();
      _videoTrackCodecs.addAll(offerSdp.videoCodecsPerSection);
      Logger().info('$_tag Per-track codecs from SDP: $_videoTrackCodecs');

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(offerSdp, offer.type),
      );

      _iceManager.setMlineMapping(offerSdp.mlineToMidMapping);
      _iceManager.markRemoteDescSet();
      await _iceManager.drainQueuedCandidates(_peerConnection!);

      if (_isClosing) {
        Logger().info('$_tag Aborting negotiate — session closed mid-flight');
        return;
      }

      _setState(SessionConnectionState.creatingAnswer);
      final answer = await _peerConnection!.createAnswer();

      final answerSdp = answer.sdp;
      if (answerSdp == null) {
        throw StateError(
          '$_tag Failed to create answer: RTCSessionDescription.sdp was null',
        );
      }

      // Apply DTLS active role and H264 fixes BEFORE setLocalDescription
      // so the local peer connection and signaled SDP are identical.
      // Previously these were applied after setLocalDescription, which
      // meant the local PC was configured with a different SDP than what
      // was sent to the remote peer.
      final fixedSdp = answerSdp.withAnswerFixes;
      _codecDetector.extractFromSdp(fixedSdp);
      Logger().info('$_tag Applied answer fixes (DTLS active role)');

      await _peerConnection!.setLocalDescription(
        RTCSessionDescription(fixedSdp, answer.type),
      );

      if (_isClosing) {
        Logger().info('$_tag Aborting negotiate — session closed before send');
        return;
      }

      _setState(SessionConnectionState.sendingAnswer);
      await _signalRService.sendSignalInviteMessage(
        _sessionId!,
        SdpWrapper(type: answer.type!, sdp: fixedSdp),
        _lastInviteId ?? '',
      );
      _answerSentAt = DateTime.now();
      final negotiateMs = _inviteReceivedAt != null
          ? _answerSentAt!.difference(_inviteReceivedAt!).inMilliseconds
          : 0;
      Logger().info('$_tag ⏱ Answer created+sent in ${negotiateMs}ms');

      _setState(SessionConnectionState.exchangingIce);
      _cancelNegotiationTimer();
    } catch (e) {
      Logger().error('$_tag Negotiation failed: $e');
      _cancelNegotiationTimer();
      _fail(ConnectionError.negotiationFailed);
    } finally {
      _isNegotiating = false;
    }
  }

  void _startNegotiationTimer() => _timers.startNegotiation();

  void _cancelNegotiationTimer() => _timers.cancelNegotiation();

  // ═══════════════════════════════════════════════════════════════════════════
  // Connect Phase Timeout
  // ═══════════════════════════════════════════════════════════════════════════

  void _startConnectTimeout() => _timers.startConnect();

  void _cancelConnectTimeout() => _timers.cancelConnect();

  // ═══════════════════════════════════════════════════════════════════════════
  // WebRTC Event Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  // Synchronous handler — never await inside to prevent out-of-order
  // state processing when the native stack fires events in quick succession.
  void _handleIceConnectionState(RTCIceConnectionState state) {
    Logger().info('$_tag ICE connection state: $state');

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        // Stats monitor is deferred to peer-connected state to avoid
        // polling during DTLS handshake when all values are empty.
        break;
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _disconnectRecoveryTimer?.cancel();
        _disconnectRecoveryTimer = null;
        if (_peerConnection != null) {
          unawaited(
            _statsMonitor.logOnce(_peerConnection!).catchError((e) {
              Logger().warn('$_tag logOnce error: $e');
            }),
          );
        }
        final iceMs = _answerSentAt != null
            ? DateTime.now().difference(_answerSentAt!).inMilliseconds
            : 0;
        final totalMs = _connectStartedAt != null
            ? DateTime.now().difference(_connectStartedAt!).inMilliseconds
            : 0;
        Logger().info('$_tag 🎉 ICE CONNECTION ESTABLISHED!');
        Logger().info(
          '$_tag ⏱ ICE connected ${iceMs}ms after answer, ${totalMs}ms total',
        );
        _setState(SessionConnectionState.connected);
        _iceRestartAttempts = 0;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        if (_peerConnection != null) {
          unawaited(
            _statsMonitor.logOnce(_peerConnection!).catchError((e) {
              Logger().warn('$_tag logOnce error: $e');
            }),
          );
        }
        Logger().error('$_tag ❌ ICE FAILED');
        _attemptReconnect();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        if (_peerConnection != null) {
          _statsMonitor.start(_peerConnection!);
          unawaited(
            _statsMonitor.logOnce(_peerConnection!).catchError((e) {
              Logger().warn('$_tag logOnce error: $e');
            }),
          );
        }
        Logger().warn('$_tag ⚠️ ICE DISCONNECTED');
        _setState(SessionConnectionState.disconnected);
        // Use a cancellable timer instead of inline await to avoid race
        // conditions. Timer is cancelled on close(), connect(), or recovery.
        _disconnectRecoveryTimer?.cancel();
        _disconnectRecoveryTimer = Timer(const Duration(seconds: 3), () {
          if (_state == SessionConnectionState.disconnected && !_isClosing) {
            _attemptReconnect();
          }
        });
      default:
        break;
    }
  }

  void _handleConnectionState(RTCPeerConnectionState state) {
    Logger().info('$_tag Peer connection state: $state');
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        Logger().info('$_tag 🎉 PEER CONNECTION ESTABLISHED!');
        // Start stats monitor now that DTLS is complete and values are meaningful
        _statsMonitor.setTag(_tag);

        _statsMonitor.start(_peerConnection!);
        onConnectionComplete?.call();
        // Codec detection now listens to the stats notifier instead of
        // running its own getStats() calls.
        _statsMonitor.statsNotifier.addListener(_checkCodecFromStats);
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        // Second line of defense: connectionState is the aggregate of ICE+DTLS
        // transports. On some mobile/native edge cases, ICE state alone misses
        // terminal failures. Only act if not already reconnecting/closing.
        if (!_isClosing &&
            _state != SessionConnectionState.reconnecting &&
            _state != SessionConnectionState.failed) {
          Logger().error('$_tag ❌ PEER CONNECTION FAILED');
          _attemptReconnect();
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        Logger().warn('$_tag Peer connection closed');
      default:
        break;
    }
  }

  /// Check if the stats monitor has detected a codec and forward it
  /// to the codec detector. Removes itself once resolved.
  void _checkCodecFromStats() {
    final codec = _statsMonitor.statsNotifier.value.codec;
    if (codec.isNotEmpty) {
      _codecDetector.resolveFromStats(codec);
      _statsMonitor.statsNotifier.removeListener(_checkCodecFromStats);
    }
  }

  Future<void> _handleIceGatheringState(RTCIceGatheringState state) async {
    Logger().info('$_tag ICE gathering state: $state');
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await _iceManager.sendAllEndOfCandidates(_peerConnection!);
    }
  }

  void _handleDataChannel(RTCDataChannel channel) {
    Logger().info('$_tag Data channel opened: ${channel.label}');
    _dataChannel = channel;
    _dataChannel!.onMessage = (msg) {
      if (msg.isBinary) {
        onDataFrame?.call(Uint8List.fromList(msg.binary));
      } else {
        _ensureMessageController.add(msg.text);
      }
    };
    _dataChannel!.onDataChannelState = (state) {
      Logger().info('$_tag Data channel state: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onDataChannelReady?.call();
      }
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Reconnection
  // ═══════════════════════════════════════════════════════════════════════════

  /// Attempt a full connection restart after ICE disconnect/failure.
  ///
  /// Unlike SDP-level ICE restart (which IoT cameras often don't support),
  /// this tears down the peer connection entirely and re-connects via
  /// the signaling server to get a fresh session.
  Future<void> _attemptReconnect() async {
    if (!restartOnDisconnect) {
      Logger().warn('$_tag Reconnect disabled');
      _fail(ConnectionError.reconnectFailed);
      return;
    }

    if (_isClosing) {
      Logger().info('$_tag Skipping reconnect — session is closing');
      return;
    }

    // Single-flight guard: prevent overlapping reconnect attempts from
    // onSignalClosed, ICE failed, and the disconnected recovery timer.
    if (_reconnectInFlight) {
      Logger().info('$_tag Reconnect already in flight — skipping');
      return;
    }

    if (_iceRestartAttempts >= _maxIceRestartAttempts) {
      Logger().error(
        '$_tag Max reconnect attempts reached ($_maxIceRestartAttempts)',
      );
      _fail(ConnectionError.reconnectFailed);
      return;
    }

    _reconnectInFlight = true;
    _connectionGeneration++;
    final gen = _connectionGeneration;
    _iceRestartAttempts++;
    _setState(SessionConnectionState.reconnecting);

    Logger().info(
      '$_tag Attempting reconnect (attempt $_iceRestartAttempts/$_maxIceRestartAttempts, gen=$gen)',
    );

    try {
      // Tear down existing connection
      _iceManager.reset();
      _statsMonitor.statsNotifier.removeListener(_checkCodecFromStats);
      _statsMonitor.dispose();
      await _cleanupDataChannel();
      await _cleanupPeerConnection();
      _remoteStreams.clear();
      _videoTracks.clear();
      _audioTracks.clear();
      _videoTrackCodecs.clear();
      _lastInviteId = null;
      _isNegotiating = false;

      // Abort if a newer operation has started
      if (gen != _connectionGeneration) return;

      // Disconnect the old session on the server before requesting a new one.
      // Without this, connectConsumerSession triggers error 100
      // (Session Already Exist) because the stale session is still alive.
      final oldSession = _sessionId;
      _sessionId = null;
      if (oldSession != null) {
        try {
          await _signalRService.sendCloseMessage(oldSession, cameraId);
        } catch (e) {
          Logger().warn('$_tag Failed to disconnect old session: $e');
        }
      }

      // Abort if a newer operation has started
      if (gen != _connectionGeneration) return;

      // Re-initialize peer connection and request a fresh session/offer
      _setState(SessionConnectionState.initializingPeer);
      await _initializePeerConnection();

      _startConnectTimeout();
      await _signalRService.connectConsumerSession(cameraId);

      Logger().info('$_tag Reconnect request sent, awaiting invite');
    } catch (e) {
      Logger().error('$_tag Reconnect failed: $e');
      _fail(ConnectionError.reconnectFailed);
    } finally {
      _reconnectInFlight = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Cleanup Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _cleanupDataChannel() async {
    try {
      _dataChannel?.onMessage = null;
      _dataChannel?.onDataChannelState = null;
      await _dataChannel?.close();
    } catch (e) {
      Logger().warn('$_tag Data channel cleanup warning: $e');
    }
    _dataChannel = null;
  }

  Future<void> _cleanupPeerConnection() async {
    // Nullify the reference FIRST to prevent re-entrancy.
    // If _cleanupPeerConnection() is called twice in rapid succession
    // (e.g. disconnect + ICE failure), the second call will see null
    // and return immediately instead of double-closing native resources.
    final pc = _peerConnection;
    _peerConnection = null;
    _peerConnectionReady = null;
    if (pc == null) return;

    // Detach all callbacks before stopping/closing to prevent stale
    // callbacks from firing during teardown and mutating session state.
    pc.onTrack = null;
    pc.onIceConnectionState = null;
    pc.onConnectionState = null;
    pc.onIceGatheringState = null;
    pc.onIceCandidate = null;
    pc.onDataChannel = null;
    pc.onSignalingState = null;
    pc.onRenegotiationNeeded = null;

    try {
      final txs = await pc.getTransceivers();
      for (final t in txs) {
        try {
          await t.stop();
        } catch (e) {
          Logger().warn('$_tag Transceiver stop warning: $e');
        }
      }
    } catch (e) {
      Logger().warn('$_tag Transceiver cleanup warning: $e');
    }

    try {
      await pc.close();
    } catch (e) {
      Logger().warn('$_tag PeerConnection close warning: $e');
    }
  }

  void _resetState() {
    _sessionId = null;
    _lastInviteId = null;
    _isNegotiating = false;
    _peerConnectionReady = null;
    _iceRestartAttempts = 0;
    _reconnectInFlight = false;
    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _connectStartedAt = null;
    _inviteReceivedAt = null;
    _answerSentAt = null;
    lastError = null;
    _remoteStreams.clear();
    _videoTracks.clear();
    _audioTracks.clear();
    _videoTrackCodecs.clear();
    _cancelNegotiationTimer();
  }
}
