# Hybrid web event-notification implementation handoff

## Purpose

This folder is a handoff for the agent integrating the hybrid notification
implementation into the real Flutter repository.

The hybrid has two delivery transports:

1. A direct EventPublisher gRPC stream supplies event-monitoring alerts while
   the web app is visible and focused. This path works without FCM permission.
2. FCM and `firebase-messaging-sw.js` handle background/minimized delivery and
   native system notifications when browser notification permission is
   available.

Both transports ultimately pass a Firebase `RemoteMessage` into the same Dart
cache and foreground UI path. Focus controls presentation, not whether a
message is recorded.

## Baseline and scope

The baseline is the unreworked source transcribed from the files and
screenshots supplied by the user. It is represented under `reconstructed/` in
this handoff project. Do not substitute files from `reworked/` or
`minimal_changes/`.

Only four application files are required:

| Handoff file | Destination in the real repository | Integration action |
| --- | --- | --- |
| `firebase_service_web.dart` | `lib/common/firebase/firebase_service_web.dart` | Merge or replace the current web Firebase service. |
| `firebase-messaging-sw.js` | `web/firebase-messaging-sw.js` | Replace the messaging worker with this complete file. |
| `web_alert_stream_manager.dart` | `lib/event_monitoring/web_alert_stream_manager.dart` | Add this new file. |
| `thunks.dart` | `lib/event_monitoring/thunks.dart` | Apply the one small change described below. Do not overwrite unrelated repository changes. |

No hybrid changes are intended for:

- `event_monitoring/state.dart`
- `event_monitoring/selectors.dart`
- `event_monitoring/reducers.dart`
- `event_monitoring/event_monitoring_profile.dart`
- `event_monitoring/event_source_to_event_type.dart`
- `store.dart`
- `push_notifications_cache.dart`
- native Firebase service implementations

The Dart files do not compile from inside this handoff folder because their
relative imports assume their real repository locations.

## Exact change in `thunks.dart`

This is the original unreworked/transcribed `thunks.dart` plus one insertion.
It is not the reworked thunk implementation.

In `updateProfileSubscription(...)`, immediately after `linkGuids` is
calculated and before `execNvrApi(...pushNotifySubscribe...)`, add:

```dart
// Record the user's desired subscription independently of FCM. This
// drives the focused-web EventPublisher stream when notification
// permission, the FCM token, or NVR push registration is unavailable.
await store.dispatch(
  updateLocalSubscription(server, profile.id, linkGuids),
);
```

Why this is required:

- Previously the local Redux subscription could depend on the later NVR/FCM
  registration path succeeding.
- If notification permission, FCM token creation, or push registration failed,
  the direct stream did not know what profiles and links the user wanted.
- The new dispatch records subscription intent first. Existing
  `updateLocalSubscription(...)` code remains unchanged.

This block is the only intentional difference between the supplied original
thunk and `hybrid/thunks.dart`.

## New `web_alert_stream_manager.dart`

The supplied old PR manager opened an EventPublisher stream and directly
cached/displayed notifications. This final manager keeps the useful direct
stream but changes its responsibilities:

- It does not cache notifications or display snackbars itself.
- It converts an EventPublisher `Event` into an FCM-compatible
  `RemoteMessage`.
- It sends that message to the callback supplied by `FirebaseService`, giving
  FCM and EventPublisher one cache, deduplication, and UI path.
- It automatically observes Redux store changes rather than requiring every
  caller to manually refresh streams.
- It restores and persists desired subscriptions in local storage under
  `eventMonitoring.webAlertSubscriptions.v1`.
- It opens at most one stream per subscribed server and merges duplicate
  source/event-type subscription entries.
- It skips `event.cached` events delivered during initial subscription.
- It runs only while the app is visible and focused. Losing focus cancels all
  direct streams; regaining focus recreates the required streams.
- It reconnects ended/failed streams using generation guards and exponential
  backoff with jitter, capped at 30 seconds.
- It cancels obsolete subscriptions and retry timers when Redux state changes.

The generated `RemoteMessage.data` uses the existing event-monitoring payload
shape:

```text
key=event_monitor_profile
property=<profile name>
link_guid=<profile link GUID>
server_name=<display name>
server_serial=<server MAC/serial identity>
source_id=<event source ID>
time=<UTC event time>
event_type=<existing payload event-type value>
```

The message is then delivered through
`FirebaseService._eventPublisherMessageHandler(...)`.

