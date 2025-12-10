import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../signalr/signalr_service.dart';
import 'codec_detector.dart';
import 'ice_candidate_manager.dart';
import 'webrtc_player.dart';
import 'sdp_utils.dart';
import 'signaling_message.dart';
import 'webrtc_logger.dart';

/// WebRTC camera session implementing the VideoWebRTCPlayer interface.
///
/// Uses composition with [IceCandidateManager] and [CodecDetector] for cleaner code.
class WebRtcCameraSession implements VideoWebRTCPlayer {
  WebRtcCameraSession({
    required this.cameraId,
    SignalRService? signalRService,
    this.turnTcpOnly = false,
    this.restartOnDisconnect = true,
    this.onLocalOffer,
    this.enableDetailedLogging = true,
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
  bool enableDetailedLogging;

  /// Callback for ICE restart offers.
  final void Function(RTCSessionDescription offer)? onLocalOffer;

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
  bool _iceRestartInFlight = false;

  late final IceCandidateManager _iceManager;
  late final CodecDetector _codecDetector;
  final WebRtcLogger _logger = WebRtcLogger();
  final StreamController<String> _messageController =
      StreamController<String>.broadcast();

  String get _tag => '[$cameraId]';

  /// Get the SignalR service.
  SignalRService get signalRService => _signalRService;

  /// Get negotiated video codec.
  String? get negotiatedVideoCodec => _codecDetector.codec;

  /// Stream of data channel text messages.
  Stream<String> get messageStream => _messageController.stream;

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
      case SignalRMessageType.onSignalTimeout:
        dev.log('$_tag SignalR connection timeout');
      case SignalRMessageType.onSignalError:
        dev.log('$_tag SignalR error: ${message.detail}');
    }
  }

  void _handleIceServers(dynamic detail) {
    final session = detail['session'] as String?;
    if (session != null) {
      _sessionId = session;
      dev.log('$_tag Session started: $_sessionId');
      _initializePeerConnection();
    }
  }

  void _handleInvite(dynamic detail) {
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
    dev.log('$_tag Connecting...');
    _signalRService.registerPlayer(this);
    await _signalRService.connectConsumerSession(cameraId);
  }

  /// Send a message on the data channel.
  void sendDataChannelMessage(String text) {
    if (_dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen ||
        text.isEmpty)
      return;
    _dataChannel!.send(RTCDataChannelMessage(text));
  }

  /// Close the session.
  Future<void> close() async {
    _logger.stop();
    _signalRService.unregisterPlayer(this);
    _codecDetector.dispose();
    _iceManager.reset();

    await _cleanupDataChannel();
    await _cleanupPeerConnection();
    _resetState();

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
        'iceCandidatePoolSize': 0,
        'rtcpMuxPolicy': 'require',
        'sdpSemantics': 'unified-plan',
      };
    }

    servers.insert(0, {'urls': 'stun:stun.l.google.com:19302'});
    return {
      'iceServers': servers,
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 0,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };
  }

  void _bindPeerConnectionHandlers(RTCPeerConnection pc) {
    pc.onTrack = (event) {
      dev.log('$_tag Track received: ${event.track.kind}');
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
    _iceManager.createGatheringCompleter();

    // Apply compatibility fixes
    final offerSdp = offer.sdp.withCompatibilityFixes;

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp, offer.type),
    );

    _iceManager.setMlineMapping(offerSdp.mlineToMidMapping);
    _iceManager.markRemoteDescSet();
    await _iceManager.drainQueuedCandidates(_peerConnection!);

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    final finalAnswer = await _peerConnection!.getLocalDescription();
    if (finalAnswer?.sdp != null) {
      _codecDetector.extractFromSdp(finalAnswer!.sdp!);
    }

    await _signalRService.sendSignalInviteMessage(
      _sessionId!,
      SdpWrapper(type: finalAnswer!.type!, sdp: finalAnswer.sdp!),
      _lastInviteId ?? '',
    );

    await _iceManager.drainQueuedCandidates(_peerConnection!);
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
        _iceRestartInFlight = false;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        await _logOnce();
        dev.log('$_tag ❌ ICE FAILED');
        await _attemptIceRestart();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _startLogger();
        await _logOnce();
        dev.log('$_tag ❌ ICE DISCONNECTED');
        await Future.delayed(const Duration(seconds: 3));
        await _attemptIceRestart();
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
      return;
    }
    if (_peerConnection == null) return;
    if (_peerConnection!.signalingState ==
        RTCSignalingState.RTCSignalingStateClosed)
      return;
    if (onLocalOffer == null) return;
    if (_iceRestartInFlight) return;

    try {
      await _peerConnection!.restartIce();
      final offer = await _peerConnection!.createOffer({'iceRestart': true});
      await _peerConnection!.setLocalDescription(offer);
      _iceRestartInFlight = true;

      dev.log('$_tag Requested ICE restart');
      onLocalOffer!.call(offer);
    } catch (e) {
      dev.log('$_tag ICE restart failed: $e');
      _iceRestartInFlight = false;
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
    _iceRestartInFlight = false;
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
