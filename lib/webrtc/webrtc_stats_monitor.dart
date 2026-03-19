import 'dart:async';

import '../utils/logger.dart';

import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

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

// ═══════════════════════════════════════════════════════════════════════════════
// Data Model
// ═══════════════════════════════════════════════════════════════════════════════

/// Snapshot of video stats for a single inbound WebRTC stream.
class WebRtcVideoStats extends Equatable {
  const WebRtcVideoStats({
    this.rfps = 0,
    this.dfps = 0,
    this.width = 0,
    this.height = 0,
    this.bitrateKbps = 0,
    this.codec = '',
  });

  /// Received frames per second as reported by the browser / native stack.
  final double rfps;

  /// Decoded frames per second (computed from framesDecoded delta).
  final double dfps;

  /// Frame width in pixels.
  final int width;

  /// Frame height in pixels.
  final int height;

  /// Incoming video bitrate in kbps (computed from bytesReceived delta).
  final double bitrateKbps;

  /// Codec name (e.g. 'H264', 'VP8', 'VP9', 'AV1').
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

// ═══════════════════════════════════════════════════════════════════════════════
// Unified Stats Monitor
// ═══════════════════════════════════════════════════════════════════════════════

/// Polls `RTCPeerConnection.getStats()` once per interval and:
///   1. Always updates [statsNotifier] with [WebRtcVideoStats] for the UI.
///   2. Writes a detailed debug log block (filtered by the global [Logger] level).
class WebRtcStatsMonitor {
  WebRtcStatsMonitor({
    this.interval = const Duration(seconds: 1),
    String tag = '',
  }) : _tag = tag;

  final Duration interval;

  /// Listen to this notifier for live stats updates.
  final ValueNotifier<WebRtcVideoStats> statsNotifier = ValueNotifier(
    WebRtcVideoStats.empty,
  );

  /// Optional callback fired on each poll with the latest stats snapshot.
  void Function(WebRtcVideoStats stats)? onStats;

  Timer? _timer;
  String _tag;

  // delta tracking
  DateTime? _lastPollTime;
  int? _lastFramesDecoded;
  int? _lastVidRxBytes, _lastVidTxBytes, _lastAudRxBytes, _lastAudTxBytes;
  bool _pollInProgress = false;

  /// Set the debug‑log tag.
  void setTag(String tag) => _tag = tag;

  /// Start periodic polling.
  void start(RTCPeerConnection pc) {
    stop();
    _timer = Timer.periodic(interval, (_) => _poll(pc));
  }

  /// Stop periodic polling (does not clear last values).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Reset everything (call on disconnect / close).
  void dispose() {
    stop();
    _lastPollTime = null;
    _lastFramesDecoded = null;
    _lastVidRxBytes = null;
    _lastVidTxBytes = null;
    _lastAudRxBytes = null;
    _lastAudTxBytes = null;
    _pollInProgress = false;
    statsNotifier.value = WebRtcVideoStats.empty;
  }

  /// One‑shot: poll once, update notifier, optionally log.
  Future<void> logOnce(RTCPeerConnection pc) => _poll(pc);

