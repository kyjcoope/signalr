import 'dart:async';

import '../utils/logger.dart';

import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
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
    final d = double.tryParse(val.toString());
    if (d != null) return d;
  }
  return null;
}

int? _pickInt(Map v, List<String> keys) => _pickNum(v, keys)?.round();

String _dash(String s) => (s.isEmpty || s == '?' || s == '—') ? '—' : s;
String _fmtKbps(num bps) => bps <= 0 ? '—' : '${(bps / 1000).round()}kbps';
String _fmtOptKbps(double? k) =>
    (k == null || k <= 0) ? '—' : '${k.round()}kbps';
String _fmtMs(double? s) => s == null ? '—' : '${(s * 1000).round()}ms';
String _fmtFps(double? fps) {
  if (fps == null || fps <= 0) return '—';
  final i = fps.round();
  return ((fps - i).abs() < 0.05) ? '$i' : fps.toStringAsFixed(1);
}

String _fmtRes(String w, String h) {
  final ws = _dash(w), hs = _dash(h);
  return (ws == '—' && hs == '—') ? '—' : '${ws}x$hs';
}

String _pad(String s) => s.padRight(6);

StatsReport? _findRtp(
  Map<String, List<StatsReport>>? byType,
  String type,
  String mediaKind, {
  bool requireLocal = false,
}) {
  return byType?[type]?.firstWhereOrNull(
    (r) {
      final kind =
          _pick(r.values, ['kind', 'mediaType']).toLowerCase();
      if (kind != mediaKind) return false;
      if (requireLocal &&
          _pick(r.values, ['remoteSource'], fallback: 'false') != 'false') {
        return false;
      }
      return true;
    },
  );
}

class WebRtcVideoStats extends Equatable {
  const WebRtcVideoStats({
    this.rfps = 0,
    this.dfps = 0,
    this.width = 0,
    this.height = 0,
    this.bitrateKbps = 0,
    this.codec = '',
  });

  final double rfps;
  final double dfps;
  final int width;
  final int height;
  final double bitrateKbps;
  final String codec;

  static const WebRtcVideoStats empty = WebRtcVideoStats();

  @override
  String toString() =>
      'WebRtcVideoStats(rx=${rfps.toStringAsFixed(1)}fps, '
      'dec=${dfps.toStringAsFixed(1)}fps, '
      '${width}x$height, ${bitrateKbps.toStringAsFixed(0)}kbps, '
      'codec=$codec)';

  @override
  List<Object?> get props => [rfps, dfps, width, height, bitrateKbps, codec];
}

class WebRtcStatsMonitor {
  WebRtcStatsMonitor({
    this.interval = const Duration(seconds: 1),
    String tag = '',
  }) : _tag = tag;

  final Duration interval;
  void Function()? onStatsUpdated;

  static const int _detailedLogInterval = 5;

  Timer? _timer;
  String _tag;
  DateTime? _lastPollTime;
  int? _lastFramesDecoded;
  int? _lastVidRxBytes, _lastVidTxBytes, _lastAudRxBytes, _lastAudTxBytes;
  WebRtcVideoStats _latestStats = WebRtcVideoStats.empty;
  int _pollCount = 0;
  bool _pollInProgress = false;

  void setTag(String tag) => _tag = tag;

