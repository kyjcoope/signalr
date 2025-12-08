class EventMonitoringProfilesListPage extends StatefulWidget {
  final EventMonitorTab tab;
  final String searchFilter;
  final SortTypes sortType;

  const EventMonitoringProfilesListPage({
    super.key, // Ensure this key is receiving the PageStorageKey from the parent!
    required this.tab,
    required this.searchFilter,
    this.sortType = SortTypes.alpha,
  });

  @override
  State<EventMonitoringProfilesListPage> createState() =>
      _EventMonitoringProfilesListPage();
}

class _EventMonitoringProfilesListPage
    extends State<EventMonitoringProfilesListPage> {
  late EventMonitorListModel _model;

  // Local cache of what is currently shown in the AnimatedList
  List<EvEventMonitoringProfile> _filteredProfiles = [];

  // Initialize Key ONCE. Do not regenerate this unless absolutely necessary.
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  @override
  void initState() {
    super.initState();
    // No explicit scroll controller or animationTo(0) here.
    // We rely on PageStorageKey for scroll position.
  }

  void _storeInit(Store<AppState> store) {
    _model = EventMonitorListModel(store);
    // Initial calculation
    _recalculateFilteredProfiles(forceReset: true);
  }

  // Helper to calculate what the list *should* be based on Redux
  List<EvEventMonitoringProfile> _getComputedList() {
    final profiles = _model.profiles
        .where(
          (p) =>
              p.name.toLowerCase().contains(
                widget.searchFilter.toLowerCase(),
              ) &&
              _model.statusMatches(p, widget.tab),
        )
        .toList();

    return widget.sortType == SortTypes.alphaDesc
        ? profiles.reversed.toList()
        : profiles;
  }

  void _recalculateFilteredProfiles({bool forceReset = false}) {
    final newList = _getComputedList();

    // If we are forcing a reset (e.g. search filter changed),
    // or if the list length differs and it wasn't our manual toggle,
    // we rebuild the list.
    if (forceReset) {
      setState(() {
        _filteredProfiles = newList;
        // We do NOT create a new GlobalKey here.
        // That would kill the scroll position.
      });
    } else {
      // SMART UPDATE:
      // If the Redux update just confirms what we already did locally
      // (length matches), we just update the model reference and do nothing to the UI.
      if (_filteredProfiles.length == newList.length) {
        // The lists match in count, just update the backing data
        // so pure updates (like name changes) are reflected
        _filteredProfiles = newList;
      } else {
        // External update (e.g. another user added a profile),
        // or a sync issue. We have to hard reset.
        setState(() {
          _filteredProfiles = newList;
        });
      }
    }
  }

  void _modelUpdater(
    EventMonitorListModel? oldModel,
    EventMonitorListModel newModel,
  ) {
    if (!mounted) return;
    _model = newModel;

    if (!_model.hasEventMonitoringPrivileges) {
      Navigator.pushReplacementNamed(
        NavBarNavigationManager().context,
        RoutePaths.more.path,
      );
      return;
    }

    // Logic: Only force a visual reset if the parameters governing the list changed
    // (like search text). If just the data changed, let _recalculate handle the "Smart Update"
    _recalculateFilteredProfiles(forceReset: false);
  }

  @override
  void didUpdateWidget(EventMonitoringProfilesListPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    // If the tab, search, or sort changed, we MUST force a reset of the list content.
    if (widget.tab != oldWidget.tab ||
        widget.searchFilter != oldWidget.searchFilter ||
        widget.sortType != oldWidget.sortType) {
      _recalculateFilteredProfiles(forceReset: true);
    }
  }

  Widget _buildProfileDisplayCount(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Text(
            widget.tab.description(_filteredProfiles.length),
            style: evStyle(context, CraftStyle.fourteenFive),
          ),
        ],
      ),
    );
  }

  void _onToggle(bool value, int index) {
    if (index >= _filteredProfiles.length) return;

    final profile = _filteredProfiles[index];

    // 1. Optimistic UI: Remove it from the UI immediately
    setState(() {
      _filteredProfiles.removeAt(index);
    });

    // 2. Animate it out
    _listKey.currentState?.removeItem(
      index,
      (ctx, anim) => _staticEventProfileTile(
        profile,
        anim,
        // Keep the switch state visually consistent as it animates out
        state: value,
      ),
      duration: const Duration(milliseconds: 300),
    );

    // 3. Perform the Action
    // Because we updated the UI *before* the action,
    // when Redux returns with the new list, it will match our new _filteredProfiles length
    // and _recalculateFilteredProfiles will skip the hard reset.
    if (value) {
      _model.subscribeAll(profile);
    } else {
      _model.unsubscribeAll(profile);
    }
  }

  Widget _staticEventProfileTile(
    EvEventMonitoringProfile profile,
    Animation<double> animation, {
    bool state = false,
  }) => StaticEventProfileListItem(
    profile: profile,
    switchState: state,
    animation: animation,
    showIcon: false,
  );

  Widget _buildItem(
    BuildContext context,
    int index,
    Animation<double> animation,
  ) {
    if (index >= _filteredProfiles.length) {
      return const SizedBox.shrink();
    }

    return wrapDivider(
      SizeTransition(
        sizeFactor: animation,
        child: AnimatedEventProfileListItem(
          // Important: Pass a Key based on ID so Flutter can track this widget
          // if the list order shifts slightly
          key: ValueKey(_filteredProfiles[index].id),
          profile: _filteredProfiles[index],
          showIcon: false,
          initialState: _model.profileIsActive(_filteredProfiles[index]),
          onToggle: (value) => _onToggle(value, index),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StoreConnector<AppState, EventMonitorListModel>(
      converter: (store) => EventMonitorListModel(store),
      onInit: _storeInit,
      onWillChange: _modelUpdater,
      distinct: true,
      builder: (context, model) => Column(
        children: [
          _buildProfileDisplayCount(context),
          Expanded(
            child: AnimatedList(
              key: _listKey,
              // REMOVED: controller: _listController
              // The PageStorageKey from parent will handle scroll preservation now.
              initialItemCount: _filteredProfiles.length,
              itemBuilder:
                  (
                    BuildContext context,
                    int index,
                    Animation<double> animation,
                  ) => _buildItem(context, index, animation),
            ),
          ),
        ],
      ),
    );
  }
}
