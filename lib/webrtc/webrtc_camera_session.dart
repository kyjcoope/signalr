import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../signalr/signalr_messages.dart';
import '../signalr/signalr_service.dart';
import '../utils/logger.dart';
import 'codec_detector.dart';
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
    this.enableDetailedLogging = true,
    this.negotiationTimeout = _negotiationTimeout,
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
  bool enableDetailedLogging;

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

  @override
  StreamSubscription<SignalRMessage>? subscription;

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal State
  // ═══════════════════════════════════════════════════════════════════════════

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _lastInviteId;
  bool _isNegotiating = false;
  bool _isClosing = false;
  Timer? _disconnectRecoveryTimer;

  // Connection timing
  DateTime? _connectStartedAt;
  DateTime? _inviteReceivedAt;
  DateTime? _answerSentAt;

  // Track storage for external access (e.g., mute/unmute)
  final List<MediaStream> _remoteStreams = [];
  final List<MediaStreamTrack> _videoTracks = [];
  final List<MediaStreamTrack> _audioTracks = [];
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
  final WebRtcStatsMonitor _statsMonitor = WebRtcStatsMonitor();
  final StreamController<String> _messageController =
      StreamController<String>.broadcast();

  /// Current connection state.
  SessionConnectionState _state = SessionConnectionState.idle;

  /// Get the current connection state.
  SessionConnectionState get state => _state;

  String get _tag => '[$cameraId]';

  /// Get the SignalR service.
  SignalRService get signalRService => _signalRService;

  /// Get negotiated video codec.
  String? get negotiatedVideoCodec => _codecDetector.codec;

  /// Live video stats notifier (received FPS, decoded FPS, etc.).
  ValueNotifier<WebRtcVideoStats> get statsNotifier =>
      _statsMonitor.statsNotifier;

  /// Stream of data channel text messages.
  Stream<String> get messageStream => _messageController.stream;

  /// Maximum ICE restart attempts before giving up.
  static const int _maxIceRestartAttempts = 3;

  void _setState(SessionConnectionState newState) {
    if (_state == newState) return;
    final oldState = _state;
    _state = newState;
    Logger().info('$_tag State: $oldState -> $newState');
    onStateChanged?.call(newState);
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
      onNegotiationTimeout: () => _setState(SessionConnectionState.failed),
      onConnectTimeout: () {
        _signalRService.unregisterPlayer(this);
        _setState(SessionConnectionState.failed);
      },
    );
  }

  void _sendCandidate(RTCIceCandidate candidate) {
    if (_sessionId != null) {
      _signalRService.sendSignalTrickleMessage(_sessionId!, candidate);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Player Interface - Message Handling
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void onSignalRMessage(SignalRMessage message) {
    Logger().info('$_tag onSignalRMessage: ${message.method}');

    switch (message.method) {
      case SignalRMessageType.onSignalReady:
        Logger().info('$_tag SignalR is ready');
        break;
      case SignalRMessageType.onSignalInvite:
        _handleInvite(message.detail);
      case SignalRMessageType.onSignalTrickle:
        _handleTrickle(message.detail);
      case SignalRMessageType.onSignalIceServers:
        _handleIceServers(message.detail);
      case SignalRMessageType.onSignalClosed:
        Logger().info('$_tag SignalR connection closed');
        _setState(SessionConnectionState.closed);
      case SignalRMessageType.onSignalTimeout:
        Logger().warn('$_tag SignalR connection timeout');
        _setState(SessionConnectionState.failed);
      case SignalRMessageType.onSignalError:
        Logger().error('$_tag SignalR error: ${message.detail}');
    }
  }

  Future<void> _handleIceServers(dynamic detail) async {
    // Clear the connect timeout - we received a response
    _cancelConnectTimeout();

    final session = detail['session'] as String?;
    if (session != null) {
      _sessionId = session;
      Logger().info('$_tag Session started: $_sessionId');
      _setState(SessionConnectionState.initializingPeer);
      await _initializePeerConnection();
      Logger().info('$_tag Peer connection ready, awaiting invite');
    }
  }

  void _handleInvite(dynamic detail) {
    if (_state.isTerminal) {
      Logger().info('$_tag Ignoring invite in terminal state');
      return;
    }

    try {
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
      _setState(SessionConnectionState.failed);
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
      _setState(SessionConnectionState.failed);
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

      // Empty candidate = end-of-candidates signal
      if (candidateStr == null || candidateStr.isEmpty) {
        Logger().info('$_tag Received end-of-candidates marker');
        return;
      }

      // Extract sdpMid and sdpMLineIndex with fallback
      final sdpMid = candidateData['sdpMid'] as String?;
      final sdpMLineIndex = candidateData['sdpMLineIndex'] as int? ?? 0;

      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);
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

    // Reset state from any previous attempt
    if (_state != SessionConnectionState.idle) {
      _resetState();
    }
    _isClosing = false;

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

    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _cancelNegotiationTimer();
    _cancelConnectTimeout();
    _statsMonitor.dispose();

    // Send close message to signaling server before cleanup
    if (_sessionId != null) {
      try {
        await _signalRService.sendCloseMessage(_sessionId!, cameraId);
      } catch (e) {
        Logger().warn('$_tag Error sending close message: $e');
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
      await _messageController.close();
    } catch (_) {}

    Logger().info('$_tag Session closed');
  }

  /// Enable or disable detailed logging.
  void setLoggingEnabled(bool enabled) {
    enableDetailedLogging = enabled;
    _statsMonitor.enableLogging = enabled;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Peer Connection Setup
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _initializePeerConnection() async {
    if (_peerConnection != null) return;

    Logger().info('$_tag Initializing peer connection');

    final pc = await createPeerConnection(_buildConfig());
    _bindPeerConnectionHandlers(pc);
    _peerConnection = pc;

    // Add transceivers for audio and video.
    // Some cameras expect audio transceiver even for video-only streams.
    // This fixes "bundle" issues where cameras fail without audio m-line.
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
      iceCandidatePoolSize: 2,
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
        track.enabled = false; // Default muted
        _audioTracks.add(track);
        Logger().info(
          '$_tag   → Audio track #${_audioTracks.length} added (muted)',
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

      // Extract per-track codecs from the offer SDP
      _videoTrackCodecs.clear();
      _videoTrackCodecs.addAll(offerSdp.videoCodecsPerSection);
      Logger().info('$_tag Per-track codecs from SDP: $_videoTrackCodecs');

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(offerSdp, offer.type),
      );

      _iceManager.setMlineMapping(offerSdp.mlineToMidMapping);
      _iceManager.markRemoteDescSet();
      await _iceManager.drainQueuedCandidates(_peerConnection!);

      _setState(SessionConnectionState.creatingAnswer);
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      final finalAnswer = await _peerConnection!.getLocalDescription();
      if (finalAnswer?.sdp != null) {
        _codecDetector.extractFromSdp(finalAnswer!.sdp!);
      }

      // Apply DTLS active role and H264 fixes to the answer SDP.
      // This forces Flutter to initiate DTLS handshake, fixing deadlocks
      // with IoT cameras that expect the client to send ClientHello first.
      final fixedSdp = finalAnswer!.sdp!.withAnswerFixes;
      Logger().info('$_tag Applied answer fixes (DTLS active role)');

      _setState(SessionConnectionState.sendingAnswer);
      await _signalRService.sendSignalInviteMessage(
        _sessionId!,
        SdpWrapper(type: finalAnswer.type!, sdp: fixedSdp),
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
      _setState(SessionConnectionState.failed);
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

  void _handleIceConnectionState(RTCIceConnectionState state) async {
    Logger().info('$_tag ICE connection state: $state');

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        _statsMonitor.setTag(_tag);
        _statsMonitor.enableLogging = enableDetailedLogging;
        _statsMonitor.start(_peerConnection!);
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _disconnectRecoveryTimer?.cancel();
        _disconnectRecoveryTimer = null;
        await _statsMonitor.logOnce(_peerConnection!);
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
        await _statsMonitor.logOnce(_peerConnection!);
        Logger().error('$_tag ❌ ICE FAILED');
        _attemptReconnect();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _statsMonitor.start(_peerConnection!);
        await _statsMonitor.logOnce(_peerConnection!);
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
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      Logger().info('$_tag 🎉 PEER CONNECTION ESTABLISHED!');
      onConnectionComplete?.call();
      _codecDetector.scheduleStatsDetection(_peerConnection!);
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
        _messageController.add(msg.text);
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
      _setState(SessionConnectionState.failed);
      return;
    }

    if (_isClosing) {
      Logger().info('$_tag Skipping reconnect — session is closing');
      return;
    }

    if (_iceRestartAttempts >= _maxIceRestartAttempts) {
      Logger().error(
        '$_tag Max reconnect attempts reached ($_maxIceRestartAttempts)',
      );
      _setState(SessionConnectionState.failed);
      return;
    }

    _iceRestartAttempts++;
    _setState(SessionConnectionState.reconnecting);

    Logger().info(
      '$_tag Attempting reconnect (attempt $_iceRestartAttempts/$_maxIceRestartAttempts)',
    );

    try {
      // Tear down existing connection
      _iceManager.reset();
      _statsMonitor.dispose();
      await _cleanupDataChannel();
      await _cleanupPeerConnection();
      _remoteStreams.clear();
      _videoTracks.clear();
      _audioTracks.clear();
      _videoTrackCodecs.clear();
      _lastInviteId = null;
      _isNegotiating = false;

      // Keep the session ID — leave session alive on server
      // Re-initialize peer connection and request a new offer
      _setState(SessionConnectionState.initializingPeer);
      await _initializePeerConnection();

      // Ask the server for a fresh session/offer
      _startConnectTimeout();
      await _signalRService.connectConsumerSession(cameraId);

      Logger().info('$_tag Reconnect request sent, awaiting invite');
    } catch (e) {
      Logger().error('$_tag Reconnect failed: $e');
      _setState(SessionConnectionState.failed);
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
    } catch (_) {}
    _dataChannel = null;
  }

  Future<void> _cleanupPeerConnection() async {
    final pc = _peerConnection;
    if (pc == null) return;

    try {
      final txs = await pc.getTransceivers();
      for (final t in txs) {
        try {
          await t.stop();
        } catch (_) {}
      }
    } catch (_) {}

    try {
      await pc.close();
    } catch (_) {}

    _peerConnection = null;
  }

  void _resetState() {
    _sessionId = null;
    _lastInviteId = null;
    _isNegotiating = false;
    _iceRestartAttempts = 0;
    _disconnectRecoveryTimer?.cancel();
    _disconnectRecoveryTimer = null;
    _connectStartedAt = null;
    _inviteReceivedAt = null;
    _answerSentAt = null;
    _remoteStreams.clear();
    _videoTracks.clear();
    _audioTracks.clear();
    _videoTrackCodecs.clear();
    _cancelNegotiationTimer();
  }
}