  void start(RTCPeerConnection pc) {
    stop();
    _lastPollTime = DateTime.now();
    _timer = Timer.periodic(interval, (_) => _poll(pc));
    _poll(pc);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  WebRtcVideoStats get latestStats => _latestStats;

  void dispose() {
    stop();
    _lastPollTime = null;
    _lastFramesDecoded = null;
    _lastVidRxBytes = null;
    _lastVidTxBytes = null;
    _lastAudRxBytes = null;
    _lastAudTxBytes = null;
    _pollCount = 0;
    _pollInProgress = false;
    _latestStats = WebRtcVideoStats.empty;
  }

  Future<void> logOnce(RTCPeerConnection pc) => _poll(pc);

  Future<void> _poll(RTCPeerConnection pc) async {
    if (_pollInProgress) return;
    _pollInProgress = true;
    _pollCount++;

    try {
      final reports = await pc.getStats();
      if (reports.isEmpty) return;

      final byId = {for (final r in reports) r.id: r};
      final byType = <String, List<StatsReport>>{};
      for (final r in reports) {
        (byType[r.type] ??= []).add(r);
      }

      final inV = _findRtp(byType, 'inbound-rtp', 'video', requireLocal: true);
      final outV = _findRtp(byType, 'outbound-rtp', 'video');
      final inA = _findRtp(byType, 'inbound-rtp', 'audio', requireLocal: true);
      final outA = _findRtp(byType, 'outbound-rtp', 'audio');

      final now = DateTime.now();
      final dt = _lastPollTime != null
          ? now.difference(_lastPollTime!).inMilliseconds / 1000.0
          : 0.0;

      final vidRxBytes = _pickInt(inV?.values ?? {}, ['bytesReceived']);
      final vidTxBytes = _pickInt(outV?.values ?? {}, ['bytesSent']);
      final audRxBytes = _pickInt(inA?.values ?? {}, ['bytesReceived']);
      final audTxBytes = _pickInt(outA?.values ?? {}, ['bytesSent']);

      double? vidRxKbps = _deltaKbps(vidRxBytes, _lastVidRxBytes, dt);
      double? vidTxKbps = _deltaKbps(vidTxBytes, _lastVidTxBytes, dt);
      double? audRxKbps = _deltaKbps(audRxBytes, _lastAudRxBytes, dt);
      double? audTxKbps = _deltaKbps(audTxBytes, _lastAudTxBytes, dt);

      _updateVideoStats(byId, inV, vidRxKbps ?? 0, dt);
      if (_pollCount % _detailedLogInterval == 0) {
        _logDetailed(byId, byType, inV, outV, inA, outA, vidRxKbps, vidTxKbps, audRxKbps, audTxKbps);
      }

      _lastPollTime = now;
      _lastVidRxBytes = vidRxBytes ?? _lastVidRxBytes;
      _lastVidTxBytes = vidTxBytes ?? _lastVidTxBytes;
      _lastAudRxBytes = audRxBytes ?? _lastAudRxBytes;
      _lastAudTxBytes = audTxBytes ?? _lastAudTxBytes;
    } catch (e) {
      Logger().warn('$_tag Stats poll error: $e');
    } finally {
      _pollInProgress = false;
    }
  }

  double? _deltaKbps(int? now, int? last, double dt) {
    if (now == null || last == null || dt <= 0) return null;
    return ((now - last) * 8.0 / dt) / 1000.0;
  }

  void _updateVideoStats(
    Map<String, StatsReport> byId,
    StatsReport? inV,
    double bitrateKbps,
    double dt,
  ) {
    if (inV == null) return;

    final v = inV.values;
    final receivedFps = _pickNum(v, ['framesPerSecond']) ?? 0;
    final width = _pickInt(v, ['frameWidth']) ?? 0;
    final height = _pickInt(v, ['frameHeight']) ?? 0;
    final framesDecoded = _pickInt(v, ['framesDecoded']);

    final codecId = _pick(v, ['codecId'], fallback: '');
    String codec = '';
    if (codecId.isNotEmpty) {
      final codecReport = byId[codecId];
      if (codecReport != null) {
        final mime = _pick(codecReport.values, ['mimeType'], fallback: '');
        codec = mime.contains('/') ? mime.split('/').last : mime;
      }
    }

    double decodedFps = 0;
    if (dt > 0) {
      if (framesDecoded != null && _lastFramesDecoded != null) {
        decodedFps = (framesDecoded - _lastFramesDecoded!) / dt;
      } else if (receivedFps > 0) {
        decodedFps = receivedFps.toDouble();
      }
    }

    _lastFramesDecoded = framesDecoded;

    _latestStats = WebRtcVideoStats(
      rfps: receivedFps.toDouble(),
      dfps: decodedFps,
      width: width,
      height: height,
      bitrateKbps: bitrateKbps,
      codec: codec,
    );
    onStatsUpdated?.call();
  }

  void _logDetailed(
    Map<String, StatsReport> byId,
    Map<String, List<StatsReport>> byType,
    StatsReport? inV,
    StatsReport? outV,
    StatsReport? inA,
    StatsReport? outA,
    double? vidRxKbps,
    double? vidTxKbps,
    double? audRxKbps,
    double? audTxKbps,
  ) {
    final transport = byType['transport']?.firstWhereOrNull(
      (r) =>
          _pick(r.values, ['selectedCandidatePairId'], fallback: '').isNotEmpty,
    );
    final pairId = transport != null
        ? _pick(transport.values, ['selectedCandidatePairId'], fallback: '')
        : null;

    final pair = (pairId != null && pairId.isNotEmpty)
        ? byId[pairId]
        : byType['candidate-pair']?.firstWhereOrNull(
            (r) =>
                _pick(r.values, ['state']).toLowerCase() == 'succeeded' ||
                _pick(r.values, ['selected', 'googActiveConnection']) ==
                    'true' ||
                _pick(r.values, ['nominated']) == 'true',
          );

    if (pair == null) {
      Logger().info('$_tag WebRTC: awaiting selected candidate-pair…');
      return;
    }

    final localId = _pick(pair.values, ['localCandidateId']);
    final remoteId = _pick(pair.values, ['remoteCandidateId']);
    final local = byId[localId], remote = byId[remoteId];
    if (local == null || remote == null) {
      Logger().info(
        '$_tag WebRTC: candidate reports missing (local=$localId remote=$remoteId)',
      );
      return;
    }

    final lv = local.values, rv = remote.values, pv = pair.values;

    final iceState = _pick(pv, ['state', 'writable', 'googWritable']);
    final rttSec = _pickNum(pv, ['currentRoundTripTime', 'googRtt']) ?? 0;
    final outBps = _pickNum(pv, ['availableOutgoingBitrate']) ?? 0;
    final inBps = _pickNum(pv, ['availableIncomingBitrate']) ?? 0;
    final consent = _pickInt(pv, ['consentRequestsSent']) ?? 0;

    final lType = _pick(lv, ['candidateType', 'googCandidateType']);
    final lProto = _pick(lv, ['protocol', 'transport']);
    final lIp = _pick(lv, ['ip', 'address', 'ipAddress']);
    final lPort = _pick(lv, ['port', 'portNumber']);
    final rType = _pick(rv, ['candidateType', 'googCandidateType']);
    final rProto = _pick(rv, ['protocol', 'transport']);
    final rIp = _pick(rv, ['ip', 'address', 'ipAddress']);
    final rPort = _pick(rv, ['port', 'portNumber']);

    final tv = transport?.values ?? {};
    final dtls = _pick(tv, ['dtlsState', 'tlsCipher']);
    final tls = _pick(tv, ['tlsVersion']);
    final srtp = _pick(tv, ['srtpCipher']);
    final role = _pick(tv, ['iceRole']);
    final ufrag = _pick(tv, ['iceLocalUsernameFragment', 'localCertificateId']);

    final vidRxFps = _pickNum(inV?.values ?? {}, ['framesPerSecond']);
    final vidW = _pick(inV?.values ?? {}, ['frameWidth']);
    final vidH = _pick(inV?.values ?? {}, ['frameHeight']);
    final vidLost = _pick(inV?.values ?? {}, ['packetsLost']);
    final vidJit = _pickNum(inV?.values ?? {}, ['jitter']);
    final vidTxFps = _pickNum(outV?.values ?? {}, ['framesPerSecond']);

    final audLost = _pick(inA?.values ?? {}, ['packetsLost']);
    final audJit = _pickNum(inA?.values ?? {}, ['jitter']);

    final t = _tag.isNotEmpty ? '$_tag ' : '';
    final buf = StringBuffer()
      ..writeln('$t WebRTC status:')
      ..writeln(
        '${_pad("ICE")} | state: ${iceState.padRight(9)} | rtt: ${_fmtMs(rttSec)} '
        '| out: ${_fmtKbps(outBps)} | in: ${_fmtKbps(inBps)} | consent: $consent',
      )
      ..writeln(
        '${_pad("PATH")} | local: ${_dash(lType)}/${_dash(lProto)} $lIp:$lPort  ⇄  '
        'remote: ${_dash(rType)}/${_dash(rProto)} $rIp:$rPort',
      )
      ..writeln(
        '${_pad("DTLS")} | ${_dash(dtls)} | tls: ${_dash(tls)} '
        '| srtp: ${_dash(srtp)} | role: ${_dash(role)} | ufrag: ${_dash(ufrag)}',
      )
      ..writeln(
        '${_pad("VIDEO")} | rx: ${_fmtOptKbps(vidRxKbps)} '
        '| res: ${_fmtRes(vidW, vidH)} @${_fmtFps(vidRxFps)} '
        '| lost: ${_dash(vidLost)} | jit: ${_fmtMs(vidJit)} '
        '| tx: ${_fmtOptKbps(vidTxKbps)} @${_fmtFps(vidTxFps)}',
      )
      ..writeln(
        '${_pad("AUDIO")} | rx: ${_fmtOptKbps(audRxKbps)} '
        '| lost: ${_dash(audLost)} | jit: ${_fmtMs(audJit)} '
        '| tx: ${_fmtOptKbps(audTxKbps)}',
      );
    Logger().debug(buf.toString());
  }
}
