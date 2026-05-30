## Why

When a sailboat lies at anchor overnight, a wind shift or poor holding can cause the anchor to *drag*, letting the boat drift toward rocks, shore, or other vessels — often while the crew is asleep. An "anchor watch" app turns a phone into a drag alarm: mark where the anchor is set, define how far the boat may swing, and sound a loud alarm the moment it leaves that circle.

The existing apps in this niche work but are cluttered — buried settings, confusing radius math, paywalled basics, chart/AIS/weather features piled on top of a job that should take ten seconds to arm. We are building a focused, reliable iOS anchor watch whose entire pitch is: **drop the pin, set the swing, arm it, sleep.** No account, no cloud, no clutter — an alarm that always fires.

## What Changes

- **New iOS app (SwiftUI, iOS 16+)** — a fresh project, not part of the reminders-sync codebase. A single-screen anchor watch built around a live map.
- Mark the anchor position from current GPS (with manual nudge to correct for where the bow sat when the hook dropped).
- Set a **swing radius** with a sane default derived from rode let out + boat length + GPS error, adjustable by drag or stepper.
- One-tap **Arm / Disarm**. Armed state survives app backgrounding, screen-off, and device reboot.
- **Background drag monitoring** of GPS vs. the swing circle, with noise filtering and a sustained-breach requirement so wave/GPS jitter doesn't false-alarm.
- **Loud, escalating alarm** plus a critical local notification when a drag is confirmed — audible even with the ringer silenced.
- **Live map**: anchor marker, swing circle, current boat position, and a fading track of where the boat has swung through the night.
- **Local-first & private**: no login, no network dependency, alarm logic runs fully offline.

Out of scope for this MVP (explicit non-goals): nautical chart overlays, AIS/traffic, weather/wind forecasts, Apple Watch app, cloud sync/sharing, multi-anchor or multi-vessel.

## Capabilities

### New Capabilities
- `anchor-setup`: Marking and adjusting the anchor position and the allowed swing radius before arming.
- `drag-detection`: Background GPS monitoring, swing-circle breach evaluation with noise filtering and hysteresis, and the armed/disarmed lifecycle.
- `anchor-alarm`: The alert behavior when a drag is confirmed — escalating sound that overrides the silent switch, critical notification, and acknowledgement/snooze.
- `anchor-watch-map`: The live map visualization of anchor, swing circle, current position, and swing track.

### Modified Capabilities
<!-- None — this is a greenfield project with no existing specs. -->

## Impact

- **New codebase**: a standalone SwiftUI iOS app (separate Xcode/SwiftPM project), independent of the existing `apple-reminders-sync` Swift package.
- **Apple frameworks**: CoreLocation (continuous background location, "Always" authorization, `location` background mode), MapKit, AVFoundation (alarm audio with the `playback` category to sound through the silent switch), UserNotifications (critical alerts — requires the Critical Alerts entitlement from Apple).
- **Permissions & entitlements**: Always-location usage strings, background location capability, and a Critical Alerts entitlement request.
- **No backend, no third-party dependencies, no account system.**
