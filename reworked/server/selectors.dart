Map<String, Server> getServersBySlug(AppState state) => state.server.bySlug;

Server? getServer(AppState state, String slug) => getServersBySlug(state)[slug];

String getServerAddress(AppState state, String slug) =>
    getServer(state, slug)?.connectionAddress ?? '';

String getServerMacAddress(AppState state, String slug) =>
    getServer(state, slug)?.macAddress ?? slug;

int getServerPort(AppState state, String slug) =>
    getServer(state, slug)?.port ?? 0;

String getServerName(AppState state, String slug) =>
    getServer(state, slug)?.name ?? '';

APICallState getServerConnectionState(AppState state, String slug) =>
    getServer(state, slug)?.connectionState ?? APICallState.errorUnknown;

bool getServerIsConnected(AppState state, String slug) =>
    getServer(state, slug)?.isConnected ?? false;

bool checkValidLicenseForServers(AppState state) {
  return getServers(state).any(
    (server) =>
        server.licenseType == LicenseType.pro ||
        server.licenseType == LicenseType.enterprise,
  );
}

bool isServerHasValidLicense(AppState state, String slug) {
  final license = getServerLicenseType(state, slug);
  return license == LicenseType.pro || license == LicenseType.enterprise;
}

APICallState getServerStatus(AppState state, String slug) =>
    getServer(state, slug)?.connectionState ?? APICallState.pending;

String getSessionID(AppState state, String slug) =>
    getServer(state, slug)?.sessionId ?? '';

bool checkUserDisconnectedServer(AppState state, String slug) =>
    getServer(state, slug)?.isUserDisconnected ?? false;

int getTimezoneOffset(AppState state, String slug) =>
    getServer(state, slug)?.timezoneOffset ?? 0;

LicenseType getServerLicenseType(AppState state, String slug) =>
    getServer(state, slug)?.licenseType ?? LicenseType.badLicense;

bool getHasCaseLicense(AppState state, Iterable<String> serverSlugs) {
  return serverSlugs.any((slug) {
    final license = getServer(state, slug)?.licenseType;
    return license == LicenseType.enterprise || license == LicenseType.pro;
  });
}

String getServerRemoteAddress(AppState state, String slug) =>
    getServer(state, slug)?.remoteAddress ?? prodSwitchboardUrl;

bool getServerIsRemote(AppState state, String slug) =>
    getServer(state, slug)?.isRemoteConnection ?? false;

bool getIsLicensedForBookmarks(AppState state) =>
    _memoizedIsLicensedForBookmarks(state);

bool getIsServerLicensedForBookmarks(AppState state, String serverSlug) {
  final license = getServer(state, serverSlug)?.licenseType;
  return license == LicenseType.enterprise || license == LicenseType.pro;
}

bool anyServerSupportsVideoPush(AppState state) {
  return getServers(state).any(
    (server) =>
        server.isConnected &&
        server.features.any((feature) => feature.videoPush.singleLive),
  );
}

bool anySelectedServerSupportsVideoPush(AppState state, List<String> slugs) {
  return slugs.any((slug) => serverSupportsVideoPush(state, slug));
}

bool serverSupportsVideoPush(AppState state, String slug) =>
    getVideoPushCapabilities(
      state,
      slug,
    ).any((feature) => feature.videoPush.singleLive);

bool serverSupportsMultiServerLiveVideoPush(AppState state, String slug) =>
    getVideoPushCapabilities(
      state,
      slug,
    ).any((feature) => feature.videoPush.multiLive);

bool serverSupportsSearchVideoPush(AppState state, String slug) =>
    getVideoPushCapabilities(
      state,
      slug,
    ).any((feature) => feature.videoPush.singleSearch);

bool serverSupportsMultiServerSearchVideoPush(AppState state, String slug) =>
    getVideoPushCapabilities(
      state,
      slug,
    ).any((feature) => feature.videoPush.multiSearch);