### Manager integration assumptions

The real repository must already provide the symbols used by the supplied
unreworked files:

- `AppStoreService().getStore()`
- `UpdateSubscribedLinks`
- `getSubscribedLinks(...)`
- `getProfiles(...)`
- `getServerName(...)`
- `getServerMacAddress(...)`
- `eventSourceToEventType(...)`
- `eventTypeToPayloadSource(...)`
- the existing server connection/interceptor helpers

One generated SDK enum member was reconstructed from screenshots:

```dart
EventType.EVENT_TYPE_EVENT_SOURCE_GROUP
```

Confirm that exact member exists in the installed `nvrsdk` generated
`EventType`. If the generated enum uses a different spelling, change only that
case to the real member name.

## Changes in `firebase_service_web.dart`

This file contains both the earlier FCM reliability work and the hybrid
coordination work. An integrating agent should preserve current repository
changes while ensuring all behavior below is present.

### Hybrid stream integration

- Imports `../../event_monitoring/web_alert_stream_manager.dart`.
- `handleMessageOnBackground()` initializes the manager:

```dart
WebAlertStreamManager().initialize(
  onMessage: _eventPublisherMessageHandler,
  active: _shouldHoldActiveLease(),
);
```

- FCM foreground messages and EventPublisher messages converge on
  `_handleForegroundMessage(...)`.
- `_syncActiveLease()` forwards the current focus state to
  `WebAlertStreamManager().setAppActive(active)`.
- Disposing the active-tab heartbeat also deactivates the stream manager.

### Cache and presentation separation

The supplied original only cached in the foreground display path. The final
version changes the order:

1. Compute the message fingerprint and suppress a duplicate.
2. Call `PushNotificationsCacheManager().putPushNotification(message)`.
3. Return without UI when `allowDisplay` is false or the tab is not active.
4. Otherwise display the existing dialog or snackbar.

This is required so a background push can populate the application's
notification/event-history page without creating a second visible
notification.

`FCM_PUSH_CACHE_ONLY` worker messages call the same method with
`allowDisplay: false`. A focus change while the message is in flight therefore
cannot accidentally produce both a system notification and a snackbar.

### Cross-transport and cross-tab duplicate suppression

The final service retains short in-memory deduplication and adds a shared,
bounded local-storage fingerprint set:

- Storage key: `exacq.push-notification-seen.v1`
- Retention: 24 hours
- Maximum entries: 512
- Event-monitor fingerprint:
  `server identity + link GUID + event type + source ID + normalized time`
- Other messages prefer `messageId`, then fall back to sent time, title, body,
  and sorted data.

This prevents the same physical event from being inserted again when:

- EventPublisher and FCM both deliver it.
- Focus moves between browser tabs during delivery.
- A background notification is later clicked in another tab.
- FlutterFire and the custom worker both surface the same FCM payload.

If local storage is blocked, the code logs a warning and retains the existing
per-tab in-memory deduplication.

### Worker message handling

The service handles four worker-to-Dart messages:

| Message type | Dart behavior |
| --- | --- |
| `SW_READY_PROBE` | Reply with `APP_CLIENT_READY`. |
| `FCM_PUSH` | Reconstruct `RemoteMessage`, cache it, and allow foreground UI if the tab is still active. |
| `FCM_PUSH_CACHE_ONLY` | Reconstruct and cache the message without Flutter UI. |
| `NOTIFICATION_CLICK` | Reconstruct the original nested `FCM_MSG`, avoid a second cache insertion, and run existing route/deep-link handling. |

Reconstructing the nested original FCM payload is important. Building a new
message only from flattened click data can lose `messageId`, notification
metadata, and the fields used for semantic deduplication.

### Earlier FCM reliability behavior retained

The final service also retains these intentional changes from the initially
supplied web service:

- Firebase initialization and token requests share in-flight futures so
  concurrent startup calls do not race.
- Notification permission is checked before requesting a token.
- Token creation retries up to three times with short backoff.
- `/firebase-messaging-sw.js` is explicitly registered with scope
  `/firebase-cloud-messaging-push-scope`.
- Worker registration uses `updateViaCache: 'none'`, explicitly checks for an
  update, and waits for an activated worker with a timeout.
- Active worker lookup is cached but safely refreshed after a failure.
- Foreground/click listeners are installed once.
- Notification routing retries while the Flutter navigator is starting.
- Service-worker readiness and activity messages are posted to the worker
  registration rather than assuming `navigator.serviceWorker.controller`
  always points at the messaging worker.
