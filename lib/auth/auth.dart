import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:signalr/config.dart';
import 'package:signalr/models/models.dart';
import 'package:signalr/utils/logger.dart';

// Top-level function for Isolate execution
Map<String, Device> _parseDevices(String responseBody) {
  final List list = jsonDecode(responseBody);
  return {
    for (var d in list)
      if (d['GUID'] != null)
        d['GUID']: Device(
          guid: d['GUID'],
          sourceType: d['DeviceType'] ?? d['ClassType'] ?? 'Unknown',
          name: d['Name'] ?? d['DisplayName'] ?? 'Unnamed',
        ),
  };
}

class AuthService {
  String? _sessionId;
  Map<String, Device> devices = {};

  String? get sessionId => _sessionId;

  Future<void> login(UserLogin login) async {
    Logger().info('Logging in: ${login.username}');
    try {
      final request = MultipartRequest(
        'POST',
        Uri.parse('https://$url/api/Authenticate/LoginSSO'),
      );

      request.fields.addAll(
        login.toJson().map((k, v) => MapEntry(k, v.toString())),
      );

      final response = await request.send();
      final body = await response.stream.bytesToString();

      if (response.statusCode != 200) throw Exception('Login failed: $body');

      _sessionId = response.headers['session-id'];
      Logger().info('Session ID: $_sessionId');
    } catch (e) {
      Logger().error('Login error: $e');
      rethrow;
    }
  }

  /// Re-fetch devices from the API using the existing session.
  Future<void> fetchDevices() async {
    if (_sessionId == null) throw StateError('Not logged in');
    devices = await _fetchDevices(url, _sessionId!);
    Logger().info('Fetched ${devices.length} devices');
  }

  Future<Map<String, Device>> _fetchDevices(String host, String sid) async {
    const cloudPayload = ObjectRequest(
      typeFullName: 'Jci.Osp.Objects.OspVideo.OSPVMSCloudCamera',
      loadCollection: false,
      pageSize: 1000,
      pageNumber: 1,
      // whereClause: 'Name LIKE ?',
      // arguments: ['%adam%'],
      displayProperties: ['GUID', 'Name', 'ClassType'],
    );
    const gatewayPayload = ObjectRequest(
      typeFullName: 'Jci.Osp.Objects.OspVideo.OSPVMSGatewayCamera',
      loadCollection: false,
      pageSize: 1000,
      pageNumber: 1,
      displayProperties: ['GUID', 'Name', 'ClassType'],
      // whereClause: 'Name LIKE ?',
      // arguments: ['%adam%'],
    );

    Logger().info('Cloud payload: ${cloudPayload.toJson()}');
    Logger().info('Gateway payload: ${gatewayPayload.toJson()}');

    // Fetch both camera types in parallel
    Logger().info('Fetching cloud + gateway cameras...');
    final results = await Future.wait([
      _fetchCollection(host, sid, cloudPayload).then((v) {
        Logger().info(
          'Cloud cameras response: ${v != null ? "${v.length} chars" : "null"}',
        );
        return v;
      }),
      _fetchCollection(host, sid, gatewayPayload).then((v) {
        Logger().info(
          'Gateway cameras response: ${v != null ? "${v.length} chars" : "null"}',
        );
        return v;
      }),
    ]);

    // Parse each response on an isolate and merge
    Logger().info('Parsing camera responses...');
    final merged = <String, Device>{};

    if (results[0] != null) {
      final cloudDevices = await compute(_parseDevices, results[0]!);
      Logger().info('Parsed ${cloudDevices.length} cloud cameras');
      merged.addAll(cloudDevices);
    }
    if (results[1] != null) {
      final gatewayDevices = await compute(_parseDevices, results[1]!);
      Logger().info('Parsed ${gatewayDevices.length} gateway cameras');
      merged.addAll(gatewayDevices);
    }

    Logger().info('Total cameras: ${merged.length}');
    return merged;
  }

  Future<String?> _fetchCollection(
    String host,
    String sid,
    ObjectRequest payload,
  ) async {
    try {
      final request = MultipartRequest(
        'POST',
        Uri.parse('https://$host/api/Objects/GetAllWithCriteria'),
      );
      request.headers['Session-Id'] = sid;

      payload.toJson().forEach((key, value) {
        if (value == null) return;
        if (value is List) {
          for (var i = 0; i < value.length; i++) {
            request.fields['$key[$i]'] = value[i].toString();
          }
        } else {
          request.fields[key] = value.toString();
        }
      });

      final response = await request.send();
      return response.statusCode == 200
          ? await response.stream.bytesToString()
          : null;
    } catch (e) {
      Logger().error('Fetch error: $e');
      return null;
    }
  }
}
