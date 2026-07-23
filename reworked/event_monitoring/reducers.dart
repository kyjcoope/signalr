EventMonitoringState eventMonitoringStateReducer(
  EventMonitoringState state,
  dynamic action,
) {
  if (action is! EventMonitoringAction) return state;

  switch (action.subtype) {
    case EventMonitoringActionType.replaceServerSubscriptions:
      return _replaceServerSubscriptions(
        state,
        action as ReplaceServerSubscriptions,
      );
    case EventMonitoringActionType.clearServerSubscriptions:
      return _clearServerSubscriptions(
        state,
        action as ClearServerSubscriptions,
      );
    case EventMonitoringActionType.beginProfileSubscriptionOperation:
      return _beginProfileSubscriptionOperation(
        state,
        action as BeginProfileSubscriptionOperation,
      );
    case EventMonitoringActionType.completeProfileSubscriptionOperation:
      return _completeProfileSubscriptionOperation(
        state,
        action as CompleteProfileSubscriptionOperation,
      );
  }
}

EventMonitoringState _replaceServerSubscriptions(
  EventMonitoringState state,
  ReplaceServerSubscriptions action,
) {
  final next = Map<String, Map<String, List<String>>>.from(
    state.subscriptionsByServer,
  );

  if (action.subscriptions.isEmpty) {
    next.remove(action.server);
  } else {
    next[action.server] = action.subscriptions;
  }

  return state.copyWith(subscriptionsByServer: next);
}

EventMonitoringState _clearServerSubscriptions(
  EventMonitoringState state,
  ClearServerSubscriptions action,
) {
  if (!state.subscriptionsByServer.containsKey(action.server)) return state;

  final next = Map<String, Map<String, List<String>>>.from(
    state.subscriptionsByServer,
  )..remove(action.server);
  return state.copyWith(subscriptionsByServer: next);
}

EventMonitoringState _beginProfileSubscriptionOperation(
  EventMonitoringState state,
  BeginProfileSubscriptionOperation action,
) {
  final current = state.operationsByProfile[action.profileId];
  if (current != null && action.revision <= current.revision) return state;

  final next =
      Map<String, ProfileSubscriptionOperation>.from(state.operationsByProfile)
        ..[action.profileId] = ProfileSubscriptionOperation(
          revision: action.revision,
          desiredActive: action.desiredActive,
          status: ProfileSubscriptionOperationStatus.pending,
        );

  return state.copyWith(operationsByProfile: next);
}

EventMonitoringState _completeProfileSubscriptionOperation(
  EventMonitoringState state,
  CompleteProfileSubscriptionOperation action,
) {
  final current = state.operationsByProfile[action.profileId];
  if (current == null || current.revision != action.revision) return state;

  final next = Map<String, ProfileSubscriptionOperation>.from(
    state.operationsByProfile,
  )..[action.profileId] = current.complete(action.failuresByServer);

  return state.copyWith(operationsByProfile: next);
}
