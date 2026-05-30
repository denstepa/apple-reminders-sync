## Context

This is a greenfield SwiftUI iOS app. The hard problem is not the UI — it is staying alive and audible all night on iOS, which aggressively suspends backgrounded apps. An anchor watch that misses a drag is worse than useless, so the architecture is driven by **reliability of background monitoring and alarm audibility**, with a deliberately minimal UI on top.

Target: iOS 16+, iPhone, portrait. No backend, no third-party packages.

## Goals / Non-Goals

**Goals:**
- Continuous position monitoring that survives backgrounding, screen-off, and device reboot while armed.
- A drag alarm that is loud even when the ringer is silenced and the phone is in a pocket/berth.
- Detection tuned so normal swing and GPS jitter never false-alarm, but a real drag triggers within seconds.
- A single-screen, arm-in-three-taps experience.

**Non-Goals:**
- Chart/AIS/weather overlays, Apple Watch, cloud sync, multi-vessel (all future).
- Sub-meter accuracy or fusing other sensors (compass/accelerometer) in the MVP.
- Guaranteeing behavior when the OS terminates the app due to memory pressure — we mitigate, not promise.

## Decisions

**1. Continuous standard location updates (not region monitoring) as the primary detector.**
Swing circles are typically 20–60 m. iOS circular region monitoring resolves at ~100 m+ and fires unreliably, so it can't detect a real drag. We use `CLLocationManager` with `desiredAccuracy = kCLLocationAccuracyBest`, `allowsBackgroundLocationUpdates = true`, and `pausesLocationUpdatesAutomatically = false`. Continuous background location is also what keeps the app *running* in the background so our own alarm code can fire. Region monitoring (geofence exit) is kept as a cheap secondary backstop, not the primary signal.
- *Alternative considered:* significant-location-change → far too coarse and infrequent. Rejected.

**2. Alarm = in-process looping audio (primary) + critical local notification (backstop).**
While armed, background location keeps the process alive, so on a confirmed breach we play a looping alarm via `AVAudioPlayer` under an `AVAudioSession` configured with the `.playback` category — this sounds *through* the silent switch. As a backstop in case iOS has suspended us, we also schedule a critical `UNNotification` (loud, ignores Focus/DND).
- *Trade-off:* Critical Alerts require an Apple entitlement (manual approval). If unavailable, fall back to time-sensitive interruption-level notifications + the audio path. Audio remains the primary loud signal regardless.

**3. Drag confirmation with accuracy gating + hysteresis.**
Effective radius = configured swing radius. A fix counts as a breach only if `distance(anchor, fix) - horizontalAccuracy > radius` (so a noisy fix can't trip it). A breach is *confirmed* only after it persists for a sustained window (e.g. ≥ N consecutive qualifying fixes or ≥ T seconds). Fixes with `horizontalAccuracy` worse than a threshold are discarded. Distance via equirectangular/haversine approximation at these short ranges.

**4. Explicit state machine, persisted.**
`idle → armed → alarming → acknowledged(→ armed)`. The anchor coordinate, radius, and armed flag are persisted (UserDefaults + a small JSON file) immediately on arm, so a relaunch/reboot restores the active watch and re-starts location updates from the app's launch path.

**5. SwiftUI + MVVM around one engine.**
An `AnchorWatchEngine` (observable) owns the `CLLocationManager`, the state machine, the breach evaluator, the alarm player, and persistence. The single `ContentView` (map + controls) observes it. Keeping all monitoring logic in one testable type lets the breach/hysteresis logic be unit-tested without CoreLocation.

## Risks / Trade-offs

- **iOS terminates the app (memory pressure / Low Power Mode).** → Background location relaunches the app on significant change; armed state is persisted and restored; critical notification acts as backstop. Document that the phone should stay plugged in.
- **GPS drift / multipath near rigging or hull causes a false alarm.** → Accuracy gating + sustained-breach hysteresis; discard low-quality fixes.
- **Silent switch / Focus / DND suppress the alert.** → `.playback` audio category for in-process audio; Critical Alerts entitlement for the notification backstop.
- **Battery drain overnight from continuous best-accuracy GPS.** → Acceptable while armed; surface a "keep charging" hint when arming; consider relaxing accuracy in a later iteration.
- **Anchor point ≠ where the hook actually sits** (phone is at the helm, not the bow). → Manual nudge of the anchor marker before arming; default radius padded for this.

## Migration Plan

Greenfield — no migration. Ship as a new Xcode project. Rollback = don't ship.

## Open Questions

- Should we apply for the Critical Alerts entitlement up front, or ship MVP with time-sensitive notifications + audio and add critical alerts in a fast-follow?
- Default sustained-breach window (N fixes / T seconds) — needs on-water tuning; pick a conservative default (e.g. 3 fixes or ~30 s) for MVP.
- Do we need a manual "set anchor by dropping a pin on the map" in MVP, or is "mark from current GPS + nudge" sufficient?
