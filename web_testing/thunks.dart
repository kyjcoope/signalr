ThunkAction<AppState> fetchEventMonitorProfiles(String server) {
  Future<void> execute(Store<AppState> store) async {
    await execNvrApi(store, NVRAPICall.fetchEventMonitorProfiles, server,
        (channel) async {
      var evProfiles = await EvGrpcApi().getEventMonitorProfiles(
          channel,
          server,
          server_selectors.getSessionID(store.state, server));
      if (evProfiles == null) return;
      // Always dispatch: this is the only place that rebuilds
      // profileServersMap. profileServersMap is transient/session-only
      // state, while profileFragments is persisted per-server, so on a
      // fresh app start the fragments can already match the server's
      // response (listEquals == true) even though profileServersMap has
      // not yet been populated for this server. Skipping the dispatch in
      // that case silently drops this server from getServersForProfile(),
      // causing subscribe/unsubscribe actions to target the wrong server.
      store.dispatch(updateEventMonitoringProfiles(server, evProfiles));
      StatusSubscriptionManager()
          .cacheFor(server, NVRAPICall.fetchEventMonitorProfiles);
    });
  }

  return fetch(
      server,
      '[PushNotify] Fetching event monitor profiles for server $server',
      execute,
      NVRAPICall.fetchEventMonitorProfiles);
}

ThunkAction<AppState> fetchSubscribedProfiles(String server) {
  Future<void> execute(Store<AppState> store) async {
    dev.log('[PushNotify] fetchSubscribedProfiles');
    await store.dispatch(reconcilePushNotifyOnStartup(server));

    await execNvrApi(store, NVRAPICall.fetchSubscribedProfiles, server,
        (channel) async {
      var clientRegId =
          server_selectors.getServerClientRegistrationId(store.state, server);
      if (clientRegId.isEmpty) {
        Logger().info(
            '[PushNotify] fetchSubscribedProfiles: missing registration for $server; registering and retrying');
        await store.dispatch(registerPushNotify(server));
        clientRegId = server_selectors
            .getServerClientRegistrationId(store.state, server);
      }
      if (clientRegId.isNotEmpty) {
        var res =
            await EvGrpcApi().getSubScribedProfiles(channel, clientRegId);

        // Self-heal for stale/invalid registration handles by re-registering
        // once and retrying immediately with the refreshed registration ID.
        if (res == null) {
          Logger().warn(
              '[PushNotify] fetchSubscribedProfiles failed for $server; refreshing registration and retrying once');
          await store.dispatch(registerPushNotify(server));
          clientRegId = server_selectors
              .getServerClientRegistrationId(store.state, server);
          if (clientRegId.isNotEmpty) {
            res = await EvGrpcApi()
                .getSubScribedProfiles(channel, clientRegId);
          }
        }

        if (res == null) return;

        final prevAll = getSubscribedLinks(store.state);
        final prevForServer = <String, List<String>>{};
        for (final entry in prevAll.entries) {
          final listForServer = entry.value[server];
          if (listForServer != null) {
            prevForServer[entry.key] =
                List<String>.from(listForServer);
          }
        }

        Map<String, List<String>> normalize(
            Map<String, List<String>> src) {
          return {
            for (final e in src.entries)
              e.key: (List<String>.from(e.value)..sort())
          };
        }

        final normalizedPrev = normalize(prevForServer);
        final normalizedNew = normalize(res);

        final mapsEqual = const DeepCollectionEquality()
            .equals(normalizedPrev, normalizedNew);

        if (!mapsEqual) {
          store.dispatch(syncSubscribedProfiles(server, res));
        }

        StatusSubscriptionManager()
            .cacheFor(server, NVRAPICall.fetchSubscribedProfiles);
      }
    });
  }

  return fetch(
      server,
      '[PushNotify] Fetching subscribed profiles for server $server',
      execute,
      NVRAPICall.fetchSubscribedProfiles);
}

