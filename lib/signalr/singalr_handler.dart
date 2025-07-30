import 'dart:convert';
import 'dart:developer' as dev;

import 'package:signalr_netcore/hub_connection.dart';
import 'package:signalr_netcore/hub_connection_builder.dart';

import 'signalr_message.dart';

class SignalRHandler {
  SignalRHandler({
    required this.onConnect,
    required this.onRegister,
    required this.onInvite,
    required this.onTrickle,
    required this.signalServiceUrl,
  }) : _connection = HubConnectionBuilder()
           .withUrl(signalServiceUrl)
           .withAutomaticReconnect(retryDelays: [0, 5000, 5000, 5000])
           .build();
  void Function(ConnectResponse) onConnect;
  void Function(RegisterResponse) onRegister;
  void Function(InviteResponse) onInvite;
  void Function(TrickleMessage) onTrickle;
  final String signalServiceUrl;
  final HubConnection _connection;

  String get connectionId => _connection.connectionId ?? '';

  void shutdown(List<String> sessions) async {
    for (var session in sessions) {
      await _connection.invoke('LeaveSession', args: [session]);
    }
    await _connection.stop();
  }

  Future<void> setupSignaling() async {
    _connection.on(
      'error',
      (arguments) => dev.log('WebRTC SignalR Error: $arguments'),
    );
    _connection.onreconnecting(
      ({error}) => dev.log('reconnecting with $error'),
    );
    _connection.onreconnected(
      ({connectionId}) => dev.log('reconnected with $connectionId'),
    );
    _connection.onclose(({error}) => dev.log('Connection closed. $error'));
    _connection.on('register', _onRegister);
    _connection.on('connect', _onConnect);
    _connection.on('invite', _onInvite);
    _connection.on('trickle', _onTrickle);

    try {
      await _connection.start();
      dev.log('✅ SignalR connection started successfully');
      dev.log('Connection State: ${_connection.state}');
      dev.log('Connection ID: ${_connection.connectionId}');
    } catch (e) {
      dev.log('❌ SignalR connection failed: $e');
      rethrow;
    }

    dev.log('send register');
    await sendRegister('');
  }

  void _onRegister(List<Object?>? arguments) {
    dev.log('Received register message: $arguments');
    if (arguments == null || arguments.isEmpty) return;
    dev.log(
      'Received register message: ${arguments.length}',
      name: 'SignalRHandler._onRegister',
    );
    dev.log('Received register message: ${arguments.length}');
    final data = jsonDecode(arguments[0].toString());
    onRegister(RegisterResponse.fromJson(data));
  }

  void _onConnect(arguments) {
    if (arguments == null || arguments.isEmpty) return;

    final data = arguments[0] is Map
        ? arguments[0]
        : jsonDecode(arguments[0].toString());
    dev.log('Received connect message: $data');
    onConnect(ConnectResponse.fromJson(data));
  }

  void _onInvite(arguments) {
    if (arguments == null || arguments.isEmpty) return;
    final data = arguments[0] is Map
        ? arguments[0]
        : jsonDecode(arguments[0].toString());
    final inviteResponse = InviteResponse.fromJson(data);
    dev.log('Received invite message: $data');
    onInvite(inviteResponse);
  }

  void _onTrickle(arguments) {
    if (arguments == null || arguments.isEmpty) return;
    final data = arguments[0] is Map
        ? arguments[0]
        : jsonDecode(arguments[0].toString());

    final trickleResponse = TrickleMessage.fromJson(data);
    dev.log('Received trickle message: $data');
    onTrickle(trickleResponse);
  }

  Future<void> _send(SignalRMessage message) async {
    dev.log('Sending SignalR message: ${message.toJson()}');
    await _connection
        .invoke('SendMessage', args: [message.toJson()])
        .catchError((error) {
          dev.log('Error sending SignalR message:', error: error);
          return false;
        });
  }

  Future<void> sendRegister(String auth) async => await _send(
    RegisterRequest(authorization: auth, id: _connection.connectionId ?? ''),
  );

  Future<void> sendConnect(ConnectRequest request) async =>
      await _send(request);

  Future<void> sendInvite(InviteRequest request) async => await _send(request);

  Future<void> sendInviteAnswer(InviteAnswerMessage request) async =>
      await _send(request);

  Future<void> sendTrickle(TrickleMessage request) async =>
      await _send(request);
}
