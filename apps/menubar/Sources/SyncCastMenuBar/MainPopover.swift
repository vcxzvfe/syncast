import CoreAudio
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
    }

    /// Live tuning for the whole-home FIFO delay (≈1.8 s by default,
    /// matching AirPlay 2's PTP playout window). The "Measured lag"
    /// caption surfaces the sidecar's actual_delivery_lag_ms so the user
    /// can see whether their nudge took effect.
    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Sync")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { model.resetAirplayDelayToDefault() }) {
                    Text("Reset (\(AppModel.defaultAirplayDelayMs) ms)")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("syncResetButton")
            }
            HStack(spacing: 8) {
                let lo = Double(AppModel.airplayDelayMsRange.lowerBound)
                let hi = Double(AppModel.airplayDelayMsRange.upperBound)
                let bound = Binding(
                    get: { Double(model.airplayDelayMs) },
                    set: { model.setAirplayDelay(Int($0.rounded())) }
                )
                Slider(value: bound, in: lo...hi, step: 25)
                    .controlSize(.small)
                    .accessibilityIdentifier("airplayDelaySlider")
                Text("\(model.airplayDelayMs) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Text("AirPlay delay: \(model.airplayDelayMs) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Measured lag: \(model.measuredLagMs.map { "\($0)" } ?? "—") ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Auto-calibrate row: button + mic picker + status indicator.
            HStack(spacing: 8) {
                Button(action: {
                    Task { await model.runAutoCalibrate() }
                }) {
                    HStack(spacing: 4) {
                        if case .running = model.calibrationStatus {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                        } else if case .requestingPermission = model.calibrationStatus {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 10))
                        }
                        Text(autoCalibrateLabel)
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(autoCalibrateDisabled)
                .accessibilityIdentifier("autoCalibrateButton")
                Spacer()
                if !model.availableInputDevices.isEmpty {
                    Picker("Mic", selection: micPickerBinding) {
                        ForEach(model.availableInputDevices, id: \.id) { dev in
                            Text("\(dev.name) (\(dev.transportType))")
                                .tag(Optional(dev.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.mini)
                    .frame(maxWidth: 140)
                    .accessibilityIdentifier("calibrationMicPicker")
                }
            }
            // Per-status caption (result or error). Tap to dismiss.
            if case let .completed(delta, confidence) = model.calibrationStatus {
                let sign = delta >= 0 ? "+" : ""
                let pct = Int((confidence * 100).rounded())
                Text("Adjusted \(sign)\(delta) ms (confidence \(pct)%) — tap to dismiss")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .onTapGesture { model.dismissCalibrationStatus() }
            } else if case let .failed(msg) = model.calibrationStatus {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .onTapGesture { model.dismissCalibrationStatus() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var autoCalibrateLabel: String {
        switch model.calibrationStatus {
        case .idle:                  return "Auto-calibrate"
        case .requestingPermission:  return "Asking…"
        case .running:               return "Calibrating…"
        case .completed:             return "Auto-calibrate"
        case .failed:                return "Auto-calibrate"
        }
    }

    private var autoCalibrateDisabled: Bool {
        switch model.calibrationStatus {
        case .running, .requestingPermission: return true
        default: return false
        }
    }

    private var micPickerBinding: Binding<AudioDeviceID?> {
        Binding(
            get: { model.selectedMicID },
            set: { model.setSelectedMic($0) }
        )
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
            Image(systemName: model.statusIconName)
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
                if !model.airPlayDevices.isEmpty {
                    sectionHeader("AirPlay")
                    ForEach(model.airPlayDevices) { dev in
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
            Button(action: {}) {
                Label("Calibrate", systemImage: "tuningfork")
            }
            Button(action: {}) {
                Label("Settings", systemImage: "gearshape")
            }
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(routing.enabled ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleDevice(deviceID) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(device.name), \(routing.enabled ? "enabled" : "disabled"), \(syncLabel)"))
        .accessibilityHint(Text("Double-tap to \(routing.enabled ? "disable" : "enable")"))
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
