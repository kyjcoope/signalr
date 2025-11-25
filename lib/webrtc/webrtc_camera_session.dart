import 'dart:async';
import 'dart:collection';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';

import '../signalr/signalr_message.dart';
import '../webrtc/signaling_message.dart';
import '../webrtc/webrtc_logger.dart';

class WebRtcCameraSession {
  WebRtcCameraSession({
    required this.cameraId,
    required this.sessionHub,
    this.turnTcpOnly = false,
    this.restartOnDisconnect = true,
    this.onLocalOffer,
    this.enableDetailedLogging = true,
  });

  final String cameraId;
  final SignalRSessionHub sessionHub;
  final bool turnTcpOnly;
  final bool restartOnDisconnect;

  bool _remoteDescSet = false;
  bool enableDetailedLogging;
  void setLoggingEnabled(bool v) {
    enableDetailedLogging = v;
    _logger.setEnabled(v);
    if (!v) _logger.stop();
  }

  final void Function(RTCSessionDescription offer)? onLocalOffer;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  String? sessionId;

  final StreamController<String> _messageController =
      StreamController<String>.broadcast();

  // Callbacks
  VoidCallback? onConnectionComplete;
  VoidCallback? onDataChannelReady;
  void Function(RTCTrackEvent)? onTrack;
  void Function(Uint8List)? onDataFrame;

  // ICE state callbacks
  VoidCallback? onLocalIceCandidate;
  VoidCallback? onRemoteIceCandidate;

  // Codec callback
  void Function(String codec)? onVideoCodecResolved;

  // Negotiated codec (best-effort)
  String? selectedVideoCodec;
  String? get negotiatedVideoCodec => selectedVideoCodec;

  bool _firedLocalIce = false;
  bool _firedRemoteIce = false;

  final Queue<TrickleMessage> _pendingTrickles = Queue<TrickleMessage>();
  Map<int, String> _mlineToMid = {};
  final Set<String> _eocSentForMid = {};
  Completer<void> _iceCandidatesGathering = Completer<void>();
  bool _iceRestartInFlight = false;
  final WebRtcLogger _logger = WebRtcLogger();

  // Codec detection attempts
  int _codecDetectAttempts = 0;
  static const int _maxCodecDetectAttempts = 6;

  Stream<String> get messageStream => _messageController.stream;

  void handleConnectResponse(ConnectResponse msg) {
    sessionId = msg.session;
    dev.log('[$cameraId] Session started: $sessionId');
    _initializeConnection();
  }

  Future<void> handleInvite(InviteResponse msg) async {
    if (msg.offer.type == 'offer') {
      await _negotiate(msg);
    }
  }

  Future<void> handleLocalOfferAnswer(SdpWrapper answer) async {
    final pc = _peerConnection;
    if (pc == null) return;
    final desc = RTCSessionDescription(answer.sdp, answer.type);
    await pc.setRemoteDescription(desc);
    dev.log(
      '[$cameraId] Applied remote answer to local offer (ICE restart complete)',
    );
    _iceRestartInFlight = false;
  }

  Future<void> handleTrickle(TrickleMessage msg) async {
    if ((msg.candidate.candidate ?? '').isEmpty) {
      dev.log(
        '[$cameraId] Received end-of-candidates for mid=${msg.candidate.sdpMid}',
      );
      return;
    }
    if (_peerConnection == null || !_remoteDescSet) {
      _pendingTrickles.addLast(msg);
      return;
    }

    dev.log('[$cameraId] Received remote ICE candidate');
    try {
      if (!_firedRemoteIce) {
        _firedRemoteIce = true;
        onRemoteIceCandidate?.call();
      }
      final mline = msg.candidate.sdpMLineIndex;
      final mid = _resolveMid(msg.candidate.sdpMid, mline);

      if (mid == null) {
        dev.log(
          '[$cameraId] Could not resolve mid for remote candidate '
          '(mline=$mline, rawMid="${msg.candidate.sdpMid}") — dropping',
        );
        return;
      }

      final candidate = RTCIceCandidate(msg.candidate.candidate, mid, mline);
      await _peerConnection!.addCandidate(candidate);

      dev.log('[$cameraId] ✅ Added remote ICE: mid=$mid mline=$mline');
    } catch (e) {
      dev.log('[$cameraId] Error adding remote ICE candidate: $e');
    }
  }

