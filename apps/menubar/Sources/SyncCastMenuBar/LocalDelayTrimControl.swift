import SwiftUI
import SyncCastRouter

/// Per-device delay compensation for one row of the local Stereo list.
///
/// Only ever rendered where the value would actually be applied —
/// `AppModel.localDelayTrimIsAvailable(for:)` answers that — so a visible
/// control always does something. The inert case is deliberately not offered:
/// on Direct Stereo the samples never reach us, and a slider that silently
/// changes nothing is worse than no slider.
///
/// # Slider, not stepper
///
/// The opposite call from the whole-home trim row, for a concrete reason. That
/// one is a stepper because every commit relatches an AirPlay receiver, so a
/// drag would be a stutter stream. Here a commit is a memcpy and a 20 ms
/// crossfade on the render thread, and the user is hunting for a value they
/// can only recognise by ear — which is a sweep, not a series of guesses. The
/// ± buttons stay for the last millisecond of it, where 201 detents across a
/// popover-width track are too coarse to hit.
struct LocalDelayTrimControl: View {
    let deviceID: String

    @Environment(AppModel.self) private var model

    private var trim: Int { model.localDelayTrimMs(for: deviceID) }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(model.localDelayTrimMs(for: deviceID)) },
            // persist: false — the defaults are written once on release
            // instead of once per pixel. The in-memory value is what gets
            // pushed to the Router either way, so what is playing and what is
            // shown never disagree mid-drag.
            set: { model.setLocalDelayTrim(Int($0.rounded()), for: deviceID, persist: false) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(AppModel.localDelayTrimHint)
                nudgeButton(-LocalDelayTrim.stepMs, systemName: "minus")
                Slider(
                    value: sliderBinding,
                    in: Double(LocalDelayTrim.rangeMs.lowerBound)
                        ... Double(LocalDelayTrim.rangeMs.upperBound),
                    step: Double(LocalDelayTrim.stepMs),
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        model.setLocalDelayTrim(trim, for: deviceID, persist: true)
                    }
                )
                .controlSize(.mini)
                .accessibilityIdentifier("localDelayTrimSlider-\(deviceID)")
                .accessibilityLabel(Text("Output delay"))
                .accessibilityValue(Text("\(trim) milliseconds"))
                nudgeButton(LocalDelayTrim.stepMs, systemName: "plus")
                Text(AppModel.localDelayTrimLabel(trim))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(
                        trim == 0
                            ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                            : AnyShapeStyle(.primary)
                    )
                    .frame(minWidth: 46, alignment: .trailing)
                    .lineLimit(1)
                // Per-row reset appears only when there is something to reset,
                // so an untouched row gains no chrome and no layout shift.
                if trim != 0 {
                    Button {
                        model.resetLocalDelayTrim(for: deviceID)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                    .help("重置这台设备的延迟 · reset this output's delay to 0 ms")
                    .accessibilityIdentifier("localDelayTrimResetButton-\(deviceID)")
                    .accessibilityLabel(Text("Reset delay"))
                }
            }
            // Shown once the row carries a value, which is when the sign
            // convention becomes actionable. Rendering it on every enabled row
            // would put the same sentence under every speaker in the list; the
            // icon's tooltip carries it for anyone who has not dialled
            // anything yet.
            if trim != 0 {
                Text(AppModel.localDelayTrimHint)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Swallow taps that land in this sub-row. The whole device row carries
        // `.onTapGesture { model.toggleDevice(deviceID) }`, and missing the
        // slider by a few points must not switch the speaker off in the middle
        // of tuning it.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    @ViewBuilder
    private func nudgeButton(_ deltaMs: Int, systemName: String) -> some View {
        Button {
            model.nudgeLocalDelayTrim(deltaMs, for: deviceID)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 8))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(
            "localDelayTrim\(deltaMs > 0 ? "Increment" : "Decrement")Button-\(deviceID)"
        )
        .accessibilityLabel(Text(deltaMs > 0 ? "Delay this output more" : "Delay this output less"))
    }
}
