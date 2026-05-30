## ADDED Requirements

### Requirement: Display anchor, swing circle, and current position
The app SHALL present a map showing the anchor position, the swing radius as a circle centered on the anchor, and the device's current position.

#### Scenario: Map renders the watch state
- **WHEN** an anchor position and radius are set
- **THEN** the map shows the anchor marker, a swing circle of the configured radius, and the current boat position

#### Scenario: Current position updates live
- **WHEN** the device receives new location fixes
- **THEN** the current-position indicator on the map updates to reflect the latest fix

### Requirement: Show the swing track
While armed, the app SHALL render a track of recent positions so the user can see how the boat has swung over time.

#### Scenario: Track accumulates over time
- **WHEN** the watch is armed and the boat swings around the anchor
- **THEN** the map shows a trail of recent positions

### Requirement: Communicate watch status visually
The map view SHALL clearly indicate the current watch state (idle, armed, or alarming) and show key values such as the current distance from the anchor and the swing radius.

#### Scenario: Alarming state is obvious
- **WHEN** the watch is in the alarming state
- **THEN** the view presents a clear alarming indication distinct from the armed and idle states

#### Scenario: Distance from anchor shown
- **WHEN** the watch is armed
- **THEN** the view displays the current distance from the anchor relative to the swing radius