final _memoizedVideoPushCapabilities =
    createSelector1<(AppState, String), Server?, List<EvFeature>>(
      (args) => getServer(args.$1, args.$2),
      (server) => List<EvFeature>.unmodifiable(server?.features ?? const []),
    );

List<EvFeature> getVideoPushCapabilities(AppState state, String slug) =>
    _memoizedVideoPushCapabilities((state, slug));

int getServerCount(AppState state) => getServers(state).length;

List<String> getSlugs(AppState state) => _memoizedSlugs(state);

List<Server> getServers(AppState state) => _memoizedServers(state);

List<String> getUninitializedSlugs(AppState state) =>
    _memoizedUninitializedSlugs(state);

List<String> getInitializedSlugs(AppState state) =>
    _memoizedInitializedSlugs(state);

String getServerSlugBySessionId(AppState state, String sessionId) =>
    _memoizedServerBySessionId(state)[sessionId]?.slug ?? '';

Server getServerByMac(AppState state, String mac) =>
    _memoizedServerByMac(state)[mac] ?? Server();

Server getServerByName(AppState state, String serverName) => getServers(
  state,
).firstWhere((server) => server.name == serverName, orElse: Server.new);

List<EvView> getServerViews(AppState state, String server) =>
    _memoizedServerViewsBySlug(state)[server] ?? const [];

List<EvView> getViewFragments(AppState state, String viewName) {
  return [
    for (final server in getServersBySlug(state).values)
      if (getViewFragmentsByServer(state, server.slug)[viewName]
          case final fragment?)
        fragment,
  ];
}

Map<String, EvView> getViewFragmentsByServer(
  AppState state,
  String serverSlug,
) => getServer(state, serverSlug)?.viewFragments ?? const {};

List<EvGroup> getServerGroups(AppState state, String server) =>
    getServer(state, server)?.groupFragments.values.toList() ?? const [];

List<EvGroup> getGroupFragments(AppState state, String groupId) {
  return [
    for (final server in getServersBySlug(state).values)
      if (getGroupFragmentsByServer(state, server.slug)[groupId]
          case final fragment?)
        fragment,
  ];
}

Map<String, EvGroup> getGroupFragmentsByServer(
  AppState state,
  String serverSlug,
) => getServer(state, serverSlug)?.groupFragments ?? const {};

List<EvEventMonitoringProfile> getProfileFragments(
  AppState state,
  String profileId,
) {
  return [
    for (final server in getServersBySlug(state).values)
      if (getProfileFragmentsByServer(state, server.slug)[profileId]
          case final fragment?)
        fragment,
  ];
}

List<EvVideoPushTarget> getVideoPushTargets(AppState state, String targetId) =>
    _memoizedVideoPushTargets((state, targetId));

final _memoizedVideoPushTargets =
    createSelector2<
      (AppState, String),
      List<Server>,
      String,
      List<EvVideoPushTarget>
    >(
      (args) => getServers(args.$1),
      (args) => args.$2,
      (servers, targetId) => List.unmodifiable([
        for (final server in servers)
          if (server.videoPushTargets[targetId] case final target?) target,
      ]),
    );

List<EvVideoPushLayout> getVideoPushLayouts(AppState state, String layoutId) =>
    _memoizedVideoPushLayouts((state, layoutId));

final _memoizedVideoPushLayouts =
    createSelector2<
      (AppState, String),
      List<Server>,
      String,
      List<EvVideoPushLayout>
    >(
      (args) => getServers(args.$1),
      (args) => args.$2,
      (servers, layoutId) => List.unmodifiable([
        for (final server in servers)
          if (server.videoPushLayouts[layoutId] case final layout?) layout,
      ]),
    );

Map<String, EvEventMonitoringProfile> getProfileFragmentsByServer(
  AppState state,
  String serverSlug,
) => getServer(state, serverSlug)?.profileFragments ?? const {};

String getServerClientRegistrationId(AppState state, String serverSlug) =>
    state.server.serverToClientRegistrationId[serverSlug] ?? '';

