/// JSON-RPC 2.0 message building utilities.
///
/// Provides clean, idiomatic Dart methods for constructing JSON-RPC messages.
library;

/// JSON-RPC 2.0 version constant.
const String jsonRpcVersion = '2.0';

/// JSON-RPC 2.0 message builder.
abstract final class JsonRpc {
  /// Create a JSON-RPC request message.
  ///
  /// ```dart
  /// final msg = JsonRpc.request(
  ///   method: 'register',
  ///   id: '1',
  ///   params: {'authorization': ''},
  /// );
  /// ```
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

  /// Create a JSON-RPC notification (no id, no response expected).
  ///
  /// ```dart
  /// final msg = JsonRpc.notification(
  ///   method: 'trickle',
  ///   params: {'session': sessionId, 'candidate': candidateData},
  /// );
  /// ```
  static Map<String, dynamic> notification({
    required String method,
    Map<String, dynamic> params = const {},
  }) => {'jsonrpc': jsonRpcVersion, 'method': method, 'params': params};

  /// Create a JSON-RPC response message.
  ///
  /// ```dart
  /// final msg = JsonRpc.response(
  ///   id: inviteId,
  ///   result: {'session': sessionId, 'answer': answerSdp},
  /// );
  /// ```
  static Map<String, dynamic> response({
    required String id,
    required Map<String, dynamic> result,
  }) => {'jsonrpc': jsonRpcVersion, 'result': result, 'id': id};
}

/// Extension for parsing JSON-RPC messages.
extension JsonRpcParsing on Map<String, dynamic> {
  /// Check if this is a valid JSON-RPC 2.0 message.
  bool get isJsonRpc => this['jsonrpc'] == jsonRpcVersion;

  /// Check if this is a request/notification (has method).
  bool get isRequest => containsKey('method');

  /// Check if this is a response (has result or error, no method).
  bool get isResponse =>
      (containsKey('result') || containsKey('error')) && !containsKey('method');

  /// Check if this is a success response (has result, no error).
  bool get isSuccessResponse => containsKey('result') && !containsKey('method');

  /// Check if this is an error response (has error, no method).
  bool get isErrorResponse => containsKey('error') && !containsKey('method');

  /// Get the method name (for requests/notifications).
  String? get method => this['method'] as String?;

  /// Get the message id.
  String? get id => this['id']?.toString();

  /// Get the params (for requests/notifications).
  Map<String, dynamic>? get params => this['params'] as Map<String, dynamic>?;

  /// Get the result (for success responses).
  Map<String, dynamic>? get result => this['result'] as Map<String, dynamic>?;

  /// Get the error object (for error responses).
  Map<String, dynamic>? get error => this['error'] as Map<String, dynamic>?;

  /// Get nested param value safely.
  T? param<T>(String key) => params?[key] as T?;

  /// Get nested result value safely.
  T? resultValue<T>(String key) => result?[key] as T?;
}
