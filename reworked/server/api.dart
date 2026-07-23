enum LicenseType { enterprise, pro, restricted, unlicensed, badLicense }

extension LicenseTypeExt on LicenseType {
  LicenseFlags get asLicenseFlags => switch (this) {
    LicenseType.enterprise => LicenseFlags()..enterprise = true,
    LicenseType.pro => LicenseFlags(),
    LicenseType.restricted => LicenseFlags()..restricted = true,
    LicenseType.unlicensed => LicenseFlags()..unlicensed = true,
    LicenseType.badLicense => LicenseFlags()..badLicense = true,
  };
}

extension LicenseFlagsExt on LicenseFlags {
  LicenseType toLicenseType() {
    if (badLicense) return LicenseType.badLicense;
    if (unlicensed) return LicenseType.unlicensed;
    if (restricted) return LicenseType.restricted;
    if (enterprise) return LicenseType.enterprise;
    return LicenseType.pro;
  }
}

LicenseType mapLicenseType(LicenseFlags grpcLicense) =>
    grpcLicense.toLicenseType();

enum ServerApiFailureKind {
  invalidArgument,
  invalidRegistration,
  unauthorized,
  unavailable,
  timeout,
  unknown,
}

class ServerApiException implements Exception {
  final ServerApiFailureKind kind;
  final String operation;
  final GrpcError cause;

  const ServerApiException({
    required this.kind,
    required this.operation,
    required this.cause,
  });

  factory ServerApiException.fromGrpc(String operation, GrpcError error) {
    final kind = switch (error.code) {
      3 => ServerApiFailureKind.invalidArgument,
      5 => ServerApiFailureKind.invalidRegistration,
      7 || 16 => ServerApiFailureKind.unauthorized,
      4 => ServerApiFailureKind.timeout,
      14 => ServerApiFailureKind.unavailable,
      _ => ServerApiFailureKind.unknown,
    };
    return ServerApiException(kind: kind, operation: operation, cause: error);
  }

  @override
  String toString() =>
      'ServerApiException($operation, $kind, ${cause.message})';
}

class ServerApi implements IServerApi {
  @override
  Future<void> sendKeepAlive(Connection con, String sessionID) async {
    final service = ServerClient(
      con.channel,
      interceptors: await con.interceptors,
      options: CallOptions(metadata: con.attempt.metadata),
    );

    try {
      await service.getLicense(ServerLicenseRequest()..sid = sessionID);
    } on GrpcError catch (error) {
      Logger().warn('sendKeepAlive: gRPC error -> $error');
      if (error.code == 14 ||
          (error.code == 2 &&
              (error.message?.contains('500 instead of 200') ?? false))) {
        throw APICallException(APICallState.keepAliveDead);
      }
      if (error.code == 16 || error.code == 7) {
        throw APICallException(APICallState.errorUnauthorized);
      }
      throw ServerApiException.fromGrpc('sendKeepAlive', error);
    } on SocketException catch (error) {
      Logger().warn('sendKeepAlive: SocketException $error');
      throw APICallException(APICallState.keepAliveDead);
    }
  }

  @override
  Future<ServerInfo> getServerInfo(
    Connection con, {
    String? hostname,
    int? port,
  }) async {
    final service = nvr.GatewayClient(
      con.channel,
      options: CallOptions(
        timeout: const Duration(seconds: 30),
        metadata: con.attempt.metadata,
      ),
      interceptors: await con.interceptors,
    );

    try {
      return await service.discover(
        DiscoverRequest(hostname: hostname, port: port),
      );
    } on GrpcError catch (error) {
      throw ServerApiException.fromGrpc('getServerInfo', error);
    }
  }

