import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../utils/logger.dart';
import 'sdp_utils.dart';

/// Detects the negotiated video codec from SDP or WebRTC stats.
///
/// Attempts SDP-based detection first (fast, approximate),
/// then falls back to stats-based detection (accurate, requires connection).
class CodecDetector {
  CodecDetector({this.onCodecResolved, this.maxAttempts = 6, this.tag = ''});

  /// Called when the video codec is determined.
  final void Function(String codec)? onCodecResolved;

  /// Maximum stats polling attempts.
  final int maxAttempts;

  /// Tag for logging.
  final String tag;

  String? _detectedCodec;
  int _attempts = 0;
  Timer? _retryTimer;

  /// The detected codec, if available.
  String? get codec => _detectedCodec;

  /// Whether a codec has been detected.
  bool get hasCodec => _detectedCodec != null;

  /// Reset detector state.
  void reset() {
    _detectedCodec = null;
    _attempts = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Dispose of resources.
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SDP-based Detection
  // ═══════════════════════════════════════════════════════════════════════════

  /// Try to extract codec from SDP (fast, but approximate).
  void extractFromSdp(String sdp) {
    if (hasCodec) return;

    final codec = sdp.primaryVideoCodec;
    if (codec != null) {
      _setCodec(codec, 'SDP');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Stats-based Detection
  // ═══════════════════════════════════════════════════════════════════════════

  /// Schedule stats-based codec detection.
  ///
  /// This is more accurate but requires an established connection.
  void scheduleStatsDetection(
    RTCPeerConnection pc, {
    Duration delay = const Duration(milliseconds: 700),
  }) {
    if (hasCodec) return;
    _retryTimer = Timer(delay, () => _detectFromStats(pc));
  }

  Future<void> _detectFromStats(RTCPeerConnection pc) async {
    if (hasCodec) return;
    if (_attempts >= maxAttempts) return;

    _attempts++;

    try {
      final reports = await pc.getStats();
      if (reports.isEmpty) {
        _scheduleRetry(pc);
        return;
      }

      final byId = {for (final r in reports) r.id: r};

      // Find inbound video RTP stream
      final inboundVideo = reports.where((r) {
        if (r.type.toLowerCase() != 'inbound-rtp') return false;
        final kind = (r.values['kind'] ?? r.values['mediaType'] ?? '')
            .toString()
            .toLowerCase();
        return kind == 'video';
      }).toList();

      if (inboundVideo.isEmpty) {
        _scheduleRetry(pc);
        return;
      }

      // Get codec from first inbound video stream
      for (final inbound in inboundVideo) {
        final codecId = inbound.values['codecId'] ?? inbound.values['codec_id'];
        if (codecId == null || !byId.containsKey(codecId)) continue;

        final codecReport = byId[codecId]!;
        final mime =
            (codecReport.values['mimeType'] ??
                    codecReport.values['codec'] ??
                    '')
                .toString();

        if (mime.isEmpty) continue;

        final upper = mime.contains('/')
            ? mime.split('/').last.toUpperCase()
            : mime.toUpperCase();
        if (upper.isNotEmpty) {
          _setCodec(upper, 'Stats');
          return;
        }
      }

      _scheduleRetry(pc);
    } catch (e) {
      Logger().info('$tag Codec detection error: $e');
      _scheduleRetry(pc);
    }
  }

  void _scheduleRetry(RTCPeerConnection pc) {
    if (hasCodec || _attempts >= maxAttempts) return;
    _retryTimer = Timer(const Duration(seconds: 1), () => _detectFromStats(pc));
  }

  void _setCodec(String codec, String source) {
    _detectedCodec = codec;
    _retryTimer?.cancel();
    Logger().info('$tag Selected video codec ($source): $codec');
    onCodecResolved?.call(codec);
  }
}
