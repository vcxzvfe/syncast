import SwiftUI

/// "调音方案": save the current EQ / 声场 / 声道 / delay configuration as a
/// named snapshot, and put any saved one back with a click — the A/B tool for
/// tuning several speakers against each other.
struct DspProfileSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("调音方案")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("保存当前") { model.saveCurrentDspProfile() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .disabled(!model.canSaveMoreDspProfiles)
                    .help("把现在所有设备的 EQ、声场、声道分配和延迟存成一个方案 · snapshot every per-output setting")
                    .accessibilityIdentifier("dspProfileSaveButton")
            }
            if model.dspProfiles.isEmpty {
                Text("先把三台设备调到一个状态，存成方案；再调另一个状态存成第二个，就能一键来回对比。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let active = model.activeDspProfileID
                ForEach(model.dspProfiles) { profile in
                    HStack(spacing: 6) {
                        Image(systemName: profile.id == active ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(profile.id == active ? Color.accentColor : Color.secondary)
                        Text(profile.name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if profile.id != active {
                            Button("应用") { model.applyDspProfile(profile) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10))
                                .accessibilityIdentifier("dspProfileApply-\(profile.id)")
                        } else {
                            Text("当前")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            model.deleteDspProfile(profile)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("删除这个方案 · delete this profile")
                        .accessibilityIdentifier("dspProfileDelete-\(profile.id)")
                    }
                }
                if active == nil {
                    Text("当前设置与任何已存方案都不同（改过之后就会这样）；想留住就再存一份。")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .onAppear { model.reloadDspProfilesFromStore() }
    }
}
