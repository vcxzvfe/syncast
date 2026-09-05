import SwiftUI
import SyncCastRouter

/// The extra sub-rows a LAN receiver gets under its volume row: the pairing
/// prompt, the target-latency slider, and the link readout.
///
/// Deliberately not a whole separate row type. A receiver IS an output — it
/// has the same enable toggle, the same fader, the same EQ / 声场 / 声道
/// buttons — and giving it its own row shape would mean maintaining two of
/// everything to express one difference.
struct LanReceiverControls: View {
    let deviceID: String

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !model.hasLanToken(for: deviceID) {
                pairingRow
            } else {
                targetRow
                if let summary = model.lanLinkSummary(for: deviceID) {
                    Text(summary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(linkIsHealthy ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.orange))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("lanLinkSummary-\(deviceID)")
                }
                if let note = model.lanHardwareVolumeNote(for: deviceID) {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.lanTokenMatchesHint(for: deviceID) == false {
                    Text("令牌与该接收端广播的提示不符 · the stored token does not match this receiver's advertised hint")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                changeTokenRow
            }
        }
        // Swallow taps, or missing the slider by a few points toggles the
        // receiver off mid-tuning.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private var linkIsHealthy: Bool {
        model.lanStatus(for: deviceID)?.link.isAudioReady ?? false
    }

    // MARK: - Pairing

    private var pairingRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "key")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("需要配对令牌 · needs a pairing token")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let hint = model.lanTokenHint(for: deviceID) {
                    Text("接收端日志里以 \(hint) 开头 · the receiver's log prints one starting \(hint)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button("输入令牌") {
                model.presentLanTokenWindow(for: deviceID)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .accessibilityIdentifier("lanTokenEntryButton-\(deviceID)")
        }
    }

    private var changeTokenRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button("更换令牌") {
                model.presentLanTokenWindow(for: deviceID)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9))
            .accessibilityIdentifier("lanTokenChangeButton-\(deviceID)")
        }
    }

    // MARK: - Target latency

    private var targetRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(model.lanTargetMs(for: deviceID)) },
                    set: { model.setLanTargetMs(Int($0), for: deviceID, persist: false) }
                ),
                in: Double(LanReceiverTargetStore.rangeMs.lowerBound)
                    ... Double(LanReceiverTargetStore.rangeMs.upperBound),
                step: Double(LanReceiverTargetStore.stepMs),
                onEditingChanged: { editing in
                    guard !editing else { return }
                    model.setLanTargetMs(
                        model.lanTargetMs(for: deviceID), for: deviceID, persist: true
                    )
                }
            )
            .controlSize(.mini)
            .accessibilityIdentifier("lanTargetSlider-\(deviceID)")
            Text("\(model.lanTargetMs(for: deviceID)) ms")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// The token entry form.
///
/// Lives in its own key-capable window rather than in the popover, for exactly
/// the reason `PairingWindowController` documents: the `MenuBarExtra(.window)`
/// panel is non-activating, so a text field inside it can never receive a
/// keystroke, and the click that tries to focus it tears the panel down.
struct LanTokenEntryView: View {
    static let contentWidth: CGFloat = 360

    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool
    @State private var typed: String = ""

    let deviceID: String
    let onFinished: () -> Void

    private var deviceName: String {
        model.devices.first { $0.id == deviceID }?.name ?? "receiver"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配对 \(deviceName)")
                .font(.headline)
            Text(
                "在接收端运行 synccast-receiver --print-token，把打印出来的令牌粘贴到这里。"
                + "\nRun synccast-receiver --print-token on the receiver and paste the token here."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // A plain field rather than a SecureField: the user is pasting a
            // token off another machine's log and needs to see whether it
            // arrived intact. It is never persisted here, never logged, and
            // goes straight to the keychain on save.
            TextField("3f2a…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($fieldFocused)
                .onAppear {
                    typed = ""
                    fieldFocused = true
                }
                .onSubmit(save)

            if let hint = model.lanTokenHint(for: deviceID) {
                Text("这台接收端广播的开头是 \(hint) · this receiver advertises a hint of \(hint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.lanTokenSaveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !typed.isEmpty, LanReceiverTokenStore.sanitize(typed) != nil,
               !LanReceiverTokenStore.looksLikeADaemonToken(
                   LanReceiverTokenStore.sanitize(typed) ?? ""
               ) {
                Text("这看起来不像守护进程生成的令牌（应为 16 位以上的十六进制），仍可保存")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.hasLanToken(for: deviceID) {
                    Button("清除") {
                        model.setLanToken("", for: deviceID)
                        onFinished()
                    }
                    .accessibilityIdentifier("lanTokenClearButton")
                }
                Spacer()
                Button("取消") { onFinished() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(LanReceiverTokenStore.sanitize(typed) == nil)
                    .accessibilityIdentifier("lanTokenSaveButton")
            }
        }
        .padding(20)
        .frame(width: Self.contentWidth)
    }

    private func save() {
        guard LanReceiverTokenStore.sanitize(typed) != nil else { return }
        model.setLanToken(typed, for: deviceID)
        // Clear the field before the window goes away, so the string does not
        // sit in SwiftUI state until the view is next rebuilt.
        typed = ""
        guard model.lanTokenSaveError == nil else { return }
        onFinished()
    }
}
