class Device {
  final String guid;
  final String sourceType;
  final String name;

  Device({required this.guid, required this.sourceType, required this.name});
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
