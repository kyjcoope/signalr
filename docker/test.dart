class EventMonitorListModel extends EvViewModel {
  final List<EvEventMonitoringProfile> profiles;
  final bool hasEventMonitoringPrivileges;
  final Map<String, Map<String, List<String>>> subscribedLinks;

  EventMonitorListModel(super.store)
    : profiles = getSortedProfiles(store.state),
      hasEventMonitoringPrivileges = validatePrivileges(store.state, {
        Privilege.eventMonitor,
      }),
      subscribedLinks = getSubscribedLinks(store.state);

  bool statusMatches(EvEventMonitoringProfile profile, EventMonitorTab tab) {
    switch (tab) {
      case EventMonitorTab.active:
        return profileIsActive(profile);
      case EventMonitorTab.inactive:
        return !profileIsActive(profile);
      case EventMonitorTab.search:
        return true;
    }
  }

  // FIXED: Added null check to prevent errors or false positives
  bool profileIsActive(EvEventMonitoringProfile profile) {
    final links = subscribedLinks[profile.id];
    return links != null && links.isNotEmpty;
  }

  void subscribeAll(EvEventMonitoringProfile profile) {
    store.dispatch(updateProfileSubscription(profile: profile));
  }

  void unsubscribeAll(EvEventMonitoringProfile profile) {
    store.dispatch(unsubscribeFromProfile(profile: profile));
  }

  @override
  List<Object?> get props => [
    profiles,
    hasEventMonitoringPrivileges,
    subscribedLinks,
  ];
}

ThunkAction<AppState> fetchEventMonitorProfiles(String server) {
  Future<void> execute(Store<AppState> store) async {
    await execNvrApi(store, NVRAPICall.fetchEventMonitorProfiles, server, (
      channel,
    ) async {
      var evProfiles = await EvGrpcApi().getEventMonitorProfiles(
        channel,
        server,
        server_selectors.getSessionID(store.state, server),
      );
      if (evProfiles == null) return;

      final oldProfiles = getProfileFragmentsByServer(
        store.state,
        server,
      ).values.toList();
      if (!listEquals(evProfiles, oldProfiles)) {
        store.dispatch(updateEventMonitoringProfiles(server, evProfiles));
      }

      StatusSubscriptionManager().cacheFor(
        server,
        NVRAPICall.fetchEventMonitorProfiles,
      );
    });
  }

  return fetch(
    server,
    'Fetching event monitor profiles for server $server',
    execute,
    NVRAPICall.fetchEventMonitorProfiles,
  );
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
        var response = await EvGrpcApi().getSubscribedProfiles(
          channel,
          clientRegId,
        );
        if (response == null) return;

        final prevALL = getSubscribedLinks(store.state);
        final prevForServer = <String, List<String>>{};
        for (final entry in prevALL.entries) {
          final listForServer = entry.value[server];
          if (listForServer != null) {
            prevForServer[entry.key] = List<String>.from(listForServer);
          }
        }

        Map<String, List<String>> normalize(Map<String, List<String>> src) {
          return {
            for (final e in src.entries)
              e.key: (List<String>.from(e.value)..sort()),
          };
        }

        final normalizedPrev = normalize(prevForServer);
        final normalizedNew = normalize(response);

        final mapsEqual = const DeepCollectionEquality().equals(
          normalizedPrev,
          normalizedNew,
        );

        if (!mapsEqual) {
          // CHANGED: Use syncSubscribedProfiles for API responses
          store.dispatch(syncSubscribedProfiles(server, response));
        }

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

/// If no links are specified, all links for the profile are subscribed to
ThunkAction<AppState> updateProfileSubscription({
  required EvEventMonitoringProfile profile,
  List<EvEventProfileLink>? links,
}) {
  return (store) async {
    // 1. API ONLY: Unsubscribe first without touching the store yet.
    // This prevents the UI from flashing "empty" or "inactive".
    await _unsubscribeLinksApiOnly(store, profile);

    // 2. API ONLY: Subscribe to the new links.
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

        await EvGrpcApi().subscribeToProfileLinks(
          channel,
          profile.id,
          linkGuids,
          clientRegId,
        );
      });
    }

    // 3. REFRESH TRUTH
    // Now that APIs are done, fetch the true state to ensure consistency.
    for (String server in getServersForProfile(store.state, profile.id)) {
      store.dispatch(fetchSubscribedProfiles(server));
    }
  };
}

ThunkAction<AppState> unsubscribeFromProfile({
  required EvEventMonitoringProfile profile,
}) {
  return (store) async {
    // 1. API Call (Do not touch store yet)
    await _unsubscribeLinksApiOnly(store, profile);

    // 2. Safe Local Update
    // We update the local state immediately to reflect the user's action without waiting for a fetch.
    for (String server in getServersForProfile(store.state, profile.id)) {
      store.dispatch(updateLocalSubscription(server, profile.id, []));
    }
  };
}

/// Helper: Performs unsubscribe API calls without dispatching store updates
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
        await EvGrpcApi().unsubscribeToProfileLinks(
          channel,
          profile.id,
          clientRegId,
        );
      });
    }
  }
}