  @override
  Future<ServerResponse> getServerResponse(
    Connection con, {
    String? hostname,
    int? port,
    required VersionInfo versionInfo,
  }) async {
    final serverInfo = await getServerInfo(con, hostname: hostname, port: port);
    final sid = const Uuid().v4();

    return ServerResponse(
      name: serverInfo.description,
      serial: serverInfo.serial,
      id: sid,
      sessionId: sid,
      timezoneOffset: serverInfo.serverTimezone.gmtOffset.seconds.toInt(),
      connectionState: APICallState.ok,
      address: con.attempt.connectionUrl,
      port: port ?? 0,
      macAddress: serverInfo.licensedMac,
      remoteAddress: serverInfo.remoteConnectionUrl.isEmpty
          ? ''
          : applyScheme(serverInfo.remoteConnectionUrl),
      licenseType: mapLicenseType(serverInfo.licenseType),
      isRemoteConnected: con.attempt.nvrFrpsUrl.isNotEmpty,
      features: versionInfo.features.map(EvFeature.fromGrpc),
    );
  }

  @override
  Future<RemoteConnectionInfoResponse> getRemoteConnectionInfo(
    Connection con,
  ) async {
    final service = ServerClient(
      con.channel,
      options: CallOptions(
        timeout: const Duration(seconds: 30),
        metadata: con.attempt.metadata,
      ),
      interceptors: await con.interceptors,
    );

    try {
      return await service.getRemoteConnectionInfo(
        RemoteConnectionInfoRequest(),
      );
    } on GrpcError catch (error, stack) {
      Logger().error(
        'Remote Connectivity Error',
        error: error,
        stackTrace: stack,
      );
      throw ServerApiException.fromGrpc('getRemoteConnectionInfo', error);
    }
  }

  @override
  Future<MobileRemoteConnectionResponse> registerRemoteConnection(
    Connection con,
    String deviceId,
  ) async {
    final service = ServerClient(
      con.channel,
      options: CallOptions(
        timeout: const Duration(seconds: 30),
        metadata: con.attempt.metadata,
      ),
      interceptors: await con.interceptors,
    );

    try {
      return await service.addMobileRemoteConnection(
        MobileRemoteConnectionRequest(mobileDeviceId: deviceId),
      );
    } on GrpcError catch (error, stack) {
      Logger().error(
        'Unable to register for remote connectivity',
        error: error,
        stackTrace: stack,
      );
      throw ServerApiException.fromGrpc('registerRemoteConnection', error);
    }
  }

  @override
  Future<String> registerPushNotifcations(
    Connection con,
    String clientToken,
  ) async {
    Logger().info('[PushNotify] registerPushNotifcations');
    final service = PushNotifyClient(
      con.channel,
      options: CallOptions(
        timeout: const Duration(seconds: 30),
        metadata: con.attempt.metadata,
      ),
      interceptors: await con.interceptors,
    );

    try {
      final response = await service.register(
        RegisterRequest()
          // FirebaseMessaging.getToken() returns an FCM token on every platform.
          ..platform = RegisterRequest_Platform.FCM
          ..deviceToken = clientToken,
      );
      Logger().info(
        '[PushNotify] NVR Register response '
        'clientRegistrationId="${response.clientRegistationId}"',
      );
      return response.clientRegistationId;
    } on GrpcError catch (error) {
      Logger().error(
        '[PushNotify] registerPushNotifcations gRPC error: '
        'code=${error.code} codeName=${error.codeName} '
        'message=${error.message}',
      );
      throw ServerApiException.fromGrpc('registerPushNotifcations', error);
    }
  }

  @override
  Future<void> unregisterPushNotifcations(
    Connection con,
    String clientToken,
  ) async {
    final service = PushNotifyClient(
      con.channel,
      options: CallOptions(
        timeout: const Duration(seconds: 30),
        metadata: con.attempt.metadata,
      ),
      interceptors: await con.interceptors,
    );

    try {
      await service.unregister(
        UnregisterRequest()..clientRegistationId = clientToken,
      );
    } on GrpcError catch (error) {
      // Unregister is idempotent from the client's perspective.
      if (error.code == 5) return;
      throw ServerApiException.fromGrpc('unregisterPushNotifcations', error);
    }
  }
}