- Focus, visibility, lifecycle, `pagehide`, and `beforeunload` update the
  active-tab lease.

### VAPID key

The hybrid does not require a particular VAPID-key configuration mechanism.
The key is public and may remain in the existing `_vapidKey` constant.

The handoff file currently uses:

```dart
const String _vapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY');
```

If the real repository already assigns the existing public key directly to
`_vapidKey`, preserve that assignment. Do not replace a working key merely to
use `--dart-define`.

## Changes in `firebase-messaging-sw.js`

This worker is self-contained and should normally replace the real worker as a
whole. Its version is:

```javascript
const WORKER_VERSION = '2026-07-27.1';
```

### Raw-push/CSP-safe worker

- The worker intentionally does not call Firebase CDN `importScripts(...)`.
- It parses the decrypted Web Push JSON payload directly.
- This prevents restrictive CSP or enterprise blocking of `gstatic.com` from
  making worker evaluation fail.
- Payload normalization preserves the full original FCM object under
  `FCM_MSG`, while also exposing route, deep-link, title, body, and nested data
  for notification clicks.

Do not add Firebase compat `importScripts(...)` back without redesigning the
worker and retesting duplicate delivery.

### Active-tab lease and foreground delivery

- Dart posts `APP_ACTIVE_STATE` every four seconds while resumed, visible, and
  focused.
- The worker lease lasts 15 seconds to tolerate normal timer jitter.
- A lease is only a candidate: the worker rechecks the live
  `WindowClient.focused` and `visibilityState` values at push time.
- If one tab is truly active, the worker sends exactly one `FCM_PUSH` message
  to it and does not show a system notification.

This means Flutter owns the focused snackbar/dialog path and the worker owns
the background native-notification path.

### Background cache delivery

When no tab is truly active:

1. Select exactly one ready same-origin Flutter client.
2. Send it `FCM_PUSH_CACHE_ONLY`.
3. Independently call `showNotification(...)`.

The worker must not broadcast cache-only messages to every open tab because
the tabs can share the persistent notification cache and create duplicate
history entries.

If no ready tab exists, the system notification is still shown.

### Readiness and click routing

- Dart announces `APP_CLIENT_READY` after installing its message listener.
- The worker can send `SW_READY_PROBE` and wait briefly for that response.
- A notification click is sent to one best client only.
- The worker prefers the most recent lease, then a focused/visible client,
  then the first client.
- If no client exists, it opens the route and waits for the new client to
  announce readiness before sending `NOTIFICATION_CLICK`.
- `clickId` prevents processing the same click twice.
- `skipWaiting()` and `clients.claim()` activate a deployed update promptly.

### Worker-level duplicate suppression

The worker keeps an eight-second push fingerprint map. It prefers FCM message
IDs and otherwise fingerprints title, body, and sorted data. This suppresses
immediate duplicate `push` events before either native or Flutter presentation.

## Worker/Dart protocol summary

| Direction | Message | Meaning |
| --- | --- | --- |
| Dart → worker | `APP_CLIENT_READY` | This tab installed its worker-message listener. |
| Dart → worker | `APP_ACTIVE_STATE` | This tab's current visible/focused/lifecycle state. |
| Worker → Dart | `SW_READY_PROBE` | Re-announce readiness. |
| Worker → Dart | `FCM_PUSH` | Cache and optionally display in focused Flutter UI. |
| Worker → Dart | `FCM_PUSH_CACHE_ONLY` | Cache only; worker is showing the system notification. |
| Worker → Dart | `NOTIFICATION_CLICK` | Cache if needed, focus/open the app, and route the click. |

Both sides JSON-encode messages deliberately to avoid browser/package-web
JavaScript-object conversion differences.

## Required existing initialization calls

The supplied screenshots showed partial initialization files rather than
complete source files, so those files are not included in this bundle. The
integrating agent must verify the real application still calls:

```dart
firebaseService.handleMessageOnBackground();
firebaseService.initializeActiveTabLeaseHeartbeat();
```

The root lifecycle observer must continue forwarding:

```dart
firebaseService.updateActiveTabLeaseForLifecycle(state);
```

and should call:

```dart
firebaseService.disposeActiveTabLeaseHeartbeat();
```

when the owning application object is disposed.

