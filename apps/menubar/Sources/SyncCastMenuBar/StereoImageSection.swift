import SwiftUI
import SyncCastRouter

/// Row affordance that opens/closes one device's stereo-image panel.
///
/// Only ever rendered where the setting would actually be applied —
/// `AppModel.stereoImageIsAvailable(for:)` answers that — so a visible button
/// always does something. Same rule as the equalizer button it sits next to:
/// on Direct Stereo the samples never reach us, and a control that silently
/// changes nothing is worse than no control.
struct StereoImageToggleButton: View {
    let deviceID: String

    @Environment(AppModel.self) private var model

    private var isOpen: Bool { model.stereoImageEditorDeviceID == deviceID }
    private var hasSetting: Bool { model.hasStereoImageSetting(for: deviceID) }

    var body: some View {
        Button {
            model.stereoImageEditorDeviceID = isOpen ? nil : deviceID
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10))
                if hasSetting {
                    Text("声场")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(
                hasSetting && !model.stereoImageIsBypassed(for: deviceID)
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(HierarchicalShapeStyle.secondary)
            )
        }
        .buttonStyle(.borderless)
        .help("声场：宽度与串扰消除 · stereo width and crosstalk cancellation")
        .accessibilityIdentifier("stereoImageToggleButton-\(deviceID)")
        .accessibilityLabel(Text(isOpen ? "Close stereo image" : "Open stereo image"))
    }
}

/// One compact labelled slider. Every control in the panel is this shape, so
/// the rows line up and the panel stays readable at 340 pt.
private struct StereoImageSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueLabel: String
    let help: String
    let identifier: String
    var isEnabled: Bool = true
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
                .lineLimit(1)
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                step: step
            )
            .controlSize(.mini)
            .disabled(!isEnabled)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(Text(valueLabel))
            Text(valueLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 52, alignment: .trailing)
                .lineLimit(1)
        }
        .help(help)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Stereo-image editor for one output, rendered inline in the row.
///
/// Inline rather than a nested `.popover`, for the same reason the equalizer
/// panel is: the whole UI lives in a `MenuBarExtra(.window)`, where a second
/// floating window is an unverified AppKit interaction.
///
/// Every edit is applied live — `AppModel` writes the defaults immediately and
/// debounces only the push to the Router (50 ms), which then crossfades over
/// 20 ms — so a drag is audible while it happens and is already saved if the
/// app is killed mid-tuning.
struct StereoImageEditor: View {
    let deviceID: String

    @Environment(AppModel.self) private var model

    private var settings: StereoImageSettings {
        model.stereoImageSettings(for: deviceID)
    }