/// If no links are specified, all links for the profile are subscribed to
ThunkAction<AppState> updateProfileSubscription(
    {required EvEventMonitoringProfile profile,
    List<EvEventProfileLink>? links}) {
  return (store) async {
    await _unsubscribeLinks(store, profile);

    for (String server in getServersForProfile(store.state, profile.id)) {
      String clientRegId = server_selectors
          .getServerClientRegistrationId(store.state, server);
      List<String> linkGuids =
          (links?.isEmpty ?? true ? profile.links : links!)
              .where((element) => element.server == server)
              .map((e) => e.guid)
              .toList();

      // Record the user's desired subscription independently of FCM. This
      // drives the focused-web EventPublisher stream when notification
      // permission, the FCM token, or NVR push registration is unavailable.
      await store.dispatch(
        updateLocalSubscription(server, profile.id, linkGuids),
      );

      await execNvrApi(store, NVRAPICall.pushNotifySubscribe, server,
          (channel) async {
        if (clientRegId.isEmpty) {
          await store.dispatch(registerPushNotify(server));
          clientRegId = server_selectors
              .getServerClientRegistrationId(store.state, server);
        }
        if (clientRegId.isEmpty) return; // No valid push registration

        try {
          await EvGrpcApi().subscribeToProfileLinks(
              channel, profile.id, linkGuids, clientRegId);
        } catch (e) {
          Logger().warn(
              '[PushNotify] subscribeToProfileLinks failed for $server/$clientRegId; re-registering and retrying once: $e');
          await store.dispatch(registerPushNotify(server));
          clientRegId = server_selectors
              .getServerClientRegistrationId(store.state, server);
          if (clientRegId.isEmpty) return;

          await EvGrpcApi().subscribeToProfileLinks(
              channel, profile.id, linkGuids, clientRegId);
        }
      });
    }

    for (String server in getServersForProfile(store.state, profile.id)) {
      store.dispatch(fetchSubscribedProfiles(server));
    }
  };
}

Future<void> _unsubscribeLinks(
    Store<AppState> store, EvEventMonitoringProfile profile) async {
  dev.log('[PushNotify] _unsubscribeLinks');
  // getServersForProfile() only reflects which servers *define* this
  // profile, which is not necessarily the same set of servers the profile
  // is actually *subscribed* on (subscriptions are tracked independently,
  // server-side, and can end up on a server that doesn't currently define
  // the profile). Union both so we never leave a live subscription behind.
  final subscribedServers =
      getSubscribedLinks(store.state)[profile.id]?.keys.toSet() ??
          <String>{};
  final definedServers =
      getServersForProfile(store.state, profile.id).toSet();
  final servers = {...subscribedServers, ...definedServers};
  dev.log(
      '[PushNotify] _unsubscribeLinks servers to process: $servers (subscribed: $subscribedServers, defined: $definedServers)');
  for (String server in servers) {
    String clientRegId = server_selectors
        .getServerClientRegistrationId(store.state, server);
    dev.log(
        '[PushNotify] getServerClientRegistrationId clientRegId: $clientRegId, server: $server');

    if (clientRegId.isNotEmpty) {
      // Send the same link guids used to subscribe. Some servers match
      // subscriptions on the exact (profileId, eventLinkGuids) pair, so
      // omitting them can cause the unsubscribe to be a silent no-op.
      final linkGuids =
          getSubscribedLinks(store.state)[profile.id]?[server] ??
              profile.links
                  .where((l) => l.server == server)
                  .map((l) => l.guid)
                  .toList();
      await execNvrApi(store, NVRAPICall.pushNotifyUnsubscribe, server,
          (channel) async {
        dev.log(
            '[PushNotify] unsubscribeToProfileLinks clientRegId: $clientRegId, server: $server, linkGuids: $linkGuids');
        await EvGrpcApi().unsubscribeToProfileLinks(
            channel, profile.id, linkGuids, clientRegId);
      });
    }
  }
}

ThunkAction<AppState> unsubscribeFromProfile(
    {required EvEventMonitoringProfile profile}) {
  return (store) async {
    await _unsubscribeLinks(store, profile);
    final subscribedServers =
        getSubscribedLinks(store.state)[profile.id]?.keys.toSet() ??
            <String>{};
    final servers = {
      ...subscribedServers,
      ...getServersForProfile(store.state, profile.id)
    };
    for (String server in servers) {
      dev.log(
          '[PushNotify] updateLocalSubscription -> server: $server');
      await store
          .dispatch(updateLocalSubscription(server, profile.id, []));
    }

    // Diagnostic verification: re-fetch subscriptions straight from the
    // server for each affected server and log whether the profile still
    // shows up as subscribed. If it does, the unsubscribe RPC did not
    // actually remove it server-side even though it didn't throw.
    for (String server in servers) {
      await store.dispatch(fetchSubscribedProfiles(server));
      final stillSubscribed =
          getSubscribedLinks(store.state)[profile.id]?[server];
      dev.log(
          '[PushNotify] post-unsubscribe verification -> server: $server, '
          'profileId: ${profile.id}, stillSubscribedLinks: $stillSubscribed');
    }
  };
}

