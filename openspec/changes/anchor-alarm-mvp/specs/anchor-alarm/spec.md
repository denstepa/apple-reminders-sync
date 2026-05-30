## ADDED Requirements

### Requirement: Sound a loud alarm on confirmed drag
When a drag is confirmed, the app SHALL sound a loud, looping audible alarm that plays even when the device's ringer/silent switch is set to silent.

#### Scenario: Alarm sounds on drag
- **WHEN** the watch transitions to the alarming state
- **THEN** a looping alarm sound begins playing at high volume

#### Scenario: Alarm audible with ringer silenced
- **WHEN** the device's silent switch is enabled and a drag is confirmed
- **THEN** the alarm still plays audibly

### Requirement: Deliver an alert notification as a backstop
In addition to in-app audio, the app SHALL deliver a high-priority local notification on a confirmed drag, so the user is alerted even if the app has been suspended by the system.

#### Scenario: Notification on drag while backgrounded
- **WHEN** a drag is confirmed while the app is in the background
- **THEN** the app delivers a high-priority notification indicating the boat is dragging

### Requirement: Acknowledge and stop the alarm
The user SHALL be able to acknowledge an active alarm to silence it, and the app SHALL make clear whether acknowledging continues monitoring or disarms the watch.

#### Scenario: Acknowledge active alarm
- **WHEN** the alarm is sounding and the user acknowledges it
- **THEN** the alarm sound stops and the watch state reflects the chosen outcome (continue monitoring or disarmed)

#### Scenario: Re-alarm if still dragging
- **WHEN** the user acknowledges but chooses to keep the watch armed and the device remains beyond the swing radius
- **THEN** the app re-evaluates and alarms again if the drag is still confirmed
