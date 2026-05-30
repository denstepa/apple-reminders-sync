## ADDED Requirements

### Requirement: Mark anchor position from current location
The app SHALL let the user set the anchor position to the device's current GPS coordinate with a single action, and SHALL only enable this action once a usable location fix is available.

#### Scenario: Set anchor with a good fix
- **WHEN** the user taps "Set Anchor" and a location fix with acceptable horizontal accuracy is available
- **THEN** the anchor position is recorded at that coordinate and shown on the map

#### Scenario: No usable fix yet
- **WHEN** no location fix is available or accuracy is below the usable threshold
- **THEN** the "Set Anchor" action is disabled and the app indicates it is waiting for GPS

### Requirement: Adjust the anchor position
The app SHALL allow the user to nudge the marked anchor position before arming, to account for the bow/rode offset from where the device sits.

#### Scenario: Drag the anchor marker
- **WHEN** the user drags the anchor marker on the map before arming
- **THEN** the anchor position updates to the new coordinate and the swing circle re-centers on it

### Requirement: Set the swing radius
The app SHALL provide a swing radius with a sensible default and allow the user to adjust it. The radius MUST be a positive distance and SHALL be editable by a stepper/slider and by dragging the circle edge.

#### Scenario: Default radius offered
- **WHEN** the user marks an anchor position
- **THEN** a default swing radius is pre-filled and rendered as a circle around the anchor

#### Scenario: Adjust radius
- **WHEN** the user changes the radius via the control or by dragging the circle edge
- **THEN** the swing circle resizes to the new radius and the value is displayed in the user's chosen distance unit

### Requirement: Persist the anchor configuration
The app SHALL persist the anchor coordinate and swing radius so they survive app relaunch.

#### Scenario: Configuration restored after relaunch
- **WHEN** the user has set an anchor and the app is relaunched
- **THEN** the previously set anchor position and swing radius are restored
