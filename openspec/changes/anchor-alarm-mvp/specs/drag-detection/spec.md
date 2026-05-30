## ADDED Requirements

### Requirement: Arm and disarm the watch
The app SHALL let the user arm the watch once an anchor position and swing radius are set, and disarm it at any time. While armed, the app SHALL continuously monitor the device position; while disarmed, it SHALL NOT trigger alarms.

#### Scenario: Arm the watch
- **WHEN** an anchor position and radius are set and the user taps "Arm"
- **THEN** the watch enters the armed state and begins continuous position monitoring

#### Scenario: Disarm the watch
- **WHEN** the watch is armed (or alarming) and the user disarms it
- **THEN** monitoring stops, any active alarm stops, and the watch returns to idle

#### Scenario: Cannot arm without configuration
- **WHEN** no anchor position has been set
- **THEN** the "Arm" action is unavailable

### Requirement: Continue monitoring in the background
While armed, the app SHALL continue monitoring position when backgrounded and with the screen off, and SHALL request the location authorization required to do so.

#### Scenario: Monitoring persists when backgrounded
- **WHEN** the watch is armed and the app is sent to the background
- **THEN** position monitoring continues and a breach can still be detected

#### Scenario: Request always-authorization
- **WHEN** the user attempts to arm without always-location authorization
- **THEN** the app requests the required authorization and explains why it is needed

### Requirement: Restore an active watch after relaunch
If the watch was armed when the app was terminated or the device rebooted, the app SHALL restore the armed state and resume monitoring on next launch.

#### Scenario: Resume armed watch on relaunch
- **WHEN** the app launches and persisted state shows the watch was armed
- **THEN** the app restores the anchor, radius, and armed state and resumes monitoring without user action

### Requirement: Detect a confirmed drag
The app SHALL confirm a drag only when the device's distance from the anchor exceeds the swing radius in a sustained manner, filtering out GPS noise. Fixes whose horizontal accuracy is worse than a quality threshold SHALL be discarded, and the fix's accuracy SHALL be accounted for so a single noisy fix cannot trigger an alarm.

#### Scenario: Sustained breach triggers detection
- **WHEN** the device's accuracy-adjusted distance from the anchor exceeds the swing radius for the sustained-breach window
- **THEN** the watch transitions to the alarming state

#### Scenario: Transient jitter does not trigger
- **WHEN** a single or brief sequence of fixes shows distance beyond the radius but it does not persist through the sustained-breach window
- **THEN** no alarm is triggered and the watch remains armed

#### Scenario: Low-quality fix is ignored
- **WHEN** a location fix has horizontal accuracy worse than the quality threshold
- **THEN** that fix is excluded from breach evaluation

#### Scenario: Normal swing within radius
- **WHEN** the device moves around the anchor but stays within the swing radius
- **THEN** no alarm is triggered
