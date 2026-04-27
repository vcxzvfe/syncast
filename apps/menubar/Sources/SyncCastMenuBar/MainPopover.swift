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

    // MARK: - Sync section (manual-first)
    //
    // Manual-first calibration: a slider the user drags until music sounds
    // aligned, a Lock button that pins the chosen value, and an A/B test
    // (Stevens method bracketing) for users who can't tell which side of
    // the sweet spot they're on. Auto-calibrate and continuous calibration
    // are demoted into an Advanced disclosure — they remain available but
    // are no longer the headline action.
    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: title + lock pill + reset
            HStack {
                Text("AirPlay Delay")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                LockStatePill(state: model.delayLockState)
                Button("Reset") { model.airplayDelayMs = 2200 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .accessibilityIdentifier("syncResetButton")
            }

            // Slider — step 10ms (was 25)
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(model.airplayDelayMs) },
                    set: { model.airplayDelayMs = Int($0) }
                ), in: 0...5000, step: 10)
                    .controlSize(.small)
                    .accessibilityIdentifier("airplayDelaySlider")
                Text("\(model.airplayDelayMs) ms")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 70, alignment: .trailing)
            }

            // Action row: Lock + A/B test
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

                Button(action: {
                    if case .idle = model.auditionState {
                        model.startAudition()
                    } else {
                        model.stopAudition()
                    }
                }) {
                    Label(auditionButtonLabel,
                          systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stevens method bracketing: alternates ±150ms every 1.2s for 4 rounds")
                .accessibilityIdentifier("auditionButton")

                Spacer()
            }

            // A/B running prompt
            if case .running(let round, _) = model.auditionState {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Round \(round)/4 — which sounds aligned?")
                        .font(.caption2)
                    HStack {
                        Button("← A sounds better") { model.chooseAuditionA() }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("auditionChooseAButton")
                        Button("B sounds better →") { model.chooseAuditionB() }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("auditionChooseBButton")
                    }
                }
                .padding(6)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(6)
            }

            // Coaching hint
            Text(coachingHint)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Advanced disclosure: existing Auto-calibrate + Continuous toggle.
            // Hybrid Tracking UI is intentionally removed here.
            DisclosureGroup("Advanced") {
                advancedSection
            }
            .font(.system(size: 10))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .focusable()
        .onKeyPress(.leftArrow) {
            if case .idle = model.auditionState {
                let step = NSEvent.modifierFlags.contains(.shift) ? -100 : -10
                model.nudgeAirplayDelay(by: step)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if case .idle = model.auditionState {
                let step = NSEvent.modifierFlags.contains(.shift) ? 100 : 10
                model.nudgeAirplayDelay(by: step)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Advanced (Auto-calibrate + Continuous)
    //
    // Demoted from headline UI. Auto-calibrate is renamed to
    // "Estimate (rough)" to set expectations: it gives a starting point,
    // not the final number. Continuous calibration is preserved verbatim.
    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Estimate (rough) row: button + mic picker + status indicator.
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
            // Live progress while sequential per-device sweep is running:
            // "Calibrating <Device> (n/total)…". Sequential sweep takes
            // ≈30s for 4 devices, so per-device feedback matters.
            if case .running = model.calibrationStatus,
               let progress = model.calibrationProgress {
                Text(progress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

            // Continuous (background) calibration: toggle, optional
            // stepper, status caption. Hybrid mutual-exclusion logic
            // is removed because Hybrid Tracking is gone from this UI.
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { model.backgroundCalibrationEnabled },
                    set: { newValue in
                        model.backgroundCalibrationEnabled = newValue
                        if newValue {
                            Task { await model.ensureMicPermissionForBackgroundCalibration() }
                        }
                    }
                )) {
                    Text("Continuous").font(.system(size: 10))
                }
                .toggleStyle(.switch).controlSize(.mini)
                .accessibilityIdentifier("continuousCalibrationToggle")
                .help("Continuous Calibration runs full Auto-calibrate every N minutes.")
                if model.backgroundCalibrationEnabled {
                    Stepper(value: Binding(
                        get: { model.backgroundCalibrationIntervalS },
                        set: { model.backgroundCalibrationIntervalS = $0 }
                    ), in: AppModel.bgIntervalRange, step: 10) {
                        Text("\(model.backgroundCalibrationIntervalS)s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 32, alignment: .trailing)
                    }
                    .controlSize(.mini)
                    .accessibilityIdentifier("continuousCalibrationStepper")
                }
                Spacer()
            }
            if model.backgroundCalibrationEnabled,
               let status = continuousStatusText {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(model.backgroundCalibrationMicDenied ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(2)
            }
            if model.backgroundCalibrationActive {
                liveStatusBlock
                    .accessibilityIdentifier("continuousCalibrationLiveStatus")
            }

            // Measured-lag readout (was inline in v1 syncSection).
            HStack(spacing: 6) {
                Text("Measured lag: \(model.measuredLagMs.map { "\($0)" } ?? "—") ms")
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

    private var auditionButtonLabel: String {
        if case .idle = model.auditionState {
            return "A/B test"
        }
        return "Stop A/B"
    }

    private var coachingHint: String {
        if case .running = model.auditionState {
            return "Listening — pick the side that sounds in sync"
        }
        if case .locked(let v) = model.delayLockState {
            return "Locked at \(v) ms"
        }
        return "Drag until music sounds aligned, then press Lock"
    }

    // MARK: - Live continuous-calibration status block
    //
    // Three rows: per-device τ strip, trend timeline, cycle info.
    // Reads `model.lastCalibrationSample` + `calibrationSampleHistory`;
    // @Observable invalidates on mutation. The "Xs ago" string updates
    // each second because `syncSection` already re-renders on the
    // existing `measuredLagMs` 1 Hz poller.
    @ViewBuilder
    private var liveStatusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            perDeviceLatencyStrip
            trendTimelineRow
            cycleInfoRow
        }
        .padding(.top, 2)
    }

    /// One row per entry in `lastCalibrationSample?.perDeviceTauMs`.
    /// Empty until the integrator swaps in `ContinuousActiveCalibrator.Sample`.
    @ViewBuilder
    private var perDeviceLatencyStrip: some View {
        let entries = sortedPerDeviceEntries
        if entries.isEmpty {
            Text("Per-device τ: awaiting first cycle")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            // Bar scale: τ_d / τ_max so the 15 ms locals render as
            // pips next to ~2400 ms AirPlay, matching the spec mock.
            let tauMax = max(1, entries.map(\.1).max() ?? 1)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(entries, id: \.0) { entry in
                    perDeviceRow(name: entry.0, tau: entry.1, tauMax: tauMax)
                }
            }
        }
    }

    /// Stable display order: largest τ first, so AirPlay receivers
    /// (the dominant latency contributors) sit at the top.
    private var sortedPerDeviceEntries: [(String, Int)] {
        guard let sample = model.lastCalibrationSample else { return [] }
        return sample.perDeviceTauMs
            .map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
    }

    /// One device row: name, τ, proportional bar, drift indicator.
    @ViewBuilder
    private func perDeviceRow(name: String, tau: Int, tauMax: Int) -> some View {
        let frac = max(0, min(1.0, Double(tau) / Double(tauMax)))
        HStack(spacing: 6) {
            Text(truncate(name, max: 10))
                .frame(width: 70, alignment: .leading)
            Text("\(tau) ms")
                .frame(width: 56, alignment: .trailing)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.12))
                    .frame(width: 60, height: 6)
                Rectangle().fill(Color.accentColor.opacity(0.55))
                    .frame(width: max(2, CGFloat(frac) * 60), height: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 1))
            Text(driftLabel(for: name, tau: tau))
                .foregroundStyle(driftColor(for: name, tau: tau))
                .frame(width: 64, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    /// "steady" / "+Xms drift" / "−Xms drift" against the same
    /// device's τ in the previous sample. "—" on first cycle.
    private func driftLabel(for device: String, tau: Int) -> String {
        guard let prev = previousTau(for: device) else { return "—" }
        let delta = tau - prev
        if abs(delta) <= 2 { return "steady" }
        return "\(delta > 0 ? "+" : "−")\(abs(delta))ms drift"
    }

    private func driftColor(for device: String, tau: Int) -> Color {
        guard let prev = previousTau(for: device) else { return .secondary }
        let d = abs(tau - prev)
        return d <= 2 ? .secondary : (d <= 10 ? .yellow : .orange)
    }

    /// Previous-sample τ for `device`, or nil if no comparison frame.
    private func previousTau(for device: String) -> Int? {
        let h = model.calibrationSampleHistory
        return h.count >= 2 ? h[h.count - 2].perDeviceTauMs[device] : nil
    }

    /// Trend timeline — last 10 sliding samples' appliedDelayMs,
    /// comma-joined. Truncates on overflow.
    @ViewBuilder
    private var trendTimelineRow: some View {
        let recent = Array(model.calibrationSampleHistory.suffix(10))
        if !recent.isEmpty {
            let parts = recent.map { String($0.appliedDelayMs) }
            let spanS = model.backgroundCalibrationIntervalS * max(1, recent.count - 1)
            let span = spanS >= 60 ? "\(spanS / 60)m" : "\(spanS)s"
            HStack(spacing: 4) {
                Text("Recent:")
                Text(parts.joined(separator: ", "))
                    .lineLimit(1).truncationMode(.tail)
                Text("(\(span) sliding)")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    /// Cycle info: age, confidence, last applied delta. The threshold
    /// figure shown in the spec mock is engine-side (CalibrationRunner.
    /// deltaApplyThresholdMs); if the integrator exposes it on the new
    /// Sample, surface it here.
    @ViewBuilder
    private var cycleInfoRow: some View {
        if let sample = model.lastCalibrationSample {
            let age = max(0, Int(Date().timeIntervalSince(sample.timestamp)))
            let conf = String(format: "%.1f", sample.confidence * 100)
            let lastDelta = model.lastAppliedDelta
                .map { $0 >= 0 ? "+\($0) ms" : "\($0) ms" } ?? "0 ms"
            HStack(spacing: 6) {
                Text("Last: \(age)s ago")
                Text("•")
                Text("Conf: \(conf)")
                Text("•")
                Text("Δ: \(lastDelta)")
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    /// Truncate `s` to `n` characters with an ellipsis on overflow.
    private func truncate(_ s: String, max n: Int) -> String {
        s.count <= n ? s : String(s.prefix(max(1, n - 1))) + "…"
    }

    /// One of: mic-denied / inactive / waiting / active-with-sample.
    private var continuousStatusText: String? {
        if model.backgroundCalibrationMicDenied {
            return "Microphone access denied — open System Settings"
        }
        if !model.backgroundCalibrationActive {
            return "Inactive — enable AirPlay first"
        }
        guard let sample = model.lastCalibrationSample else {
            return "Active — waiting for sample"
        }
        let age = max(0, Int(Date().timeIntervalSince(sample.timestamp)))
        // ActiveCalibrator's aggregate confidence is an SNR (≥ 3 ⇒
        // detection threshold, higher ⇒ better). Map to a 0–100%
        // display by saturating at 20 — empirically a "very clean"
        // measurement runs 10–30, and treating 20+ as "100% confident"
        // keeps the popover caption readable.
        let pct = min(100, Int((sample.confidence / 20.0 * 100).rounded()))
        return "Active — last drift \(sample.measuredDeltaMs) ms (applied \(sample.appliedDelayMs) ms, \(pct)% confidence) \(age)s ago"
    }

    private var autoCalibrateLabel: String {
        switch model.calibrationStatus {
        case .idle:                  return "Estimate (rough)"
        case .requestingPermission:  return "Asking…"
        case .running:               return "Estimating…"
        case .completed:             return "Estimate (rough)"
        case .failed:                return "Estimate (rough)"
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
