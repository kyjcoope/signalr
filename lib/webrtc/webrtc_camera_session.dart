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

  bool remoteDescSet = false;
  List<TrickleMessage> pendingTrickles = [];

  Map<int, String> _mlineToMid = {};
  final Set<String> _eocSentForMid = {};

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

  Stream<String> get messageStream => _messageController.stream;

  Future<void> initializeConnection() async {
    if (_peerConnection != null) return;

    final defaultIceServers = [
      //{'urls': 'stun:stun.l.google.com:19302'},
      //{'urls': 'stun:stun1.l.google.com:19302'},
      //{'urls': 'stun:stun2.l.google.com:19302'},
      //{'urls': 'stun:stun3.l.google.com:19302'},
      //{'urls': 'stun:stun4.l.google.com:19302'},
      ...sessionHub.iceServers.map((e) => e.toJson()),
    ];

    final config = <String, dynamic>{
      'iceServers': defaultIceServers,
      'iceTransportPolicy': 'relay',
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
    //dev.log('[$cameraId] Sending data channel message: $text');
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

  Future<void> _drainQueuedRemoteIce() async {
    if (pendingTrickles.isEmpty) return;
    dev.log('[$cameraId] Draining ${pendingTrickles.length} queued remote ICE');
    while (pendingTrickles.isNotEmpty) {
      final t = pendingTrickles.removeAt(0);
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
    iceCandidatesGathering = Completer<void>();

    final offerSdp =
        _isH264(msg.offer.sdp) ? mungeSdp(msg.offer.sdp) : msg.offer.sdp;

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp, msg.offer.type),
    );
    _mlineToMid = _buildMLineToMid(offerSdp);

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
      // if (!_localIceSeen) {
      //   _localIceSeen = true;
      //   onLocalIceCandidate?.call();
      // }

      // final candStr = c.candidate!;
      // final m = RegExp(
      //   r'candidate:\S+ \d (udp|tcp) \S+ ([0-9a-fA-F\.\-:]+) (\d+) typ (\w+)',
      // ).firstMatch(candStr);
      // if (m != null) {
      //   final proto = m.group(1);
      //   final ip = m.group(2) ?? '';
      //   final port = m.group(3);
      //   final typ = m.group(4)?.toLowerCase();
      //   dev.log('[$cameraId] Local cand: typ=$typ proto=$proto $ip:$port');

      //   // Drop host candidates (.local/private) to avoid confusing the remote
      //   final isMdns = ip.endsWith('.local');
      //   final isPrivateV4 = RegExp(
      //     r'^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.)',
      //   ).hasMatch(ip);
      //   final isHost = typ == 'host';
      //   if (isHost && (isMdns || isPrivateV4)) {
      //     dev.log('[$cameraId] Skipping host candidate to remote: $ip:$port');
      //     return;
      //   }
      // } else {
      //   dev.log('[$cameraId] Local cand: ${c.candidate}');
      // }
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
    //dev.log('[$cameraId] Data channel message: ${msg.text}');
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
      final goodId =
          Platform.isIOS
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

  void startStatusLogging([Duration every = const Duration(seconds: 5)]) {
    _statusTimer?.cancel();
    if (_peerConnection == null) return;
    _statusTimer = Timer.periodic(every, (_) => logStatus(_peerConnection!));
  }

  void stopStatusLogging() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  DateTime? _lastStatsAt;
  int? _lastVidRxBytes, _lastVidTxBytes, _lastAudRxBytes, _lastAudTxBytes;
  Timer? _statusTimer;

  Future<void> logStatus(RTCPeerConnection pc) async {
    final reports = await pc.getStats();
    if (reports.isEmpty) {
      dev.log('STATUS: no stats yet');
      return;
    }

    // Index by id and type
    final byId = {for (final r in reports) r.id: r};
    Map<String, List<StatsReport>> byType = {};
    for (final r in reports) {
      (byType[r.type] ??= []).add(r);
    }

    // Helpers
    String pick(Map v, List<String> keys, {String fallback = '?'}) {
      for (final k in keys) {
        final val = v[k];
        if (val != null && val.toString().isNotEmpty) return val.toString();
      }
      return fallback;
    }

    double? pickNum(Map v, List<String> keys) {
      for (final k in keys) {
        final val = v[k];
        if (val == null) continue;
        final s = val.toString();
        final d = double.tryParse(s);
        if (d != null) return d;
      }
      return null;
    }

    int? pickInt(Map v, List<String> keys) {
      final d = pickNum(v, keys);
      return d?.round();
    }

    // ---- Transport / DTLS / ICE selection ----
    // Prefer a 'transport' that references the selected pair
    StatsReport? transport = byType['transport']?.firstWhereOrNull(
      (r) =>
          pick(r.values, ['selectedCandidatePairId'], fallback: '').isNotEmpty,
    );

    String? pairId =
        transport != null
            ? pick(transport.values, ['selectedCandidatePairId'], fallback: '')
            : null;

    // Fallback: hunt a nominated/selected pair
    StatsReport? pair =
        (pairId != null && pairId.isNotEmpty)
            ? byId[pairId]
            : byType['candidate-pair']?.firstWhereOrNull(
              (r) =>
                  pick(r.values, ['state']).toLowerCase() == 'succeeded' ||
                  pick(r.values, ['selected', 'googActiveConnection']) ==
                      'true' ||
                  pick(r.values, ['nominated']) == 'true',
            );

    if (pair == null) {
      dev.log('STATUS: no selected candidate-pair yet');
      return;
    }

    // local/remote candidates
    final localId = pick(pair.values, ['localCandidateId']);
    final remoteId = pick(pair.values, ['remoteCandidateId']);
    final local = byId[localId];
    final remote = byId[remoteId];
    if (local == null || remote == null) {
      dev.log(
        'STATUS: candidate reports missing (local=$localId remote=$remoteId)',
      );
      return;
    }

    // candidate details
    final lv = local.values, rv = remote.values, pv = pair.values;
    final localType = pick(lv, ['candidateType', 'googCandidateType']);
    final localProto = pick(lv, ['protocol', 'transport']);
    final localIp = pick(lv, ['ip', 'address', 'ipAddress']);
    final localPort = pick(lv, ['port', 'portNumber']);
    final remoteType = pick(rv, ['candidateType', 'googCandidateType']);
    final remoteProto = pick(rv, ['protocol', 'transport']);
    final remoteIp = pick(rv, ['ip', 'address', 'ipAddress']);
    final remotePort = pick(rv, ['port', 'portNumber']);
    final iceState = pick(pv, [
      'state',
      'writable',
      'googWritable',
    ]); // succeeded / in-progress / failed, etc.
    final rttSeconds = pickNum(pv, ['currentRoundTripTime', 'googRtt']) ?? 0;
    final rttMs = (rttSeconds > 1 ? rttSeconds : rttSeconds * 1000)
        .toStringAsFixed(1);
    final outBps = pickNum(pv, ['availableOutgoingBitrate']) ?? 0;
    final inBps = pickNum(pv, ['availableIncomingBitrate']) ?? 0;
    final consentSent = pickInt(pv, ['consentRequestsSent']) ?? 0;

    // DTLS/TLS/SRTP (from 'transport' if present)
    final tv = transport?.values ?? {};
    final dtlsState = pick(tv, ['dtlsState', 'tlsCipher']);
    final tlsVersion = pick(tv, ['tlsVersion'], fallback: '?');
    final dtlsCipher = pick(tv, ['dtlsCipher'], fallback: '?');
    final srtpCipher = pick(tv, ['srtpCipher'], fallback: '?');
    final iceRole = pick(tv, ['iceRole'], fallback: '?');
    final ufrag = pick(tv, [
      'iceLocalUsernameFragment',
      'localCertificateId',
    ], fallback: '?');

    // ---- RTP health (video/audio) ----
    StatsReport? inV = byType['inbound-rtp']?.firstWhereOrNull(
      (r) =>
          (pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'video') &&
          (pick(r.values, ['remoteSource'], fallback: 'false') == 'false'),
    );
    StatsReport? outV = byType['outbound-rtp']?.firstWhereOrNull(
      (r) => pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'video',
    );
    StatsReport? inA = byType['inbound-rtp']?.firstWhereOrNull(
      (r) =>
          (pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'audio') &&
          (pick(r.values, ['remoteSource'], fallback: 'false') == 'false'),
    );
    StatsReport? outA = byType['outbound-rtp']?.firstWhereOrNull(
      (r) => pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'audio',
    );

    final now = DateTime.now();
    num kbps(num bitsPerSecond) =>
        (bitsPerSecond <= 0) ? 0 : (bitsPerSecond / 1000.0);

    // compute simple bitrate deltas since last sample
    double? deltaKbps(int? nowBytes, int? lastBytes) {
      if (nowBytes == null || lastBytes == null || _lastStatsAt == null) {
        return null;
      }
      final dt = now.difference(_lastStatsAt!).inMilliseconds / 1000.0;
      if (dt <= 0) return null;
      final bits = (nowBytes - lastBytes) * 8.0;
      return (bits / dt) / 1000.0;
    }

    // video RX
    final vidRxBytes = pickInt(inV?.values ?? {}, ['bytesReceived']);
    final vidRxFps = pick(inV?.values ?? {}, ['framesPerSecond']);
    final vidW = pick(inV?.values ?? {}, ['frameWidth']);
    final vidH = pick(inV?.values ?? {}, ['frameHeight']);
    final vidLost = pick(inV?.values ?? {}, ['packetsLost']);
    final vidJitter = pick(inV?.values ?? {}, ['jitter']); // seconds

    // video TX
    final vidTxBytes = pickInt(outV?.values ?? {}, ['bytesSent']);
    final vidTxFps = pick(outV?.values ?? {}, ['framesPerSecond']);

    // audio RX/TX
    final audRxBytes = pickInt(inA?.values ?? {}, ['bytesReceived']);
    final audLost = pick(inA?.values ?? {}, ['packetsLost']);
    final audJitter = pick(inA?.values ?? {}, ['jitter']); // seconds
    final audTxBytes = pickInt(outA?.values ?? {}, ['bytesSent']);

    final vidRxKbps = deltaKbps(vidRxBytes, _lastVidRxBytes);
    final vidTxKbps = deltaKbps(vidTxBytes, _lastVidTxBytes);
    final audRxKbps = deltaKbps(audRxBytes, _lastAudRxBytes);
    final audTxKbps = deltaKbps(audTxBytes, _lastAudTxBytes);

    // Update last-sample
    _lastStatsAt = now;
    _lastVidRxBytes = vidRxBytes ?? _lastVidRxBytes;
    _lastVidTxBytes = vidTxBytes ?? _lastVidTxBytes;
    _lastAudRxBytes = audRxBytes ?? _lastAudRxBytes;
    _lastAudTxBytes = audTxBytes ?? _lastAudTxBytes;

    // ---- Compose log ----
    final iceLine =
        'ICE sel=$iceState rtt=${rttMs}ms outAvail=${kbps(outBps).toStringAsFixed(0)}kbps '
        'inAvail=${kbps(inBps).toStringAsFixed(0)}kbps consentSent=$consentSent';
    final pathLine =
        'path local=$localType/$localProto $localIp:$localPort  <->  '
        'remote=$remoteType/$remoteProto $remoteIp:$remotePort';
    final dtlsLine =
        'DTLS state=$dtlsState tls=$tlsVersion dtlsCipher=$dtlsCipher srtp=$srtpCipher '
        'iceRole=$iceRole ufrag=$ufrag';
    final videoLine =
        'RTP[video] rx=${vidRxKbps?.toStringAsFixed(0) ?? '?'}kbps ${vidW}x$vidH '
        '${vidRxFps.isNotEmpty ? "fps=$vidRxFps " : ""}'
        'lost=$vidLost jit=${vidJitter}s | '
        'tx=${vidTxKbps?.toStringAsFixed(0) ?? '?'}kbps ${vidTxFps.isNotEmpty ? "fps=$vidTxFps" : ""}';
    final audioLine =
        'RTP[audio] rx=${audRxKbps?.toStringAsFixed(0) ?? '?'}kbps '
        'lost=$audLost jit=${audJitter}s | '
        'tx=${audTxKbps?.toStringAsFixed(0) ?? '?'}kbps';

    dev.log('— STATUS —');
    dev.log(iceLine);
    dev.log(pathLine);
    dev.log(dtlsLine);
    dev.log(videoLine);
    dev.log(audioLine);
  }
}