ThunkAction<AppState> unsubscribeProfilesForServer({required String slug}) {
  return (store) async {
    var links = getSubscribedLinks(store.state);
    for (var profile in links.entries) {
      var servers = getServersForProfile(store.state, profile.key);
      if (servers.contains(slug)) {
        String clientRegId = server_selectors.getServerClientRegistrationId(
          store.state,
          slug,
        );
        if (clientRegId.isNotEmpty) {
          await execNvrApi(store, NVRAPICall.pushNotifyUnsubscribe, slug, (
            channel,
          ) async {
            await EvGrpcApi().unsubscribeToProfileLinks(
              channel,
              profile.key,
              clientRegId,
            );
          });
        }

        // Use safe update
        store.dispatch(updateLocalSubscription(slug, profile.key, []));
      }
    }
  };
}

ThunkAction<AppState> unsubscribeAllPushNotifications() {
  return (store) async {
    var links = getSubscribedLinks(store.state);
    if (links.isNotEmpty) {
      List<String> slugs = server_selectors.getSlugs(store.state);
      await Future.wait(
        slugs.map((e) async {
          await store.dispatch(unregisterPushNotify(e));
        }),
      );
    }
  };
}

/// NEW: Use this for partial updates (toggling a single profile).
/// It ensures other profiles are not removed from the state.
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

    // Get the specific profile map we are editing
    var profileMap = newSubscribedProfileLinks[profileId] ?? {};

    if (links.isEmpty) {
      profileMap.remove(server);
    } else {
      profileMap[server] = links;
    }

    if (profileMap.isEmpty) {
      newSubscribedProfileLinks.remove(profileId);
    } else {
      newSubscribedProfileLinks[profileId] = profileMap;
    }

    store.dispatch(UpdateSubscribedLinks(newSubscribedProfileLinks));
  };
}

/// RENAMED: Use this ONLY when getting a full list from the API.
ThunkAction<AppState> syncSubscribedProfiles(
  String server,
  Map<String, List<String>> subscribedprofiles,
) {
  return (store) async {
    final newSubscribedProfileLinks =
        Map<String, Map<String, List<String>>>.from(
          getSubscribedLinks(store.state),
        );

    // Cleanup profiles no longer present in the incoming API response for this server
    for (var item in newSubscribedProfileLinks.entries.toList()) {
      final incoming = subscribedprofiles[item.key];
      if (incoming == null) {
        item.value.remove(server);
      }

      if (item.value.isEmpty) {
        newSubscribedProfileLinks.remove(item.key);
      }
    }

    // Apply incoming data
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

ThunkAction<AppState> updateEventMonitoringProfiles(
  String serverSlug,
  List<EvEventMonitoringProfile> inProfiles,
) {
  return (store) async {
    store.dispatch(mergeProfileFragments(serverSlug, inProfiles));

    final newProfileServersMap = Map<String, List<String>>.from(
      getProfileServersMap(store.state),
    );
    final newProfiles = List<EvEventMonitoringProfile>.from(
      getProfiles(store.state),
    );
    final keys = <String>[];

    for (var p in inProfiles) {
      var key = p.id;
      if (!newProfileServersMap.containsKey(key)) {
        newProfileServersMap[key] = [serverSlug];
      }

      if (!newProfileServersMap[key]!.contains(serverSlug)) {
        newProfileServersMap[key]!.add(serverSlug);
      }
    }

    for (var entry in newProfileServersMap.entries) {
      if (inProfiles.isEmpty ||
          inProfiles.firstWhereOrNull((g) => g.id == entry.key) == null) {
        entry.value.remove(serverSlug);
      }

      if (entry.value.isEmpty) {
        newProfiles.removeWhere((v) => v.id == entry.key);
      }

      keys.add(entry.key);
    }

    for (var profileName in keys) {
      final state = AppStoreService().getStore().state;
      var profileFragments = getProfileFragments(state, profileName);
      mergeProfiles(profileFragments, profiles: newProfiles);
    }

    store.dispatch(UpdateProfiles(newProfileServersMap, newProfiles));
  };
}

void mergeProfiles(
  List<EvEventMonitoringProfile> profileFragments, {
  required List<EvEventMonitoringProfile> profiles,
}) {
  if (profileFragments.isEmpty) return;

  List<EvEventProfileLink> links = [];
  for (var gf in profileFragments) {
    links.addAll(gf.links);
  }

  var found = profiles.firstWhereOrNull(
    (existing) => existing.id == profileFragments.first.id,
  );

  if (found == null) {
    profiles.add(profileFragments.first);
  } else {
    if (links.isEmpty) {
      profiles.remove(found);
    } else {
      found = found.copyWith(
        name: profileFragments.first.name,
        description: profileFragments.first.description,
        type: profileFragments.first.type,
        flags: profileFragments.first.flags,
        links: links,
      );

      final index = profiles.indexWhere(
        (existing) => existing.id == profileFragments.first.id,
      );
      profiles[index] = found;
    }
  }
}