String getServerLastFcmToken(AppState state, String serverSlug) =>
    state.server.serverToLastFcmToken[serverSlug] ?? '';

List<String> getDisabledServers(AppState state) => state.server.disabledServers;

List<Server> getSortedServers(AppState state) => _memoizedSortedServers(state);

String getServerURLBySerial(AppState state, String serial) =>
    _memoizedServerBySerial(state)[serial]?.url ?? '';

String getServerBySerial(AppState state, String serial) =>
    _memoizedServerBySerial(state)[serial]?.slug ?? '';

List<Server> getEnabledServers(AppState state) =>
    _memoizedEnabledServers(state);

List<String> getEnabledServersList(AppState state) =>
    _memoizedEnabledServersList(state);

List<Server> getConnectedServers(AppState state) =>
    _memoizedConnectedServers(state);

List<String> getConnectedServersList(AppState state) =>
    _memoizedConnectedServersList(state);

List<Server> getPrivilegedServers(
  AppState state,
  Set<Privilege> requiredPrivileges,
) => _memoizedPrivilegedServers((state, requiredPrivileges));

bool getServerEnabledState(AppState state, String slug) =>
    !_memoizedDisabledServerSlugs(state).contains(slug);

String getServerURL(AppState state, String slug) {
  final serverUrl = getServer(state, slug)?.url;
  if (serverUrl != null) return serverUrl;

  final credentials = getSavedCredentailsList(state);
  return credentials.keys.firstWhereOrNull(
        (key) => credentials[key]!.keys.contains(slug),
      ) ??
      '';
}

APICallState getOverallServerState(AppState state, String slug) {
  final connection = getServerStatus(state, slug);
  if (connection == APICallState.keepAliveDead) {
    return APICallState.keepAliveDead;
  }

  final mac = getServerMacAddress(state, slug);
  final init = getServerAPICallState(state, slug, NVRAPICall.doLogin);
  final login = getAuthAPICallState(state, mac, AuthAPICall.doLogin);
  final version = getAuthAPICallState(state, mac, AuthAPICall.getVersion);
  final switchboardRegister = getAuthAPICallState(
    state,
    mac,
    AuthAPICall.doSwitchboardRegister,
  );
  final switchboardTunnel = getAuthAPICallState(
    state,
    mac,
    AuthAPICall.doSwitchboardTunnel,
  );

  if ([
    login,
    version,
    switchboardRegister,
    switchboardTunnel,
  ].contains(APICallState.errorTimeout)) {
    return APICallState.errorTimeout;
  }
  if (switchboardRegister != null && switchboardRegister != APICallState.ok) {
    return switchboardRegister;
  }
  if (switchboardTunnel != null &&
      switchboardTunnel != APICallState.serverAlreadyExists &&
      switchboardTunnel != APICallState.ok) {
    return switchboardTunnel;
  }
  if (version != null && version != APICallState.ok) return version;
  if (login != null &&
      login != APICallState.ok &&
      login != APICallState.loggedIn) {
    return login;
  }
  if (init != null && init != APICallState.ok) return init;
  return connection;
}

final _memoizedServerBySessionId =
    createSelector1<AppState, Map<String, Server>, Map<String, Server>>(
      getServersBySlug,
      (servers) => Map.unmodifiable({
        for (final server in servers.values) server.sessionId: server,
      }),
    );

final _memoizedServerByMac =
    createSelector1<AppState, List<Server>, Map<String, Server>>(
      getServers,
      (servers) => Map.unmodifiable({
        for (final server in servers) server.macAddress: server,
      }),
    );

final _memoizedServerViewsBySlug =
    createSelector1<AppState, Map<String, Server>, Map<String, List<EvView>>>(
      getServersBySlug,
      (servers) => Map.unmodifiable({
        for (final entry in servers.entries)
          entry.key: List<EvView>.unmodifiable(
            entry.value.viewFragments.values,
          ),
      }),
    );