  void sendDataChannelMessage(String text) {
    final ch = _dataChannel;
    if (ch == null ||
        ch.state != RTCDataChannelState.RTCDataChannelOpen ||
        text.isEmpty) {
      return;
    }
    ch.send(RTCDataChannelMessage(text));
  }

  Future<void> close() async {
    _logger.stop();

    try {
      _dataChannel?.onMessage = null;
      _dataChannel?.onDataChannelState = null;
      await _dataChannel?.close();
    } catch (_) {}
    _dataChannel = null;

    final pc = _peerConnection;
    if (pc != null) {
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
    }

    _peerConnection = null;
    _remoteDescSet = false;
    _pendingTrickles.clear();
    _mlineToMid.clear();
    _eocSentForMid.clear();
    _iceRestartInFlight = false;
    sessionId = null;
    _firedLocalIce = false;
    _firedRemoteIce = false;
    selectedVideoCodec = null;
    _codecDetectAttempts = 0;

    try {
      await _messageController.close();
    } catch (_) {}

    dev.log('[$cameraId] Session closed and cleaned up');
  }

  Future<void> dispose() => close();

  List<Map<String, dynamic>> _getIceServers() {
    final servers = sessionHub.iceServers.map((e) => e.toJson()).toList();

    if (!turnTcpOnly) {
      servers.insert(0, {'urls': 'stun:stun.l.google.com:19302'});
      return servers;
    }

    return servers
        .map((s) {
          final urls = (s['urls'] is List ? s['urls'] : [s['urls']]) as List;
          final tcpUrls =
              urls.where((u) {
                final str = u.toString().toLowerCase();
                return str.startsWith('turns:') ||
                    str.contains('transport=tcp');
              }).toList();
          return {...s, 'urls': tcpUrls};
        })
        .where((s) => (s['urls'] as List).isNotEmpty)
        .toList();
  }

  Future<void> _initializeConnection() async {
    if (_peerConnection != null) return;

    final config = <String, dynamic>{
      'iceServers': _getIceServers(),
      'iceTransportPolicy': (turnTcpOnly) ? 'relay' : 'all',
      'iceCandidatePoolSize': 0,
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };

    dev.log('[$cameraId] Initializing WebRTC peer connection');
    final pc = await createPeerConnection(config);
    dev.log('cfg: ${(pc.getConfiguration).toString()}');

    pc.onTrack = _onTrack;
    pc.onIceConnectionState = _onIceConnectionState;
    pc.onConnectionState = _onConnectionState;
    pc.onIceCandidate = _onIceCandidate;
    pc.onDataChannel = _onDataChannel;
    pc.onSignalingState = (s) => dev.log('[$cameraId] Signaling state: $s');
    pc.onRenegotiationNeeded =
        () => dev.log('[$cameraId] Renegotiation needed');
    pc.onIceGatheringState = _onIceGatheringState;

    _peerConnection = pc;
  }

  void _sendEndOfCandidates(String mid) {
    if (sessionId == null) return;
    final eoc = RTCIceCandidate('', mid, null);
    sessionHub.signalingHandler.send(
      TrickleMessage(session: sessionId!, candidate: eoc, id: 'eoc'),
    );
  }

  Future<void> _drainQueuedRemoteIce() async {
    if (_pendingTrickles.isEmpty) return;
    dev.log(
      '[$cameraId] Draining ${_pendingTrickles.length} queued remote ICE',
    );
    while (_pendingTrickles.isNotEmpty) {
      final t = _pendingTrickles.removeFirst();
      try {
        final mline = t.candidate.sdpMLineIndex;
        final mid = _resolveMid(t.candidate.sdpMid, mline);

        if (mid == null) {
          dev.log(
            '[$cameraId] Could not resolve mid for queued candidate '
            '(mline=$mline, rawMid="${t.candidate.sdpMid}") — dropping',
          );
          continue;
        }

        final c = RTCIceCandidate(t.candidate.candidate, mid, mline);
        if (!_firedRemoteIce) {
          _firedRemoteIce = true;
          onRemoteIceCandidate?.call();
        }
        await _peerConnection?.addCandidate(c);

        dev.log('[$cameraId] ✅ Added queued ICE: mid=$mid mline=$mline');
      } catch (e) {
        dev.log('[$cameraId] Error adding queued ICE: $e');
      }
    }
  }

