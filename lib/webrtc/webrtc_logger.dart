import 'dart:async';
import 'dart:developer' as dev;
import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

String _pick(Map v, List<String> keys, {String fallback = '?'}) {
  for (final k in keys) {
    final val = v[k];
    if (val != null && val.toString().isNotEmpty) return val.toString();
  }
  return fallback;
}

double? _pickNum(Map v, List<String> keys) {
  for (final k in keys) {
    final val = v[k];
    if (val == null) continue;
    final s = val.toString();
    final d = double.tryParse(s);
    if (d != null) return d;
  }
  return null;
}

int? _pickInt(Map v, List<String> keys) {
  final d = _pickNum(v, keys);
  return d?.round();
}

class WebRtcLogger {
  Timer? _timer;
  DateTime? _lastStatsAt;
  int? _lastVidRxBytes, _lastVidTxBytes, _lastAudRxBytes, _lastAudTxBytes;

  void start(
    RTCPeerConnection pc, {
    Duration interval = const Duration(seconds: 1),
  }) {
    stop();
    _timer = Timer.periodic(interval, (_) => logOnce(pc));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> logOnce(RTCPeerConnection pc) async {
    final reports = await pc.getStats();
    if (reports.isEmpty) {
      dev.log('STATUS: no stats yet');
      return;
    }

    // index by id and type
    final byId = {for (final r in reports) r.id: r};
    final byType = <String, List<StatsReport>>{};
    for (final r in reports) {
      (byType[r.type] ??= []).add(r);
    }

    // transport / DTLS / ICE selection
    final transport = byType['transport']?.firstWhereOrNull(
      (r) =>
          _pick(r.values, ['selectedCandidatePairId'], fallback: '').isNotEmpty,
    );

    final pairId =
        transport != null
            ? _pick(transport.values, ['selectedCandidatePairId'], fallback: '')
            : null;

    final pair =
        (pairId != null && pairId.isNotEmpty)
            ? byId[pairId]
            : byType['candidate-pair']?.firstWhereOrNull(
              (r) =>
                  _pick(r.values, ['state']).toLowerCase() == 'succeeded' ||
                  _pick(r.values, ['selected', 'googActiveConnection']) ==
                      'true' ||
                  _pick(r.values, ['nominated']) == 'true',
            );

    if (pair == null) {
      dev.log('STATUS: no selected candidate-pair yet');
      return;
    }

    // local/remote candidates
    final localId = _pick(pair.values, ['localCandidateId']);
    final remoteId = _pick(pair.values, ['remoteCandidateId']);
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
    final localType = _pick(lv, ['candidateType', 'googCandidateType']);
    final localProto = _pick(lv, ['protocol', 'transport']);
    final localIp = _pick(lv, ['ip', 'address', 'ipAddress']);
    final localPort = _pick(lv, ['port', 'portNumber']);
    final remoteType = _pick(rv, ['candidateType', 'googCandidateType']);
    final remoteProto = _pick(rv, ['protocol', 'transport']);
    final remoteIp = _pick(rv, ['ip', 'address', 'ipAddress']);
    final remotePort = _pick(rv, ['port', 'portNumber']);
    final iceState = _pick(pv, ['state', 'writable', 'googWritable']);
    final rttSeconds = _pickNum(pv, ['currentRoundTripTime', 'googRtt']) ?? 0;
    final rttMs = (rttSeconds > 1 ? rttSeconds : rttSeconds * 1000)
        .toStringAsFixed(1);
    final outBps = _pickNum(pv, ['availableOutgoingBitrate']) ?? 0;
    final inBps = _pickNum(pv, ['availableIncomingBitrate']) ?? 0;
    final consentSent = _pickInt(pv, ['consentRequestsSent']) ?? 0;

    // DTLS/TLS/SRTP from transport if present
    final tv = transport?.values ?? {};
    final dtlsState = _pick(tv, ['dtlsState', 'tlsCipher']);
    final tlsVersion = _pick(tv, ['tlsVersion'], fallback: '?');
    final dtlsCipher = _pick(tv, ['dtlsCipher'], fallback: '?');
    final srtpCipher = _pick(tv, ['srtpCipher'], fallback: '?');
    final iceRole = _pick(tv, ['iceRole'], fallback: '?');
    final ufrag = _pick(tv, [
      'iceLocalUsernameFragment',
      'localCertificateId',
    ], fallback: '?');

    // RTP health video/audio
    final inV = byType['inbound-rtp']?.firstWhereOrNull(
      (r) =>
          (_pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'video') &&
          (_pick(r.values, ['remoteSource'], fallback: 'false') == 'false'),
    );
    final outV = byType['outbound-rtp']?.firstWhereOrNull(
      (r) => _pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'video',
    );
    final inA = byType['inbound-rtp']?.firstWhereOrNull(
      (r) =>
          (_pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'audio') &&
          (_pick(r.values, ['remoteSource'], fallback: 'false') == 'false'),
    );
    final outA = byType['outbound-rtp']?.firstWhereOrNull(
      (r) => _pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'audio',
    );

    final now = DateTime.now();
    num kbps(num bitsPerSecond) =>
        (bitsPerSecond <= 0) ? 0 : (bitsPerSecond / 1000.0);

    // compute simple bitrate deltas (kbps) since last sample
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
    final vidRxBytes = _pickInt(inV?.values ?? {}, ['bytesReceived']);
    final vidRxFps = _pick(inV?.values ?? {}, ['framesPerSecond']);
    final vidW = _pick(inV?.values ?? {}, ['frameWidth']);
    final vidH = _pick(inV?.values ?? {}, ['frameHeight']);
    final vidLost = _pick(inV?.values ?? {}, ['packetsLost']);
    final vidJitter = _pick(inV?.values ?? {}, ['jitter']); // seconds

    // video TX
    final vidTxBytes = _pickInt(outV?.values ?? {}, ['bytesSent']);
    final vidTxFps = _pick(outV?.values ?? {}, ['framesPerSecond']);

    // audio RX/TX
    final audRxBytes = _pickInt(inA?.values ?? {}, ['bytesReceived']);
    final audLost = _pick(inA?.values ?? {}, ['packetsLost']);
    final audJitter = _pick(inA?.values ?? {}, ['jitter']); // seconds
    final audTxBytes = _pickInt(outA?.values ?? {}, ['bytesSent']);

    final vidRxKbps = deltaKbps(vidRxBytes, _lastVidRxBytes);
    final vidTxKbps = deltaKbps(vidTxBytes, _lastVidTxBytes);
    final audRxKbps = deltaKbps(audRxBytes, _lastAudRxBytes);
    final audTxKbps = deltaKbps(audTxBytes, _lastAudTxBytes);

    // update last sample
    _lastStatsAt = now;
    _lastVidRxBytes = vidRxBytes ?? _lastVidRxBytes;
    _lastVidTxBytes = vidTxBytes ?? _lastVidTxBytes;
    _lastAudRxBytes = audRxBytes ?? _lastAudRxBytes;
    _lastAudTxBytes = audTxBytes ?? _lastAudTxBytes;

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