    /// Everything except the A/B switch is inert while bypassed; dimming
    /// rather than hiding keeps the panel's height stable when it is toggled.
    private var isLive: Bool { !settings.bypassed }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            widthSection
            Divider().opacity(0.4)
            crosstalkSection
            footerRow
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        // The device row toggles the speaker on tap. Missing a slider by a few
        // points must not switch the speaker off in the middle of tuning it.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("声场")
                .font(.system(size: 10, weight: .semibold))
            Spacer(minLength: 0)
            Toggle(
                "A/B 旁路",
                isOn: Binding(
                    get: { settings.bypassed },
                    set: { model.setStereoImageBypassed($0, for: deviceID) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 9))
            .help(
                "A/B 旁路：保留全部设置但暂时不处理，用来对比开关前后"
                    + " · keep every setting, stop applying the module"
            )
            .accessibilityIdentifier("stereoImageBypassToggle-\(deviceID)")
        }
    }

    // MARK: - Width

    private var widthSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(
                    "宽度",
                    isOn: Binding(
                        get: { settings.width.enabled },
                        set: { model.setStereoWidthEnabled($0, for: deviceID) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 9, weight: .semibold))
                .disabled(!isLive)
                .help(
                    "中/侧展宽：只放大左右声道的差值，和声不变，合并成单声道不会抵消"
                        + " · mid/side width, mono-compatible by construction"
                )
                .accessibilityIdentifier("stereoWidthToggle-\(deviceID)")
                Spacer(minLength: 0)
            }
            let enabled = isLive && settings.width.enabled
            StereoImageSlider(
                title: "展宽",
                value: settings.width.width,
                range: StereoImageLimits.widthRange,
                step: StereoImageLimits.widthStep,
                valueLabel: AppModel.stereoImageWidthLabel(settings.width.width),
                help: "1.00× 不变，2.00× 侧信号加倍 · side-signal scale, 1 = unchanged",
                identifier: "stereoWidthSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoWidth($0, for: deviceID) }
            StereoImageSlider(
                title: "起始",
                value: settings.width.cornerHz,
                range: StereoImageLimits.widthCornerRangeHz,
                step: StereoImageLimits.widthCornerStepHz,
                valueLabel: AppModel.stereoImageHertzLabel(settings.width.cornerHz),
                help:
                    "只在这个频率以上展宽；以下保持原样（小音箱的低频本来就是左右相加的）"
                    + " · width applies above this corner only",
                identifier: "stereoWidthCornerSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoWidthCorner($0, for: deviceID) }
            StereoImageSlider(
                title: "中置补偿",
                value: settings.width.midTrimDb,
                range: StereoImageLimits.midTrimRangeDb,
                step: StereoImageLimits.midTrimStepDb,
                valueLabel: AppModel.stereoImageDecibelLabel(settings.width.midTrimDb),
                help: "展宽后略降中置，保持整体响度 · trim the mid to keep loudness even",
                identifier: "stereoMidTrimSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoMidTrim($0, for: deviceID) }
        }
    }

    // MARK: - Crosstalk

    private var crosstalkSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(
                    "串扰消除",
                    isOn: Binding(
                        get: { settings.crosstalk.enabled },
                        set: { model.setStereoCrosstalkEnabled($0, for: deviceID) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 9, weight: .semibold))
                .disabled(!isLive)
                .help(
                    "递归串扰消除：把传到对侧耳朵的声音反相延时减掉，只在固定听音位置有效"
                        + " · recursive crosstalk cancellation, sweet-spot dependent"
                )
                .accessibilityIdentifier("stereoCrosstalkToggle-\(deviceID)")
                Spacer(minLength: 0)
            }
            let enabled = isLive && settings.crosstalk.enabled
            StereoImageSlider(
                title: "听距",
                value: settings.crosstalk.distanceMeters,
                range: StereoImageLimits.distanceRangeMeters,
                step: StereoImageLimits.distanceStepMeters,
                valueLabel: AppModel
                    .stereoImageCentimetreLabel(settings.crosstalk.distanceMeters),
                help: "耳朵到音箱的距离 · listening distance",
                identifier: "stereoCrosstalkDistanceSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoCrosstalkDistance($0 , for: deviceID) }
            StereoImageSlider(
                title: "单元间距",
                value: settings.crosstalk.spanMeters,
                range: StereoImageLimits.spanRangeMeters,
                step: StereoImageLimits.spanStepMeters,
                valueLabel: AppModel.stereoImageCentimetreLabel(settings.crosstalk.spanMeters),
                help: "两个高音单元的中心间距 · centre-to-centre driver spacing",
                identifier: "stereoCrosstalkSpanSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoCrosstalkSpan($0, for: deviceID) }
            // Read-only: τ falls out of the two sliders above, and watching it
            // move is what makes them legible.
            Text(AppModel.stereoImageDelayLabel(settings.crosstalk))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(enabled ? 1 : 0.4)
                .accessibilityIdentifier("stereoCrosstalkDelayLabel-\(deviceID)")
            StereoImageSlider(
                title: "衰减",
                value: settings.crosstalk.attenuationDb,
                range: StereoImageLimits.attenuationRangeDb,
                step: StereoImageLimits.attenuationStepDb,
                valueLabel: AppModel
                    .stereoImageDecibelLabel(settings.crosstalk.attenuationDb),
                help: "对侧声音相对本侧的衰减；越接近 −1 dB 越激进 · crosstalk attenuation",
                identifier: "stereoCrosstalkAttenuationSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoCrosstalkAttenuation($0, for: deviceID) }
            StereoImageSlider(
                title: "强度",
                value: settings.crosstalk.strength,
                range: StereoImageLimits.strengthRange,
                step: StereoImageLimits.strengthStep,
                valueLabel: AppModel.stereoImagePercentLabel(settings.crosstalk.strength),
                help: "0% 等于关闭；先从低往高推，听到中频发闷就退一点 · 0 = bypass",
                identifier: "stereoCrosstalkStrengthSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoCrosstalkStrength($0, for: deviceID) }
            StereoImageSlider(
                title: "频段下限",
                value: settings.crosstalk.lowHz,
                range: StereoImageLimits.crosstalkLowRangeHz,
                step: StereoImageLimits.crosstalkBandStepHz,
                valueLabel: AppModel.stereoImageHertzLabel(settings.crosstalk.lowHz),
                help: "这个频率以下原样通过 · below this the signal is passed through",
                identifier: "stereoCrosstalkLowSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoCrosstalkLow($0, for: deviceID) }
            StereoImageSlider(
                title: "频段上限",
                value: settings.crosstalk.highHz,
                range: StereoImageLimits.crosstalkHighRangeHz,
                step: StereoImageLimits.crosstalkBandStepHz,
                valueLabel: AppModel.stereoImageHertzLabel(settings.crosstalk.highHz),
                help: "这个频率以上原样通过 · above this the signal is passed through",
                identifier: "stereoCrosstalkHighSlider-\(deviceID)",
                isEnabled: enabled
            ) { model.setStereoCrosstalkHigh($0, for: deviceID) }
            // The colouration this structure inherently adds. Stated up front
            // rather than left for the user to discover as "why does the
            // middle sound honky".
            if enabled, let hint = AppModel.stereoImageColourationLabel(settings.crosstalk) {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stereoCrosstalkColourationHint-\(deviceID)")
            }
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button("重置") {
                model.resetStereoImage(for: deviceID)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
            .disabled(!model.hasStereoImageSetting(for: deviceID))
            .help("两级全部关闭，参数回到默认 · both stages off, values back to default")
            .accessibilityIdentifier("stereoImageResetButton-\(deviceID)")

            if model.stereoImageIsClipping(for: deviceID) {
                Label("输出链削波，建议降低强度或展宽", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityIdentifier("stereoImageClipIndicator-\(deviceID)")
            }
            Spacer(minLength: 0)
            Button("收起") {
                model.stereoImageEditorDeviceID = nil
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
        }
    }
}
