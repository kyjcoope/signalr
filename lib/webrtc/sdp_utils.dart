library;

extension SdpUtils on String {

  String get withCompatibilityFixes {
    var sdp = this;
    if (sdp._containsH264) sdp = sdp._withH264Fixes;
    sdp = sdp._withoutExtmapAllowMixed;
    sdp = sdp._withRtcpMux;
    return sdp;
  }

  String get withAnswerFixes {
    var sdp = this;
    sdp = sdp.replaceAll('a=setup:actpass', 'a=setup:active');
    if (sdp._containsH264) sdp = sdp._withH264ProfileFix;
    sdp = sdp._withoutExtmapAllowMixed;
    return sdp;
  }

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

  bool get _containsH264 =>
      RegExp(r'\bH264/90000\b', caseSensitive: false).hasMatch(this);

  String get _withoutExtmapAllowMixed =>
      replaceAll(RegExp(r'a=extmap-allow-mixed\r?\n?'), '');

  String get _withH264Fixes => _withH264ProfileFix._withH264FmtpFix;

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

  String get _withH264FmtpFix {
    final lines = split(RegExp(r'\r?\n'));
    final lineBreak = contains('\r\n') ? '\r\n' : '\n';
    final result = <String>[];
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
      final isMedia = section.first.startsWith('m=');
      if (!isMedia) {
        result.addAll(section);
        continue;
      }

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

String? resolveMid(String? sdpMid, int? mline, Map<int, String> mlineToMid) {
  if (sdpMid != null && sdpMid.isNotEmpty) return sdpMid;
  if (mline != null) return mlineToMid[mline];
  return null;
}
