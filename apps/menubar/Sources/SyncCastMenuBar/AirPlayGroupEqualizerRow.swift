import SwiftUI

/// The AirPlay section's own tone control: one curve for every receiver.
///
/// It sits above the receiver rows rather than inside one of them because it
/// belongs to none of them. OwnTone sends a single stream to all receivers, so
/// this is the only equalisation the AirPlay leg can carry — the hint says so
/// on the row itself, permanently, rather than only in a tooltip. A user who
/// reads "EQ" next to a group of speakers will otherwise reasonably assume the
/// next thing to try is a curve per speaker, and spend the evening looking for
/// a control that cannot exist.
///
/// Local speakers in whole-home mode are NOT affected by this: each renders its
/// own copy of the broadcast and keeps its own per-device curve.
struct AirPlayGroupEqualizerRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("AirPlay 组 EQ")
                    .font(.system(size: 12))
                if let summary = model.equalizerSummary(target: .airPlayGroup) {
                    Text(summary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                EqualizerToggleButton(
                    target: .airPlayGroup,
                    helpText: "所有 AirPlay 接收端共用一条曲线"
                        + " · one curve for every AirPlay receiver"
                )
            }
            Text(AppModel.airPlayGroupEqualizerHint)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.equalizerEditorTarget == .airPlayGroup {
                EqualizerEditor(target: .airPlayGroup)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // The rows around this one toggle a speaker on tap; missing a control
        // by a few points must not do anything here either.
        .contentShape(Rectangle())
        .onTapGesture { }
        .accessibilityIdentifier("airPlayGroupEqualizerRow")
    }
}