final _memoizedServerBySerial =
    createSelector1<AppState, List<Server>, Map<String, Server>>(
      getSortedServers,
      (servers) => Map.unmodifiable({
        for (final server in servers) server.serial: server,
      }),
    );

final _memoizedDisabledServerSlugs =
    createSelector1<AppState, List<String>, Set<String>>(
      getDisabledServers,
      (servers) => Set<String>.unmodifiable(servers),
    );

final _memoizedSlugs =
    createSelector1<AppState, Map<String, Server>, List<String>>(
      getServersBySlug,
      (servers) => List<String>.unmodifiable(servers.keys),
    );

final _memoizedServers =
    createSelector1<AppState, Map<String, Server>, List<Server>>(
      getServersBySlug,
      (servers) => List<Server>.unmodifiable(servers.values),
    );

final _memoizedUninitializedSlugs =
    createSelector2<
      AppState,
      List<String>,
      Map<String, Map<NVRAPICall, APICallRecord>>,
      List<String>
    >(
      getSlugs,
      getNvrAPICallStates,
      (slugs, calls) => List.unmodifiable(
        slugs.where((slug) => calls[slug]?[NVRAPICall.doLogin] == null),
      ),
    );

final _memoizedInitializedSlugs =
    createSelector2<
      AppState,
      List<String>,
      Map<String, Map<NVRAPICall, APICallRecord>>,
      List<String>
    >(
      getSlugs,
      getNvrAPICallStates,
      (slugs, calls) => List.unmodifiable(
        slugs.where((slug) {
          final status = calls[slug]?[NVRAPICall.doLogin]?.callState;
          return status == APICallState.ok ||
              status == APICallState.keepAliveDead;
        }),
      ),
    );

final _memoizedSortedServers =
    createSelector1<AppState, List<Server>, List<Server>>(getServers, (
      servers,
    ) {
      final sorted = List<Server>.from(servers)..sort();
      return List.unmodifiable(sorted);
    });

final _memoizedEnabledServers =
    createSelector2<AppState, List<Server>, List<String>, List<Server>>(
      getServers,
      getDisabledServers,
      (servers, disabled) {
        final result =
            servers.where((server) => !disabled.contains(server.slug)).toList()
              ..sort();
        return List.unmodifiable(result);
      },
    );

final _memoizedEnabledServersList =
    createSelector1<AppState, List<Server>, List<String>>(
      getEnabledServers,
      (servers) => List.unmodifiable(servers.map((server) => server.slug)),
    );

final _memoizedConnectedServers =
    createSelector2<AppState, List<Server>, List<String>, List<Server>>(
      getServers,
      getDisabledServers,
      (servers, disabled) {
        final result =
            servers
                .where(
                  (server) =>
                      server.isConnected && !disabled.contains(server.slug),
                )
                .toList()
              ..sort();
        return List.unmodifiable(result);
      },
    );

final _memoizedConnectedServersList =
    createSelector1<AppState, List<Server>, List<String>>(
      getConnectedServers,
      (servers) => List.unmodifiable(servers.map((server) => server.slug)),
    );

final _memoizedPrivilegedServers =
    createSelector3<
      (AppState, Set<Privilege>),
      Map<String, Server>,
      Map<String, Set<Privilege>>,
      Set<Privilege>,
      List<Server>
    >(
      (args) => getServersBySlug(args.$1),
      (args) => getPrivilegesByServer(args.$1),
      (args) => args.$2,
      (serversBySlug, privilegesByServer, required) => List.unmodifiable(
        privilegesByServer.entries
            .where((entry) => entry.value.containsAll(required))
            .map((entry) => serversBySlug[entry.key])
            .whereType<Server>()
            .where((server) => server.isConnected),
      ),
    );

final _memoizedIsLicensedForBookmarks =
    createSelector1<AppState, List<Server>, bool>(
      getServers,
      (servers) => servers.any(
        (server) =>
            server.licenseType == LicenseType.enterprise ||
            server.licenseType == LicenseType.pro,
      ),
    );
