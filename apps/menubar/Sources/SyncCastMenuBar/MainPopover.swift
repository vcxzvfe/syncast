import SwiftUI
import SyncCastDiscovery
import SyncCastRouter

struct MainPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            modePicker
            Divider().padding(.horizontal, 12)
            debugStrip
            Divider().padding(.horizontal, 12)
            if model.volumeKeyNeedsAccessibilityHint {
                volumeKeyPermissionHint
                Divider().padding(.horizontal, 12)
            }
            deviceList
            // Sync slider is only meaningful in whole-home mode.
            if model.mode == .wholeHome {
                Divider().padding(.horizontal, 12)
                syncSection
            }
            Divider().padding(.horizontal, 12)
            footer
        }
        .padding(.vertical, 8)
        // Pairing is deliberately NOT presented here. A sheet attached to the
        // MenuBarExtra(.window) panel can never receive keyboard input — the
        // panel is non-activating, and the click that tried to focus the PIN
        // field made the panel resign key, which tore the sheet down with it.
        // `PairingWindowController` owns a real, key-capable window instead.
        .onAppear {
            // Re-check Accessibility on every popover open: if the user
            // just granted it in System Settings, the media-key event
            // tap installs immediately — no app restart.
            model.recheckVolumeKeyPermission()
        }
    }

    /// Shown only while Direct Stereo is running WITHOUT Accessibility
    /// permission — the CGEventTap that captures media volume keys
    /// cannot be created until the user grants it in System Settings.
    private var volumeKeyPermissionHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("音量键控制需要辅助功能权限")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("打开设置") { model.openAccessibilitySettings() }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .accessibilityIdentifier("volumeKeyPermissionButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Sync section (manual)
    //
    // A slider the user drags until music sounds aligned, plus a Lock
    // button that pins the chosen value. Long-term alignment is handled
    // by the clock-following control loop in the router, not by this
    // fixed value.
    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: title + lock pill + reset
            HStack {
                Text("Local + AirPlay Delay")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                LockStatePill(state: model.delayLockState)
                Button("Reset") { model.resetAirplayDelayToDefault() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .accessibilityIdentifier("syncResetButton")
            }

            // Slider — step 10ms (was 25)
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(model.airplayDelayMs) },
                    set: { model.setAirplayDelay(Int($0)) }
                ), in: airplayDelaySliderRange, step: 10)
                    .controlSize(.small)
                    .accessibilityIdentifier("airplayDelaySlider")
                Text("\(model.airplayDelayMs) ms")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 70, alignment: .trailing)
            }

            // Action row: Lock
            HStack(spacing: 6) {
                Button(action: {
                    if case .locked = model.delayLockState {
                        model.unlockAirplayDelay()
                    } else {
                        model.lockAirplayDelay()
                    }
                }) {
                    Label(lockButtonLabel, systemImage: lockIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("lockDelayButton")

                Spacer()
            }

            // Coaching hint
            Text(coachingHint)
                .font(.caption2)
                .foregroundStyle(.secondary)

            perSpeakerTrimHint

            // Diagnostics disclosure: read-only pipeline readouts.
            DisclosureGroup("Diagnostics") {
                advancedSection
            }
            .font(.system(size: 10))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .focusable()
        .onKeyPress(.leftArrow) {
            let step = NSEvent.modifierFlags.contains(.shift) ? -100 : -10
            model.nudgeAirplayDelay(by: step)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            let step = NSEvent.modifierFlags.contains(.shift) ? 100 : 10
            model.nudgeAirplayDelay(by: step)
            return .handled
        }
    }

    /// Explains the per-speaker trim controls that live on the device rows,
    /// and offers the one global escape hatch.
    ///
    /// The sign convention has to be stated somewhere the user will read it:
    /// nothing can play EARLY, so the values are relative and the earliest
    /// speaker is always the reference. Without that sentence, "I set -5 and
    /// nothing moved on that speaker" looks like a bug rather than the
    /// normalisation working correctly.
    @ViewBuilder
    private var perSpeakerTrimHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(
                "Per-speaker delay is on each device row. Relative only: "
                + "the earliest speaker is the reference. Plus holds a "
                + "speaker back, so one that sits FURTHER away needs a "
                + "MINUS value. "
                + "1 ms ≈ \(Int((DeviceDelayTrim.speedOfSoundMPerS / 10).rounded())) cm."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.hasAnyDeviceTrim {
                Button("Reset trims") { model.resetAllDeviceTrims() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .accessibilityIdentifier("resetAllDeviceTrimsButton")
            }
        }
    }

    // MARK: - Diagnostics
    //
    // Read-only pipeline readouts. The acoustic (microphone) measurement
    // tools that used to live here were retired: alignment is handled by
    // the OwnTone clock domain plus the ring-level control loop, so no
    // acoustic measurement is needed.
    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Measured lag: \(model.measuredLagMs.map { "\($0)" } ?? "\u{2014}") ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Computed labels for manual-first UI

    private var lockButtonLabel: String {
        if case .locked = model.delayLockState {
            return "Unlock"
        }
        return "Lock \(model.airplayDelayMs) ms"
    }

    private var lockIcon: String {
        if case .locked = model.delayLockState {
            return "lock.open.fill"
        }
        return "lock.fill"
    }

    private var coachingHint: String {
        if case .locked(let v) = model.delayLockState {
            return "Locked at \(v) ms"
        }
        return "Drag until music sounds aligned, then press Lock"
    }

    private var airplayDelaySliderRange: ClosedRange<Double> {
        let lower = Double(AppModel.airplayDelayMsRange.lowerBound)
        let upper = Double(AppModel.airplayDelayMsRange.upperBound)
        return lower...upper
    }

    /// Single-line live debug strip — visible to the user, lets us diagnose
    /// the "0 devices in UI even though discovery saw them" class of bugs
    /// without needing Console.app.
    private var debugStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Label("\(model.devices.count)", systemImage: "speaker.wave.2.bubble")
                Label("\(model.localDevices.count)", systemImage: "hifispeaker")
                Label("\(model.airPlayDevices.count)", systemImage: "airplayaudio")
                Label(model.sidecarRunning ? "OK" : "DOWN",
                      systemImage: model.sidecarRunning ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(model.sidecarRunning ? .green : .red)
                Spacer()
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            if let err = model.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon(name: model.statusIconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("SyncCast").font(.headline)
                Text(statusSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var statusSubtitle: String {
        switch model.streamingState {
        case .idle:     return "Idle · \(model.enabledDeviceCount) selected"
        case .starting: return "Starting…"
        case .running:  return "Streaming · \(model.enabledDeviceCount) devices"
        case .stopping: return "Stopping…"
        case .error:    return model.lastError ?? "Error"
        }
    }

    /// Mode picker: the user's fundamental architectural choice. Switching
    /// tears down and rebuilds the audio pipeline; SwiftUI handles the
    /// state binding, AppModel.setMode handles the engine teardown.
    ///
    /// Why two segmented choices and not a hidden toggle: in a multi-room
    /// audio app the latency tradeoff is the most important user-facing
    /// concept (~50 ms vs ~1.8 s). Burying it behind a switch was the
    /// previous design, and the user repeatedly hit the resulting
    /// "AirPlay-vs-local can't sync" failure mode without realising why.
    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(
                get: { model.mode },
                set: { model.setMode($0) }
            )) {
                ForEach(AppModel.Mode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("modePicker")
            Text(model.mode.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var deviceList: some View {
        // Plain VStack — no ScrollView. Inside MenuBarExtra(.window) on
        // macOS 14/15, ScrollView often collapses to zero height when
        // the popover doesn't propagate a parent frame, hiding rows even
        // though they exist in the view tree. We accept a tall popover
        // for now; if the device count grows beyond ~10 we'll revisit.
        VStack(spacing: 0) {
            if model.devices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.bubble")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("Looking for speakers…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                if !model.localDevices.isEmpty {
                    sectionHeader("Local")
                    // Pass `deviceID: String` instead of the `Device` value
                    // so `DeviceRow` looks the device up via `model.devices`
                    // every render. If we captured `Device` directly, a
                    // .updated discovery event could leave the row's
                    // closures bound to a stale Device (or worse, a row
                    // recycled by SwiftUI under another id). User-visible
                    // symptom of that bug: tapping one row toggled a
                    // different device.
                    ForEach(model.localDevices) { dev in
                        DeviceRow(deviceID: dev.id)
                    }
                }
                // Only genuinely remote AirPlay receivers are targets. This
                // Mac's own AirPlay Receiver is never listed: under direction
                // B the local speakers are an OwnTone output (the "Local"
                // section above), not an AirPlay target, so self-targeting —
                // and its full-screen-PIN deadlock — cannot arise.
                if !model.remoteAirPlayDevices.isEmpty {
                    sectionHeader("AirPlay")
                    ForEach(model.remoteAirPlayDevices) { dev in
                        DeviceRow(deviceID: dev.id)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

// MARK: - LockStatePill
//
// Compact pill in the syncSection header that mirrors the lock state.
// Unlocked = grey "Unlocked"; locked = green "<value> ms" with a lock
// glyph. Pure presentation — never mutates state.
struct LockStatePill: View {
    let state: DelayLockState
    var body: some View {
        Group {
            switch state {
            case .unlocked:
                Text("Unlocked")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            case .locked(let v):
                Label("\(v) ms", systemImage: "lock.fill")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.3))
                    .cornerRadius(4)
            }
        }
        .font(.caption2)
    }
}

private struct DeviceRow: View {
    /// Stable SyncCast id of the device this row represents. Looked up via
    /// `model.devices` on each render; never captured by value. Without this
    /// indirection, SwiftUI view recycling can bind a row's tap closure to
    /// a stale `Device` value, causing taps to toggle the wrong device.
    let deviceID: String

    @Environment(AppModel.self) private var model

    private var device: Device? {
        model.devices.first { $0.id == deviceID }
    }

    private var routing: DeviceRouting {
        model.routing[deviceID] ?? DeviceRouting(deviceID: deviceID)
    }

    var body: some View {
        // If discovery has dropped the device while the menu is open, render
        // nothing for that row rather than holding a stale reference.
        if let device = device {
            rowBody(for: device)
        } else {
            EmptyView()
        }
    }

    /// Pairing affordance for AirPlay receivers that demand authentication.
    ///
    /// Rendered only when there is something to say. A receiver that needs no
    /// pairing, or is already paired, gets no extra chrome — the row stays as
    /// quiet as it has always been.
    @ViewBuilder
    private func pairingRow(for device: Device) -> some View {
        let state = model.pairingState(for: device)
        switch state {
        case .notRequired, .paired:
            EmptyView()
        case .awaitingPIN, .verifying:
            // Cancel has to be reachable from here. An attempt in this state
            // holds the receiver's display hostage with a full-screen PIN for
            // the sidecar's whole four-minute window, and a row with no
            // button at all left the user nothing to do but wait it out.
            HStack(spacing: 6) {
                Label("Pairing…", systemImage: "hourglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    model.cancelPairing(for: device)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                Spacer(minLength: 0)
            }
        case .required, .failed, .cancelled, .timedOut:
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(state == .required ? "Needs pairing" : "Pairing did not finish")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button(state == .required ? "Pair" : "Try again") {
                    model.startPairing(for: device)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func rowBody(for device: Device) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: device))
                .font(.system(size: 14))
                .foregroundStyle(routing.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    transportBadge(for: device)
                    Spacer(minLength: 0)
                    syncDot
                }
                if routing.enabled {
                    HStack(spacing: 6) {
                        Image(systemName: routing.muted
                              ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            // All tap closures use `deviceID` (the let-bound
                            // String), not `device.id` (the just-looked-up
                            // Device's id). They're the same value in normal
                            // operation, but using `deviceID` removes any
                            // chance of binding to a transiently-different
                            // Device returned by `model.devices.first`.
                            .onTapGesture { model.toggleMute(deviceID) }
                        VolumeSlider(
                            value: Binding(
                                get: { Double(routing.volume) },
                                set: { model.setVolume(Float($0), for: deviceID) }
                            )
                        )
                    }
                    // Direct Stereo: devices with no controllable hardware
                    // volume (backend == .none — no CoreAudio volume, no
                    // DDC path) get a one-line hint; .ddc and CoreAudio
                    // hardware backends render the normal slider only.
                    if let hint = model.volumeControlHint(for: deviceID) {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // Per-speaker delay trim. Whole-home only: in stereo the
                    // bridges do not run and the Scheduler is deliberately
                    // given an empty trim map, so a visible control would be
                    // inert and therefore misleading. Rendering nothing (as
                    // opposed to a disabled control) also keeps the row
                    // height identical between modes.
                    //
                    // ENABLED only, for the same reason:
                    // `Router.trimmableOutputIDs()` excludes disabled outputs
                    // from both the normalisation minimum and the result, so
                    // a disabled row's stepper moves nothing anywhere. The
                    // value is keyed by `Device.persistenceKey` and re-seeded
                    // by `applyPersistedDeviceTrims()`, so hiding the row
                    // never loses a trim set while the device was on.
                    if model.mode == .wholeHome && routing.enabled {
                        delayTrimRow(for: device)
                    }
                }
                // One-line failure breadcrumb. Only shown when the
                // sidecar has reported `failed` for this device, so a
                // healthy connection produces no extra row chrome.
                // Why this matters: before the connection-state pipe
                // landed, OwnTone could silently fail to wire up a
                // receiver and the UI cheerfully showed a green dot;
                // the user's only signal was "no audio". The failure
                // reason from the sidecar (e.g. "OwnTone never
                // discovered receiver") gives them a real direction.
                if connectionState == .failed {
                    Text(failureMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                pairingRow(for: device)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(routing.enabled ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleDevice(deviceID) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityRowLabel(for: device)))
        .accessibilityHint(Text("Double-tap to \(routing.enabled ? "disable" : "enable")"))
    }

    private func accessibilityRowLabel(for device: Device) -> String {
        var parts = [
            device.name,
            routing.enabled ? "enabled" : "disabled",
            syncLabel,
        ]
        let trim = model.deviceTrimMs(for: deviceID)
        if model.mode == .wholeHome && routing.enabled && trim != 0 {
            parts.append("delay \(trim > 0 ? "+" : "")\(trim) milliseconds")
        }
        return parts.joined(separator: ", ")
    }

    /// Millisecond delay trim for one speaker.
    ///
    /// A stepper rather than a slider, deliberately: the useful range is a
    /// handful of milliseconds, one press IS one step, and — unlike a drag —
    /// it produces discrete commit events. That matters because every AirPlay
    /// commit costs that receiver a ~0.4 s relatch dropout, so a drag stream
    /// would be a stutter stream.
    ///
    /// Sign convention is stated in the section hint, not just in code:
    /// positive = later. Only the relative pattern is meaningful, so dialling
    /// the far speaker negative and the near one positive are the same edit.
    @ViewBuilder
    private func delayTrimRow(for device: Device) -> some View {
        let trim = model.deviceTrimMs(for: deviceID)
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Stepper(
                "",
                onIncrement: {
                    model.nudgeDeviceTrim(DeviceDelayTrim.stepMs, for: deviceID)
                },
                onDecrement: {
                    model.nudgeDeviceTrim(-DeviceDelayTrim.stepMs, for: deviceID)
                }
            )
            .labelsHidden()
            .controlSize(.mini)
            .accessibilityIdentifier("deviceTrimStepper-\(deviceID)")
            .accessibilityValue(Text("\(trim) milliseconds"))
            Text(model.deviceTrimDistanceHint(for: deviceID))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(trim == 0 ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                           : AnyShapeStyle(.primary))
                .lineLimit(1)
            // Per-row reset appears only when there is something to reset, so
            // an untouched row gains no chrome and no layout shift.
            if trim != 0 {
                Button {
                    model.resetDeviceTrim(for: deviceID)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9))
                .help("Reset this speaker's delay to 0 ms")
                .accessibilityIdentifier("deviceTrimResetButton-\(deviceID)")
            }
            // A device with no stable identity (no CoreAudio UID, no Bonjour
            // `deviceid`) cannot be keyed in the defaults plist, so its trim
            // lives for this session only. Silently accepting an edit that
            // cannot survive a relaunch is the one behaviour that misleads —
            // on the next launch the speaker reverts to 0 while every
            // neighbour is restored, which reads as the feature regressing.
            if trim != 0 && device.persistenceKey == nil {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("This output has no stable identity, so its delay "
                          + "is kept for this session only.")
                    .accessibilityLabel(Text("Not remembered after quitting"))
            }
            // An AirPlay commit disables and re-enables the receiver, which
            // is an audible ~0.4 s gap. Say so, or it reads as a bug.
            if device.transport == .airplay2 && model.deviceTrimCommitInFlight {
                Text("applying…")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // Swallow taps that land in this sub-row. The whole device row
        // carries `.onTapGesture { model.toggleDevice(deviceID) }`, and
        // missing the stepper by a few points must not switch the speaker
        // off in the middle of tuning it.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private func iconName(for device: Device) -> String {
        switch device.transport {
        case .coreAudio:
            if device.name.localizedCaseInsensitiveContains("display") { return "tv" }
            if device.name.localizedCaseInsensitiveContains("built") { return "laptopcomputer" }
            return "hifispeaker"
        case .airplay2:
            return "airplayaudio"
        }
    }

    private func transportBadge(for device: Device) -> some View {
        Text(device.transport == .airplay2 ? "AirPlay" : "Local")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// The most recent connection state for THIS row's device, polled
    /// from the Router actor by AppModel. Falls back to `.unknown`
    /// before the first event arrives — the UI renders that as grey.
    private var connectionState: DeviceConnectionState {
        // For a row whose user-facing toggle is OFF we want the dot to
        // go grey regardless of the cached state, so a stale "connected"
        // from before the user toggled off doesn't keep the dot green.
        // We DON'T overwrite the cache itself — the sidecar will emit
        // `disconnected` shortly after and reconcile. This is purely a
        // render-time override.
        if !routing.enabled { return .disconnected }
        return model.connectionStates[deviceID] ?? .unknown
    }

    /// Human-readable failure message shown under the row when the
    /// state is `.failed`. Pulls the sidecar's reason if present, falls
    /// back to a generic copy. Kept short — full diagnostic detail
    /// goes to the system log via SyncCastLog.
    private var failureMessage: String {
        if let reason = model.connectionFailureReasons[deviceID],
           !reason.isEmpty {
            return "Connection failed — \(reason)"
        }
        return "Connection failed — check device"
    }

    private var syncDot: some View {
        Circle()
            .fill(syncColor)
            .frame(width: 7, height: 7)
            .accessibilityLabel(Text(syncLabel))
    }

    /// Maps the per-device connection state to the dot colour.
    /// Connected → green, connecting → yellow, failed → red,
    /// disconnected (or row toggled off) → grey, unknown → grey-ish.
    /// Replaces the previous always-green-when-enabled stub; see
    /// MainPopover commit history for the design rationale.
    private var syncColor: Color {
        switch connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return .secondary.opacity(0.3)
        case .unknown:
            // If the row is enabled but no event has come back yet,
            // show a soft yellow rather than dead-grey so the user
            // sees that something is in flight. After the 1-second
            // poll the cache fills in and the colour locks in.
            return routing.enabled ? .yellow : .secondary.opacity(0.3)
        }
    }

    private var syncLabel: String {
        switch connectionState {
        case .connected:    return "connected"
        case .connecting:   return "connecting"
        case .failed:       return "connection failed"
        case .disconnected: return "disconnected"
        case .unknown:      return routing.enabled ? "connecting" : "disabled"
        }
    }
}

private struct VolumeSlider: View {
    @Binding var value: Double

    var body: some View {
        Slider(value: $value, in: 0.0...1.0)
            .controlSize(.small)
            .accessibilityValue(Text("\(Int(value * 100))%"))
    }
}
