final Map<String, Future<void>> _pushRegisterInFlightByServer = {};
final Map<String, Future<void>> _pushOperationTailByServer = {};
final Map<String, Set<String>> _registrationCleanupPendingByServer = {};

/// Serializes every push operation for a server while allowing different
/// servers to progress independently.
Future<T> runSerializedPushOperation<T>(
  String server,
  Future<T> Function() operation,
) {
  final previous = _pushOperationTailByServer[server] ?? Future<void>.value();
  final completer = Completer<T>();

  late final Future<void> barrier;
  barrier = previous
      .then((_) async {
        try {
          completer.complete(await operation());
        } catch (error, stack) {
          completer.completeError(error, stack);
        }
      })
      .whenComplete(() {
        if (identical(_pushOperationTailByServer[server], barrier)) {
          _pushOperationTailByServer.remove(server);
        }
      });

  _pushOperationTailByServer[server] = barrier;
  return completer.future;
}

ThunkAction<AppState> registerWithSwitchboard(String serverSlug, String url) {
  return (store) async {
    try {
      final connection = getConnection(serverSlug, state: store.state);
      final deviceId = await getPlatformDeviceId() ?? '';
      await EvGrpcApi().registerRemoteConnection(connection, deviceId);
    } on Exception catch (error, stack) {
      Logger().error(
        'Unable to register with the switchboard for $url',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  };
}

ThunkAction<AppState> keepAlive(String slug) {
  return (store) async {
    if (!server_selectors.getServerIsConnected(store.state, slug)) return;

    await execNvrApi(
      store,
      NVRAPICall.doLogin,
      slug,
      (gateway) async {
        await store.dispatch(fetchPrivileges(slug, keepAlive: true));
        return EvGrpcApi().sendKeepAlive(
          gateway,
          server_selectors.getSessionID(store.state, slug),
        );
      },
      onError: () {
        final apiState = getServerAPICallState(
          store.state,
          slug,
          NVRAPICall.doLogin,
        );
        store.dispatch(
          SetConnectionState(slug, apiState ?? APICallState.keepAliveDead),
        );
        return null;
      },
      setPending: false,
    );
  };
}

ThunkAction<AppState> updateServerInfo(String slug) {
  return (store) async {
    await execNvrApi(store, NVRAPICall.fetchLicense, slug, (gateway) async {
      final serverInfo = await EvGrpcApi().getServerInfo(
        gateway,
        hostname: server_selectors.getServerURL(store.state, slug),
        port: server_selectors.getServerPort(store.state, slug),
      );
      store.dispatch(UpdateServerInfo(slug, serverInfo));
    }, setPending: false);
  };
}

Future<String> _createPushRegistration(
  Store<AppState> store,
  String server,
  String fcmToken,
) async {
  String? registrationId;
  await execNvrApi(store, NVRAPICall.pushNotifyRegister, server, (
    gateway,
  ) async {
    registrationId = await EvGrpcApi().registerPushNotifcations(
      gateway,
      fcmToken,
    );
  }, setPending: false);

  if (registrationId == null || registrationId!.isEmpty) {
    throw StateError('Push registration did not return an ID for $server');
  }
  return registrationId!;
}

Future<void> _subscribeRegistrationToSnapshot(
  Store<AppState> store,
  String server,
  String registrationId,
  Map<String, List<String>> subscriptions,
) async {
  for (final entry in subscriptions.entries) {
    var completed = false;
    await execNvrApi(store, NVRAPICall.pushNotifySubscribe, server, (
      channel,
    ) async {
      await EvGrpcApi().subscribeToProfileLinks(
        channel,
        entry.key,
        entry.value,
        registrationId,
      );
      completed = true;
    });
    if (!completed) {
      throw StateError('Unable to restore ${entry.key} on $server');
    }
  }
}

Future<void> _retirePushRegistration(
  Store<AppState> store,
  String server,
  String registrationId,
) async {
  var completed = false;
  await execNvrApi(store, NVRAPICall.pushNotifyUnregister, server, (
    gateway,
  ) async {
    await EvGrpcApi().unregisterPushNotifcations(gateway, registrationId);
    completed = true;
  }, setPending: false);
  if (!completed) {
    throw StateError('Unable to retire push registration for $server');
  }
}

Future<void> _retryPendingRegistrationCleanup(
  Store<AppState> store,
  String server,
) async {
  final pending = _registrationCleanupPendingByServer[server];
  if (pending == null || pending.isEmpty) return;

  for (final registrationId in pending.toList()) {
    try {
      await _retirePushRegistration(store, server, registrationId);
      pending.remove(registrationId);
    } catch (error) {
      Logger().warn(
        '[PushNotify] Registration cleanup is still pending for '
        '$server/$registrationId: $error',
      );
    }
  }

  if (pending.isEmpty) {
    _registrationCleanupPendingByServer.remove(server);
  }
}

/// Ensures that [server] has a registration for the current device token.
///
/// Call this from inside [runSerializedPushOperation] when it is part of a
/// larger server mutation. Concurrent direct calls are still deduplicated.
Future<String> ensurePushRegistration(
  Store<AppState> store,
  String server, {
  bool forceRefresh = false,
}) async {
  final currentToken = await FirebaseService().getToken();
  if (currentToken.isEmpty) {
    throw StateError('FCM token is unavailable');
  }

  final currentId = server_selectors.getServerClientRegistrationId(
    store.state,
    server,
  );
  final registeredToken = server_selectors.getServerLastFcmToken(
    store.state,
    server,
  );

  await _retryPendingRegistrationCleanup(store, server);

  if (!forceRefresh &&
      currentId.isNotEmpty &&
      registeredToken == currentToken) {
    return currentId;
  }

  final inFlight = _pushRegisterInFlightByServer[server];
  if (inFlight != null) {
    await inFlight;
    final result = server_selectors.getServerClientRegistrationId(
      store.state,
      server,
    );
    if (result.isEmpty) {
      throw StateError('Push registration failed for $server');
    }
    return result;
  }

  late final Future<void> registration;
  registration = () async {
    final confirmedSubscriptions = getSubscriptionsForServer(
      store.state,
      server,
    );
    final newId = await _createPushRegistration(store, server, currentToken);

    try {
      // Restore the last confirmed snapshot before exposing the new handle.
      await _subscribeRegistrationToSnapshot(
        store,
        server,
        newId,
        confirmedSubscriptions,
      );
    } catch (_) {
      try {
        await _retirePushRegistration(store, server, newId);
      } catch (cleanupError) {
        _registrationCleanupPendingByServer
            .putIfAbsent(server, () => <String>{})
            .add(newId);
        Logger().warn(
          '[PushNotify] Cleanup is pending for failed replacement '
          '$server/$newId: $cleanupError',
        );
      }
      rethrow;
    }

    store.dispatch(SetRegistrationId(server, newId));
    store.dispatch(SetFcmToken(server, currentToken));

    if (currentId.isNotEmpty && currentId != newId) {
      try {
        await _retirePushRegistration(store, server, currentId);
      } catch (error, stack) {
        // The new registration is already usable. Keep it and surface the
        // cleanup failure for diagnostics instead of deleting the device token.
        _registrationCleanupPendingByServer
            .putIfAbsent(server, () => <String>{})
            .add(currentId);
        Logger().warn(
          '[PushNotify] Unable to retire old registration for $server: '
          '$error\n$stack',
        );
      }
    }
  }();

  _pushRegisterInFlightByServer[server] = registration;
  try {
    await registration;
  } finally {
    if (identical(_pushRegisterInFlightByServer[server], registration)) {
      _pushRegisterInFlightByServer.remove(server);
    }
  }

  return server_selectors.getServerClientRegistrationId(store.state, server);
}

ThunkAction<AppState> registerPushNotify(
  String server, {
  bool forceRefresh = false,
}) {
  return (store) async {
    await runSerializedPushOperation(
      server,
      () => ensurePushRegistration(store, server, forceRefresh: forceRefresh),
    );
  };
}

ThunkAction<AppState> reconcilePushNotifyOnStartup(String server) {
  return (store) async {
    await runSerializedPushOperation(
      server,
      () => ensurePushRegistration(store, server),
    );
  };
}

ThunkAction<AppState> unregisterPushNotify(String server) {
  return (store) async {
    await runSerializedPushOperation(server, () async {
      final registrationId = server_selectors.getServerClientRegistrationId(
        store.state,
        server,
      );
      if (registrationId.isEmpty) {
        store.dispatch(ClearServerSubscriptions(server));
        return;
      }

      await _retirePushRegistration(store, server, registrationId);
      await _retryPendingRegistrationCleanup(store, server);
      store.dispatch(SetRegistrationId(server, ''));
      store.dispatch(SetFcmToken(server, ''));
      store.dispatch(ClearServerSubscriptions(server));
    });
  };
}

ThunkAction<AppState> mergeViewFragments(String server, List<EvView> inViews) {
  return (store) async {
    final snapshot = Map<String, EvView>.unmodifiable({
      for (final view in inViews) view.fullPathName: view,
    });
    store.dispatch(UpdateViewFragments(server, snapshot));
  };
}

ThunkAction<AppState> mergeGroupFragments(
  String server,
  List<EvGroup> inGroups,
) {
  return (store) async {
    final snapshot = Map<String, EvGroup>.unmodifiable({
      for (final group in inGroups) group.id: group,
    });
    store.dispatch(UpdateGroupFragments(server, snapshot));
  };
}

ThunkAction<AppState> mergeProfileFragments(
  String server,
  List<EvEventMonitoringProfile> inProfiles,
) {
  return (store) async {
    final snapshot = Map<String, EvEventMonitoringProfile>.unmodifiable({
      for (final profile in inProfiles) profile.id: profile,
    });
    store.dispatch(UpdateProfileFragments(server, snapshot));
  };
}

ThunkAction<AppState> mergeVideoPushTargets(
  String server,
  List<EvVideoPushTarget> inTargets,
) {
  return (store) async {
    final snapshot = Map<String, EvVideoPushTarget>.unmodifiable({
      for (final target in inTargets) target.id: target,
    });
    store.dispatch(UpdateVideoPushTargets(server, snapshot));
  };
}

ThunkAction<AppState> mergeVideoPushLayouts(
  String server,
  List<EvVideoPushLayout> inLayouts,
) {
  return (store) async {
    final snapshot = Map<String, EvVideoPushLayout>.unmodifiable({
      for (final layout in inLayouts) layout.id: layout,
    });
    store.dispatch(UpdateVideoPushLayouts(server, snapshot));
  };
}
