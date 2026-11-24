import SwiftUI
import SyncCastDiscovery

/// The 「自动连接」 block in the popover.
///
/// Its own file rather than another computed property on `MainPopover`: the
/// popover is already 980 lines, and this section owns local `@State` (the
/// trigger picked in the creation row) that has no business living in the
/// parent view.
///
/// Deliberately compact. The rule is set up once and then never touched, so
/// the steady state is a title, a switch and one sentence; everything the user
/// only needs while configuring sits behind the 「断开时」 disclosure.
struct AutoConnectSection: View {
    @Environment(AppModel.self) private var model
    /// Trigger chosen in the creation row. nil until the user picks, at which
    /// point `effectiveTriggerUID` stops defaulting.
    @State private var pickedTriggerUID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let profile = model.autoConnectProfile {
                existingRule(profile)
            } else {
                creationRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("自动连接")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            if let profile = model.autoConnectProfile {
                Toggle("", isOn: Binding(
                    get: { profile.enabled },
                    set: { model.autoConnectSetEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityIdentifier("autoConnectEnabledToggle")
            }
        }
    }

    // MARK: - No rule yet

    @ViewBuilder
    private var creationRow: some View {
        if model.autoConnectTriggerCandidates.isEmpty {
            Text("接上显示器或外接声卡后，可以把当前的设备选择存成规则。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(model.autoConnectEnabledLocalDevices.isEmpty
                 ? "先勾好想同时出声的输出，再选一个「一出现就自动连上」的设备。"
                 : "选一个「一出现就自动连上」的设备，当前已开启的输出会成为规则成员。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { effectiveTriggerUID ?? "" },
                    set: { pickedTriggerUID = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(model.autoConnectTriggerCandidates, id: \.id) { device in
                        Text(device.name).tag(device.coreAudioUID ?? "")
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 150)
                .accessibilityIdentifier("autoConnectTriggerPicker")

                Spacer(minLength: 0)

                Button("用当前选择创建规则") {
                    guard let uid = effectiveTriggerUID else { return }
                    model.autoConnectCreateProfile(triggerUID: uid)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                // Disabled rather than letting the model's guard reject the
                // press: a rule created from an empty selection could never
                // fire, and a refusal after the fact reads as a bug.
                .disabled(
                    effectiveTriggerUID == nil
                    || model.autoConnectEnabledLocalDevices.isEmpty
                )
                .accessibilityIdentifier("autoConnectCreateButton")
            }
        }
    }

    /// The picker's selection, defaulting to the sole external output when the
    /// user has not picked. One external device is the overwhelmingly common
    /// case (a laptop on a desk), and defaulting there means the whole feature
    /// is one button press.
    private var effectiveTriggerUID: String? {
        let candidates = model.autoConnectTriggerCandidates.compactMap(\.coreAudioUID)
        if let picked = pickedTriggerUID, candidates.contains(picked) { return picked }
        return candidates.first
    }

    // MARK: - Existing rule

    @ViewBuilder
    private func existingRule(_ profile: AutoConnectProfile) -> some View {
        if let summary = model.autoConnectSummary {
            Text(summary)
                .font(.system(size: 10))
                .foregroundStyle(profile.enabled ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 4) {
            Image(systemName: model.autoConnectTriggerPresent
                  ? "checkmark.circle.fill" : "clock")
                .font(.system(size: 9))
                .foregroundStyle(model.autoConnectTriggerPresent ? .green : .secondary)
            Text(model.autoConnectTriggerPresent
                 ? "\(model.autoConnectDisplayName(for: profile.triggerUID, in: profile)) 已连接"
                 : "等待 \(model.autoConnectDisplayName(for: profile.triggerUID, in: profile))")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }

        playbackAwakeOptions(profile)

        DisclosureGroup("断开时") {
            disconnectOptions(profile)
        }
        .font(.system(size: 10))

        HStack(spacing: 10) {
            Button("重新应用规则") { model.autoConnectReapplyNow() }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .disabled(!profile.enabled)
                .accessibilityIdentifier("autoConnectReapplyButton")
            Button("删除规则") { model.autoConnectDeleteProfile() }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .accessibilityIdentifier("autoConnectDeleteButton")
            Spacer(minLength: 0)
        }
    }

    /// 「有声音时不熄屏」. Its own switch, independent of the rule's master
    /// switch: it acts on whatever is playing out of the trigger device, no
    /// matter which route got it there. Off for a new rule.
    @ViewBuilder
    private func playbackAwakeOptions(_ profile: AutoConnectProfile) -> some View {
        let trigger = model.autoConnectDisplayName(for: profile.triggerUID, in: profile)
        Toggle(isOn: Binding(
            get: { profile.keepsDisplayAwakeWhilePlaying },
            set: { model.autoConnectSetKeepDisplayAwake($0) }
        )) {
            Text("有声音从 \(trigger) 放出时，不让它空闲熄屏")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("autoConnectKeepDisplayAwakeToggle")

        if profile.keepsDisplayAwakeWhilePlaying {
            let minutes = profile.resolvedPlaybackAwakeReleaseSeconds / 60
            HStack(spacing: 6) {
                Stepper(
                    value: Binding(
                        get: { minutes },
                        set: { model.autoConnectSetPlaybackAwakeReleaseMinutes($0) }
                    ),
                    in: PlaybackAwakeDefaults.releaseMinutesRange
                ) {
                    Text("声音停 \(minutes) 分钟后放开")
                        .font(.system(size: 10).monospacedDigit())
                }
                .controlSize(.mini)
                .accessibilityIdentifier("autoConnectPlaybackAwakeReleaseStepper")
                Spacer(minLength: 0)
                if model.playbackAwakeHolding {
                    Text("正在保持亮屏")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
            }
            .padding(.leading, 18)

            if let hint = playbackAwakeHint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
        }
    }

    /// What the keep-awake option cannot see right now, if anything.
    private var playbackAwakeHint: String? {
        if #unavailable(macOS 14.2) {
            return "低于 macOS 14.2 时，只能检测经 SyncCast 播放的声音；别的 App 直接输出到显示器的声音测不到。"
        }
        if model.playbackAwakeMeterProblem {
            return "测不到别的 App 直接输出到显示器的声音。请在「隐私与安全性」里允许 SyncCast 录制系统音频。"
        }
        return nil
    }

    /// What happens when the trigger goes away. Both options default OFF for a
    /// new rule: silently re-pointing someone's system output, or dropping
    /// their speaker level to a number they never chose, is not a reasonable
    /// thing to do to a user who only asked for auto-connect.
    @ViewBuilder
    private func disconnectOptions(_ profile: AutoConnectProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { profile.onDisconnect.restoreBuiltIn },
                set: { model.autoConnectSetRestoreBuiltIn($0) }
            )) {
                Text("切回内建扬声器")
                    .font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("autoConnectRestoreBuiltInToggle")

            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { profile.onDisconnect.builtInVolumePercent != nil },
                    set: { model.autoConnectSetBuiltInVolumePercent($0 ? 0 : nil) }
                )) {
                    Text("并把内建音量设为")
                        .font(.system(size: 10))
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("autoConnectForceVolumeToggle")

                if let percent = profile.onDisconnect.builtInVolumePercent {
                    Stepper(
                        value: Binding(
                            get: { percent },
                            set: { model.autoConnectSetBuiltInVolumePercent($0) }
                        ),
                        in: AutoConnect.percentRange,
                        step: 5
                    ) {
                        Text("\(percent)%")
                            .font(.system(size: 10).monospacedDigit())
                    }
                    .controlSize(.mini)
                    .accessibilityIdentifier("autoConnectVolumeStepper")
                }
                Spacer(minLength: 0)
            }

            Text("0% 是真正的静音（写的是系统音量滑块位置），适合合上盖子带出门。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}
