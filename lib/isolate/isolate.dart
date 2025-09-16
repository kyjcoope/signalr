import 'dart:isolate';

import 'package:flutter_webrtc/bindings/native_bindings.dart';

import 'dart:developer' as dev;

class LogPrinterIsolate {
  static Isolate? _isolate;
  static SendPort? _sendPort;

  static Future<void> start() async {
    if (_isolate != null) return;
    final readyPort = ReceivePort();
    _isolate = await Isolate.spawn<_IsolateInitMessage>(
      _entry,
      _IsolateInitMessage(readyPort.sendPort),
      debugName: 'LogPrinterIsolate',
    );
    _sendPort = await readyPort.first as SendPort;
  }

  static void send(String value) {
    _sendPort?.send(value);
  }

  static void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }

  static void _entry(_IsolateInitMessage init) {
    final inbox = ReceivePort();
    // Send back the SendPort so main isolate can talk to us.
    init.readyPort.send(inbox.sendPort);

    inbox.listen((msg) async {
      if (msg is String) {
        final stream = await WebRTCMediaStreamer().videoFramesFrom(msg);
        stream.listen((frame) {
          dev.log('frame: ${frame.buffer.length}', name: 'LogPrinterIsolate');
        });
      }
    });
  }
}

class _IsolateInitMessage {
  _IsolateInitMessage(this.readyPort);
  final SendPort readyPort;
}

// Convenience top-level helper
void logFromIsolate(String message) => LogPrinterIsolate.send(message);
