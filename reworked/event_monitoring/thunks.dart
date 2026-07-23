class SubscriptionSnapshotUnavailableException implements Exception {
  final String server;

  const SubscriptionSnapshotUnavailableException(this.server);

  @override
  String toString() => 'Subscription snapshot was unavailable for $server';
}

Map<String, List<String>> _normalizeServerSubscriptions(
  Map<String, List<String>> source,
) {
  return {
    for (final entry in source.entries)
      if (entry.value.isNotEmpty)
        entry.key: (List<String>.from(entry.value)..sort()),
  };
}

bool _sameServerSubscriptions(
  Map<String, List<String>> left,
  Map<String, List<String>> right,
) {
  return const DeepCollectionEquality().equals(
    _normalizeServerSubscriptions(left),
    _normalizeServerSubscriptions(right),
  );
}

Future<Map<String, List<String>>> _fetchSubscribedProfilesNow(
  Store<AppState> store,
  String server,
) async {
  final registrationId = await ensurePushRegistration(store, server);
  Map<String, List<String>>? response;

  await execNvrApi(store, NVRAPICall.fetchSubscribedProfiles, server, (
    channel,
  ) async {
    response = await EvGrpcApi().getSubScribedProfiles(channel, registrationId);
    if (response == null) {
      throw SubscriptionSnapshotUnavailableException(server);
    }
  });

  final snapshot = response;
  if (snapshot == null) {
    // A null response is ambiguous. Do not create a new registration or
    // overwrite confirmed state unless the API reports an invalid handle.
    throw SubscriptionSnapshotUnavailableException(server);
  }

  final previous = getSubscriptionsForServer(store.state, server);
  if (!_sameServerSubscriptions(previous, snapshot)) {
    store.dispatch(ReplaceServerSubscriptions(server, snapshot));
  }

  StatusSubscriptionManager().cacheFor(
    server,
    NVRAPICall.fetchSubscribedProfiles,
  );
  return snapshot;
}

ThunkAction<AppState> fetchEventMonitorProfiles(String server) {
  Future<void> execute(Store<AppState> store) async {
    await execNvrApi(store, NVRAPICall.fetchEventMonitorProfiles, server, (
      channel,
    ) async {
      final profiles = await EvGrpcApi().getEventMonitorProfiles(
        channel,
        server,
        server_selectors.getSessionID(store.state, server),
      );
      if (profiles == null) return;

      // The per-server fragment snapshot is the only writable profile state.
      // Merged profiles and reverse indexes are selector projections.
      await store.dispatch(mergeProfileFragments(server, profiles));
      StatusSubscriptionManager().cacheFor(
        server,
        NVRAPICall.fetchEventMonitorProfiles,
      );
    });
  }

  return fetch(
    server,
    '[PushNotify] Fetching event monitor profiles for server $server',
    execute,
    NVRAPICall.fetchEventMonitorProfiles,
  );
}

ThunkAction<AppState> fetchSubscribedProfiles(String server) {
  Future<void> execute(Store<AppState> store) async {
    dev.log('[PushNotify] fetchSubscribedProfiles: $server');
    await runSerializedPushOperation(
      server,
      () => _fetchSubscribedProfilesNow(store, server),
    );
  }

  return fetch(
    server,
    '[PushNotify] Fetching subscribed profiles for server $server',
    execute,
    NVRAPICall.fetchSubscribedProfiles,
  );
}

Map<String, List<String>> _desiredLinksByServer(
  AppState state,
  EvEventMonitoringProfile profile,
  List<EvEventProfileLink>? requestedLinks,
) {
  final selectedLinks = requestedLinks == null || requestedLinks.isEmpty
      ? profile.links
      : requestedLinks;

  return Map.unmodifiable({
    for (final server in getServersForProfile(state, profile.id))
      server: List<String>.unmodifiable(
        selectedLinks
            .where((link) => link.server == server)
            .map((link) => link.guid),
      ),
  });
}

Future<void> _unsubscribeProfileOnServer({
  required Store<AppState> store,
  required String server,
  required String profileId,
  required List<String> linkGuids,
  required String registrationId,
}) async {
  var completed = false;
  await execNvrApi(store, NVRAPICall.pushNotifyUnsubscribe, server, (
    channel,
  ) async {
    await EvGrpcApi().unsubscribeToProfileLinks(
      channel,
      profileId,
      linkGuids,
      registrationId,
    );
    completed = true;
  });
  if (!completed) {
    throw StateError('Unsubscribe did not complete for $server/$profileId');
  }
}

Future<void> _subscribeProfileOnServer({
  required Store<AppState> store,
  required String server,
  required String profileId,
  required List<String> linkGuids,
  required String registrationId,
}) async {
  var completed = false;
  await execNvrApi(store, NVRAPICall.pushNotifySubscribe, server, (
    channel,
  ) async {
    await EvGrpcApi().subscribeToProfileLinks(
      channel,
      profileId,
      linkGuids,
      registrationId,
    );
    completed = true;
  });
  if (!completed) {
    throw StateError('Subscribe did not complete for $server/$profileId');
  }
}

