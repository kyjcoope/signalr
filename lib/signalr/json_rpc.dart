library;

const String jsonRpcVersion = '2.0';

abstract final class JsonRpc {
  static Map<String, dynamic> request({
    required String method,
    required String id,
    Map<String, dynamic> params = const {},
  }) => {
    'jsonrpc': jsonRpcVersion,
    'method': method,
    'params': params,
    'id': id,
  };

  static Map<String, dynamic> notification({
    required String method,
    Map<String, dynamic> params = const {},
  }) => {'jsonrpc': jsonRpcVersion, 'method': method, 'params': params};

  static Map<String, dynamic> response({
    required String id,
    required Map<String, dynamic> result,
  }) => {'jsonrpc': jsonRpcVersion, 'result': result, 'id': id};
}

extension JsonRpcParsing on Map<String, dynamic> {
  bool get isJsonRpc => this['jsonrpc'] == jsonRpcVersion;
  bool get isRequest => containsKey('method');
  bool get isResponse =>
      (containsKey('result') || containsKey('error')) && !containsKey('method');
  bool get isSuccessResponse => containsKey('result') && !containsKey('method');
  bool get isErrorResponse => containsKey('error') && !containsKey('method');

  String? get method => this['method'] as String?;
  String? get id => this['id']?.toString();
  Map<String, dynamic>? get params => this['params'] as Map<String, dynamic>?;
  Map<String, dynamic>? get result => this['result'] as Map<String, dynamic>?;
  Map<String, dynamic>? get error => this['error'] as Map<String, dynamic>?;

  T? param<T>(String key) => params?[key] as T?;
  T? resultValue<T>(String key) => result?[key] as T?;
}
