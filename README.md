# signalr

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.



Claim	Decision	Reasoning
Audio mute lost on reconnect	Defer	Working as designed. Adding audio state caching adds complexity; revisit if user reports as a pain point
switchVideoTrack
 isolated stream	Defer	Current approach works for IoT cameras (separate streams per track). Can revisit if multi-track-per-stream is encountered
ICE restart before full teardown	Defer	Good idea but requires server cooperation. Current full-reconnect is reliable. Can add as opt-in later
queueRemoteCandidate()
 removal	Skip	Part of public API; removing could break external callers



 Items Rejected / Deferred
Claim	Decision	Reasoning
Hardcoded JSON-RPC IDs	Defer	Protocol-level — server uses id:'1' and id:'2'. Changing breaks compatibility.
Auth dead surface	Defer	authorization: '' matches web client. Server doesn't validate it. Cosmetic cleanup only.
Timeout/keepalive model	Defer	The 15s connect timeout is a mobile safety net. Removing requires real-world network testing.
Batched outbound trickle	Defer	Requires server-side changes to accept batched candidate messages.