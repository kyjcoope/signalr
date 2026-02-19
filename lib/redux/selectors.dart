import 'package:reselect/reselect.dart';

import '../models/models.dart';
import 'app_state.dart';

// Re-export WebRTC selectors so existing imports continue to work.
export '../webrtc/redux/webrtc_selectors.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Camera Selectors
// ═══════════════════════════════════════════════════════════════════════════

/// All cameras as a sorted list of slugs (memoized — safe for shallow compare).
final selectAllSlugs =
    createSelector1<AppState, Map<String, Device>, List<String>>(
      (state) => state.cameras.cameras,
      (cameras) {
        final slugs = cameras.keys.toList()..sort();
        return slugs;
      },
    );

/// Get a Device by slug.
Device? selectDevice(AppState state, String slug) =>
    state.cameras.cameras[slug];

/// Whether cameras have been loaded from the API.
bool selectCamerasLoaded(AppState state) => state.cameras.isLoaded;

// ═══════════════════════════════════════════════════════════════════════════
// Filter + Favorites Selectors
// ═══════════════════════════════════════════════════════════════════════════

/// Whether a slug is a favorite.
bool selectIsFavorite(AppState state, String slug) =>
    state.favorites.ids.contains(slug);

/// Visible camera slugs after applying all filters (memoized).
///
/// Depends on cameras, filters, favorites, and webRtc sessions.
/// Only recomputes when any of those sub-states change.
final selectVisibleCameras =
    createSelector4<
      AppState,
      Map<String, Device>,
      FilterState,
      Set<String>,
      Map<String, WebRtcSessionState>,
      List<String>
    >(
      (state) => state.cameras.cameras,
      (state) => state.filters,
      (state) => state.favorites.ids,
      (state) => state.webRtc.sessions,
      (cameras, filters, favorites, sessions) {
        var base = cameras.keys.toList()..sort();

        // Favorites filter
        if (filters.favoritesOnly) {
          base = base.where((id) => favorites.contains(id)).toList();
        }

        // Working / Pending filter
        bool isWorking(String id) =>
            sessions[id]?.connectionState ==
            WebRtcConnectionState.sessionConnected;
        bool isPending(String id) =>
            sessions[id]?.connectionState ==
            WebRtcConnectionState.sessionPending;

        if (filters.workingOnly && filters.pendingOnly) {
          base = base.where((id) => isWorking(id) || isPending(id)).toList();
        } else if (filters.workingOnly) {
          base = base.where(isWorking).toList();
        } else if (filters.pendingOnly) {
          base = base.where(isPending).toList();
        }

        // Search filter
        if (filters.searchQuery.isNotEmpty) {
          final q = filters.searchQuery.toLowerCase();
          base = base.where((id) {
            final name = cameras[id]?.name.toLowerCase() ?? '';
            return id.toLowerCase().contains(q) || name.contains(q);
          }).toList();
        }

        return base;
      },
    );
