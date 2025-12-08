class EventMonitoringProfilesListPage extends StatefulWidget {
  final EventMonitorTab tab;
  final String searchFilter;
  final SortTypes sortType;

  const EventMonitoringProfilesListPage({
    super.key, // This receives the PageStorageKey from the parent
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

  // Initialize Key ONCE. We only recreate this if the list needs a hard reset (like a new search).
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  // FIXED: Changed logic to direct assignment to avoid setState error
  void _storeInit(Store<AppState> store) {
    _model = EventMonitorListModel(store);

    // We calculate the initial list and assign it directly.
    // We do NOT call setState() here because the widget is currently building.
    // The 'builder' method below will see this value immediately.
    _filteredProfiles = _getComputedList();
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

  // Smart update logic to prevent Scroll Reset
  void _recalculateFilteredProfiles({bool forceReset = false}) {
    final newList = _getComputedList();

    if (forceReset) {
      // If search/tab changed, we must reset the entire list view
      // This WILL reset scroll position, which is expected for a new search.
      setState(() {
        _filteredProfiles = newList;
        _listKey = GlobalKey<AnimatedListState>();
      });
    } else {
      // SMART UPDATE:
      // If the Redux update confirms what we already did locally (lengths match),
      // we update the data without destroying the list.
      if (_filteredProfiles.length == newList.length) {
        // Just update the data (names/descriptions might have changed)
        setState(() {
          _filteredProfiles = newList;
        });
      } else {
        // Length mismatch! This means an external update occurred (not our toggle).
        // We have to hard reset to prevent crashes.
        setState(() {
          _filteredProfiles = newList;
          _listKey = GlobalKey<AnimatedListState>();
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

    // Pass false to attempt a "Soft Update" that preserves scroll position
    _recalculateFilteredProfiles(forceReset: false);
  }

  @override
  void didUpdateWidget(EventMonitoringProfilesListPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    // If the parameters defining the list change, we must force a hard reset
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

    // 2. Animate it out visually
    _listKey.currentState?.removeItem(
      index,
      (ctx, anim) => _staticEventProfileTile(
        profile,
        anim,
        state: value, // Keep switch state consistent during animation
      ),
      duration: const Duration(milliseconds: 300),
    );

    // 3. Perform the Redux Action
    // Because we updated the UI *before* the action, when Redux returns with
    // the new list, it will match our new _filteredProfiles length,
    // and _recalculateFilteredProfiles will skip the hard reset (preserving scroll).
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
    // Safety check for animation timing issues
    if (index >= _filteredProfiles.length) {
      return const SizedBox.shrink();
    }

    return wrapDivider(
      SizeTransition(
        sizeFactor: animation,
        child: AnimatedEventProfileListItem(
          // Use ID Key to help Flutter track items if order shifts
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
