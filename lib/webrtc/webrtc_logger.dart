import 'dart:async';
import 'dart:developer' as dev;
import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

String _pick(Map v, List<String> keys, {String fallback = '—'}) {
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

String _dashIfUnknown(String s) =>
    (s.isEmpty || s == '?' || s == '—') ? '—' : s;

String _fmtKbpsNum(num bitsPerSecond) {
  if (bitsPerSecond <= 0) return '—';
  final kb = (bitsPerSecond / 1000).round();
  return '${kb}kbps';
}

String _fmtOptKbps(double? kbps) =>
    (kbps == null || kbps <= 0) ? '—' : '${kbps.round()}kbps';

String _fmtMsFromSeconds(double? s) =>
    (s == null) ? '—' : '${(s * 1000).round()}ms';

String _fmtFps(double? fps) {
  if (fps == null || fps <= 0) return '—';
  final i = fps.round();
  return ((fps - i).abs() < 0.05) ? '$i' : fps.toStringAsFixed(1);
}

String _fmtRes(String w, String h) {
  final ws = _dashIfUnknown(w);
  final hs = _dashIfUnknown(h);
  if (ws == '—' && hs == '—') return '—';
  return '${ws}x$hs';
}

String _padLabel(String s) => s.padRight(6);

class WebRtcLogger {
  WebRtcLogger({bool enabled = true, String tag = ''})
    : _enabled = enabled,
      _tag = tag;

  Timer? _timer;
  DateTime? _lastStatsAt;
  int? _lastVidRxBytes, _lastVidTxBytes, _lastAudRxBytes, _lastAudTxBytes;
  bool _enabled;
  String _tag;

  void setEnabled(bool v) {
    _enabled = v;
    if (!v) stop();
  }

  void setTag(String tag) => _tag = tag;

  void start(
    RTCPeerConnection pc, {
    Duration interval = const Duration(seconds: 1),
    String? tag,
  }) {
    if (!_enabled) return;
    if (tag != null) _tag = tag;
    stop();
    _timer = Timer.periodic(interval, (_) => logOnce(pc, tag: _tag));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> logOnce(RTCPeerConnection pc, {String? tag}) async {
    if (!_enabled) return;

    final reports = await pc.getStats();
    if (reports.isEmpty) {
      dev.log('${tag ?? _tag} WebRTC: no stats yet');
      return;
    }

    final byId = {for (final r in reports) r.id: r};
    final byType = <String, List<StatsReport>>{};
    for (final r in reports) {
      (byType[r.type] ??= []).add(r);
    }

    // transport / selected candidate-pair
    final transport = byType['transport']?.firstWhereOrNull(
      (r) =>
          _pick(r.values, ['selectedCandidatePairId'], fallback: '').isNotEmpty,
    );
    final pairId =
        (transport != null)
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
      dev.log('${tag ?? _tag} WebRTC: awaiting selected candidate-pair…');
      return;
    }

    // local/remote candidates
    final localId = _pick(pair.values, ['localCandidateId']);
    final remoteId = _pick(pair.values, ['remoteCandidateId']);
    final local = byId[localId];
    final remote = byId[remoteId];
    if (local == null || remote == null) {
      dev.log(
        '${tag ?? _tag} WebRTC: candidate reports missing (local=$localId remote=$remoteId)',
      );
      return;
    }

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
    final outBps = _pickNum(pv, ['availableOutgoingBitrate']) ?? 0;
    final inBps = _pickNum(pv, ['availableIncomingBitrate']) ?? 0;
    final consentSent = _pickInt(pv, ['consentRequestsSent']) ?? 0;

    // DTLS/TLS/SRTP
    final tv = transport?.values ?? {};
    final dtlsState = _pick(tv, ['dtlsState', 'tlsCipher']);
    final tlsVersion = _pick(tv, ['tlsVersion']);
    final srtpCipher = _pick(tv, ['srtpCipher']);
    final iceRole = _pick(tv, ['iceRole']);
    final ufrag = _pick(tv, ['iceLocalUsernameFragment', 'localCertificateId']);

    // RTP health
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
    final vidRxFpsNum = _pickNum(inV?.values ?? {}, ['framesPerSecond']);
    final vidW = _pick(inV?.values ?? {}, ['frameWidth']);
    final vidH = _pick(inV?.values ?? {}, ['frameHeight']);
    final vidLost = _pick(inV?.values ?? {}, ['packetsLost']);
    final vidJitterS = _pickNum(inV?.values ?? {}, ['jitter']);

    // video TX
    final vidTxBytes = _pickInt(outV?.values ?? {}, ['bytesSent']);
    final vidTxFpsNum = _pickNum(outV?.values ?? {}, ['framesPerSecond']);

    // audio RX/TX
    final audRxBytes = _pickInt(inA?.values ?? {}, ['bytesReceived']);
    final audLost = _pick(inA?.values ?? {}, ['packetsLost']);
    final audJitterS = _pickNum(inA?.values ?? {}, ['jitter']);
    final audTxBytes = _pickInt(outA?.values ?? {}, ['bytesSent']);

    final vidRxKbps = deltaKbps(vidRxBytes, _lastVidRxBytes);
    final vidTxKbps = deltaKbps(vidTxBytes, _lastVidTxBytes);
    final audRxKbps = deltaKbps(audRxBytes, _lastAudRxBytes);
    final audTxKbps = deltaKbps(audTxBytes, _lastAudTxBytes);

    _lastStatsAt = now;
    _lastVidRxBytes = vidRxBytes ?? _lastVidRxBytes;
    _lastVidTxBytes = vidTxBytes ?? _lastVidTxBytes;
    _lastAudRxBytes = audRxBytes ?? _lastAudRxBytes;
    _lastAudTxBytes = audTxBytes ?? _lastAudTxBytes;

    final tagStr = (tag ?? _tag).isNotEmpty ? '${tag ?? _tag} ' : '';
    final iceLine =
        '${_padLabel("ICE")} | state: ${iceState.padRight(9)} | rtt: ${_fmtMsFromSeconds(rttSeconds)} '
        '| out: ${_fmtKbpsNum(outBps)} | in: ${_fmtKbpsNum(inBps)} | consent: $consentSent';
    final pathLine =
        '${_padLabel("PATH")} | local: ${_dashIfUnknown(localType)}/${_dashIfUnknown(localProto)} '
        '$localIp:$localPort  ⇄  remote: ${_dashIfUnknown(remoteType)}/${_dashIfUnknown(remoteProto)} '
        '$remoteIp:$remotePort';
    final dtlsLine =
        '${_padLabel("DTLS")} | ${_dashIfUnknown(dtlsState)} | tls: ${_dashIfUnknown(tlsVersion)} '
        '| srtp: ${_dashIfUnknown(srtpCipher)} | role: ${_dashIfUnknown(iceRole)} | ufrag: ${_dashIfUnknown(ufrag)}';
    final videoLine =
        '${_padLabel("VIDEO")} | rx: ${_fmtOptKbps(vidRxKbps)} '
        '| res: ${_fmtRes(vidW, vidH)} @${_fmtFps(vidRxFpsNum)} '
        '| lost: ${_dashIfUnknown(vidLost)} | jit: ${_fmtMsFromSeconds(vidJitterS)} '
        '| tx: ${_fmtOptKbps(vidTxKbps)} @${_fmtFps(vidTxFpsNum)}';
    final audioLine =
        '${_padLabel("AUDIO")} | rx: ${_fmtOptKbps(audRxKbps)} '
        '| lost: ${_dashIfUnknown(audLost)} | jit: ${_fmtMsFromSeconds(audJitterS)} '
        '| tx: ${_fmtOptKbps(audTxKbps)}';

    final block =
        StringBuffer()
          ..writeln('$tagStr┌──────────────── WebRTC status ────────────────')
          ..writeln(iceLine)
          ..writeln(pathLine)
          ..writeln(dtlsLine)
          ..writeln(videoLine)
          ..writeln(audioLine)
          ..write('$tagStr└────────────────────────────────────────────────');

    dev.log(block.toString());
  }
}
