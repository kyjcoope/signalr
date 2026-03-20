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

const Duration _negotiationTimeout = Duration(seconds: 30);

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

  final String cameraId;
  final SignalRService _signalRService;
  final bool turnTcpOnly;
  final bool restartOnDisconnect;
  final String _playerId;
  final Duration negotiationTimeout;
  final int iceCandidatePoolSize;

  VoidCallback? onConnectionComplete;
  VoidCallback? onDataChannelReady;
  void Function(RTCTrackEvent)? onTrack;
  void Function(Uint8List)? onDataFrame;
  VoidCallback? onLocalIceCandidate;
  VoidCallback? onRemoteIceCandidate;
  void Function(String codec)? onVideoCodecResolved;
  void Function(SessionConnectionState state)? onStateChanged;
  void Function(ConnectionError error)? onSessionFailed;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? _sessionId;
  String? _lastInviteId;
  bool _isNegotiating = false;
  bool _isClosing = false;
  bool _reconnectInFlight = false;
  bool _hadConnected = false;
  int _connectionGeneration = 0;
  Timer? _disconnectRecoveryTimer;
  Completer<void>? _peerConnectionReady;
  int _iceRestartAttempts = 0;
  SessionConnectionState _state = SessionConnectionState.idle;
  Completer<bool> _connectionCompleter = Completer<bool>();
  ConnectionError? lastError;
  StreamController<String>? _messageController;

  final List<MediaStream> _remoteStreams = [];
  final List<MediaStreamTrack> _videoTracks = [];
  final List<MediaStreamTrack> _audioTracks = [];
  final Map<String, bool> _audioEnabledState = {};
  final List<String> _videoTrackCodecs = [];

  late final SessionTimers _timers;
  late final IceCandidateManager _iceManager;
  late final CodecDetector _codecDetector;
  final WebRtcStatsMonitor _statsMonitor = WebRtcStatsMonitor(
    interval: Duration(seconds: 5),
  );

  static const int _maxIceRestartAttempts = 3;

  @override
  String get playerId => _playerId;

  @override
  String get deviceId => cameraId;

  @override
  String? get sessionId => _sessionId;

  @override
  set sessionId(String? value) => _sessionId = value;

  SessionConnectionState get state => _state;
  Future<bool> get connectionResult => _connectionCompleter.future;
  String get _tag => '[$cameraId]';
  SignalRService get signalRService => _signalRService;
  String? get negotiatedVideoCodec => _codecDetector.codec;

  ValueNotifier<WebRtcVideoStats> get statsNotifier =>
      _statsMonitor.statsNotifier;

  List<MediaStream> get remoteStreams => List.unmodifiable(_remoteStreams);
  MediaStream? get remoteStream =>
      _remoteStreams.isNotEmpty ? _remoteStreams.first : null;
  List<MediaStreamTrack> get videoTracks => List.unmodifiable(_videoTracks);
  List<MediaStreamTrack> get audioTracks => List.unmodifiable(_audioTracks);
  MediaStreamTrack? get videoTrack =>
      _videoTracks.isNotEmpty ? _videoTracks.first : null;
  MediaStreamTrack? get audioTrack =>
      _audioTracks.isNotEmpty ? _audioTracks.first : null;
  int get videoTrackCount => _videoTracks.length;
  int get audioTrackCount => _audioTracks.length;
  List<String> get videoTrackCodecs => List.unmodifiable(_videoTrackCodecs);

  Stream<String> get messageStream => _ensureMessageController.stream;

  StreamController<String> get _ensureMessageController {
    if (_messageController == null || _messageController!.isClosed) {
      _messageController = StreamController<String>.broadcast();
    }
    return _messageController!;
  }

  void updateAudioEnabledCache() {
    for (final track in _audioTracks) {
      final id = track.id;
      if (id != null) _audioEnabledState[id] = track.enabled;
    }
  }

  String? getVideoTrackCodec(int index) {
    if (index < 0 || index >= _videoTrackCodecs.length) return null;
    return _videoTrackCodecs[index];
  }

  void _setState(SessionConnectionState newState) {
    if (_state == newState) return;
    final oldState = _state;
    _state = newState;
    Logger().info('$_tag State: $oldState -> $newState');
    onStateChanged?.call(newState);

    if (!_connectionCompleter.isCompleted) {
      if (newState == SessionConnectionState.connected) {
        _connectionCompleter.complete(true);
      } else if (newState.isTerminal) {
        _connectionCompleter.complete(false);
      }
    }

    if (newState == SessionConnectionState.connected) {
      _hadConnected = true;
    }
  }

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
    _isClosing = false;

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

  @override
  void onSignalRMessage(SignalRMessage message) {
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
        unawaited(
          _handleInvite(message.detail).catchError((e) {
            Logger().error('$_tag Unhandled error in _handleInvite: $e');
            _fail(ConnectionError.negotiationFailed);
          }),
        );
      case SignalRMessageType.onSignalTrickle:
        _handleTrickle(message.detail);
      case SignalRMessageType.onSignalIceServers:
        unawaited(
          _handleIceServers(message.detail).catchError((e) {
            Logger().error('$_tag Unhandled error in _handleIceServers: $e');
            _fail(ConnectionError.negotiationFailed);
          }),
        );
      case SignalRMessageType.onSignalClosed:
        Logger().warn('$_tag Server closed session — attempting reconnect');
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
        Logger().info('$_tag Ignoring invalid session id (server cleaned up)');
        _sessionId = null;
      default:
        _sessionId = null;
        _fail(connectionError);
    }
  }

  Future<void> _recoverFromSessionAlreadyExists() async {
    Logger().warn(
      '$_tag Session already exists on server — cleaning up and retrying',
    );

    final staleSession = _sessionId;
    _sessionId = null;
    if (staleSession != null) {
      try {
        await _signalRService.sendCloseMessage(staleSession, cameraId);
      } catch (e) {
        Logger().warn('$_tag Failed to disconnect stale session: $e');
      }
    }

    await Future.delayed(const Duration(milliseconds: 300));
    if (_isClosing || _state == SessionConnectionState.connected) return;

    _startConnectTimeout();
    try {
      await _signalRService.connectConsumerSession(cameraId);
      Logger().info('$_tag Recovery: connect request sent, awaiting invite');
    } catch (e) {
      Logger().error('$_tag Recovery connect failed: $e');
      _fail(ConnectionError.sessionAlreadyExists);
    }
  }

  Future<void> _recoverFromSessionLimitExceeded() async {
    Logger().warn(
      '$_tag Active session limit exceeded — disconnecting and waiting',
    );

    final staleSession = _sessionId;
    _sessionId = null;
    if (staleSession != null) {
      try {
        await _signalRService.sendCloseMessage(staleSession, cameraId);
      } catch (e) {
        Logger().warn('$_tag Failed to disconnect session: $e');
      }
    }

    final jitterMs = math.Random().nextInt(2000);
    await Future.delayed(Duration(seconds: 5, milliseconds: jitterMs));
    if (_isClosing || _state == SessionConnectionState.connected) return;

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
    if (_isClosing) return;

    final session = detail['session'] as String?;
    if (session != null) {
      _sessionId = session;
      Logger().info('$_tag Session started: $_sessionId');

      if (_peerConnection != null ||
          (_peerConnectionReady != null && !_peerConnectionReady!.isCompleted)) {
        return;
      }

      _setState(SessionConnectionState.initializingPeer);
      _peerConnectionReady ??= Completer<void>();
      try {
        await _initializePeerConnection();
        if (_isClosing) return;
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
    }
  }

  Future<void> _handleInvite(dynamic detail) async {
    if (_state.isTerminal || _isClosing) {
      Logger().info('$_tag Ignoring invite in terminal/closing state');
      return;
    }

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

    if (_sessionId == null &&
        _state != SessionConnectionState.idle &&
        _state != SessionConnectionState.waitingForSession &&
        _state != SessionConnectionState.initializingPeer) {
      Logger().info(
        '$_tag Ignoring invite — no active session (reconnect in progress)',
      );
      return;
    }

    _cancelConnectTimeout();

    try {
      _peerConnectionReady ??= Completer<void>();
      if (!_peerConnectionReady!.isCompleted) {
        try {
          await _peerConnectionReady!.future.timeout(negotiationTimeout);
        } on TimeoutException {
          Logger().error('$_tag Timed out waiting for PC ready');
          _fail(ConnectionError.connectTimeout);
          return;
        } catch (e) {
          return;
        }
      }

      final params = detail['params'] as Map<String, dynamic>?;
      final offer = params?['offer'] as Map<String, dynamic>?;
      if (offer == null) return;

      final inviteId = detail['id']?.toString();
      if (_lastInviteId != null && inviteId == _lastInviteId) {
        Logger().info(
          '$_tag Ignoring duplicate invite (id=$inviteId, state=$_state)',
        );
        return;
      }
      if (_isNegotiating) {
        Logger().info(
          '$_tag Ignoring invite while negotiating (id=$inviteId, state=$_state)',
        );
        return;
      }
      if (_state == SessionConnectionState.connected) {
        Logger().info('$_tag Ignoring invite while connected (id=$inviteId)');
        return;
      }

      final sdpWrapper = SdpWrapper.fromJson(offer);
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

  Future<void> _restartPeerConnection(
    SdpWrapper offer,
    String? inviteId,
  ) async {
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

      final List<Map<String, dynamic>> candidates = [];
      final candidatesList = detail['candidates'];
      if (candidatesList is List) {
        for (final item in candidatesList) {
          if (item is Map<String, dynamic>) candidates.add(item);
        }
      }

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

  void _processCandidate(Map<String, dynamic> candidateData) {
    try {
      String? candidateStr;
      final rawCandidate = candidateData['candidate'];
      if (rawCandidate is String) {
        candidateStr = rawCandidate;
      } else if (rawCandidate is Map<String, dynamic>) {
        candidateStr = rawCandidate['candidate'] as String?;
      }

      if (candidateStr == null || candidateStr.isEmpty) {
        Logger().info('$_tag Received end-of-candidates marker');
        final sdpMid = candidateData['sdpMid'] as String?;
        final eoc = RTCIceCandidate('', sdpMid, null);
        _iceManager.handleRemoteCandidate(eoc, _peerConnection);
        return;
      }

      final sdpMid = candidateData['sdpMid'] as String?;
      final rawIndex = candidateData['sdpMLineIndex'];
      final sdpMLineIndex = rawIndex is int
          ? rawIndex
          : rawIndex is num
          ? rawIndex.toInt()
          : rawIndex is String
          ? int.tryParse(rawIndex)
          : null;

      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);
      _iceManager.handleRemoteCandidate(candidate, _peerConnection);
    } catch (e) {
      Logger().error('$_tag Error processing candidate: $e');
    }
  }

  Future<void> connect() async {
    if (_state != SessionConnectionState.idle &&
        _state != SessionConnectionState.failed &&
        _state != SessionConnectionState.closed) {
      Logger().warn('$_tag Cannot connect: state is $_state');
      return;
    }

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
    if (_connectionCompleter.isCompleted) {
      _connectionCompleter = Completer<bool>();
    }

    Logger().info('$_tag Connecting...');
    _setState(SessionConnectionState.waitingForSession);
    _signalRService.registerPlayer(this);
    _startConnectTimeout();

    if (_signalRService.iceServers.isNotEmpty && _peerConnection == null) {
      _peerConnectionReady = Completer<void>();
      _setState(SessionConnectionState.initializingPeer);
      unawaited(_initializePeerConnection().then((_) {
        if (!_isClosing && !_peerConnectionReady!.isCompleted) {
          _peerConnectionReady!.complete();
        }
      }).catchError((e) {
        if (_peerConnectionReady != null &&
            !_peerConnectionReady!.isCompleted) {
          _peerConnectionReady!.completeError(e);
        }
      }));
    }

    await _signalRService.connectConsumerSession(cameraId);
  }

  void sendDataChannelMessage(String text) {
    if (_dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen ||
        text.isEmpty) {
      return;
    }
    _dataChannel!.send(RTCDataChannelMessage(text));
  }

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

  Future<void> _initializePeerConnection() async {
    if (_peerConnection != null) return;

    final pc = await createPeerConnection(_buildConfig());

    if (_isClosing) {
      await pc.close();
      if (_peerConnectionReady != null &&
          !_peerConnectionReady!.isCompleted) {
        _peerConnectionReady!.completeError(
          StateError('Session closed during PC init'),
        );
      }
      return;
    }

    _bindPeerConnectionHandlers(pc);
    _peerConnection = pc;
  }

  Map<String, dynamic> _buildConfig() {
    return PeerConnectionFactory.buildConfig(
      iceServers: _signalRService.iceServers,
      turnTcpOnly: turnTcpOnly,
      iceCandidatePoolSize: iceCandidatePoolSize,
    );
  }

  void _bindPeerConnectionHandlers(RTCPeerConnection pc) {
    pc.onTrack = (event) {
      final track = event.track;
      final streamIds = event.streams.map((s) => s.id).join(', ');
      final mid = event.transceiver?.mid ?? '?';

      Logger().info('$_tag ———————————— Track Received ————————————');
      Logger().info('$_tag   kind      : ${track.kind}');
      Logger().info('$_tag   id        : ${track.id}');
      Logger().info('$_tag   label     : ${track.label}');
      Logger().info('$_tag   mid       : $mid');
      Logger().info('$_tag   enabled   : ${track.enabled}');
      Logger().info('$_tag   muted     : ${track.muted}');
      Logger().info('$_tag   streamIds : $streamIds');

      if (event.streams.isNotEmpty) {
        final stream = event.streams[0];
        if (!_remoteStreams.any((s) => s.id == stream.id)) {
          _remoteStreams.add(stream);
        }
      }

      if (track.kind == 'video') {
        final trackIdx = _videoTracks.length;
        _videoTracks.add(track);
        final codec = trackIdx < _videoTrackCodecs.length
            ? _videoTrackCodecs[trackIdx]
            : '?';
        Logger().info('$_tag   codec     : $codec');
        Logger().info('$_tag   ← Video track #${trackIdx + 1} added');
      } else if (track.kind == 'audio') {
        final audioIdx = _audioTracks.length;
        final trackId = track.id;
        final restored = (trackId != null)
            ? (_audioEnabledState[trackId] ?? false)
            : false;
        track.enabled = restored;
        _audioTracks.add(track);
        Logger().info(
          '$_tag   ← Audio track #${audioIdx + 1} added (enabled=$restored)',
        );
      }

      Logger().info(
        '$_tag ———————————— Totals: V:${_videoTracks.length} A:${_audioTracks.length} ————————————',
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

  Future<void> _negotiate(SdpWrapper offer) async {
    if (_isClosing) return;

    _isNegotiating = true;
    _startNegotiationTimer();
    _setState(SessionConnectionState.settingRemoteDescription);

    try {
      final pc = _peerConnection;
      if (pc == null || _isClosing) return;

      _iceManager.createGatheringCompleter();
      final offerSdp = offer.sdp.withCompatibilityFixes;

      _videoTrackCodecs.clear();
      _videoTrackCodecs.addAll(offerSdp.videoCodecsPerSection);

      await pc.setRemoteDescription(
        RTCSessionDescription(offerSdp, offer.type),
      );

      _iceManager.setMlineMapping(offerSdp.mlineToMidMapping);
      _iceManager.markRemoteDescSet();
      await _iceManager.drainQueuedCandidates(pc);

      if (_isClosing) return;

      _setState(SessionConnectionState.creatingAnswer);
      final answer = await pc.createAnswer();

      final answerSdp = answer.sdp;
      if (answerSdp == null) {
        throw StateError('Failed to create answer: sdp was null');
      }

      final fixedSdp = answerSdp.withAnswerFixes;
      _codecDetector.extractFromSdp(fixedSdp);

      await pc.setLocalDescription(
        RTCSessionDescription(fixedSdp, answer.type),
      );

      if (_isClosing) return;

      _setState(SessionConnectionState.sendingAnswer);
      await _signalRService.sendSignalInviteMessage(
        _sessionId!,
        SdpWrapper(type: answer.type!, sdp: fixedSdp),
        _lastInviteId ?? '',
      );

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
  void _startConnectTimeout() => _timers.startConnect();
  void _cancelConnectTimeout() => _timers.cancelConnect();

  void _handleIceConnectionState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        break;
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _disconnectRecoveryTimer?.cancel();
        _disconnectRecoveryTimer = null;
        _setState(SessionConnectionState.connected);
        _iceRestartAttempts = 0;
        if (_peerConnection != null) {
          final pc = _peerConnection!;
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!_isClosing) {
              _statsMonitor.logOnce(pc).catchError((e) {
                Logger().warn('$_tag logOnce error: $e');
              });
            }
          });
        }
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        if (_peerConnection != null) {
          unawaited(
            _statsMonitor.logOnce(_peerConnection!).catchError((e) {
              Logger().warn('$_tag logOnce error: $e');
            }),
          );
        }
        Logger().error('$_tag ICE failed');
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
        Logger().warn('$_tag ICE disconnected');
        _setState(SessionConnectionState.disconnected);
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
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        onConnectionComplete?.call();
        if (_peerConnection != null) {
          final pc = _peerConnection!;
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!_isClosing) {
              _statsMonitor.setTag(_tag);
              _statsMonitor.start(pc);
              _statsMonitor.statsNotifier.addListener(_checkCodecFromStats);
            }
          });
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        if (!_isClosing &&
            _state != SessionConnectionState.reconnecting &&
            _state != SessionConnectionState.failed) {
          Logger().error('$_tag Peer connection failed');
          _attemptReconnect();
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        Logger().warn('$_tag Peer connection closed');
      default:
        break;
    }
  }

  void _checkCodecFromStats() {
    final codec = _statsMonitor.statsNotifier.value.codec;
    if (codec.isNotEmpty) {
      _codecDetector.resolveFromStats(codec);
      _statsMonitor.statsNotifier.removeListener(_checkCodecFromStats);
    }
  }

  Future<void> _handleIceGatheringState(RTCIceGatheringState state) async {
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

      if (gen != _connectionGeneration) return;

      final oldSession = _sessionId;
      _sessionId = null;
      if (oldSession != null) {
        try {
          await _signalRService.sendCloseMessage(oldSession, cameraId);
        } catch (e) {
          Logger().warn('$_tag Failed to disconnect old session: $e');
        }
      }

      if (gen != _connectionGeneration) return;

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
    final pc = _peerConnection;
    _peerConnection = null;
    _peerConnectionReady = null;
    if (pc == null) return;

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
    lastError = null;
    _remoteStreams.clear();
    _videoTracks.clear();
    _audioTracks.clear();
    _videoTrackCodecs.clear();
    _cancelNegotiationTimer();
  }
}