ThunkAction<AppState> updateLocalSubscription(
    String server, String profileId, List<String> links) {
  return (store) async {
    final newSubscribedProfileLinks = {
      for (final entry in getSubscribedLinks(store.state).entries)
        entry.key: {
          for (final serverEntry in entry.value.entries)
            serverEntry.key: List<String>.from(serverEntry.value),
        },
    };

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

ThunkAction<AppState> unsubscribeProfilesForServer(
    {required String slug}) {
  return (store) async {
    var links = getSubscribedLinks(store.state);
    for (var profile in links.entries) {
      var servers = getServersForProfile(store.state, profile.key);
      if (servers.contains(slug)) {
        String clientRegId = server_selectors
            .getServerClientRegistrationId(store.state, slug);
        if (clientRegId.isNotEmpty) {
          final linkGuids = profile.value[slug] ?? [];
          await execNvrApi(
              store, NVRAPICall.pushNotifyUnsubscribe, slug,
              (channel) async {
            await EvGrpcApi().unsubscribeToProfileLinks(
                channel, profile.key, linkGuids, clientRegId);
          });
        }
        store.dispatch(
            syncSubscribedProfiles(slug, {profile.key: []}));
      }
    }
  };
}

ThunkAction<AppState> unsubscribeAllPushNotifications() {
  return (store) async {
    var links = getSubscribedLinks(store.state);
    if (links.isNotEmpty) {
      List<String> slugs = server_selectors.getSlugs(store.state);
      // unregister push notifications
      await Future.wait(slugs.map((e) async {
        await store.dispatch(unregisterPushNotify(e));
      }));
    }
  };
}

ThunkAction<AppState> syncSubscribedProfiles(
    String server, Map<String, List<String>> subscribedprofiles) {
  return (store) async {
    final newSubscribedProfileLinks =
        Map<String, Map<String, List<String>>>.from(
            getSubscribedLinks(store.state));

    // cleanup profiles no longer present
    for (var item in newSubscribedProfileLinks.entries.toList()) {
      final incoming = subscribedprofiles[item.key];
      if (incoming == null) {
        item.value.remove(server);
      } else {
        // incoming exists; will be set below
      }
      //if the profile has empty links removing it from list
      if (item.value.isEmpty) {
        newSubscribedProfileLinks.remove(item.key);
      }
    }

    // apply incoming (skip empty lists by removing server)
    for (var entry in subscribedprofiles.entries) {
      final links = entry.value;
      if (links.isEmpty) {
        // if empty => ensure removal of this server from that profile
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
    String serverSlug, List<EvEventMonitoringProfile> inProfiles) {
  return (store) async {
    store.dispatch(mergeProfileFragments(serverSlug, inProfiles));

    final newProfileServersMap =
        Map<String, List<String>>.from(getProfileServersMap(store.state));
    final newProfiles =
        List<EvEventMonitoringProfile>.from(getProfiles(store.state));

    final keys = <String>[];

    for (var p in inProfiles) {
      var key = p.id;
      if (!newProfileServersMap.containsKey(key)) {
        newProfileServersMap[key] = [serverSlug];
      }
      if (!(newProfileServersMap[key]!.contains(serverSlug))) {
        newProfileServersMap[key]?.add(serverSlug);
      }
    }

    for (var entry in newProfileServersMap.entries) {
      //if the serverSlug has no views or there is a view in the map
      //that is not in the incoming list of views purge that server from list
      if (inProfiles.isEmpty ||
          inProfiles.firstWhereOrNull((g) => g.id == entry.key) ==
              null) {
        //remove server slug from view list of servers
        entry.value.remove(serverSlug);

        //if that empties the list remove the view completely
        if (entry.value.isEmpty) {
          newProfiles.removeWhere((v) => v.id == entry.key);
        }
      }

      //add all the views associated with server to be updated
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

void mergeProfiles(List<EvEventMonitoringProfile> profileFragments,
    {required List<EvEventMonitoringProfile> profiles}) {
  if (profileFragments.isEmpty) return;

  List<EvEventProfileLink> links = [];
  for (var gf in profileFragments) {
    links.addAll(gf.links);
  }
  var found = profiles.firstWhereOrNull(
      (existing) => existing.id == profileFragments.first.id);
  if (found == null) {
    profiles.add(profileFragments.first);
  } else {
    if (links.isEmpty) {
      profiles.remove(found);
    } else {
      // Make sure we update the name, desc, etc
      found = found.copyWith(
          name: profileFragments.first.name,
          description: profileFragments.first.description,
          type: profileFragments.first.type,
          flags: profileFragments.first.flags,
          links: links);
      final index = profiles.indexWhere(
          (existing) => existing.id == profileFragments.first.id);
      profiles[index] = found;
    }
  }
}
