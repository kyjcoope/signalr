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
  WebRtcCameraSession({
    required this.cameraId,
    required this.sessionHub,

    /// If true, wait longer for local ICE gathering before sending the answer (10s vs 5s).
    this.longInitialGatherWait = true,

    /// If true, on Disconnected/Failed we will attempt restartIce() + createOffer(iceRestart: true).
    /// The resulting offer is provided to [onLocalOffer] for you to send via signaling.
    this.enableIceRestartRenegotiation = true,

    /// If true, on ICE 'failed' we switch TURN config to TCP/TLS-only (turns:...:443?transport=tcp),
    /// apply it to the pc, restart ICE, and emit a new offer via [onLocalOffer].
    this.enableTcpTurnFallback = true,

    /// If provided, called whenever this side generates an SDP offer (e.g., for ICE restart or TCP fallback).
    /// You are responsible for sending it to the remote and driving the normal O/A flow.
    this.onLocalOffer,
  });

  final String cameraId;
  final SignalRSessionHub sessionHub;

  /// Config toggles
  final bool longInitialGatherWait;
  final bool enableIceRestartRenegotiation;
  final bool enableTcpTurnFallback;

  /// Callback you can use to ship locally-created offers (renegotiations) to the remote peer.
  final Future<void> Function(RTCSessionDescription offer)? onLocalOffer;

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
  bool _didTcpFallback = false;

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
    stopStatusLogging();
    _dataChannel?.close();
    _peerConnection?.close();
    _messageController.close();
  }

  void sendDataChannelMessage(String text) {
    if (_dataChannel == null) return;
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

    final timeout = Future.delayed(
      longInitialGatherWait
          ? const Duration(seconds: 10)
          : const Duration(seconds: 5),
    );
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

  void _onIceConnectionState(RTCIceConnectionState state) async {
    dev.log('[$cameraId] ICE connection state: $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
      startStatusLogging(const Duration(seconds: 1));
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      stopStatusLogging();
      final pc = _peerConnection;
      if (pc != null) logStatus(pc);
      dev.log('[$cameraId] 🎉 ICE CONNECTION ESTABLISHED!');
    }

    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      stopStatusLogging();
      final pc = _peerConnection;
      if (pc != null) logStatus(pc);
      dev.log('[$cameraId] ❌ ICE ISSUE (state=$state)');
    }

    // Try restart + renegotiate on 'disconnected' (so we attempt recovery without tearing down)
    if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      await Future.delayed(const Duration(seconds: 3));
      await _attemptIceRestartRenegotiation(reason: 'disconnected');
    }

    // On 'failed', do a stronger recovery: try TCP/TLS-only TURN fallback (once)
    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      if (enableTcpTurnFallback && !_didTcpFallback) {
        _didTcpFallback = true;
        await _applyTcpTurnFallbackAndRestart();
      } else {
        // Even if no fallback, still try a restart+renegotiate once more
        await _attemptIceRestartRenegotiation(reason: 'failed');
      }
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

    // Fix profile-level-id
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

    // Ensure level-asymmetry-allowed=1
    if (!sdp.toLowerCase().contains('level-asymmetry-allowed')) {
      sdp = sdp.replaceFirst(
        'packetization-mode=1;',
        'level-asymmetry-allowed=1;packetization-mode=1;',
      );
    }

    return sdp;
  }

  // ---- Status logging (periodic) ----

  void startStatusLogging([Duration every = const Duration(seconds: 1)]) {
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

    // Local/remote candidates
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

    // Candidate details
    final lv = local.values, rv = remote.values, pv = pair.values;
    final localType = pick(lv, ['candidateType', 'googCandidateType']);
    final localProto = pick(lv, ['protocol', 'transport']);
    final localIp = pick(lv, ['ip', 'address', 'ipAddress']);
    final localPort = pick(lv, ['port', 'portNumber']);
    final remoteType = pick(rv, ['candidateType', 'googCandidateType']);
    final remoteProto = pick(rv, ['protocol', 'transport']);
    final remoteIp = pick(rv, ['ip', 'address', 'ipAddress']);
    final remotePort = pick(rv, ['port', 'portNumber']);
    final iceState = pick(pv, ['state', 'writable', 'googWritable']);
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

    // Compute simple bitrate deltas (kbps) since last sample
    double? deltaKbps(int? nowBytes, int? lastBytes) {
      if (nowBytes == null || lastBytes == null || _lastStatsAt == null) {
        return null;
      }
      final dt = now.difference(_lastStatsAt!).inMilliseconds / 1000.0;
      if (dt <= 0) return null;
      final bits = (nowBytes - lastBytes) * 8.0;
      return (bits / dt) / 1000.0;
    }

    // Video RX
    final vidRxBytes = pickInt(inV?.values ?? {}, ['bytesReceived']);
    final vidRxFps = pick(inV?.values ?? {}, ['framesPerSecond']);
    final vidW = pick(inV?.values ?? {}, ['frameWidth']);
    final vidH = pick(inV?.values ?? {}, ['frameHeight']);
    final vidLost = pick(inV?.values ?? {}, ['packetsLost']);
    final vidJitter = pick(inV?.values ?? {}, ['jitter']); // seconds

    // Video TX
    final vidTxBytes = pickInt(outV?.values ?? {}, ['bytesSent']);
    final vidTxFps = pick(outV?.values ?? {}, ['framesPerSecond']);

    // Audio RX/TX
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

  // ---- Recovery helpers ----

  Future<void> _attemptIceRestartRenegotiation({required String reason}) async {
    if (!enableIceRestartRenegotiation) {
      dev.log(
        '[$cameraId] ICE restart renegotiation disabled (reason=$reason)',
      );
      return;
    }
    try {
      await _peerConnection?.restartIce();
      dev.log('[$cameraId] Requested ICE restart (reason=$reason)');

      // Create an offer with iceRestart so the remote learns the new ICE creds.
      final offer = await _peerConnection!.createOffer({
        'iceRestart': true,
        // keep it minimal; remote already knows our media; but some stacks like explicit flags
        'offerToReceiveVideo': true,
        'offerToReceiveAudio': true,
      });
      await _peerConnection!.setLocalDescription(offer);
      dev.log('[$cameraId] Created local ICE-restart offer');

      if (onLocalOffer != null) {
        await onLocalOffer!(offer);
        dev.log('[$cameraId] Dispatched ICE-restart offer via onLocalOffer');
      } else {
        dev.log(
          '[$cameraId] No onLocalOffer callback; you must send the new offer to the remote.',
        );
      }
    } catch (e) {
      dev.log('[$cameraId] ICE restart/renegotiate error: $e');
    }
  }

  Future<void> _applyTcpTurnFallbackAndRestart() async {
    final pc = _peerConnection;
    if (pc == null) return;

    try {
      final current = pc.getConfiguration;
      final newIceServers = _tcpOnlyTurns(current['iceServers'] ?? []);
      final newConfig = Map<String, dynamic>.from(current);
      newConfig['iceServers'] = newIceServers;
      newConfig['iceTransportPolicy'] = 'relay';

      await pc.setConfiguration(newConfig);
      dev.log('[$cameraId] Applied TCP/TLS-only TURN fallback');

      // Restart ICE and renegotiate with new creds.
      await _attemptIceRestartRenegotiation(reason: 'tcp-turn-fallback');
    } catch (e) {
      dev.log('[$cameraId] TCP/TLS TURN fallback failed: $e');
    }
  }

  List<Map<String, dynamic>> _tcpOnlyTurns(dynamic servers) {
    final List<Map<String, dynamic>> result = [];
    if (servers is List) {
      for (final s in servers) {
        if (s is Map) {
          final urls = s['urls'];
          final user = s['username'];
          final cred = s['credential'];

          Iterable<String> inputUrls;
          if (urls is String) {
            inputUrls = [urls];
          } else if (urls is List) {
            inputUrls = urls.map((u) => u.toString());
          } else {
            inputUrls = const [];
          }

          final tcpUrls = <String>[];
          for (var u in inputUrls) {
            u = u.trim();
            if (u.startsWith('turn:') || u.startsWith('turns:')) {
              tcpUrls.add(_forceTurnsTcp(u));
            } // drop stun: entries in this fallback
          }

          if (tcpUrls.isNotEmpty) {
            result.add({
              'urls': tcpUrls.toList(),
              if (user != null) 'username': user,
              if (cred != null) 'credential': cred,
            });
          }
        }
      }
    }
    return result;
  }

  String _forceTurnsTcp(String url) {
    var s = url.trim();

    // Ensure turns: scheme
    if (s.startsWith('turn:')) s = s.replaceFirst('turn:', 'turns:');

    // Split query if any
    final parts = s.split('?');
    var base = parts[0];
    var query = parts.length > 1 ? parts.sublist(1).join('?') : '';

    // Ensure :443 on the base (before any ?)
    if (!RegExp(r':\d+$').hasMatch(base)) {
      base = '$base:443';
    }

    // Ensure transport=tcp
    if (query.isEmpty) {
      query = 'transport=tcp';
    } else if (RegExp(r'(^|&)transport=').hasMatch(query)) {
      query = query.replaceAll(RegExp(r'transport=\w+'), 'transport=tcp');
    } else {
      query = '$query&transport=tcp';
    }

    return '$base?$query';
  }
}
