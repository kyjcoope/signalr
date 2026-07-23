enum ProfileSubscriptionOperationStatus { pending, succeeded, failed }

@immutable
class ProfileSubscriptionOperation extends Equatable {
  final int revision;
  final bool desiredActive;
  final ProfileSubscriptionOperationStatus status;
  final Map<String, String> failuresByServer;

  ProfileSubscriptionOperation({
    required this.revision,
    required this.desiredActive,
    required this.status,
    Map<String, String> failuresByServer = const {},
  }) : failuresByServer = Map.unmodifiable(failuresByServer);

  ProfileSubscriptionOperation complete(Map<String, String> failures) {
    return ProfileSubscriptionOperation(
      revision: revision,
      desiredActive: desiredActive,
      status: failures.isEmpty
          ? ProfileSubscriptionOperationStatus.succeeded
          : ProfileSubscriptionOperationStatus.failed,
      failuresByServer: failures,
    );
  }

  @override
  List<Object?> get props => [
    revision,
    desiredActive,
    status,
    failuresByServer,
  ];
}

Map<String, Map<String, List<String>>> _freezeStateSubscriptions(
  Map<String, Map<String, List<String>>> source,
) {
  return Map.unmodifiable({
    for (final serverEntry in source.entries)
      serverEntry.key: Map.unmodifiable({
        for (final profileEntry in serverEntry.value.entries)
          profileEntry.key: List<String>.unmodifiable(profileEntry.value),
      }),
  });
}

@immutable
class EventMonitoringState {
  /// Canonical server snapshots. This orientation matches the server API.
  final Map<String, Map<String, List<String>>> subscriptionsByServer;

  /// Latest operation per profile. Revisions prevent stale completions from
  /// overriding newer user intent.
  final Map<String, ProfileSubscriptionOperation> operationsByProfile;

  EventMonitoringState({
    Map<String, Map<String, List<String>>> subscriptionsByServer = const {},
    Map<String, ProfileSubscriptionOperation> operationsByProfile = const {},
  }) : subscriptionsByServer = _freezeStateSubscriptions(subscriptionsByServer),
       operationsByProfile = Map.unmodifiable(operationsByProfile);

  EventMonitoringState copyWith({
    Map<String, Map<String, List<String>>>? subscriptionsByServer,
    Map<String, ProfileSubscriptionOperation>? operationsByProfile,
  }) {
    return EventMonitoringState(
      subscriptionsByServer:
          subscriptionsByServer ?? this.subscriptionsByServer,
      operationsByProfile: operationsByProfile ?? this.operationsByProfile,
    );
  }
}
