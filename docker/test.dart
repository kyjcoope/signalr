/// RENAME of original updateSubscribedProfiles
/// Used ONLY when we get a full list from the API (Fetch).
ThunkAction<AppState> syncSubscribedProfiles(
  String server,
  Map<String, List<String>> subscribedprofiles,
) {
  return (store) async {
    final newSubscribedProfileLinks =
        Map<String, Map<String, List<String>>>.from(
          getSubscribedLinks(store.state),
        );

    // Cleanup profiles no longer present
    for (var item in newSubscribedProfileLinks.entries.toList()) {
      final incoming = subscribedprofiles[item.key];
      if (incoming == null) {
        item.value.remove(server);
      } else {
        // incoming exists; will be set below
      }

      /// If the profile has empty links removing it from list
      if (item.value.isEmpty) {
        newSubscribedProfileLinks.remove(item.key);
      }
    }

    // apply incoming (skip empty lists by removing server)
    for (var entry in subscribedprofiles.entries) {
      final links = entry.value;
      if (links.isEmpty) {
        final existing = newSubscribedProfileLinks[entry.key];
        existing?.remove(server);

        if (existing != null && existing.isEmpty) {
          newSubscribedProfileLinks.remove(entry.key);
        }
        continue;
      }

      final existing = newSubscribedProfileLinks[entry.key];
      if (existing == null) {
        newSubscribedProfileLinks[entry.key] = {server: links};
      } else {
        existing[server] = links;
      }
    }

    store.dispatch(UpdateSubscribedLinks(newSubscribedProfileLinks));
  };
}

/// NEW FUNCTION
/// Safely updates a single profile's links for a server without affecting others.
ThunkAction<AppState> updateLocalSubscription(
  String server,
  String profileId,
  List<String> links,
) {
  return (store) async {
    final newSubscribedProfileLinks =
        Map<String, Map<String, List<String>>>.from(
          getSubscribedLinks(store.state),
        );

    // Get the specific profile map we are editing, or create new if missing
    var profileMap = newSubscribedProfileLinks[profileId] ?? {};

    if (links.isEmpty) {
      profileMap.remove(server);
    } else {
      profileMap[server] = links;
    }

    // Clean up if empty
    if (profileMap.isEmpty) {
      newSubscribedProfileLinks.remove(profileId);
    } else {
      newSubscribedProfileLinks[profileId] = profileMap;
    }

    store.dispatch(UpdateSubscribedLinks(newSubscribedProfileLinks));
  };
}

ThunkAction<AppState> fetchSubscribedProfiles(String server) {
  Future<void> execute(Store<AppState> store) async {
    await execNvrApi(store, NVRAPICall.fetchSubscribedProfiles, server, (
      channel,
    ) async {
      String clientRegId = server_selectors.getServerClientRegistrationId(
        store.state,
        server,
      );
      if (clientRegId.isNotEmpty) {
        // Using your original method call
        var response = await EvGrpcApi().getSubscribedProfiles(
          channel,
          clientRegId,
        );
        if (response == null) return;

        // ... (Keep your existing optimization/equality check logic here) ...

        // CHANGED: Use the sync action
        store.dispatch(syncSubscribedProfiles(server, response));

        StatusSubscriptionManager().cacheFor(
          server,
          NVRAPICall.fetchSubscribedProfiles,
        );
      }
    });
  }

  return fetch(
    server,
    'Fetching subscribed profiles for server $server',
    execute,
    NVRAPICall.fetchSubscribedProfiles,
  );
}

Future<void> _unsubscribeLinksApiOnly(
  Store<AppState> store,
  EvEventMonitoringProfile profile,
) async {
  for (String server in getServersForProfile(store.state, profile.id)) {
    String clientRegId = server_selectors.getServerClientRegistrationId(
      store.state,
      server,
    );

    if (clientRegId.isNotEmpty) {
      await execNvrApi(store, NVRAPICall.pushNotifyUnsubscribe, server, (
        channel,
      ) async {
        // Using your original method call
        await EvGrpcApi().unsubscribeToProfileLinks(
          channel,
          profile.id,
          clientRegId,
        );
      });
    }
  }
}

ThunkAction<AppState> updateProfileSubscription({
  required EvEventMonitoringProfile profile,
  List<EvEventProfileLink>? links,
}) {
  return (store) async {
    // 1. API ONLY: Unsubscribe first (prevents UI flash of "inactive")
    await _unsubscribeLinksApiOnly(store, profile);

    // 2. API ONLY: Subscribe
    for (String server in getServersForProfile(store.state, profile.id)) {
      String clientRegId = server_selectors.getServerClientRegistrationId(
        store.state,
        server,
      );
      List<String> linkGuids = (links?.isEmpty ?? true ? profile.links : links!)
          .where((element) => element.server == server)
          .map((e) => e.guid)
          .toList();

      await execNvrApi(store, NVRAPICall.pushNotifySubscribe, server, (
        channel,
      ) async {
        if (clientRegId.isEmpty) {
          await store.dispatch(registerPushNotify(server));
          clientRegId = server_selectors.getServerClientRegistrationId(
            store.state,
            server,
          );
        }

        // Using your original method call
        await EvGrpcApi().subscribeToProfileLinks(
          channel,
          profile.id,
          linkGuids,
          clientRegId,
        );
      });
    }

    // 3. REFRESH: Fetch the authoritative state from server
    for (String server in getServersForProfile(store.state, profile.id)) {
      store.dispatch(fetchSubscribedProfiles(server));
    }
  };
}

ThunkAction<AppState> unsubscribeFromProfile({
  required EvEventMonitoringProfile profile,
}) {
  return (store) async {
    // 1. API Call
    await _unsubscribeLinksApiOnly(store, profile);

    // 2. Safe Local Update (Does not wipe other profiles)
    for (String server in getServersForProfile(store.state, profile.id)) {
      store.dispatch(updateLocalSubscription(server, profile.id, []));
    }
  };
}