  // ═══════════════════════════════════════════════════════════════════════════
  // Core poll
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _poll(RTCPeerConnection pc) async {
    // Guard: skip if a previous poll is still in progress (can happen on
    // slower devices where getStats() takes longer than the timer interval).
    if (_pollInProgress) return;
    _pollInProgress = true;
    try {
      final reports = await pc.getStats();
      if (reports.isEmpty) return;

      final byId = {for (final r in reports) r.id: r};
      final byType = <String, List<StatsReport>>{};
      for (final r in reports) {
        (byType[r.type] ??= []).add(r);
      }

      // ── Video stats (always) ──────────────────────────────────────────────
      final vidRxBytes = _updateVideoStats(byId, byType);

      // ── Verbose logging (filtered by global log level) ─────────────────
      _logDetailed(byId, byType);

      // Update _lastVidRxBytes AFTER logging so dKbps sees the correct delta.
      _lastVidRxBytes = vidRxBytes ?? _lastVidRxBytes;
    } catch (e) {
      // Peer connection may have been disposed — log and move on.
      Logger().warn('$_tag Stats poll error: $e');
    } finally {
      _pollInProgress = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // UI stats
  // ═══════════════════════════════════════════════════════════════════════════

  /// Updates the UI stats notifier. Returns the current vidRxBytes so the
  /// caller can defer the [_lastVidRxBytes] update until after logging.
  int? _updateVideoStats(
    Map<String, StatsReport> byId,
    Map<String, List<StatsReport>> byType,
  ) {
    final inV = byType['inbound-rtp']?.firstWhereOrNull(
      (r) =>
          _pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'video' &&
          _pick(r.values, ['remoteSource'], fallback: 'false') == 'false',
    );
    if (inV == null) return null;

    final v = inV.values;
    final receivedFps = _pickNum(v, ['framesPerSecond']) ?? 0;
    final width = _pickInt(v, ['frameWidth']) ?? 0;
    final height = _pickInt(v, ['frameHeight']) ?? 0;
    final framesDecoded = _pickInt(v, ['framesDecoded']);
    final bytesReceived = _pickInt(v, ['bytesReceived']);
    final now = DateTime.now();

    // Resolve codec name via codecId -> codec report -> mimeType
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
    double bitrateKbps = 0;

    if (_lastPollTime != null) {
      final dt = now.difference(_lastPollTime!).inMilliseconds / 1000.0;
      if (dt > 0) {
        if (framesDecoded != null && _lastFramesDecoded != null) {
          decodedFps = (framesDecoded - _lastFramesDecoded!) / dt;
        }
        if (bytesReceived != null && _lastVidRxBytes != null) {
          bitrateKbps =
              ((bytesReceived - _lastVidRxBytes!) * 8.0 / dt) / 1000.0;
        }
      }
    }

    _lastPollTime = now;
    _lastFramesDecoded = framesDecoded;

    final newStats = WebRtcVideoStats(
      rfps: receivedFps.toDouble(),
      dfps: decodedFps,
      width: width,
      height: height,
      bitrateKbps: bitrateKbps,
      codec: codec,
    );
    statsNotifier.value = newStats;
    onStats?.call(newStats);

    return bytesReceived;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Verbose debug log
  // ═══════════════════════════════════════════════════════════════════════════

  void _logDetailed(
    Map<String, StatsReport> byId,
    Map<String, List<StatsReport>> byType,
  ) {
    // transport / selected candidate‑pair
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

    // local / remote candidates
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

    // ICE
    final iceState = _pick(pv, ['state', 'writable', 'googWritable']);
    final rttSec = _pickNum(pv, ['currentRoundTripTime', 'googRtt']) ?? 0;
    final outBps = _pickNum(pv, ['availableOutgoingBitrate']) ?? 0;
    final inBps = _pickNum(pv, ['availableIncomingBitrate']) ?? 0;
    final consent = _pickInt(pv, ['consentRequestsSent']) ?? 0;

    // PATH
    final lType = _pick(lv, ['candidateType', 'googCandidateType']);
    final lProto = _pick(lv, ['protocol', 'transport']);
    final lIp = _pick(lv, ['ip', 'address', 'ipAddress']);
    final lPort = _pick(lv, ['port', 'portNumber']);
    final rType = _pick(rv, ['candidateType', 'googCandidateType']);
    final rProto = _pick(rv, ['protocol', 'transport']);
    final rIp = _pick(rv, ['ip', 'address', 'ipAddress']);
    final rPort = _pick(rv, ['port', 'portNumber']);

    // DTLS
    final tv = transport?.values ?? {};
    final dtls = _pick(tv, ['dtlsState', 'tlsCipher']);
    final tls = _pick(tv, ['tlsVersion']);
    final srtp = _pick(tv, ['srtpCipher']);
    final role = _pick(tv, ['iceRole']);
    final ufrag = _pick(tv, ['iceLocalUsernameFragment', 'localCertificateId']);

    // RTP reports
    final inV = byType['inbound-rtp']?.firstWhereOrNull(
      (r) =>
          _pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'video' &&
          _pick(r.values, ['remoteSource'], fallback: 'false') == 'false',
    );
    final outV = byType['outbound-rtp']?.firstWhereOrNull(
      (r) => _pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'video',
    );
    final inA = byType['inbound-rtp']?.firstWhereOrNull(
      (r) =>
          _pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'audio' &&
          _pick(r.values, ['remoteSource'], fallback: 'false') == 'false',
    );
    final outA = byType['outbound-rtp']?.firstWhereOrNull(
      (r) => _pick(r.values, ['kind', 'mediaType']).toLowerCase() == 'audio',
    );

    // delta kbps helper (uses _lastPollTime which was just updated above)
    double? dKbps(int? now, int? last) {
      if (now == null || last == null || _lastPollTime == null) return null;
      // We already updated _lastPollTime in _updateVideoStats, so use a 1‑sec
      // approximation for the log.
      final dt = interval.inMilliseconds / 1000.0;
      if (dt <= 0) return null;
      return ((now - last) * 8.0 / dt) / 1000.0;
    }

    // video
    final vidRxBytes = _pickInt(inV?.values ?? {}, ['bytesReceived']);
    final vidRxFps = _pickNum(inV?.values ?? {}, ['framesPerSecond']);
    final vidW = _pick(inV?.values ?? {}, ['frameWidth']);
    final vidH = _pick(inV?.values ?? {}, ['frameHeight']);
    final vidLost = _pick(inV?.values ?? {}, ['packetsLost']);
    final vidJit = _pickNum(inV?.values ?? {}, ['jitter']);
    final vidRxKbps = dKbps(vidRxBytes, _lastVidRxBytes);
    final vidTxBytes = _pickInt(outV?.values ?? {}, ['bytesSent']);
    final vidTxFps = _pickNum(outV?.values ?? {}, ['framesPerSecond']);
    final vidTxKbps = dKbps(vidTxBytes, _lastVidTxBytes);

    // audio
    final audRxBytes = _pickInt(inA?.values ?? {}, ['bytesReceived']);
    final audLost = _pick(inA?.values ?? {}, ['packetsLost']);
    final audJit = _pickNum(inA?.values ?? {}, ['jitter']);
    final audTxBytes = _pickInt(outA?.values ?? {}, ['bytesSent']);
    final audRxKbps = dKbps(audRxBytes, _lastAudRxBytes);
    final audTxKbps = dKbps(audTxBytes, _lastAudTxBytes);

    // update deltas for next log cycle
    _lastVidTxBytes = vidTxBytes ?? _lastVidTxBytes;
    _lastAudRxBytes = audRxBytes ?? _lastAudRxBytes;
    _lastAudTxBytes = audTxBytes ?? _lastAudTxBytes;

    // format & emit
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
