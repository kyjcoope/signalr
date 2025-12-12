import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../signalr/signalr_service.dart';
import 'codec_detector.dart';
import 'ice_candidate_manager.dart';
import 'session_state.dart';
import 'webrtc_player.dart';
import 'sdp_utils.dart';
import 'signaling_message.dart';
import 'webrtc_logger.dart';

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

  // Track storage for external access (e.g., mute/unmute)
  MediaStream? _remoteStream;
  MediaStreamTrack? _videoTrack;
  MediaStreamTrack? _audioTrack;

  /// The remote media stream from the camera.
  MediaStream? get remoteStream => _remoteStream;

  /// The video track from the remote stream.
  MediaStreamTrack? get videoTrack => _videoTrack;

  /// The audio track from the remote stream.
  MediaStreamTrack? get audioTrack => _audioTrack;
  Timer? _negotiationTimer;
  Timer? _connectTimeout;
  int _iceRestartAttempts = 0;

  /// Timeout for the connect phase (waiting for session/ICE servers).
  static const Duration _connectPhaseTimeout = Duration(seconds: 15);

  late final IceCandidateManager _iceManager;
  late final CodecDetector _codecDetector;
  final WebRtcLogger _logger = WebRtcLogger();
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

  /// Stream of data channel text messages.
  Stream<String> get messageStream => _messageController.stream;

  /// Maximum ICE restart attempts before giving up.
  static const int _maxIceRestartAttempts = 3;

  void _setState(SessionConnectionState newState) {
    if (_state == newState) return;
    final oldState = _state;
    _state = newState;
    dev.log('$_tag State: $oldState -> $newState');
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
  }

  Future<void> _sendCandidate(RTCIceCandidate candidate) async {
    if (_sessionId != null) {
      await _signalRService.sendSignalTrickleMessage(_sessionId!, candidate);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Player Interface - Message Handling
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void onSignalRMessage(SignalRMessage message) {
    dev.log('$_tag onSignalRMessage: ${message.method}');

    switch (message.method) {
      case SignalRMessageType.onSignalReady:
        dev.log('$_tag SignalR is ready');
        break;
      case SignalRMessageType.onSignalInvite:
        _handleInvite(message.detail);
      case SignalRMessageType.onSignalTrickle:
        _handleTrickle(message.detail);
      case SignalRMessageType.onSignalIceServers:
        _handleIceServers(message.detail);
      case SignalRMessageType.onSignalClosed:
        dev.log('$_tag SignalR connection closed');
        _setState(SessionConnectionState.closed);
      case SignalRMessageType.onSignalTimeout:
        dev.log('$_tag SignalR connection timeout');
        _setState(SessionConnectionState.failed);
      case SignalRMessageType.onSignalError:
        dev.log('$_tag SignalR error: ${message.detail}');
    }
  }

  void _handleIceServers(dynamic detail) {
    // Clear the connect timeout - we received a response
    _cancelConnectTimeout();

    final session = detail['session'] as String?;
    if (session != null) {
      _sessionId = session;
      dev.log('$_tag Session started: $_sessionId');
      _setState(SessionConnectionState.initializingPeer);
      _initializePeerConnection();
    }
  }

  void _handleInvite(dynamic detail) {
    if (_state.isTerminal) {
      dev.log('$_tag Ignoring invite in terminal state');
      return;
    }

    try {
      final params = detail['params'] as Map<String, dynamic>?;
      final offer = params?['offer'] as Map<String, dynamic>?;
      if (offer == null) return;

      final sdpWrapper = SdpWrapper.fromJson(offer);
      _lastInviteId = detail['id']?.toString();

      if (sdpWrapper.type == 'offer') {
        _negotiate(sdpWrapper);
      }
    } catch (e) {
      dev.log('$_tag Error handling invite: $e');
      _setState(SessionConnectionState.failed);
    }
  }

  void _handleTrickle(dynamic detail) {
    try {
      final session = detail['session'] as String?;
      final candidateData = detail['candidate'] as Map<String, dynamic>?;
      if (session != _sessionId || candidateData == null) return;

      final candidateStr = candidateData['candidate'] as String? ?? '';
      if (candidateStr.isEmpty) {
        dev.log('$_tag Received end-of-candidates');
        return;
      }

      final candidate = RTCIceCandidate(
        candidateStr,
        candidateData['sdpMid'] as String?,
        candidateData['sdpMLineIndex'] as int?,
      );
      _iceManager.handleRemoteCandidate(candidate, _peerConnection);
    } catch (e) {
      dev.log('$_tag Error handling trickle: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Start connecting to the camera.
  Future<void> connect() async {
    if (_state != SessionConnectionState.idle) {
      dev.log('$_tag Cannot connect: state is $_state');
      return;
    }

    dev.log('$_tag Connecting...');
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
  Future<void> close() async {
    _cancelNegotiationTimer();
    _cancelConnectTimeout();
    _logger.stop();

    // Send close message to signaling server before cleanup
    if (_sessionId != null) {
      await _signalRService.sendCloseMessage(_sessionId!, cameraId);
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

    dev.log('$_tag Session closed');
  }

  /// Dispose of resources.
  Future<void> dispose() => close();

  /// Enable or disable detailed logging.
  void setLoggingEnabled(bool enabled) {
    enableDetailedLogging = enabled;
    _logger.setEnabled(enabled);
    if (!enabled) _logger.stop();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Peer Connection Setup
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _initializePeerConnection() async {
    if (_peerConnection != null) return;

    dev.log('$_tag Initializing peer connection');

    final pc = await createPeerConnection(_buildConfig());
    _bindPeerConnectionHandlers(pc);
    _peerConnection = pc;
  }

  Map<String, dynamic> _buildConfig() {
    final servers = _signalRService.iceServers.map((e) => e.toJson()).toList();

    if (turnTcpOnly) {
      // Filter to TCP-only TURN servers
      final tcpServers = servers
          .map((s) {
            final urls = (s['urls'] is List ? s['urls'] : [s['urls']]) as List;
            final tcpUrls = urls.where((u) {
              final str = u.toString().toLowerCase();
              return str.startsWith('turns:') || str.contains('transport=tcp');
            }).toList();
            return {...s, 'urls': tcpUrls};
          })
          .where((s) => (s['urls'] as List).isNotEmpty)
          .toList();

      return {
        'iceServers': tcpServers,
        'iceTransportPolicy': 'relay',
        'iceCandidatePoolSize': 2,
        'rtcpMuxPolicy': 'require',
        'sdpSemantics': 'unified-plan',
      };
    }

    servers.insert(0, {'urls': 'stun:stun.l.google.com:19302'});
    return {
      'iceServers': servers,
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 2,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };
  }

  void _bindPeerConnectionHandlers(RTCPeerConnection pc) {
    pc.onTrack = (event) {
      dev.log('$_tag Track received: ${event.track.kind}');

      // Store track references for external access
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
      }
      if (event.track.kind == 'video') {
        _videoTrack = event.track;
      } else if (event.track.kind == 'audio') {
        _audioTrack = event.track;
        _audioTrack?.enabled = false; // Default muted
      }

      onTrack?.call(event);
    };

    pc.onIceConnectionState = _handleIceConnectionState;
    pc.onConnectionState = _handleConnectionState;
    pc.onIceGatheringState = _handleIceGatheringState;
    pc.onIceCandidate = (c) => _iceManager.handleLocalCandidate(c, _sessionId);
    pc.onDataChannel = _handleDataChannel;
    pc.onSignalingState = (s) => dev.log('$_tag Signaling state: $s');
    pc.onRenegotiationNeeded = () => dev.log('$_tag Renegotiation needed');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Negotiation
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _negotiate(SdpWrapper offer) async {
    _startNegotiationTimer();
    _setState(SessionConnectionState.settingRemoteDescription);

    try {
      _iceManager.createGatheringCompleter();

      // Apply compatibility fixes
      final offerSdp = offer.sdp.withCompatibilityFixes;

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

      _setState(SessionConnectionState.sendingAnswer);
      await _signalRService.sendSignalInviteMessage(
        _sessionId!,
        SdpWrapper(type: finalAnswer!.type!, sdp: finalAnswer.sdp!),
        _lastInviteId ?? '',
      );

      _setState(SessionConnectionState.exchangingIce);
      // await _iceManager.drainQueuedCandidates(_peerConnection!);
      _cancelNegotiationTimer();
    } catch (e) {
      dev.log('$_tag Negotiation failed: $e');
      _cancelNegotiationTimer();
      _setState(SessionConnectionState.failed);
    }
  }

  void _startNegotiationTimer() {
    _cancelNegotiationTimer();
    _negotiationTimer = Timer(negotiationTimeout, () {
      dev.log('$_tag ❌ Negotiation timeout');
      _setState(SessionConnectionState.failed);
    });
  }

  void _cancelNegotiationTimer() {
    _negotiationTimer?.cancel();
    _negotiationTimer = null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connect Phase Timeout
  // ═══════════════════════════════════════════════════════════════════════════

  void _startConnectTimeout() {
    _cancelConnectTimeout();
    _connectTimeout = Timer(_connectPhaseTimeout, () {
      dev.log('$_tag ⏰ Connect phase timeout - no session received');
      _signalRService.unregisterPlayer(this);
      _setState(SessionConnectionState.failed);
    });
  }

  void _cancelConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // WebRTC Event Handlers
  // ═══════════════════════════════════════════════════════════════════════════

  void _handleIceConnectionState(RTCIceConnectionState state) async {
    dev.log('$_tag ICE connection state: $state');

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        _startLogger();
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        await _logOnce();
        _logger.stop();
        dev.log('$_tag 🎉 ICE CONNECTION ESTABLISHED!');
        _setState(SessionConnectionState.connected);
        _iceRestartAttempts = 0;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        await _logOnce();
        dev.log('$_tag ❌ ICE FAILED');
        await _attemptIceRestart();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _startLogger();
        await _logOnce();
        dev.log('$_tag ❌ ICE DISCONNECTED');
        _setState(SessionConnectionState.disconnected);
        // Give it a few seconds to self-recover before attempting restart
        await Future.delayed(const Duration(seconds: 3));
        if (_state == SessionConnectionState.disconnected) {
          await _attemptIceRestart();
        }
      default:
        break;
    }
  }

  void _handleConnectionState(RTCPeerConnectionState state) {
    dev.log('$_tag Peer connection state: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      dev.log('$_tag 🎉 PEER CONNECTION ESTABLISHED!');
      onConnectionComplete?.call();
      _codecDetector.scheduleStatsDetection(_peerConnection!);
    }
  }

  Future<void> _handleIceGatheringState(RTCIceGatheringState state) async {
    dev.log('$_tag ICE gathering state: $state');
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await _iceManager.sendAllEndOfCandidates(_peerConnection!);
    }
  }

  void _handleDataChannel(RTCDataChannel channel) {
    dev.log('$_tag Data channel opened: ${channel.label}');
    _dataChannel = channel;
    _dataChannel!.onMessage = (msg) {
      if (msg.isBinary) {
        onDataFrame?.call(Uint8List.fromList(msg.binary));
      } else {
        _messageController.add(msg.text);
      }
    };
    _dataChannel!.onDataChannelState = (state) {
      dev.log('$_tag Data channel state: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onDataChannelReady?.call();
      }
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ICE Restart
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _attemptIceRestart() async {
    if (!restartOnDisconnect) {
      dev.log('$_tag ICE restart disabled');
      _setState(SessionConnectionState.failed);
      return;
    }

    if (_peerConnection == null) {
      _setState(SessionConnectionState.failed);
      return;
    }

    if (_peerConnection!.signalingState ==
        RTCSignalingState.RTCSignalingStateClosed) {
      _setState(SessionConnectionState.failed);
      return;
    }

    if (!_state.canRestartIce) {
      dev.log('$_tag Cannot restart ICE in state: $_state');
      return;
    }

    if (_iceRestartAttempts >= _maxIceRestartAttempts) {
      dev.log('$_tag Max ICE restart attempts reached');
      _setState(SessionConnectionState.failed);
      return;
    }

    _iceRestartAttempts++;
    _setState(SessionConnectionState.restarting);

    try {
      dev.log(
        '$_tag Attempting ICE restart (attempt $_iceRestartAttempts/$_maxIceRestartAttempts)',
      );

      await _peerConnection!.restartIce();
      final offer = await _peerConnection!.createOffer({'iceRestart': true});
      await _peerConnection!.setLocalDescription(offer);

      // Send the restart offer to the signaling server
      final localDesc = await _peerConnection!.getLocalDescription();
      if (localDesc != null && _sessionId != null) {
        await _signalRService.sendIceRestartOffer(
          _sessionId!,
          SdpWrapper(type: localDesc.type!, sdp: localDesc.sdp!),
        );
        dev.log('$_tag ICE restart offer sent');
      }
    } catch (e) {
      dev.log('$_tag ICE restart failed: $e');
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
    _iceRestartAttempts = 0;
    _remoteStream = null;
    _videoTrack = null;
    _audioTrack = null;
    _cancelNegotiationTimer();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Logging
  // ═══════════════════════════════════════════════════════════════════════════

  void _startLogger() {
    if (!enableDetailedLogging || _peerConnection == null) return;
    _logger.setTag(_tag);
    _logger.setEnabled(true);
    _logger.start(
      _peerConnection!,
      interval: const Duration(seconds: 1),
      tag: _tag,
    );
  }

  Future<void> _logOnce() async {
    if (!enableDetailedLogging || _peerConnection == null) return;
    _logger.setTag(_tag);
    await _logger.logOnce(_peerConnection!, tag: _tag);
  }
}
