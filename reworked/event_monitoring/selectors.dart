class _EventProfileProjection {
  final List<EvEventMonitoringProfile> profiles;
  final Map<String, List<String>> serversByProfile;

  const _EventProfileProjection(this.profiles, this.serversByProfile);
}

_EventProfileProjection _buildProfileProjection(
  Map<String, Server> serversBySlug,
) {
  final fragmentsByProfile = <String, List<EvEventMonitoringProfile>>{};
  final serversByProfile = <String, List<String>>{};

  for (final serverEntry in serversBySlug.entries) {
    for (final fragment in serverEntry.value.profileFragments.values) {
      if (fragment.links.isEmpty) continue;

      fragmentsByProfile.putIfAbsent(fragment.id, () => []).add(fragment);
      serversByProfile.putIfAbsent(fragment.id, () => []).add(serverEntry.key);
    }
  }

  final profiles = <EvEventMonitoringProfile>[];
  for (final entry in fragmentsByProfile.entries) {
    final fragments = entry.value;
    final links = <EvEventProfileLink>[
      for (final fragment in fragments) ...fragment.links,
    ];
    if (links.isEmpty) continue;

    profiles.add(fragments.first.copyWith(links: links));
  }

  return _EventProfileProjection(
    List.unmodifiable(profiles),
    Map.unmodifiable({
      for (final entry in serversByProfile.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    }),
  );
}

final _memoizedProfileProjection =
    createSelector1<AppState, Map<String, Server>, _EventProfileProjection>(
      (state) => state.server.bySlug,
      _buildProfileProjection,
    );

Map<String, List<String>> getProfileServersMap(AppState state) =>
    _memoizedProfileProjection(state).serversByProfile;

List<EvEventMonitoringProfile> getProfiles(AppState state) =>
    _memoizedProfileProjection(state).profiles;

final _memoizedSortedProfiles =
    createSelector1<
      AppState,
      List<EvEventMonitoringProfile>,
      List<EvEventMonitoringProfile>
    >(getProfiles, (profiles) {
      final sorted = List<EvEventMonitoringProfile>.from(profiles)..sort();
      return List.unmodifiable(sorted);
    });

List<EvEventMonitoringProfile> getSortedProfiles(AppState state) =>
    _memoizedSortedProfiles(state);

EventMonitoringState _root(AppState state) => state.eventMonitoringState;

Map<String, Map<String, List<String>>> getSubscriptionsByServer(
  AppState state,
) => _root(state).subscriptionsByServer;

Map<String, List<String>> getSubscriptionsForServer(
  AppState state,
  String server,
) => _root(state).subscriptionsByServer[server] ?? const {};

Map<String, Map<String, List<String>>> _transposeSubscriptions(
  Map<String, Map<String, List<String>>> subscriptionsByServer,
) {
  final byProfile = <String, Map<String, List<String>>>{};
  for (final serverEntry in subscriptionsByServer.entries) {
    for (final profileEntry in serverEntry.value.entries) {
      if (profileEntry.value.isEmpty) continue;
      byProfile
          .putIfAbsent(profileEntry.key, () => {})
          .putIfAbsent(
            serverEntry.key,
            () => List<String>.unmodifiable(profileEntry.value),
          );
    }
  }

  return Map.unmodifiable({
    for (final entry in byProfile.entries)
      entry.key: Map<String, List<String>>.unmodifiable(entry.value),
  });
}

final _memoizedSubscribedLinks =
    createSelector1<
      AppState,
      Map<String, Map<String, List<String>>>,
      Map<String, Map<String, List<String>>>
    >((state) => _root(state).subscriptionsByServer, _transposeSubscriptions);

/// Compatibility selector for existing UI callers.
Map<String, Map<String, List<String>>> getSubscribedLinks(AppState state) =>
    _memoizedSubscribedLinks(state);

List<String> getSubsribedLinksForProfile(AppState state, String profileId) {
  final links = <String>{};
  for (final serverLinks
      in getSubscribedLinks(state)[profileId]?.values ?? const []) {
    links.addAll(serverLinks);
  }
  return List.unmodifiable(links);
}

List<String> getServersForProfile(AppState state, String profileId) =>
    getProfileServersMap(state)[profileId] ?? const [];

ProfileSubscriptionOperation? getProfileSubscriptionOperation(
  AppState state,
  String profileId,
) => _root(state).operationsByProfile[profileId];

bool profileIsConfirmedActive(AppState state, String profileId) =>
    getSubscribedLinks(state)[profileId]?.isNotEmpty ?? false;

bool profileIsEffectivelyActive(AppState state, String profileId) {
  final operation = getProfileSubscriptionOperation(state, profileId);
  if (operation?.status == ProfileSubscriptionOperationStatus.pending) {
    return operation!.desiredActive;
  }
  return profileIsConfirmedActive(state, profileId);
}

final _memoizedEffectiveProfileActivity =
    createSelector3<
      AppState,
      List<EvEventMonitoringProfile>,
      Map<String, Map<String, List<String>>>,
      Map<String, ProfileSubscriptionOperation>,
      Map<String, bool>
    >(
      getProfiles,
      (state) => _root(state).subscriptionsByServer,
      (state) => _root(state).operationsByProfile,
      (profiles, subscriptionsByServer, operations) {
        final confirmedActive = <String>{};
        for (final serverSnapshot in subscriptionsByServer.values) {
          confirmedActive.addAll(
            serverSnapshot.entries
                .where((entry) => entry.value.isNotEmpty)
                .map((entry) => entry.key),
          );
        }

        return Map.unmodifiable({
          for (final profile in profiles)
            profile.id:
                operations[profile.id]?.status ==
                    ProfileSubscriptionOperationStatus.pending
                ? operations[profile.id]!.desiredActive
                : confirmedActive.contains(profile.id),
        });
      },
    );

Map<String, bool> getEffectiveProfileActivity(AppState state) =>
    _memoizedEffectiveProfileActivity(state);

int getNextProfileOperationRevision(AppState state, String profileId) =>
    (_root(state).operationsByProfile[profileId]?.revision ?? 0) + 1;

String getLinkSourceDisplayName(AppState state, EvEventProfileLink link) {
  if (link.sourceID.isEmpty || link.sourceID == '0') {
    return '${LocaleKeys.anyWord.tr()} - ${getServerName(state, link.server)}';
  }

  String displayName;
  switch (link.source.type) {
    case EventSource.EVENT_SOURCE_HEALTH:
      displayName =
          healthEventDisplayText[link.source.id.healthId.event] ??
          LocaleKeys.unknown.tr();
    case EventSource.EVENT_SOURCE_VIDEO_LOSS:
    case EventSource.EVENT_SOURCE_VIDEO_MOTION:
    case EventSource.EVENT_SOURCE_DISCONNECT_VIDEO:
    case EventSource.EVENT_SOURCE_RECORD_IDLE:
      displayName = getCameraName(
        state,
        ServerItemSlug.generateSlug(
          link.server,
          (Camera).toString(),
          link.sourceID,
        ),
      );
    case EventSource.EVENT_SOURCE_SECURITY:
      displayName = getEvSecuritySensorName(
        state,
        ServerItemSlug.generateSlug(
          link.server,
          (EvSecuritySensor).toString(),
          link.sourceID,
        ),
      );
    case EventSource.EVENT_SOURCE_DISCONNECT_SECURITY:
      displayName = getEvSecurityDeviceName(
        state,
        ServerItemSlug.generateSlug(
          link.server,
          (EvSecurityDevice).toString(),
          link.sourceID,
        ),
      );
    case EventSource.EVENT_SOURCE_DISCONNECT_AUDIO:
      displayName = getAudioName(
        state,
        ServerItemSlug.generateSlug(
          link.server,
          (Audio).toString(),
          link.sourceID,
        ),
      );
    case EventSource.EVENT_SOURCE_SOFT_TRIGGER:
      displayName = getSoftTriggerName(
        state,
        ServerItemSlug.generateSlug(
          link.server,
          (SoftTrigger).toString(),
          link.sourceID,
        ),
      );
    case EventSource.EVENT_SOURCE_SERIAL_PROFILE:
      final profileSlug = ServerItemSlug.generateSlug(
        link.server,
        (EvSerialProfile).toString(),
        link.sourceID,
      );
      if (link.source.id.hasSerialKeywordId()) {
        displayName = getKeywordNameForProfile(
          state,
          profileSlug,
          link.source.id.serialKeywordId.keywordId.toString(),
        );
      } else if (link.source.id.hasSerialRuleId()) {
        displayName = getRuleNameForProfile(
          state,
          profileSlug,
          link.source.id.serialRuleId.ruleId.toString(),
        );
      } else {
        displayName = getSerialProfileName(state, profileSlug);
      }
    case EventSource.EVENT_SOURCE_TIME_TRIGGER:
      displayName = getTimeTriggerName(
        state,
        ServerItemSlug.generateSlug(
          link.server,
          (EvTimeTrigger).toString(),
          link.sourceID,
        ),
      );
    case EventSource.EVENT_SOURCE_ANALYTICS:
      final analyticSlug = ServerItemSlug.generateSlug(
        link.server,
        (EvAnalytic).toString(),
        link.sourceID,
      );
      final cameraId = getCameraForAnalytic(state, analyticSlug);
      final audioId = getAudioForAnalytic(state, analyticSlug);
      final analyticName = getAnalyticName(state, analyticSlug);
      if (cameraId.isNotEmpty) {
        displayName =
            '${getCameraName(state, ServerItemSlug.generateSlug(link.server, (Camera).toString(), cameraId))} - $analyticName';
      } else if (audioId.isNotEmpty) {
        displayName =
            '${getAudioName(state, ServerItemSlug.generateSlug(link.server, (Audio).toString(), audioId))} - $analyticName';
      } else {
        displayName = analyticName;
      }
    case EventSource.EVENT_SOURCE_INPUT_TRIGGER:
      displayName = getInputTriggerName(
        state,
        ServerItemSlug.generateSlug(
          link.server,
          (EvInputTrigger).toString(),
          link.sourceID,
        ),
      );
    default:
      displayName = LocaleKeys.unknown.tr();
  }

  return displayName.isEmpty ? LocaleKeys.unknown.tr() : displayName;
}

Iterable<EvEventMonitoringProfile> getServerAssociatedProfiles(
  AppState state,
  String serverSlug,
) {
  final profilesById = {
    for (final profile in getProfiles(state)) profile.id: profile,
  };

  return getProfileServersMap(state).entries
      .where((entry) => entry.value.contains(serverSlug))
      .map((entry) => profilesById[entry.key])
      .whereType<EvEventMonitoringProfile>();
}
