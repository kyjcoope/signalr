class EventMonitorListModel extends EvViewModel {
  final List<EvEventMonitoringProfile> profiles;
  final bool hasEventMonitoringPrivileges;
  final Map<String, bool> profileActivity;
  final Map<String, Map<String, List<String>>> subscribedLinks;

  EventMonitorListModel(super.store)
    : profiles = getSortedProfiles(store.state),
      hasEventMonitoringPrivileges = validatePrivileges(store.state, {
        Privilege.eventMonitor,
      }),
      profileActivity = getEffectiveProfileActivity(store.state),
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

  bool profileIsActive(EvEventMonitoringProfile profile) =>
      profileActivity[profile.id] ?? false;

  void subscribeAll(EvEventMonitoringProfile profile) {
    dev.log('[PushNotify] subscribeAll');
    store.dispatch(updateProfileSubscription(profile: profile));
  }

  void unsubscribeAll(EvEventMonitoringProfile profile) {
    dev.log('[PushNotify] unsubscribeAll');
    store.dispatch(unsubscribeFromProfile(profile: profile));
  }

  @override
  List<Object?> get props => [
    profiles,
    hasEventMonitoringPrivileges,
    profileActivity,
    subscribedLinks,
  ];
}
