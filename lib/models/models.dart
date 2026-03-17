class Device {
  final String guid;
  final String sourceType;
  final String name;

  Device({required this.guid, required this.sourceType, required this.name});

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    guid: json['guid'] as String,
    sourceType: json['sourceType'] as String,
    name: json['name'] as String,
  );

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'sourceType': sourceType,
    'name': name,
  };
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
    'WhereClause': whereClause,
    'ArgsTypes': argsTypes,
    'arguments': arguments,
    'DisplayProperties': displayProperties,
    'SortColumnName': sortColumnName,
    'PageSize': pageSize,
    'PageNumber': pageNumber,
    'CountOnly': countOnly,
    'Sort': sort,
    'InStatementOperator': inStatementOperator,
    'InStatementPropertyName': inStatementPropertyName,
    'InStatementValues': inStatementValues,
  };
}
