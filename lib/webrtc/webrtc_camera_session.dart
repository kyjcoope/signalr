import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';
import 'package:universal_io/io.dart';

import '../signalr/signalr_message.dart';
import '../webrtc/signaling_message.dart';
import '../webrtc/webrtc_logger.dart';

class WebRtcCameraSession {
  WebRtcCameraSession({
    required this.cameraId,
    required this.sessionHub,
    this.preferRelay = false,
    this.turnTcpOnly = false,
    this.longAnswerGatherWait = false,
    this.autoRestartOnDisconnect = true,
    this.onLocalOffer,
  });

  final String cameraId;
  final SignalRSessionHub sessionHub;

  final bool preferRelay;
  final bool turnTcpOnly;
  final bool longAnswerGatherWait;
  final bool autoRestartOnDisconnect;

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
  VoidCallback? onLocalIceCandidate;

  bool _remoteDescSet = false;
  final List<TrickleMessage> _pendingTrickles = [];
  Map<int, String> _mlineToMid = {};
  final Set<String> _eocSentForMid = {};
  Completer<void> _iceCandidatesGathering = Completer<void>();
  bool _iceRestartInFlight = false;
  final WebRtcLogger _logger = WebRtcLogger();

  Stream<String> get messageStream => _messageController.stream;

  Duration get _answerGatherTimeout =>
      longAnswerGatherWait
          ? const Duration(seconds: 10)
          : const Duration(seconds: 5);

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
      _pendingTrickles.add(msg);
      return;
    }

    dev.log('[$cameraId] Received remote ICE candidate');
    try {
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
    _dataChannel?.send(RTCDataChannelMessage(text));
  }

  Future<void> close() async {
    _logger.stop();

    try {
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
    await _messageController.close();

    dev.log('[$cameraId] Session closed and cleaned up');
  }

  void dispose() {
    close();
  }

  List<Map<String, dynamic>> _toJsonServers() =>
      sessionHub.iceServers.map((e) => e.toJson()).toList();

  List<Map<String, dynamic>> _filteredIceServers() {
    final servers = <Map<String, dynamic>>[];
    if (!turnTcpOnly) {
      servers.addAll([
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        {'urls': 'stun:stun3.l.google.com:19302'},
        {'urls': 'stun:stun4.l.google.com:19302'},
      ]);
    }
    servers.addAll(_toJsonServers());

    if (turnTcpOnly) {
      bool keepUrl(dynamic url) {
        final u = url.toString().toLowerCase();
        return u.startsWith('turns:') || u.contains('transport=tcp');
      }

      List<dynamic> normalizeUrls(dynamic v) =>
          v is List
              ? v
              : v != null
              ? [v]
              : const [];

      final tcpOnly = <Map<String, dynamic>>[];
      for (final s in servers) {
        final list = normalizeUrls(s['urls']).where(keepUrl).toList();
        if (list.isEmpty) continue;
        final copy = Map<String, dynamic>.from(s);
        copy['urls'] = list;
        tcpOnly.add(copy);
      }
      return tcpOnly;
    }

    return servers;
  }

  Future<void> _initializeConnection() async {
    if (_peerConnection != null) return;

    final defaultIceServers = _filteredIceServers();

    final config = <String, dynamic>{
      'iceServers': defaultIceServers,
      'iceTransportPolicy': (preferRelay || turnTcpOnly) ? 'relay' : 'all',
      'iceCandidatePoolSize': 2,
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
    pc.onIceGatheringState = (state) async {
      dev.log('[$cameraId] ICE gathering state: $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
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
        if (!_iceCandidatesGathering.isCompleted) {
          _iceCandidatesGathering.complete();
        }
      }
    };

    _peerConnection = pc;
  }

  void _sendEndOfCandidates(String mid) {
    if (sessionId == null) return;
    final eoc = RTCIceCandidate('', mid, null);
    sessionHub.signalingHandler.sendTrickle(
      TrickleMessage(session: sessionId!, candidate: eoc, id: 'eoc'),
    );
  }

  Future<void> _drainQueuedRemoteIce() async {
    if (_pendingTrickles.isEmpty) return;
    dev.log(
      '[$cameraId] Draining ${_pendingTrickles.length} queued remote ICE',
    );
    while (_pendingTrickles.isNotEmpty) {
      final t = _pendingTrickles.removeAt(0);
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

    final oaConstraints = <String, dynamic>{
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    final answer = await _peerConnection!.createAnswer(oaConstraints);
    await _peerConnection!.setLocalDescription(answer);

    final timeout = Future.delayed(_answerGatherTimeout);
    await Future.any([_iceCandidatesGathering.future, timeout]);
    final finalAnswer = await _peerConnection!.getLocalDescription();
    await sessionHub.signalingHandler.sendInviteAnswer(
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
      final pc = _peerConnection;
      if (pc != null) _logger.start(pc, interval: const Duration(seconds: 1));
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      final pc = _peerConnection;
      if (pc != null) await _logger.logOnce(pc);
      _logger.stop();
      dev.log('[$cameraId] 🎉 ICE CONNECTION ESTABLISHED!');
      _iceRestartInFlight = false;
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      final pc = _peerConnection;
      if (pc != null) {
        _logger.start(pc, interval: const Duration(seconds: 1));
        await _logger.logOnce(pc);
      }
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
    }
  }

  void _onIceCandidate(RTCIceCandidate c) {
    if ((c.candidate ?? '').isEmpty) {
      dev.log('[$cameraId] ✅ End of LOCAL candidates.');
      if (!_iceCandidatesGathering.isCompleted) {
        _iceCandidatesGathering.complete();
      }
    }

    if (sessionId != null) {
      sessionHub.signalingHandler.sendTrickle(
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
    if (!autoRestartOnDisconnect) {
      dev.log('[$cameraId] Auto ICE restart disabled; not restarting.');
      return;
    }
    if (_peerConnection == null) {
      dev.log('[$cameraId] No peer connection to restart.');
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
      await _peerConnection!.restartIce(); // fresh creds on next offer
      final offer = await _peerConnection!.createOffer({'iceRestart': true});
      await _peerConnection!.setLocalDescription(offer);
      _iceRestartInFlight = true;

      dev.log('[$cameraId] Requested ICE restart and created local offer');
      // app must signal this offer and later call handleLocalOfferAnswer
      onLocalOffer!.call(offer);
    } catch (e) {
      dev.log('[$cameraId] ICE restart attempt failed: $e');
      _iceRestartInFlight = false;
    }
  }

  bool _isH264(String sdp) =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(sdp);

  String _mungeSdp(String sdp) {
    const iosAllowed = {'640c2a', '42e02a', '42e01f'};
    final defaultId = Platform.isIOS ? '42e02a' : '42e01f';

    // Fix profile-level-id
    sdp = sdp.replaceAllMapped(RegExp(r'profile-level-id=([0-9A-Fa-f]{6})'), (
      m,
    ) {
      final id = m[1]!.toLowerCase();
      final goodId =
          Platform.isIOS
              ? (iosAllowed.contains(id) ? id : defaultId)
              : defaultId;
      return 'profile-level-id=$goodId';
    });

    // Ensure level-asymmetry-allowed=1
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
}
