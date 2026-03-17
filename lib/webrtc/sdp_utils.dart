/// SDP parsing and manipulation utilities using Dart extension methods.
library;

/// Extension methods for SDP string manipulation.
extension SdpUtils on String {
  // ═══════════════════════════════════════════════════════════════════════════
  // SDP Fix Pipelines
  // ═══════════════════════════════════════════════════════════════════════════

  /// Apply all offer compatibility fixes before `setRemoteDescription`.
  ///
  /// Fixes known issues that cause `createAnswer()` to fail on Android
  /// or other strict WebRTC implementations:
  /// - Normalizes H264 profile + injects missing fmtp parameters
  /// - Strips `a=extmap-allow-mixed` (crashes older Android WebRTC)
  /// - Ensures `a=rtcp-mux` on audio/video m-lines (required by unified-plan)
  String get withCompatibilityFixes {
    var sdp = this;
    if (sdp._containsH264) sdp = sdp._withH264Fixes;
    sdp = sdp._withoutExtmapAllowMixed;
    sdp = sdp._withRtcpMux;
    return sdp;
  }

  /// Apply all answer-specific compatibility fixes before sending to server.
  ///
  /// - Forces DTLS active role (Flutter initiates handshake)
  /// - Normalizes H264 profile for cross-platform compatibility
  /// - Strips `a=extmap-allow-mixed` for IoT camera compatibility
  String get withAnswerFixes {
    var sdp = this;
    // Force DTLS active role — fixes deadlocks with IoT cameras that
    // expect the client to send ClientHello first.
    sdp = sdp.replaceAll('a=setup:actpass', 'a=setup:active');
    if (sdp._containsH264) sdp = sdp._withH264ProfileFix;
    sdp = sdp._withoutExtmapAllowMixed;
    return sdp;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SDP Parsing
  // ═══════════════════════════════════════════════════════════════════════════

  /// Build mapping from m-line index to mid attribute.
  Map<int, String> get mlineToMidMapping {
    final lines = split(RegExp(r'\r?\n'));
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

  /// Extract the primary video codec from this SDP.
  ///
  /// Returns the first non-helper codec (excludes RTX, ULPFEC, RED, etc).
  String? get primaryVideoCodec {
    final sections = split(RegExp(r'\r?\nm='));
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

    final pts = parts
        .skip(3)
        .where((p) => RegExp(r'^\d+$').hasMatch(p))
        .toList();
    if (pts.isEmpty) return null;

    final lines = split(RegExp(r'\r?\n'));
    const helperCodecs = {'RTX', 'ULPFEC', 'RED', 'FLEXFEC-03'};

    for (final pt in pts) {
      final rtpmapLine = lines.firstWhere(
        (l) => l.startsWith('a=rtpmap:$pt '),
        orElse: () => '',
      );
      if (rtpmapLine.isEmpty) continue;

      final codecPart = rtpmapLine.split(' ').skip(1).firstOrNull ?? '';
      final codecName = codecPart.split('/').first.toUpperCase();

      if (!helperCodecs.contains(codecName)) {
        return codecName;
      }
    }

    return null;
  }

  /// Extract the primary video codec from each video m-section.
  ///
  /// Returns a list where index 0 = codec of the 1st video m-line, etc.
  List<String> get videoCodecsPerSection {
    final sections = split(RegExp(r'\r?\nm='));
    final result = <String>[];
    const helperCodecs = {'RTX', 'ULPFEC', 'RED', 'FLEXFEC-03'};

    for (final raw in sections) {
      final sec = raw.startsWith('m=') ? raw : 'm=$raw';
      if (!sec.startsWith(RegExp(r'm=video'))) continue;

      final secLines = sec.split(RegExp(r'\r?\n'));
      final mLine = secLines.first;
      final parts = mLine.split(' ');
      if (parts.length < 4) {
        result.add('?');
        continue;
      }

      final pts = parts
          .skip(3)
          .where((p) => RegExp(r'^\d+$').hasMatch(p))
          .toList();

      String codec = '?';
      for (final pt in pts) {
        final rtpmapLine = secLines.firstWhere(
          (l) => l.startsWith('a=rtpmap:$pt '),
          orElse: () => '',
        );
        if (rtpmapLine.isEmpty) continue;

        final codecPart = rtpmapLine.split(' ').skip(1).firstOrNull ?? '';
        final codecName = codecPart.split('/').first.toUpperCase();

        if (!helperCodecs.contains(codecName)) {
          codec = codecName;
          break;
        }
      }
      result.add(codec);
    }

    return result;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Private Fix Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  bool get _containsH264 =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(this);

  /// Strip `a=extmap-allow-mixed` — crashes older Android WebRTC (pre-M87).
  String get _withoutExtmapAllowMixed =>
      replaceAll(RegExp(r'a=extmap-allow-mixed\r?\n?'), '');

  /// All H264 fixes: normalize profile + inject missing fmtp.
  String get _withH264Fixes => _withH264ProfileFix._withH264FmtpFix;

  /// Normalize profile-level-id to Constrained Baseline (42e01f).
  String get _withH264ProfileFix {
    var sdp = replaceAllMapped(
      RegExp(r'profile-level-id=([0-9A-Fa-f]{6})'),
      (_) => 'profile-level-id=42e01f',
    );

    if (!sdp.toLowerCase().contains('level-asymmetry-allowed')) {
      sdp = sdp.replaceFirst(
        'packetization-mode=1;',
        'level-asymmetry-allowed=1;packetization-mode=1;',
      );
    }

    return sdp;
  }

  /// Inject missing `a=fmtp` lines for H264 payload types.
  ///
  /// Scans and patches per media section (between `m=` boundaries) so each
  /// video m-line gets its own H264 fmtp. Payload type numbers are scoped
  /// per m-line in SDP, so global scanning would mis-inject when multiple
  /// `m=video` sections reuse the same PT numbers.
  ///
  /// Android's native WebRTC requires fmtp with profile-level-id to determine
  /// codec compatibility. Without it, `createAnswer()` rejects the video
  /// m-line entirely (m=video 0). Web/Windows assume baseline defaults.
  String get _withH264FmtpFix {
    final lines = split(RegExp(r'\r?\n'));
    final lineBreak = contains('\r\n') ? '\r\n' : '\n';
    final result = <String>[];

    // Collect lines into media sections
    final sections = <List<String>>[];
    var current = <String>[];

    for (final line in lines) {
      if (line.startsWith('m=') && current.isNotEmpty) {
        sections.add(current);
        current = <String>[];
      }
      current.add(line);
    }
    if (current.isNotEmpty) sections.add(current);

    for (final section in sections) {
      // Only patch video/audio sections that contain H264
      final isMedia = section.first.startsWith('m=');
      if (!isMedia) {
        result.addAll(section);
        continue;
      }

      // Find H264 PTs and existing fmtp PTs within this section
      final h264Pts = <String>{};
      final existingFmtpPts = <String>{};

      for (final line in section) {
        final rtpMatch = RegExp(
          r'^a=rtpmap:(\d+)\s+H264/90000',
          caseSensitive: false,
        ).firstMatch(line);
        if (rtpMatch != null) h264Pts.add(rtpMatch.group(1)!);

        final fmtpMatch = RegExp(r'^a=fmtp:(\d+)\s+').firstMatch(line);
        if (fmtpMatch != null) existingFmtpPts.add(fmtpMatch.group(1)!);
      }

      final missingFmtp = h264Pts.difference(existingFmtpPts);
      if (missingFmtp.isEmpty) {
        result.addAll(section);
        continue;
      }

      // Insert fmtp after corresponding rtpmap lines within this section
      for (final line in section) {
        result.add(line);
        for (final pt in missingFmtp) {
          if (line.startsWith('a=rtpmap:$pt ') &&
              RegExp(r'H264/90000', caseSensitive: false).hasMatch(line)) {
            result.add(
              'a=fmtp:$pt profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1',
            );
          }
        }
      }
    }

    return result.join(lineBreak);
  }

  /// Ensure all audio/video m-lines have `a=rtcp-mux`.
  String get _withRtcpMux {
    final lines = split(RegExp(r'\r?\n'));
    final lineBreak = contains('\r\n') ? '\r\n' : '\n';
    final result = <String>[];
    var inMediaSection = false;
    var hasRtcpMux = false;
    var sectionStartIndex = -1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('m=')) {
        if (inMediaSection && !hasRtcpMux && sectionStartIndex >= 0) {
          result.insert(sectionStartIndex + 1, 'a=rtcp-mux');
        }
        inMediaSection =
            line.startsWith('m=audio') || line.startsWith('m=video');
        hasRtcpMux = false;
        sectionStartIndex = result.length;
      }

      if (line.startsWith('a=rtcp-mux')) hasRtcpMux = true;
      result.add(line);
    }

    if (inMediaSection && !hasRtcpMux && sectionStartIndex >= 0) {
      result.insert(sectionStartIndex + 1, 'a=rtcp-mux');
    }

    return result.join(lineBreak);
  }
}

/// Resolve a mid from either the provided sdpMid or the mline index.
String? resolveMid(String? sdpMid, int? mline, Map<int, String> mlineToMid) {
  if (sdpMid != null && sdpMid.isNotEmpty) return sdpMid;
  if (mline != null) return mlineToMid[mline];
  return null;
}
