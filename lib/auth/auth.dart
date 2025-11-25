import 'dart:convert';

import 'package:http/http.dart';
import 'dart:developer' as dev;

import 'package:signalr/config.dart';

Map<String, Device> devices = {};

Future<void> authLogin(UserLogin login) async {
  var endpoint = '/api/Authenticate/LoginSSO';
  late StreamedResponse response;
  print('Auth Login Endpoint -> https://$url$endpoint');
  print('Logging in user: ${login.username}');
  print('login: ${login.toJson()}');
  try {
    final request = MultipartRequest(
      'POST',
      Uri.parse('https://$url$endpoint'),
    );

    for (final f in login.toJson().entries) {
      request.fields[f.key] = f.value;
    }

    response = await request.send();

    dev.log('response: ${await response.stream.bytesToString()}');
    if (response.statusCode != 200) {
      throw Exception('Failed to login user: ${login.username}');
    }
  } catch (e) {
    print('Error during login: $e');
  }
  final sessionId = response.headers['session-id'];
  dev.log('Session ID: $sessionId');

  final res = await fetchDevices(url, sessionId ?? '');
  devices = res;
}

Future<Map<String, Device>> fetchDevices(
  String hostUrl,
  String sessionId,
) async {
  final payload = ObjectRequest(
    typeFullName: 'Jci.Osp.Objects.DeviceFleetManagement.UnifiedDeviceDataView',
    loadCollection: false,
    //displayProperties: ['Name', 'Description', 'Status', 'Id'],
    pageSize: 5000,
    pageNumber: 1,
    //whereClause: 'SourceType LIKE ?',
    //arguments: ['%Jci.Osp.Objects.OspVideo.OSPCamera%', '%ConnectedPro.Common.VideoEdge4.Objects.VideoEdge4VideoCamera%', '%'],
  );

  final response = await fetchCollection(hostUrl, sessionId, payload);

  final List devices = jsonDecode(response ?? '');
  Map<String, Device> deviceMap = {};
  for (var device in devices) {
    final guid = device['GUID'] as String;
    final sourceType = device['SourceType'] as String;
    final name = device['Name'] as String;
    final devObj = Device(guid: guid, sourceType: sourceType, name: name);
    deviceMap.putIfAbsent(devObj.guid, () => devObj);
  }

  return deviceMap;
}

Future<String?> fetchCollection(
  String hostUrl,
  String sessionId,
  ObjectRequest payload,
) async {
  final endpoint = '/api/Objects/GetAllWithCriteria';

  late StreamedResponse response;
  String body = '';

  try {
    final request = MultipartRequest(
      'POST',
      Uri.parse('https://$url$endpoint'),
    );
    request.headers['Session-Id'] = sessionId;

    for (final f in payload.toJson().entries.where((e) => e.value != null)) {
      if (f.value is! List) {
        request.fields[f.key] = f.value.toString();
      } else {
        for (final e in (f.value as List).asMap().entries) {
          request.fields['${f.key}[${e.key}]'] = e.value.toString();
        }
      }
    }
    response = await request.send();
    body = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      return null;
    }
  } catch (e) {
    print('Error fetching devices: $e');
    return null;
  }
  return body;
}

class UserLogin {
  final String username;
  final String password;
  final String clientName;
  final String clientID;
  final String clientVersion;
  final String grantType;
  final String scopes;
  final String clientId_;

  UserLogin({
    required this.username,
    required this.password,
    required this.clientName,
    required this.clientID,
    required this.clientVersion,
    required this.grantType,
    required this.scopes,
    required this.clientId_,
  });

  Map<String, String> toJson() => {
    'username': username,
    'password': password,
    'ClientName': clientName,
    'ClientID': clientID,
    'ClientVersion': clientVersion,
    'Client_Id': clientId_,
    'Grant_Type': grantType,
    'scopes': scopes,
  };
}

class ObjectRequest {
  final String typeFullName;
  final bool loadCollection;
  final String? whereClause;
  final List<String>? argsTypes;
  final List<String>? arguments;
  final List<String>? displayProperties;
  final String? sortColumnName;
  final int? pageSize;
  final int pageNumber;
  final bool countOnly;
  final String? sort;
  final String? inStatementOperator;
  final String? inStatementPropertyName;
  final List<String>? inStatementValues;

  const ObjectRequest({
    required this.typeFullName,
    required this.loadCollection,
    this.whereClause,
    this.argsTypes,
    this.arguments,
    this.displayProperties,
    this.sortColumnName,
    this.pageSize,
    this.pageNumber = 1,
    this.countOnly = false,
    this.sort,
    this.inStatementOperator,
    this.inStatementPropertyName,
    this.inStatementValues,
  });

  Map<String, Object?> toJson() => {
    'TypeFullName': typeFullName,
    'LoadCollection': loadCollection,
    if (whereClause != null) 'WhereClause': whereClause,
    if (argsTypes != null) 'ArgsTypes': argsTypes,
    if (arguments != null) 'Arguments': arguments,
    if (displayProperties != null) 'DisplayProperties': displayProperties,
    if (sortColumnName != null) 'SortColumnName': sortColumnName,
    if (pageSize != null) 'PageSize': pageSize,
    'PageNumber': pageNumber,
    'CountOnly': countOnly,
    if (sort != null) 'Sort': sort,
    if (inStatementOperator != null) 'InStatementOperator': inStatementOperator,
    if (inStatementPropertyName != null)
      'InStatementPropertyName': inStatementPropertyName,
    if (inStatementValues != null) 'InStatementValues': inStatementValues,
  };
}

void printJson(String json) {
  final decoded = jsonDecode(json);
  final prettyString = const JsonEncoder.withIndent('  ').convert(decoded);
  dev.log(prettyString);
}

class Device {
  final String guid;
  final String sourceType;
  final String name;

  Device({required this.guid, required this.sourceType, required this.name});
}