Future<void> _mutateProfileOnServer({
  required Store<AppState> store,
  required String server,
  required EvEventMonitoringProfile profile,
  required Map<String, List<String>> desiredLinksByServer,
}) async {
  final confirmedLinks = getSubscriptionsForServer(
    store.state,
    server,
  )[profile.id];
  final shouldSubscribe = desiredLinksByServer.containsKey(server);

  final registrationId = shouldSubscribe
      ? await ensurePushRegistration(store, server)
      : server_selectors.getServerClientRegistrationId(store.state, server);

  if (registrationId.isEmpty) {
    // A new handle cannot control subscriptions belonging to a lost old
    // handle. Preserve confirmed state and report the failure.
    throw StateError(
      'Cannot unsubscribe $server/${profile.id}: '
      'registration ID is missing',
    );
  }

  final unsubscribeGuids =
      confirmedLinks ??
      profile.links
          .where((link) => link.server == server)
          .map((link) => link.guid)
          .toList();

  // Preserve the existing server contract: replace a subscription by sending
  // its exact unsubscribe tuple before the subscribe tuple.
  await _unsubscribeProfileOnServer(
    store: store,
    server: server,
    profileId: profile.id,
    linkGuids: unsubscribeGuids,
    registrationId: registrationId,
  );

  if (shouldSubscribe) {
    await _subscribeProfileOnServer(
      store: store,
      server: server,
      profileId: profile.id,
      linkGuids: desiredLinksByServer[server]!,
      registrationId: registrationId,
    );
  }

  await _fetchSubscribedProfilesNow(store, server);
}

Future<void> _setProfileSubscription({
  required Store<AppState> store,
  required EvEventMonitoringProfile profile,
  required bool desiredActive,
  List<EvEventProfileLink>? links,
}) async {
  final desiredLinksByServer = desiredActive
      ? _desiredLinksByServer(store.state, profile, links)
      : const <String, List<String>>{};
  final confirmedServers =
      getSubscribedLinks(store.state)[profile.id]?.keys ?? const [];
  final targets = <String>{...confirmedServers, ...desiredLinksByServer.keys};

  final revision = getNextProfileOperationRevision(store.state, profile.id);
  store.dispatch(
    BeginProfileSubscriptionOperation(
      profileId: profile.id,
      desiredActive: desiredActive,
      revision: revision,
    ),
  );

  final results = await Future.wait(
    targets.map((server) async {
      try {
        await runSerializedPushOperation(
          server,
          () => _mutateProfileOnServer(
            store: store,
            server: server,
            profile: profile,
            desiredLinksByServer: desiredLinksByServer,
          ),
        );
        return null;
      } catch (error, stack) {
        Logger().error(
          '[PushNotify] Profile operation failed for '
          '$server/${profile.id}',
          error: error,
          stackTrace: stack,
        );
        return MapEntry(server, error.toString());
      }
    }),
  );

  final failures = <String, String>{
    for (final result in results)
      if (result != null) result.key: result.value,
  };
  store.dispatch(
    CompleteProfileSubscriptionOperation(
      profileId: profile.id,
      revision: revision,
      failuresByServer: failures,
    ),
  );
}

/// If no links are specified, all links for the profile are subscribed to.
ThunkAction<AppState> updateProfileSubscription({
  required EvEventMonitoringProfile profile,
  List<EvEventProfileLink>? links,
}) {
  return (store) => _setProfileSubscription(
    store: store,
    profile: profile,
    desiredActive: true,
    links: links,
  );
}

ThunkAction<AppState> unsubscribeFromProfile({
  required EvEventMonitoringProfile profile,
}) {
  return (store) => _setProfileSubscription(
    store: store,
    profile: profile,
    desiredActive: false,
  );
}

/// Explicit single-profile patch retained for compatibility. Server fetches
/// should use [syncSubscribedProfiles], which replaces a complete snapshot.
ThunkAction<AppState> updateLocalSubscription(
  String server,
  String profileId,
  List<String> links,
) {
  return (store) async {
    final snapshot = Map<String, List<String>>.from(
      getSubscriptionsForServer(store.state, server),
    );
    if (links.isEmpty) {
      snapshot.remove(profileId);
    } else {
      snapshot[profileId] = List.unmodifiable(links);
    }
    store.dispatch(ReplaceServerSubscriptions(server, snapshot));
  };
}

ThunkAction<AppState> unsubscribeProfilesForServer({required String slug}) {
  return (store) async {
    await runSerializedPushOperation(slug, () async {
      final subscriptions = getSubscriptionsForServer(store.state, slug);
      if (subscriptions.isEmpty) return;

      final registrationId = server_selectors.getServerClientRegistrationId(
        store.state,
        slug,
      );
      if (registrationId.isEmpty) {
        throw StateError(
          'Cannot unsubscribe $slug: registration ID is missing',
        );
      }

      Object? firstError;
      StackTrace? firstStack;
      for (final profile in subscriptions.entries) {
        try {
          await _unsubscribeProfileOnServer(
            store: store,
            server: slug,
            profileId: profile.key,
            linkGuids: profile.value,
            registrationId: registrationId,
          );
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }

      try {
        await _fetchSubscribedProfilesNow(store, slug);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }

      if (firstError != null) {
        Error.throwWithStackTrace(firstError!, firstStack!);
      }
    });
  };
}

ThunkAction<AppState> unsubscribeAllPushNotifications() {
  return (store) async {
    final registeredServers = server_selectors
        .getSlugs(store.state)
        .where(
          (server) => server_selectors
              .getServerClientRegistrationId(store.state, server)
              .isNotEmpty,
        )
        .toList();

    await Future.wait(
      registeredServers.map((server) async {
        await store.dispatch(unregisterPushNotify(server));
      }),
    );
  };
}

/// Replaces the complete subscription snapshot for one server.
ThunkAction<AppState> syncSubscribedProfiles(
  String server,
  Map<String, List<String>> subscribedProfiles,
) {
  return (store) async {
    store.dispatch(ReplaceServerSubscriptions(server, subscribedProfiles));
  };
}

ThunkAction<AppState> updateEventMonitoringProfiles(
  String serverSlug,
  List<EvEventMonitoringProfile> profiles,
) {
  return (store) async {
    await store.dispatch(mergeProfileFragments(serverSlug, profiles));
  };
}
