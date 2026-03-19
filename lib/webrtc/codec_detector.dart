import '../utils/logger.dart';
import 'sdp_utils.dart';

class CodecDetector {
  CodecDetector({this.onCodecResolved, this.tag = ''});

  final void Function(String codec)? onCodecResolved;
  final String tag;

  String? _detectedCodec;

  String? get codec => _detectedCodec;
  bool get hasCodec => _detectedCodec != null;

  void reset() {
    _detectedCodec = null;
  }

  void dispose() {}

  void extractFromSdp(String sdp) {
    if (hasCodec) return;

    final codec = sdp.primaryVideoCodec;
    if (codec != null) {
      _setCodec(codec, 'SDP');
    }
  }

  void resolveFromStats(String codec) {
    if (hasCodec || codec.isEmpty) return;
    _setCodec(codec, 'Stats');
  }

  void _setCodec(String codec, String source) {
    _detectedCodec = codec;
    Logger().info('$tag Selected video codec ($source): $codec');
    onCodecResolved?.call(codec);
  }
}
