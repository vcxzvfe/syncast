# SyncCast — UX Brief

Tactical UX brief for a macOS menubar app that fans the system audio stream out to multiple speakers (CoreAudio + AirPlay 2) with per-device gain, master "Whole-house" toggle, and per-device sync health.

Target: macOS 14+ (Sonoma). Single-window menubar popover, no Dock icon.

---

## 1. Stack Recommendation

**Choice: SwiftUI `MenuBarExtra` (`.window` style).**

- macOS 14+ baseline lets us drop `NSStatusItem` legacy plumbing entirely.
- `MenuBarExtra(...) { ... } label: { ... }` gives us a native popover with proper focus, keyboard nav, and dismissal handling for free.
- `.menuBarExtraStyle(.window)` is required — `.menu` flattens our layout into an `NSMenu` and kills sliders/custom rows.
- We keep an `NSStatusItem` escape hatch only for: (a) right-click context menu, (b) middle-click mute-all. Wire via `NSApp.delegate` if needed; do not rebuild the whole UI on AppKit.
- App lifecycle: `LSUIElement = YES` in Info.plist; `MenuBarExtra` is the scene root.

Rejected: `NSStatusItem` + `NSPopover`. More code, manual focus ring, no SwiftUI previews, harder Dynamic Type.

## 2. State Management

**Choice: `@Observable` (Swift 5.9 / Observation framework).**

One root `AudioRouter` model marked `@Observable` owns `devices: [Device]`, `wholeHouseEnabled: Bool`, `masterVolume: Double`, and a `syncStats: [DeviceID: SyncSample]` dictionary updated on a 1 Hz timer. Views read fields directly; the Observation framework tracks only the properties each view actually accesses, eliminating the over-invalidation we'd hit with `ObservableObject`/`@Published`. A separate `AudioEngineService` (CoreAudio HAL + AirPlay discovery via `MPRemoteCommandCenter`/MediaPlayer) is injected; the model is the single source of truth, the service is a side-effect boundary. An explicit Store/Action layer is overkill at this scope (single popover, ~6 user actions).

## 3. Popover Layout (340pt wide)

```swift
MenuBarExtra("SyncCast", systemImage: "hifispeaker.2") {
  VStack(spacing: 0) {                              // width: 340
    StatusHeader(                                   // 44pt
      activeDeviceCount: router.activeCount,
      isStreaming: router.isStreaming,
      latencyMs: router.aggregateLatency
    )
    Divider()

    WholeHouseToggleRow(                            // 56pt
      isOn: $router.wholeHouseEnabled,
      masterVolume: $router.masterVolume           // master slider revealed when ON
    )
    Divider()

    ScrollView {                                    // max 360pt, then scroll
      DeviceGroupSection(title: "Local") {
        ForEach(router.localDevices) { dev in
          DeviceRow(device: dev)                    // see below
        }
      }
      DeviceGroupSection(title: "AirPlay") {
        ForEach(router.airplayDevices) { dev in
          DeviceRow(device: dev)
        }
        if router.isScanningAirPlay {
          AirPlayScanningRow()                      // spinner + "Scanning…"
        }
      }
    }
    Divider()

    PopoverFooter {                                 // 36pt
      FooterButton("Add…",       icon: "plus.circle")
      FooterButton("Calibrate…", icon: "waveform.badge.magnifyingglass")
      Spacer()
      FooterButton("Settings",   icon: "gearshape")
    }
  }
  .frame(width: 340)
}

// DeviceRow — 52pt tall
HStack(spacing: 10) {
  Image(systemName: dev.sfSymbol)                   // hifispeaker / airplayaudio / headphones
    .frame(width: 22)
  VStack(alignment: .leading, spacing: 2) {
    HStack(spacing: 6) {
      Text(dev.name).font(.body)
      TransportBadge(dev.transport)                 // "AirPlay 2" / "USB" / "Built-in"
    }
    HStack(spacing: 8) {
      VolumeSlider(value: $dev.volume)              // 0…1, .controlSize(.small)
      MuteToggle(isMuted: $dev.muted, icon: "speaker.slash.fill")
      SyncIndicatorDot(state: dev.syncState)        // .green / .yellow / .red
        .help(dev.syncTooltip)                      // "+3 ms drift" etc.
    }
  }
}
.contentShape(Rectangle())
.contextMenu { DeviceContextMenu(dev) }             // Rename, Remove, Diagnostics…
```

Rules:
- Sync dot: green ≤ 10 ms drift, yellow 10–40 ms, red > 40 ms or dropouts.
- Volume slider disables (greyed) when device is muted or `.red` sync.
- Whole-house master slider scales each device's volume proportionally; the user's per-device ratios are preserved on toggle-off.

## 4. First-Run Wizard (5 screens)

1. **Welcome** — "Play one song everywhere." Shows the menubar icon's location with a glowing arrow; Continue.
2. **Install BlackHole** — We bundle BlackHole 2ch `.pkg` (signed, notarized) and run the installer; fallback button "Use Homebrew Cask" runs `brew install blackhole-2ch` in a sandboxed helper.
3. **Set BlackHole as Default Output** — Auto-creates a Multi-Output Device named "SyncCast Bus" via `AudioHardwareCreateAggregateDevice`; user confirms with one click. Shows before/after diagram.
4. **Scan for AirPlay** — Live list populates as Bonjour/`_airplay._tcp` resolves; user ticks devices to trust. Skippable.
5. **Tap-Along Calibration (optional)** — Plays a click track; user taps spacebar in time on each speaker so we measure round-trip latency per device. Skip = use vendor-reported latency.

## 5. Accessibility Checklist

- [ ] Every interactive element has an `.accessibilityLabel` (slider: "Living Room volume, 60 percent"; sync dot: "Sync healthy" / "Drifting" / "Out of sync").
- [ ] Full keyboard nav: Tab cycles rows, ←/→ adjusts focused slider in 5% steps, Space toggles mute, Return opens the focused row's context menu.
- [ ] Global shortcut (`⌘⌥S`) toggles whole-house mode without opening the popover.
- [ ] Dynamic Type: respect `@ScaledMetric` for row heights and font sizes; popover height grows up to 600pt then scrolls.
- [ ] Color is never the sole signal — sync indicator pairs the dot with an SF Symbol (`checkmark.circle` / `exclamationmark.triangle` / `xmark.octagon`) and a text tooltip.
- [ ] Contrast ≥ 4.5:1 in both Light and Dark; verify against `Color(.secondaryLabel)` for badges.
- [ ] VoiceOver rotor groups: "Local Devices", "AirPlay Devices", "Controls" — set via `.accessibilityRotor`.
- [ ] Reduce Motion: disable the sync-dot pulse animation when `accessibilityReduceMotion` is on.

## 6. References

- **Raycast** — borrow the *grouped, sectioned list with subtle SF Symbol prefixes* and the muted-grey section headers; gives our Local/AirPlay split a clean rhythm.
- **Stats (exelban)** — borrow the *compact inline status header* with live numeric readouts (latency, active count) directly under the title; reinforces "this app is doing something right now."
- **Loop (MrKai77)** — borrow the *first-run onboarding cards with hero illustrations and a clear single CTA per screen*; perfect template for our 5-screen wizard.
- **IceCubes (and Ice menubar manager)** — borrow the *settings entry as a footer icon button rather than a separate window chrome*, keeping the popover the canonical surface and Settings as a secondary `Window` scene only when invoked.

---

*Word count target: ~1000. Keep this brief living — update after the calibration UX user-test in Phase 2.*
