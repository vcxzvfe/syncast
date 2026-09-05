import SwiftUI
import SyncCastRouter

/// Row affordance that opens/closes one device's channel-assignment panel.
///
/// Only ever rendered where the assignment would actually be applied —
/// `AppModel.channelMatrixIsAvailable(for:)` answers that — so a visible
/// button always does something. Same rule as the EQ and 声场 buttons beside
/// it: on Direct Stereo the samples never reach us, and a control that
/// silently changes nothing is worse than no control.
struct ChannelMatrixToggleButton: View {
    let deviceID: String

    @Environment(AppModel.self) private var model

    private var isOpen: Bool { model.channelMatrixEditorDeviceID == deviceID }
    private var hasSetting: Bool { model.hasChannelMatrixSetting(for: deviceID) }

    var body: some View {
        Button {
            model.channelMatrixEditorDeviceID = isOpen ? nil : deviceID
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2.circle")
                    .font(.system(size: 10))
                if hasSetting {
                    Text(
                        AppModel.channelMatrixPresetLabel(
                            model.channelMatrixSettings(for: deviceID).preset
                        )
                    )
                    .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(
                hasSetting
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(HierarchicalShapeStyle.secondary)
            )
        }
        .buttonStyle(.borderless)
        .help("声道分配：这只音箱播放哪个声道 · which channel this output plays")
        .accessibilityIdentifier("channelMatrixToggleButton-\(deviceID)")
        .accessibilityLabel(Text(isOpen ? "Close channel assignment" : "Open channel assignment"))
    }
}

/// The inline panel: a preset picker, and — only when 自定义 is chosen — the
/// four coefficient sliders.
///
/// The four sliders are hidden behind the preset rather than always shown
/// because they are the answer to a question most people never ask: the four
/// named presets cover "left speaker", "right speaker", "mono cabinet" and
/// "leave it alone", which is every case anyone has actually wanted. Someone
/// who does want a 30 % blend can find it one click away.
struct ChannelMatrixEditor: View {
    let deviceID: String

    @Environment(AppModel.self) private var model

    private var settings: ChannelMatrixSettings {
        model.channelMatrixSettings(for: deviceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            presetRow
            if settings.preset == .custom {
                Divider().opacity(0.4)
                customSliders
            }
            footerRow
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        // Swallow taps: missing a control by a few points must not toggle the
        // speaker off mid-tuning.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("声道分配")
                .font(.system(size: 10, weight: .semibold))
            Text("channel assignment")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Presets

    private var presetRow: some View {
        Picker("", selection: Binding(
            get: { settings.preset },
            set: { model.setChannelMatrixPreset($0, for: deviceID) }
        )) {
            ForEach(ChannelMatrixPreset.allCases, id: \.self) { preset in
                Text(AppModel.channelMatrixPresetLabel(preset)).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .accessibilityIdentifier("channelMatrixPresetPicker-\(deviceID)")
    }

    // MARK: - Custom coefficients

    private var customSliders: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ChannelMatrixPath.allCases, id: \.self) { path in
                HStack(spacing: 6) {
                    Text(path.label)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { path.decibels(in: settings) },
                            set: {
                                model.setChannelMatrixCoefficient(
                                    $0, path: path, for: deviceID
                                )
                            }
                        ),
                        in: ChannelMatrixLimits.rangeDb,
                        step: ChannelMatrixLimits.stepDb
                    )
                    .controlSize(.mini)
                    .accessibilityIdentifier(
                        "channelMatrixSlider-\(path.rawValue)-\(deviceID)"
                    )
                    Text(AppModel.channelMatrixDecibelLabel(path.decibels(in: settings)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Text("滑到最左＝静音 · the bottom of the travel is silence")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button("重置") {
                model.resetChannelMatrix(for: deviceID)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
            .disabled(!model.hasChannelMatrixSetting(for: deviceID))
            .help("回到立体声 · back to plain stereo")
            .accessibilityIdentifier("channelMatrixResetButton-\(deviceID)")

            if model.channelMatrixIsClipping(for: deviceID) {
                Label("输出链削波，建议降低系数", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityIdentifier("channelMatrixClipIndicator-\(deviceID)")
            }
            Spacer(minLength: 0)
            Button("收起") {
                model.channelMatrixEditorDeviceID = nil
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
        }
    }
}
