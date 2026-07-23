enum EventMonitoringActionType {
  replaceServerSubscriptions,
  clearServerSubscriptions,
  beginProfileSubscriptionOperation,
  completeProfileSubscriptionOperation,
}

abstract class EventMonitoringAction extends BaseAction {
  @override
  ActionType get type => ActionType.eventMonitoring;
  EventMonitoringActionType get subtype;
  const EventMonitoringAction();
}

Map<String, List<String>> _freezeActionSubscriptionSnapshot(
  Map<String, List<String>> source,
) {
  return Map.unmodifiable({
    for (final entry in source.entries)
      entry.key: List<String>.unmodifiable(entry.value),
  });
}

class ReplaceServerSubscriptions extends EventMonitoringAction {
  final String server;
  final Map<String, List<String>> subscriptions;

  ReplaceServerSubscriptions(
    this.server,
    Map<String, List<String>> subscriptions,
  ) : subscriptions = _freezeActionSubscriptionSnapshot(subscriptions);

  @override
  EventMonitoringActionType get subtype =>
      EventMonitoringActionType.replaceServerSubscriptions;
}

class ClearServerSubscriptions extends EventMonitoringAction {
  final String server;

  const ClearServerSubscriptions(this.server);

  @override
  EventMonitoringActionType get subtype =>
      EventMonitoringActionType.clearServerSubscriptions;
}

class BeginProfileSubscriptionOperation extends EventMonitoringAction {
  final String profileId;
  final bool desiredActive;
  final int revision;

  const BeginProfileSubscriptionOperation({
    required this.profileId,
    required this.desiredActive,
    required this.revision,
  });

  @override
  EventMonitoringActionType get subtype =>
      EventMonitoringActionType.beginProfileSubscriptionOperation;
}

class CompleteProfileSubscriptionOperation extends EventMonitoringAction {
  final String profileId;
  final int revision;
  final Map<String, String> failuresByServer;

  CompleteProfileSubscriptionOperation({
    required this.profileId,
    required this.revision,
    Map<String, String> failuresByServer = const {},
  }) : failuresByServer = Map.unmodifiable(failuresByServer);

  @override
  EventMonitoringActionType get subtype =>
      EventMonitoringActionType.completeProfileSubscriptionOperation;
}
