import SwiftUI
import SyncCastDiscovery
import SyncCastRouter

struct MainPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            wholeHouseToggle
            Divider().padding(.horizontal, 12)
            debugStrip
            Divider().padding(.horizontal, 12)
            deviceList
            Divider().padding(.horizontal, 12)
            footer
        }
        .padding(.vertical, 8)
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
        case .error:    return model.lastError ?? "Error"
        }
    }

    private var wholeHouseToggle: some View {
        @Bindable var model = model
        return Toggle(isOn: $model.wholeHouseEnabled) {
            HStack(spacing: 8) {
                Image(systemName: "house.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Whole-house mode").fontWeight(.medium)
                    Text("Stream to every selected speaker")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityIdentifier("wholeHouseToggle")
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
                    ForEach(model.localDevices) { dev in
                        DeviceRow(device: dev)
                    }
                }
                if !model.airPlayDevices.isEmpty {
                    sectionHeader("AirPlay")
                    ForEach(model.airPlayDevices) { dev in
                        DeviceRow(device: dev)
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
    let device: Device
    @Environment(AppModel.self) private var model

    private var routing: DeviceRouting {
        model.routing[device.id] ?? DeviceRouting(deviceID: device.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundStyle(routing.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    transportBadge
                    Spacer(minLength: 0)
                    syncDot
                }
                if routing.enabled {
                    HStack(spacing: 6) {
                        Image(systemName: routing.muted
                              ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .onTapGesture { model.toggleMute(device.id) }
                        VolumeSlider(
                            value: Binding(
                                get: { Double(routing.volume) },
                                set: { model.setVolume(Float($0), for: device.id) }
                            )
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(routing.enabled ? Color.accentColor.opacity(0.06) : Color.clear)
        // Make the WHOLE row a tap target — clicking anywhere on the row
        // (icon, name, badge, sync dot, blank space) toggles the device.
        // Previously the tap target was only on the inner VStack and many
        // pixels (icon column, trailing space) didn't react to clicks.
        .contentShape(Rectangle())
        .onTapGesture { model.toggleDevice(device.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(device.name), \(routing.enabled ? "enabled" : "disabled")"))
        .accessibilityHint(Text("Double-tap to \(routing.enabled ? "disable" : "enable")"))
    }

    private var iconName: String {
        switch device.transport {
        case .coreAudio:
            if device.name.localizedCaseInsensitiveContains("display") { return "tv" }
            if device.name.localizedCaseInsensitiveContains("built") { return "laptopcomputer" }
            return "hifispeaker"
        case .airplay2:
            return "airplayaudio"
        }
    }

    private var transportBadge: some View {
        Text(device.transport == .airplay2 ? "AirPlay" : "Local")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var syncDot: some View {
        Circle()
            .fill(syncColor)
            .frame(width: 7, height: 7)
            .accessibilityLabel(Text(syncLabel))
    }

    private var syncColor: Color {
        if !routing.enabled { return .secondary.opacity(0.3) }
        return .green   // P3 will compute real status from RouterSnapshot
    }

    private var syncLabel: String {
        routing.enabled ? "in sync" : "disabled"
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
