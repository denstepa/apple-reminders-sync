## 1. Project setup

- [ ] 1.1 Create a new SwiftUI iOS app project (iOS 16+ target), separate from the existing package
- [ ] 1.2 Add `Info.plist` keys: `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationWhenInUseUsageDescription`, and the `location` + `audio` background modes
- [ ] 1.3 Configure the AVAudioSession for the `.playback` category so alarm audio plays through the silent switch
- [ ] 1.4 Request the Critical Alerts entitlement (or document the time-sensitive-notification fallback for MVP)
- [ ] 1.5 Set up a unit test target

## 2. Domain model & persistence

- [ ] 2.1 Define `AnchorWatchState` enum (idle, armed, alarming, acknowledged) and the watch config model (anchor coordinate, radius, distance unit)
- [ ] 2.2 Implement persistence (UserDefaults + JSON file) that saves config and armed state immediately on change
- [ ] 2.3 Implement restore-on-launch that reloads persisted state

## 3. Location & detection engine

- [ ] 3.1 Implement `AnchorWatchEngine` owning `CLLocationManager` (best accuracy, background updates enabled, auto-pause disabled)
- [ ] 3.2 Implement always-authorization request flow with rationale
- [ ] 3.3 Implement distance-from-anchor calculation and the accuracy-gated, sustained-breach evaluator (configurable N fixes / T seconds; discard low-quality fixes)
- [ ] 3.4 Wire the state machine: arm/disarm transitions, breach → alarming, acknowledge handling and re-evaluation
- [ ] 3.5 Resume monitoring automatically when a relaunch restores an armed watch

## 4. Alarm

- [ ] 4.1 Implement looping `AVAudioPlayer` alarm (high volume, plays under silent switch) started on the alarming state
- [ ] 4.2 Schedule a high-priority/critical local notification backstop on confirmed drag
- [ ] 4.3 Implement acknowledge action that stops audio and applies the chosen outcome (keep armed vs. disarm)

## 5. Anchor setup UI

- [ ] 5.1 "Set Anchor" action from current GPS, disabled until a usable fix exists
- [ ] 5.2 Draggable anchor marker to nudge the anchor position before arming
- [ ] 5.3 Swing-radius control (stepper/slider + drag the circle edge) with a sensible default and unit display

## 6. Map & status UI

- [ ] 6.1 Map view rendering anchor marker, swing circle, live current position, and the swing track trail
- [ ] 6.2 Status display: current state (idle/armed/alarming), distance from anchor vs. radius, and a distinct alarming presentation
- [ ] 6.3 Arm / Disarm controls reflecting and driving engine state
- [ ] 6.4 "Keep charging" hint shown when arming

## 7. Testing & verification

- [ ] 7.1 Unit-test the breach evaluator: normal swing, transient jitter, low-quality fix rejection, sustained breach
- [ ] 7.2 Unit-test persistence round-trip and armed-state restore
- [ ] 7.3 Manual on-device test: background drag detection with screen off and ringer silenced
- [ ] 7.4 Manual test: relaunch/reboot restores an armed watch and resumes monitoring
