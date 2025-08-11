import 'dart:async';
import 'dart:developer' as dev;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:signalr/signalr/signalr_session_hub.dart';
import 'package:universal_io/io.dart';

import '../signalr/signalr_message.dart';
import '../webrtc/signaling_message.dart';

class WebRtcCameraSession {
  WebRtcCameraSession({required this.cameraId, required this.sessionHub});

  final String cameraId;
  final SignalRSessionHub sessionHub;

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
  bool _localIceSeen = false;

  bool remoteDescSet = false;
  List<TrickleMessage> pendingTrickles = [];

  Stream<String> get messageStream => _messageController.stream;

  Future<void> initializeConnection() async {
    if (_peerConnection != null) return;

    final defaultIceServers = [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      ...sessionHub.iceServers.map((e) => e.toJson()),
    ];

    final config = <String, dynamic>{
      'iceServers': defaultIceServers,
      'iceTransportPolicy': 'all',
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
    pc.onRenegotiationNeeded = () =>
        dev.log('[$cameraId] Renegotiation needed');
    pc.onIceGatheringState = (state) async {
      dev.log('[$cameraId] ICE gathering state: $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        try {
          final txs = await pc.getTransceivers();
          for (final t in txs) {
            final mid = t.mid;
            if (mid.isNotEmpty) {
              _sendEndOfCandidates(mid);
            }
          }
        } catch (_) {
          for (final mid in const ['video0', 'application1']) {
            _sendEndOfCandidates(mid);
          }
        }
        if (!iceCandidatesGathering.isCompleted) {
          iceCandidatesGathering.complete();
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

  void dispose() {
    _dataChannel?.close();
    _peerConnection?.close();
    _messageController.close();
  }

  void sendDataChannelMessage(String text) {
    if (_dataChannel == null) return;
    dev.log('[$cameraId] Sending data channel message: $text');
    _dataChannel!.send(RTCDataChannelMessage(text));
  }

  void handleConnectResponse(ConnectResponse msg) {
    sessionId = msg.session;
    dev.log('[$cameraId] Session started: $sessionId');
    initializeConnection();
  }

  Future<void> handleInvite(InviteResponse msg) async {
    if (msg.offer.type == 'offer') {
      await _negotiate(msg);
    }
  }

  Completer<void> iceCandidatesGathering = Completer<void>();

  Future<void> handleTrickle(TrickleMessage msg) async {
    if ((msg.candidate.candidate ?? '').isEmpty) {
      dev.log(
        '[$cameraId] Received end-of-candidates for mid=${msg.candidate.sdpMid}',
      );
      return;
    }
    if (_peerConnection == null || !remoteDescSet) {
      pendingTrickles.add(msg);
      return;
    }

    dev.log('[$cameraId] Received remote ICE candidate');
    try {
      String? mid = msg.candidate.sdpMid;
      final mline = msg.candidate.sdpMLineIndex;
      if (mid == null) {
        if (mline == 0) {
          mid = 'video0';
        } else if (mline == 1) {
          mid = 'application1';
        }
      }
      final candidate = RTCIceCandidate(msg.candidate.candidate, mid, mline);
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      dev.log('[$cameraId] Error adding remote ICE candidate: $e');
    }
  }

  Future<void> _drainQueuedRemoteIce() async {
    if (pendingTrickles.isEmpty) return;
    dev.log('[$cameraId] Draining ${pendingTrickles.length} queued remote ICE');
    while (pendingTrickles.isNotEmpty) {
      final trickle = pendingTrickles.removeAt(0);
      try {
        String? mid = trickle.candidate.sdpMid;
        final mline = trickle.candidate.sdpMLineIndex;
        if (mid == null) {
          if (mline == 0) {
            mid = 'video0';
          } else if (mline == 1) {
            mid = 'application1';
          }
        }
        final candidate = RTCIceCandidate(
          trickle.candidate.candidate,
          mid,
          mline,
        );
        await _peerConnection?.addCandidate(candidate);
      } catch (e) {
        dev.log('[$cameraId] Error adding queued ICE: $e');
      }
    }
  }

  Future<void> _negotiate(InviteResponse msg) async {
    iceCandidatesGathering = Completer<void>();

    final offerSdp = _isH264(msg.offer.sdp)
        ? mungeSdp(msg.offer.sdp)
        : msg.offer.sdp;

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp, msg.offer.type),
    );

    remoteDescSet = true;
    await _drainQueuedRemoteIce();

    final oaConstraints = <String, dynamic>{
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    final answer = await _peerConnection!.createAnswer(oaConstraints);
    await _peerConnection!.setLocalDescription(answer);

    final timeout = Future.delayed(const Duration(seconds: 5));
    await Future.any([iceCandidatesGathering.future, timeout]);
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

  Timer? _statsTimer;

  void _onIceConnectionState(RTCIceConnectionState state) {
    dev.log('[$cameraId] ICE connection state: $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
      _statsTimer?.cancel();
      _statsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => logSelected(_peerConnection!),
      );
    }
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      _statsTimer?.cancel();
      logSelected(_peerConnection!);
      dev.log('[$cameraId] 🎉 ICE CONNECTION ESTABLISHED!');
    }
    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      _statsTimer?.cancel();
      logSelected(_peerConnection!);
      dev.log('[$cameraId] ❌ ICE ISSUE (state=$state)');
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
    if ((c.candidate ?? '').isNotEmpty) {
      if (!_localIceSeen) {
        _localIceSeen = true;
        onLocalIceCandidate?.call();
      }

      final candStr = c.candidate!;
      final m = RegExp(
        r'candidate:\S+ \d (udp|tcp) \S+ ([0-9a-fA-F\.\-:]+) (\d+) typ (\w+)',
      ).firstMatch(candStr);
      if (m != null) {
        final proto = m.group(1);
        final ip = m.group(2) ?? '';
        final port = m.group(3);
        final typ = m.group(4)?.toLowerCase();
        dev.log('[$cameraId] Local cand: typ=$typ proto=$proto $ip:$port');

        // Drop host candidates (.local/private) to avoid confusing the remote
        final isMdns = ip.endsWith('.local');
        final isPrivateV4 = RegExp(
          r'^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.)',
        ).hasMatch(ip);
        final isHost = typ == 'host';
        if (isHost && (isMdns || isPrivateV4)) {
          dev.log('[$cameraId] Skipping host candidate to remote: $ip:$port');
          return;
        }
      } else {
        dev.log('[$cameraId] Local cand: ${c.candidate}');
      }
    } else {
      dev.log('[$cameraId] ✅ End of LOCAL candidates.');
      if (!iceCandidatesGathering.isCompleted) {
        iceCandidatesGathering.complete();
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
    dev.log('[$cameraId] Data channel message: ${msg.text}');
    if (msg.isBinary) {
      onDataFrame?.call(Uint8List.fromList(msg.binary));
    } else {
      _messageController.add(msg.text);
    }
  }

  bool _isH264(String sdp) =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(sdp);

  String mungeSdp(String sdp) {
    const iosAllowed = {'640c2a', '42e02a', '42e01f'};
    final defaultId = Platform.isIOS ? '42e02a' : '42e01f';

    // Fix profile‑level‑id
    sdp = sdp.replaceAllMapped(RegExp(r'profile-level-id=([0-9A-Fa-f]{6})'), (
      m,
    ) {
      final id = m[1]!.toLowerCase();
      final goodId = Platform.isIOS
          ? (iosAllowed.contains(id) ? id : defaultId)
          : defaultId; // always 42e01f on Android
      return 'profile-level-id=$goodId';
    });

    // Ensure level‑asymmetry‑allowed=1
    if (!sdp.toLowerCase().contains('level-asymmetry-allowed')) {
      sdp = sdp.replaceFirst(
        'packetization-mode=1;',
        'level-asymmetry-allowed=1;packetization-mode=1;',
      );
    }

    return sdp;
  }

  Future<void> logSelected(RTCPeerConnection pc) async {
    final reports = await pc.getStats();

    StatsReport? transport = reports.firstWhereOrNull(
      (r) =>
          r.type == 'transport' &&
          (r.values['selectedCandidatePairId'] ?? '').toString().isNotEmpty,
    );

    String? pairId = transport?.values['selectedCandidatePairId'];
    StatsReport? pair;

    if (pairId != null && pairId.isNotEmpty) {
      pair = reports.firstWhereOrNull(
        (r) => r.id == pairId || (r.type == 'candidate-pair' && r.id == pairId),
      );
    }

    // Fallback: look for a selected/nominated/active pair directly
    pair ??= reports.firstWhereOrNull(
      (r) =>
          r.type == 'candidate-pair' &&
          (r.values['selected']?.toString() == 'true' ||
              r.values['nominated']?.toString() == 'true' ||
              r.values['googActiveConnection']?.toString() == 'true'),
    );

    if (pair == null) {
      print('logSelected: no selected candidate-pair yet');
      return;
    }

    final localId = (pair.values['localCandidateId'] ?? '').toString();
    final remoteId = (pair.values['remoteCandidateId'] ?? '').toString();
    StatsReport? local = reports.firstWhereOrNull((r) => r.id == localId);
    StatsReport? remote = reports.firstWhereOrNull((r) => r.id == remoteId);
    if (local == null || remote == null) {
      print('logSelected: local/remote candidate reports not found');
      return;
    }

    String pick(Map v, List<String> keys) {
      for (final k in keys) {
        final val = v[k];
        if (val != null && val.toString().isNotEmpty) return val.toString();
      }
      return '?';
    }

    final lv = local.values, rv = remote.values, pv = pair.values;
    final localType = pick(lv, ['candidateType', 'googCandidateType']);
    final localProto = pick(lv, ['protocol', 'transport']);
    final localIp = pick(lv, ['ip', 'address', 'ipAddress']);
    final localPort = pick(lv, ['port', 'portNumber']);
    final remoteType = pick(rv, ['candidateType', 'googCandidateType']);
    final remoteProto = pick(rv, ['protocol', 'transport']);
    final remoteIp = pick(rv, ['ip', 'address', 'ipAddress']);
    final remotePort = pick(rv, ['port', 'portNumber']);
    final state = pick(pv, ['state', 'writable', 'googWritable']);

    print(
      'SELECTED => state=$state local=$localType/$localProto $localIp:$localPort '
      'remote=$remoteType/$remoteProto $remoteIp:$remotePort',
    );
  }
}
