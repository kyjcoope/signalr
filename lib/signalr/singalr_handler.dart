import 'dart:convert';
import 'dart:developer' as dev;
import 'package:signalr_netcore/hub_connection.dart';
import 'package:signalr_netcore/hub_connection_builder.dart';
import 'signalr_message.dart';

class SignalRHandler {
  SignalRHandler({required this.signalServiceUrl, required this.onMessage})
    : _connection =
          HubConnectionBuilder()
              .withUrl(signalServiceUrl)
              .withAutomaticReconnect(retryDelays: [0, 2000, 5000])
              .build();

  final String signalServiceUrl;
  final void Function(String method, dynamic data) onMessage;
  final HubConnection _connection;

  String get connectionId => _connection.connectionId ?? '';

  Future<void> connect() async {
    _connection.onclose(({error}) => dev.log('SignalR Closed: $error'));
    _connection.on('ReceivedSignalingMessage', _handleIncoming);

    for (final event in ['connect', 'invite', 'trickle']) {
      _connection.on(event, (args) => _handleDirect(event, args));
    }

    await _connection.start();
    dev.log('SignalR Connected: ${_connection.connectionId}');

    await send(RegisterRequest(authorization: '', id: '1'));
  }

  void _handleIncoming(List<Object?>? args) {
    if (args == null || args.isEmpty) return;
    final json = jsonDecode(args[0].toString());

    if (json['method'] != null) {
      onMessage(json['method'], json);
    } else if (json['result'] != null) {
      onMessage('connect', json);
    }
  }

  void _handleDirect(String method, List<Object?>? args) {
    if (args == null || args.isEmpty) return;
    final data = args[0] is Map ? args[0] : jsonDecode(args[0].toString());
    onMessage(method, data);
  }

  Future<void> send(SignalRMessage message) async {
    try {
      await _connection.invoke('SendMessage', args: [message.toJson()]);
    } catch (e) {
      dev.log('Send Error: $e');
    }
  }

  Future<void> leaveSession(String sessionId) async {
    try {
      await _connection.invoke('LeaveSession', args: [sessionId]);
    } catch (_) {}
  }

  Future<void> shutdown() => _connection.stop();
}
