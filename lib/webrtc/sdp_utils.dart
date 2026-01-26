/// SDP parsing and manipulation utilities using Dart extension methods.
library;

/// Extension methods for SDP string manipulation.
extension SdpUtils on String {
  /// Check if this SDP contains H264 codec.
  bool get containsH264 =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(this);

  /// Apply H264 profile fix for compatibility.
  ///
  /// Normalizes profile-level-id to baseline and adds level-asymmetry-allowed.
  String get withH264ProfileFix {
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
    // Find video section
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

    // Get payload types from m-line
    final mLine = videoSection.split(RegExp(r'\r?\n')).first;
    final parts = mLine.split(' ');
    if (parts.length < 4) return null;

    final pts = parts
        .skip(3)
        .where((p) => RegExp(r'^\d+$').hasMatch(p))
        .toList();
    if (pts.isEmpty) return null;

    // Find codec for first non-helper payload type
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

  /// Munge SDP for H264 compatibility if needed.
  String get withCompatibilityFixes {
    if (containsH264) {
      return withH264ProfileFix;
    }
    return this;
  }

  /// Force DTLS active role in the answer SDP.
  ///
  /// This fixes "hanging DTLS" where both sides wait for the other to send
  /// ClientHello. By forcing 'active', Flutter will initiate the handshake.
  ///
  /// Only apply this to ANSWER SDPs, not offers.
  String get withDtlsActiveRole {
    // Replace actpass with active to force Flutter to be the DTLS client
    // This is critical for IoT cameras that expect the client to initiate
    return replaceAll('a=setup:actpass', 'a=setup:active');
  }

  /// Apply all answer-specific compatibility fixes.
  ///
  /// Use this for local answer SDP before sending to remote peer.
  String get withAnswerFixes {
    var sdp = this;
    // Force active DTLS role
    sdp = sdp.withDtlsActiveRole;
    // Apply H264 fixes if needed
    if (sdp.containsH264) {
      sdp = sdp.withH264ProfileFix;
    }
    return sdp;
  }

  /// Extract the video track ID from the SDP.
  ///
  /// Looks for `a=msid:<stream_id> <track_id>` or `a=ssrc:<ssrc> msid:<stream_id> <track_id>`.
  String? get videoTrackId {
    // 1. Try a=msid at media level
    final sections = split(RegExp(r'\r?\nm='));
    for (final raw in sections) {
      final sec = raw.startsWith('m=') ? raw : 'm=$raw';
      if (!sec.startsWith(RegExp(r'm=video'))) continue;

      // Check for a=msid line
      final msidMatch = RegExp(r'a=msid:\S+ (\S+)').firstMatch(sec);
      if (msidMatch != null) {
        return msidMatch.group(1);
      }

      // Check for a=ssrc msid line
      final ssrcMatch = RegExp(r'a=ssrc:\d+ msid:\S+ (\S+)').firstMatch(sec);
      if (ssrcMatch != null) {
        return ssrcMatch.group(1);
      }
    }
    return null;
  }

  /// Inject a parameter into the a=fmtp line for the video codec.
  ///
  /// Used to pass custom data (like x-track-id) to the native decoder factory.
  String addFmtpParam(String param, String value) {
    var sdp = this;
    // Find the primary video payload type (usually 96 or similar)
    // We'll just target all H264 fmtp lines for robustness
    final h264Ids = RegExp(
      r'a=rtpmap:(\d+) H264',
    ).allMatches(sdp).map((m) => m.group(1)).toSet();

    for (final pt in h264Ids) {
      if (!sdp.contains('a=fmtp:$pt')) {
        // If no fmtp line exists, this is rare for H264 but possible.
        // We might want to add one, but for now let's skip to avoid breaking things.
        continue;
      }

      // Append strictly if not already present
      sdp = sdp.replaceAllMapped(RegExp('a=fmtp:$pt (.*)'), (match) {
        final current = match.group(1)!;
        if (current.contains('$param=')) return match.group(0)!;
        return 'a=fmtp:$pt $current;$param=$value';
      });
    }
    return sdp;
  }
}

/// Resolve a mid from either the provided sdpMid or the mline index.
String? resolveMid(String? sdpMid, int? mline, Map<int, String> mlineToMid) {
  if (sdpMid != null && sdpMid.isNotEmpty) return sdpMid;
  if (mline != null) return mlineToMid[mline];
  return null;
}