  Future<void> _negotiate(InviteResponse msg) async {
    _iceCandidatesGathering = Completer<void>();

    final offerSdp =
        _isH264(msg.offer.sdp) ? _mungeSdp(msg.offer.sdp) : msg.offer.sdp;

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp, msg.offer.type),
    );
    _mlineToMid = _buildMLineToMid(offerSdp);

    _remoteDescSet = true;
    await _drainQueuedRemoteIce();

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    final finalAnswer = await _peerConnection!.getLocalDescription();
    if (finalAnswer != null) {
      _extractCodecFromSdpOnce(finalAnswer.sdp ?? '');
    }

    await sessionHub.signalingHandler.send(
      InviteAnswerMessage(
        session: msg.session,
        answerSdp: SdpWrapper(type: finalAnswer!.type!, sdp: finalAnswer.sdp!),
        id: msg.id,
      ),
    );

    await _drainQueuedRemoteIce();
  }

  void _onTrack(RTCTrackEvent event) {
    dev.log('[$cameraId] Track received: ${event.track.kind}');
    onTrack?.call(event);
  }

  void _onIceConnectionState(RTCIceConnectionState state) async {
    dev.log('[$cameraId] ICE connection state: $state');

    if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
      _startLogger();
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      await _logOnce();
      _logger.stop();
      dev.log('[$cameraId] 🎉 ICE CONNECTION ESTABLISHED!');
      _iceRestartInFlight = false;
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      _startLogger();
      await _logOnce();
      dev.log('[$cameraId] ❌ ICE ISSUE (state=$state)');
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      await Future.delayed(const Duration(seconds: 3));
      await _attemptIceRestart();
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      await _attemptIceRestart();
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    dev.log('[$cameraId] Peer connection state: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      dev.log('[$cameraId] 🎉 PEER CONNECTION ESTABLISHED!');
      onConnectionComplete?.call();
      // Attempt stats-based codec detection (more accurate) asynchronously
      _scheduleCodecStatsDetection();
    }
  }

  Future<void> _onIceGatheringState(RTCIceGatheringState state) async {
    dev.log('[$cameraId] ICE gathering state: $state');
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      final pc = _peerConnection;

      if (pc != null) {
        if (_mlineToMid.isNotEmpty) {
          for (final mid in _mlineToMid.values) {
            if (_eocSentForMid.add(mid)) {
              _sendEndOfCandidates(mid);
            }
          }
        } else {
          try {
            final txs = await pc.getTransceivers();
            for (final t in txs) {
              final mid = t.mid;
              if (mid.isNotEmpty && _eocSentForMid.add(mid)) {
                _sendEndOfCandidates(mid);
              }
            }
          } catch (_) {
            dev.log(
              '[$cameraId] Unable to get transceivers, sending EOC for default mids',
            );
            for (final mid in const ['audio0', 'video0', 'application1']) {
              if (_eocSentForMid.add(mid)) _sendEndOfCandidates(mid);
            }
          }
        }
      }

      if (!_iceCandidatesGathering.isCompleted) {
        _iceCandidatesGathering.complete();
      }
    }
  }

  void _onIceCandidate(RTCIceCandidate c) {
    if ((c.candidate ?? '').isEmpty) {
      dev.log('[$cameraId] ✅ End of LOCAL candidates.');
      if (!_iceCandidatesGathering.isCompleted) {
        _iceCandidatesGathering.complete();
      }
    } else {
      if (!_firedLocalIce) {
        _firedLocalIce = true;
        onLocalIceCandidate?.call();
      }
    }

    if (sessionId != null) {
      sessionHub.signalingHandler.send(
        TrickleMessage(session: sessionId!, candidate: c, id: '4'),
      );
    }
  }

  void _onDataChannel(RTCDataChannel channel) {
    dev.log('[$cameraId] Data channel opened: ${channel.label}');
    _dataChannel = channel;
    _dataChannel!.onMessage = _onDataChannelMessage;
    _dataChannel!.onDataChannelState = _onDataChannelState;
  }

  void _onDataChannelState(RTCDataChannelState state) {
    dev.log('[$cameraId] Data channel state: $state');
    if (state == RTCDataChannelState.RTCDataChannelOpen) {
      onDataChannelReady?.call();
    }
  }

  void _onDataChannelMessage(RTCDataChannelMessage msg) {
    if (msg.isBinary) {
      onDataFrame?.call(Uint8List.fromList(msg.binary));
    } else {
      _messageController.add(msg.text);
    }
  }

  Future<void> _attemptIceRestart() async {
    if (!restartOnDisconnect) {
      dev.log('[$cameraId] Auto ICE restart disabled; not restarting.');
      return;
    }
    final pc = _peerConnection;
    if (pc == null) {
      dev.log('[$cameraId] No peer connection to restart.');
      return;
    }
    if (pc.signalingState == RTCSignalingState.RTCSignalingStateClosed) {
      dev.log('[$cameraId] Signaling is closed; cannot restart ICE.');
      return;
    }
    if (onLocalOffer == null) {
      dev.log(
        '[$cameraId] Skipping ICE restart: onLocalOffer callback is not set.',
      );
      return;
    }
    if (_iceRestartInFlight) {
      dev.log('[$cameraId] ICE restart already in flight; skipping.');
      return;
    }

    try {
      await pc.restartIce();
      final offer = await pc.createOffer({'iceRestart': true});
      await pc.setLocalDescription(offer);
      _iceRestartInFlight = true;

      dev.log('[$cameraId] Requested ICE restart and created local offer');
      onLocalOffer!.call(offer);
    } catch (e) {
      dev.log('[$cameraId] ICE restart attempt failed: $e');
      _iceRestartInFlight = false;
    }
  }

  bool _isH264(String sdp) =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(sdp);

  String _mungeSdp(String sdp) {
    sdp = sdp.replaceAllMapped(RegExp(r'profile-level-id=([0-9A-Fa-f]{6})'), (
      m,
    ) {
      final goodId = '42e01f';
      return 'profile-level-id=$goodId';
    });

    if (!sdp.toLowerCase().contains('level-asymmetry-allowed')) {
      sdp = sdp.replaceFirst(
        'packetization-mode=1;',
        'level-asymmetry-allowed=1;packetization-mode=1;',
      );
    }
    return sdp;
  }

  String? _resolveMid(String? sdpMid, int? mline) {
    final hasMid = sdpMid != null && sdpMid.isNotEmpty;
    if (hasMid) return sdpMid;
    if (mline != null) return _mlineToMid[mline];
    return null;
  }

  Map<int, String> _buildMLineToMid(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final map = <int, String>{};
    var mIndex = -1;
    for (final line in lines) {
      if (line.startsWith('m=')) mIndex++;
      if (line.startsWith('a=mid:')) {
        final mid = line.substring('a=mid:'.length).trim();
        if (mIndex >= 0) map[mIndex] = mid;
      }
    }
    return map;
  }

  // SDP parsing (fallback / initial)
  void _extractCodecFromSdpOnce(String sdp) {
    if (selectedVideoCodec != null) return;
    final codec = _parseSelectedVideoCodec(sdp);
    if (codec != null) {
      selectedVideoCodec = codec;
      dev.log('[$cameraId] Selected video codec (SDP): $codec');
      onVideoCodecResolved?.call(codec);
    }
  }

  String? _parseSelectedVideoCodec(String sdp) {
    // Find first video media section
    final sections = sdp.split(RegExp(r'\r?\nm=')); // keep first 'm=' in first
    String? videoSection;
    for (final raw in sections) {
      final sec = raw.startsWith('m=') ? raw : 'm=$raw';
      if (sec.startsWith(RegExp(r'm=video'))) {
        videoSection = sec;
        break;
      }
    }
    if (videoSection == null) return null;

    final mLine = videoSection.split(RegExp(r'\r?\n')).first;
    final parts = mLine.split(' ');
    if (parts.length < 4) return null;
    // payload types are after first 3 tokens: m= video <port> <proto> <pt> ...
    final pts =
        parts.skip(3).where((p) => RegExp(r'^\d+$').hasMatch(p)).toList();
    if (pts.isEmpty) return null;

    final lines = sdp.split(RegExp(r'\r?\n'));
    for (final pt in pts) {
      final rtpmapLine = lines.firstWhere(
        (l) => l.startsWith('a=rtpmap:$pt '),
        orElse: () => '',
      );
      if (rtpmapLine.isEmpty) continue;
      final codecPart = rtpmapLine.split(' ').skip(1).firstOrNull ?? '';
      final codecName = codecPart.split('/').first.toUpperCase();
      // Skip non-codec payload helpers
      if (['RTX', 'ULPFEC', 'RED', 'FLEXFEC-03'].contains(codecName)) {
        continue;
      }
      return codecName;
    }
    return null;
  }

  void _scheduleCodecStatsDetection() {
    if (selectedVideoCodec != null) return;
    Future.delayed(const Duration(milliseconds: 700), _detectCodecFromStats);
  }

  Future<void> _detectCodecFromStats() async {
    if (_peerConnection == null) return;
    if (selectedVideoCodec != null) return;
    if (_codecDetectAttempts >= _maxCodecDetectAttempts) return;

    _codecDetectAttempts++;

    try {
      final reports = await _peerConnection!.getStats();
      if (reports.isEmpty) {
        _retryCodecDetection();
        return;
      }

      // Map reports by id
      final byId = {for (final r in reports) r.id: r};
      // Find inbound video
      final inboundVideo =
          reports.where((r) {
            final type = r.type.toLowerCase();
            if (type != 'inbound-rtp') return false;
            final kind =
                (r.values['kind'] ?? r.values['mediaType'] ?? '')
                    .toString()
                    .toLowerCase();
            return kind == 'video';
          }).toList();

      if (inboundVideo.isEmpty) {
        _retryCodecDetection();
        return;
      }

      for (final inbound in inboundVideo) {
        final codecId = inbound.values['codecId'] ?? inbound.values['codec_id'];
        if (codecId != null && byId.containsKey(codecId)) {
          final codecReport = byId[codecId]!;
          final mime =
              (codecReport.values['mimeType'] ??
                      codecReport.values['codec'] ??
                      '')
                  .toString();
          if (mime.isNotEmpty) {
            final upper =
                mime.contains('/')
                    ? mime.split('/').last.toUpperCase()
                    : mime.toUpperCase();
            if (upper.isNotEmpty) {
              selectedVideoCodec = upper;
              dev.log('[$cameraId] Selected video codec (Stats): $upper');
              onVideoCodecResolved?.call(upper);
              return;
            }
          }
        }
      }
    } catch (e) {
      dev.log('[$cameraId] Codec stats detection error: $e');
    }

    if (selectedVideoCodec == null) {
      _retryCodecDetection();
    }
  }

  void _retryCodecDetection() {
    if (selectedVideoCodec != null) return;
    if (_codecDetectAttempts >= _maxCodecDetectAttempts) return;
    Future.delayed(const Duration(seconds: 1), _detectCodecFromStats);
  }

  void _startLogger() {
    if (!enableDetailedLogging) return;
    final pc = _peerConnection;
    if (pc == null) return;
    _logger.setTag('[$cameraId]');
    _logger.setEnabled(true);
    _logger.start(pc, interval: const Duration(seconds: 1), tag: '[$cameraId]');
  }

  Future<void> _logOnce() async {
    if (!enableDetailedLogging) return;
    final pc = _peerConnection;
    if (pc == null) return;
    _logger.setTag('[$cameraId]');
    await _logger.logOnce(pc, tag: '[$cameraId]');
  }
}
