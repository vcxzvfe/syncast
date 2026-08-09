import SwiftUI

/// Two-stage AirPlay pairing sheet.
///
/// Stage one is not decoration. When pairing starts, the RECEIVING device
/// shows a four-digit PIN on ITS OWN screen — e.g. a Mac mini fills its
/// connected display with the code. The code never appears on this Mac (the
/// one running SyncCast), so a user who is not told where to look will stare
/// at the wrong screen, enter nothing, and watch the attempt time out.
/// Telling them first — and naming the device — is the difference between a
/// feature and a dead end. (This is direction B: only remote receivers are
/// ever pairable; SyncCast never targets this Mac itself.)
struct PairingSheet: View {
    /// Content width, matched to the menu-bar popover the copy was written
    /// against so moving this view into its own window does not reflow it.
    private static let contentWidth: CGFloat = 340

    @Environment(AppModel.self) private var model

    /// Keyboard focus for the PIN field. Setting this is what actually puts
    /// the caret in the box; being inside a key window (see
    /// `PairingWindowController`) is what makes the keystrokes arrive.
    @FocusState private var pinFieldFocused: Bool

    let state: PairingSheetState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state.stage {
            case .explainFullScreenPIN:
                explain
            case .enterPIN:
                enterPIN
            case .failed(let message):
                failure(message)
            }
        }
        .padding(20)
        .frame(width: Self.contentWidth)
        // The window is reused across stages and across attempts, so the
        // stage transition — not just first appearance — has to re-aim focus.
        .onChange(of: state.stage) { _, stage in
            pinFieldFocused = (stage == .enterPIN)
        }
    }

    private var explain: some View {
        Group {
            Text("Pair with \(state.deviceName)")
                .font(.headline)
            Text(
                "In a moment, **\(state.deviceName)** will show a four-digit code on "
                + "**its own screen** — not on this Mac. A Mac mini fills its connected "
                + "display with the code; that is normal, it is how macOS confirms an "
                + "AirPlay connection. Read the code from that device, then come back "
                + "here and type it in."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { model.confirmPairingWarning() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var enterPIN: some View {
        Group {
            Text("Enter the code shown on \(state.deviceName)")
                .font(.headline)
            TextField("1234", text: pinBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .focused($pinFieldFocused)
                .onAppear { pinFieldFocused = true }
            Text("Waiting for the code — \(state.secondsRemaining)s left")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { model.submitPairingPIN() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.pin.count != 4)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        Group {
            Text("Pairing did not finish")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { model.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                // Retrying is always explicit. Retrying on our own would put
                // another full-screen code up on the receiver's screen
                // unprompted.
                //
                // `restartPairing`, not `confirmPairingWarning`: the latter
                // guards on the explain stage, so from here it returned
                // without doing anything and this button — also the Return
                // key — was a no-op.
                Button("Try again") { model.restartPairing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The PIN lives only in the sheet's state and is cleared the moment it
    /// is handed to the sidecar. It is never logged and never persisted.
    private var pinBinding: Binding<String> {
        Binding(
            get: { model.pairingSheet?.pin ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber).prefix(4)
                model.pairingSheet?.pin = String(digits)
            }
        )
    }
}
