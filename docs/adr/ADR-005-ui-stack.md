# ADR-005: MenuBarExtra + @Observable for the UI

**Status**: Accepted · 2026-04-25

## Context

SyncCast's UI is a macOS menubar popover with a device list, per-device volume sliders, master toggle, and onboarding wizard. Minimum target macOS 14 (Sonoma).

## Decision

- **Container**: SwiftUI `MenuBarExtra(.window)`.
- **State**: `@Observable AudioRouter` view-model + a separate `AudioEngineService` for the CoreAudio + IPC side effects.
- **Status item right-click / middle-click**: small AppKit escape hatch (`NSStatusItem`) for the rare cases the SwiftUI MenuBarExtra doesn't cover.

## Rationale

- MenuBarExtra removes the AppKit boilerplate (`NSStatusItem`, `NSPopover`, manual show/hide). It's mature on macOS 14+.
- `@Observable` (Swift 5.9 macros) gives us property-level observation without `@Published` ceremony. Single source of truth, no `ObservableObject` boilerplate.
- A separate engine service keeps real-time / IPC concerns out of view code; the view-model only sees value snapshots.

## Consequences

- We can't sandbox to App Store cleanly because of CoreAudio capture and external process spawning. Already non-goal (ADR-003).
- AppKit escape hatch is small but real; documented in `apps/menubar/StatusItem.swift`.

## Alternatives considered

- `NSStatusItem` + AppKit `NSPopover` — strictly more code with no upside on macOS 14+.
- `ObservableObject` + Combine `@Published` — verbose; superseded by `@Observable` in modern code.
