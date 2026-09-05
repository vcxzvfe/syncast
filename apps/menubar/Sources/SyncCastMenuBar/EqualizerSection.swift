import SwiftUI
import SyncCastDiscovery
import SyncCastRouter

/// Row affordance that opens/closes one target's tone panel.
///
/// Only ever rendered where the curve would actually be applied —
/// `AppModel.equalizerIsAvailable(target:)` answers that — so a visible button
/// always does something. The one case where a control appears but is inert is
/// deliberately NOT offered: on Direct Stereo the samples never reach us, and
/// a slider that silently changes nothing is worse than no slider.
struct EqualizerToggleButton: View {
    let target: EqualizerTarget
    /// Tooltip, so the AirPlay group can say what it really is rather than
    /// claiming to be a speaker's control.
    var helpText: String = "调音器 · per-speaker equalizer"

    @Environment(AppModel.self) private var model

    private var isOpen: Bool { model.equalizerEditorTarget == target }

    var body: some View {
        Button {
            model.equalizerEditorTarget = isOpen ? nil : target
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 10))
                if model.hasEqualizerCurve(target: target) {
                    Text("EQ")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(
                model.hasEqualizerCurve(target: target)
                    && !model.equalizerIsBypassed(target: target)
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(HierarchicalShapeStyle.secondary)
            )
        }
        .buttonStyle(.borderless)
        .help(helpText)
        .accessibilityIdentifier("equalizerToggleButton-\(target.accessibilityKey)")
        .accessibilityLabel(Text(isOpen ? "Close equalizer" : "Open equalizer"))
    }
}

/// Ten-band graphic equalizer for one output, rendered inline in the row.
///
/// Inline rather than a nested `.popover`: the whole UI lives in a
/// `MenuBarExtra(.window)`, where a second floating window is an unverified
/// AppKit interaction and a dismissal of the parent would take the editor with
/// it. Inline also keeps the control in the same visual context as the volume
/// slider it sits under.
///
/// Every edit is applied live — `AppModel` writes the defaults immediately and
/// debounces only the push to the Router (50 ms), which then crossfades over
/// 20 ms. So a drag is audible while it happens and is already saved if the
/// app is killed mid-tuning.
struct EqualizerEditor: View {
    let target: EqualizerTarget

    @Environment(AppModel.self) private var model

    /// Vertical travel of a band slider. Enough to resolve the 0.5 dB step by
    /// eye without pushing the popover taller than the device list.
    private static let bandSliderLength: CGFloat = 84
    private static let bandColumnWidth: CGFloat = 29

    private var settings: EqualizerSettings {
        model.equalizerSettings(target: target)
    }

    /// Suffix for every accessibility identifier in the panel.
    private var key: String { target.accessibilityKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            bandRow
            trimRow
            footerRow
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        // The device row toggles the speaker on tap. Missing a slider by a few
        // points must not switch the speaker off in the middle of tuning it —
        // the same rule the volume and delay-trim sub-rows follow.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("调音器")
                .font(.system(size: 10, weight: .semibold))
            Text("dB")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Toggle(
                "旁路",
                isOn: Binding(
                    get: { settings.bypassed },
                    set: { model.setEqualizerBypassed($0, target: target) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 9))
            .help("旁路：保留曲线但暂时不生效 · keep the curve, stop applying it")
            .accessibilityIdentifier("equalizerBypassToggle-\(key)")
        }
    }

    // MARK: - Bands

    private var bandRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(settings.bands.enumerated()), id: \.offset) { index, band in
                bandColumn(index: index, band: band)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(settings.bypassed ? 0.4 : 1)
    }

    private func bandColumn(index: Int, band: EqualizerBand) -> some View {
        VStack(spacing: 2) {
            Text(AppModel.equalizerGainLabel(band.gainDb))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(
                    abs(band.gainDb) < EqualizerLimits.gainStepDb
                        ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                        : AnyShapeStyle(.primary)
                )
                .lineLimit(1)
                .fixedSize()
            Slider(
                value: Binding(
                    get: { band.gainDb },
                    set: {
                        model.setEqualizerBandGain($0, bandIndex: index, target: target)
                    }
                ),
                in: EqualizerLimits.bandGainRangeDb,
                step: EqualizerLimits.gainStepDb
            )
            .controlSize(.mini)
            // A macOS `Slider` is horizontal only; rotating it is the standard
            // way to get the graphic-EQ layout. The outer frame is what
            // reserves the column, because `rotationEffect` does not change
            // layout size.
            .frame(width: Self.bandSliderLength)
            .rotationEffect(.degrees(-90))
            .frame(width: Self.bandColumnWidth, height: Self.bandSliderLength)
            .disabled(settings.bypassed)
            .accessibilityIdentifier(
                "equalizerBandSlider-\(key)-\(Int(band.frequency.rounded()))"
            )
            .accessibilityLabel(
                Text("\(AppModel.equalizerFrequencyLabel(band.frequency)) hertz")
            )
            .accessibilityValue(Text("\(AppModel.equalizerGainLabel(band.gainDb)) dB"))
            Text(AppModel.equalizerFrequencyLabel(band.frequency))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: Self.bandColumnWidth)
    }

    // MARK: - Trim

    private var trimRow: some View {
        HStack(spacing: 6) {
            Text("总量")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { settings.trimDb },
                    set: { model.setEqualizerTrim($0, target: target) }
                ),
                in: EqualizerLimits.trimRangeDb,
                step: EqualizerLimits.gainStepDb
            )
            .controlSize(.mini)
            .disabled(settings.bypassed)
            .accessibilityIdentifier("equalizerTrimSlider-\(key)")
            .accessibilityValue(Text("\(AppModel.equalizerGainLabel(settings.trimDb)) dB"))
            Text(AppModel.equalizerGainLabel(settings.trimDb))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(
                    abs(settings.trimDb) < EqualizerLimits.gainStepDb
                        ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                        : AnyShapeStyle(.primary)
                )
                .frame(width: 30, alignment: .trailing)
        }
        .opacity(settings.bypassed ? 0.4 : 1)
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button("重置") {
                model.resetEqualizer(target: target)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
            .disabled(!model.hasEqualizerCurve(target: target))
            .help("所有频段回到 0 dB · flatten every band")
            .accessibilityIdentifier("equalizerResetButton-\(key)")

            // Live limiter indicator. A boost that pushes the chain past full
            // scale is clamped rather than wrapped, and this is the only place
            // the user can find out it is happening — the audible symptom
            // (distortion on peaks) is easy to blame on the speaker.
            if model.equalizerIsClipping(target: target) {
                Label("输出削波，建议降低总量", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityIdentifier("equalizerClipIndicator-\(key)")
            }
            Spacer(minLength: 0)
            Button("收起") {
                model.equalizerEditorTarget = nil
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
        }
    }
}
