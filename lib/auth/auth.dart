import 'dart:convert';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:signalr/config.dart';
import 'package:signalr/models/models.dart';

// Top-level function for Isolate execution
Map<String, Device> _parseDevices(String responseBody) {
  final List list = jsonDecode(responseBody);
  return {
    for (var d in list)
      d['GUID']: Device(
        guid: d['GUID'],
        sourceType: d['SourceType'],
        name: d['Name'],
      ),
  };
}

class AuthService {
  String? _sessionId;
  Map<String, Device> devices = {};

  String? get sessionId => _sessionId;

  Future<void> login(UserLogin login) async {
    dev.log('Logging in: ${login.username}');
    try {
      final request = MultipartRequest(
        'POST',
        Uri.parse('https://$url/api/Authenticate/Login'),
      );

      request.fields.addAll(
        login.toJson().map((k, v) => MapEntry(k, v.toString())),
      );

      final response = await request.send();
      final body = await response.stream.bytesToString();

      if (response.statusCode != 200) throw Exception('Login failed: $body');

      _sessionId = response.headers['session-id'];
      dev.log('Session ID: $_sessionId');

      if (_sessionId != null) {
        devices = await _fetchDevices(url, _sessionId!);
      }
    } catch (e) {
      dev.log('Login error: $e');
      rethrow;
    }
  }

  Future<Map<String, Device>> _fetchDevices(String host, String sid) async {
    const payload = ObjectRequest(
      typeFullName:
          'Jci.Osp.Objects.DeviceFleetManagement.UnifiedDeviceDataView',
      loadCollection: false,
      pageSize: 5000,
      pageNumber: 1,
    );

    final body = await _fetchCollection(host, sid, payload);
    return body != null ? await compute(_parseDevices, body) : {};
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
      dev.log('Fetch error: $e');
      return null;
    }
  }
}