Do not add duplicate startup calls if these are already present. The service
guards listener installation, but lifecycle ownership should still be clear.

## Expected behavior matrix

| State | EventPublisher | FCM/worker | Cache/UI result |
| --- | --- | --- | --- |
| Focused and FCM allowed | Active | May also arrive | One cached event and one Flutter snackbar/dialog; cross-transport duplicate suppressed. |
| Focused and FCM denied/unavailable | Active | Unavailable | One cached event and Flutter snackbar/dialog from EventPublisher. |
| Hidden/minimized and FCM allowed | Stopped | Active | Worker shows one system notification and sends one tab a cache-only copy. |
| Hidden/minimized and FCM denied | Stopped | Unavailable | No real-time delivery until the app/server performs a later history refresh. |
| Multiple tabs open | Only focused tab streams | Worker chooses one recipient | One cache insertion and at most one user-visible notification. |
| No Flutter tab open, FCM allowed | Not running | Worker can receive | System notification is shown; clicking it opens the app and sends the payload. |

## Important limitation

The worker does not contain a durable IndexedDB event-history queue.

If no Flutter tab is open and the user never clicks a system notification,
that push cannot be inserted into Flutter's local cache. If the application
must show every missed event after being completely closed, the real
repository needs either:

- a server/API history fetch during startup/resume, which is preferred as the
  source of truth; or
- a separately designed worker IndexedDB queue with acknowledgement and
  replay.

That is intentionally outside this minimal four-file hybrid.

## Implementation procedure

1. Diff the handoff files against the real repository; do not overwrite newer
   unrelated work.
2. Add `web_alert_stream_manager.dart`.
3. Apply only the documented insertion to the real `thunks.dart`.
4. Merge `firebase_service_web.dart`, preserving the repository's real VAPID
   public key assignment and existing package/import conventions.
5. Replace `web/firebase-messaging-sw.js` with the supplied complete worker.
6. Verify the existing Firebase initialization and lifecycle call sites.
7. Confirm the generated `EventType` enum spelling noted above.
8. Run:

```powershell
dart format lib\common\firebase\firebase_service_web.dart lib\event_monitoring\web_alert_stream_manager.dart lib\event_monitoring\thunks.dart
flutter analyze
flutter build web
```

9. Deploy the newly built `build/web` output.
10. Confirm the browser activates worker version `2026-07-27.1`.

## Deployment requirements

- Use HTTPS with a certificate valid for the exact hostname or IP entered in
  the browser.
- Serve `/firebase-messaging-sw.js` from the site root.
- Return JavaScript for that URL, not the Flutter `index.html` SPA fallback.
- Do not redirect the worker URL.
- Prefer `Cache-Control: no-cache` for the worker so update checks see new
  versions.
- After deployment, use DevTools to update/unregister the old worker or reload
  until version `2026-07-27.1` is active.

Application code cannot override a browser TLS hostname/SAN rejection or a
server returning the wrong content for the worker URL.

## Verification and useful logs

Filter the browser console for:

- `PushNotify`
- `WebAlertStream`
- `message cached`
- `fcm.worker.active`
- `fcm.worker.background`
- `eventPublisher`
- `Duplicate`
- `Messaging worker active`

Recommended test cases:

1. One focused tab, FCM allowed.
2. One minimized tab, FCM allowed.
3. One background tab while another site is focused.
4. FCM permission denied with the Flutter app focused.
5. Two app tabs with only one focused.
6. Switch focus between two app tabs during repeated events.
7. Click a background system notification after its cache-only delivery.
8. Close all app tabs, receive a push, then click the notification.

For a background push with an open tab, expect both:

```text
[PushNotify] fcm.worker.background message received
[PushNotify] fcm.worker.background message cached
```

and one native system notification, with no Flutter snackbar/dialog.

For a duplicate path or tab handoff, expect:

```text
[PushNotify] Duplicate <source> push suppressed
```

## Validation already performed on the handoff

- `firebase_service_web.dart` passes the Dart formatter.
- `web_alert_stream_manager.dart` was formatter-checked.
- `firebase-messaging-sw.js` passes `node --check`.
- A mocked two-background-tab worker test produced exactly one cache-only
  recipient and one system notification.
- A mocked focused-tab worker test produced exactly one focused Flutter
  recipient and no system notification.

A full `flutter analyze` must be run after the files are placed in the actual
repository because this handoff folder does not contain the complete import
tree and generated SDK dependencies.
