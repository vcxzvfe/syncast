import Foundation
import AppKit
import SyncCastDiscovery
import SyncCastRouter

/// Drives the two-stage pairing sheet.
///
/// Stage one exists purely to warn the user: for a REMOTE receiver, macOS
/// shows a four-digit PIN on the RECEIVER's own screen (a Mac mini shows it on
/// its display; a speaker-only receiver may not prompt at all). Without a
/// heads-up that reads as intentional, people reasonably assume something has
/// gone wrong.
struct PairingSheetState: Identifiable, Equatable {
    enum Stage: Equatable {
        case explainFullScreenPIN
        case enterPIN
        case failed(String)
    }

    /// Mirrors the sidecar's `PAIRING_PIN_WINDOW_S`. Declared on this
    /// non-isolated struct rather than on the MainActor-bound AppModel so the
    /// default value can be used from anywhere.
    static let windowSeconds = 240

    let deviceKey: String
    let deviceName: String
    var stage: Stage
    var pin: String = ""

    /// Wall-clock instant the sidecar's PIN window closes, set when the entry
    /// stage opens. `secondsRemaining` is DERIVED from this rather than
    /// decremented once per poll: the poll sleeps a second and then awaits
    /// three sequential RPCs, so a tick is strictly slower than a second,
    /// while the sidecar's `asyncio.wait_for` runs on wall clock. Counting
    /// ticks therefore told the user they had a minute left at the moment
    /// their attempt actually died.
    var deadline: Date?
    var secondsRemaining: Int = PairingSheetState.windowSeconds

    var id: String { deviceKey }
}

extension AppModel {

    // MARK: - Whole-home local-output selection (direction B)
    //
    // Under direction B the local speakers are a plain OwnTone output, not an
    // AirPlay target: there is no self-target, no loopback, no full-screen PIN.
    // The user simply picks which local CoreAudio outputs OwnTone renders to
    // (the "Local" section of the device list, which drives `routing.enabled`).
    // The only persistence concern is that the choice survives relaunching and
    // a change of location, so it is stored as a set of CoreAudio UIDs — never
    // names, never indices — via `WholeHomeMemberStore`, and re-applied to the
    // routing table for whatever is actually connected now.

    /// Load the persisted local-output selection. Called from bootstrap,
    /// before the first engine reconcile, so the very first whole-home start
    /// already knows which local outputs the user picked.
    func loadWholeHomeLocalOutputSelection() {
        wholeHomeLocalMemberUIDs = WholeHomeMemberStore.load()
        SyncCastLog.log(
            "AppModel: loaded \(wholeHomeLocalMemberUIDs.count) remembered local output(s)"
        )
    }

    /// Re-enable the remembered local outputs for whatever is connected now.
    ///
    /// The persisted UID set is loaded at bootstrap, but the `.appeared`
    /// handler only auto-enables it while already in whole-home mode — and the
    /// app launches in stereo, so on a fresh launch the local outputs have all
    /// appeared (in stereo) before the user ever switches to whole-home. Left
    /// to `restoreRememberedSelection` alone the choice would be lost every
    /// launch (that path consults only the in-memory, never-persisted
    /// per-mode map), so the user would have to re-pick their speakers each
    /// session. This closes that gap: on entry to whole-home we apply the
    /// persisted UID set to whatever local CoreAudio outputs exist right now.
    /// Only enables; a device the user deliberately turned off was removed
    /// from the persisted set at that time, so this never resurrects an off.
    func applyRememberedWholeHomeLocalOutputs() {
        guard mode == .wholeHome, !wholeHomeLocalMemberUIDs.isEmpty else { return }
        let remembered = Set(wholeHomeLocalMemberUIDs)
        var enabledCount = 0
        for device in devices {
            guard device.transport == .coreAudio,
                  let uid = device.coreAudioUID,
                  remembered.contains(uid),
                  isSelectableInMode(device, mode: .wholeHome)
            else { continue }
            var route = routing[device.id] ?? DeviceRouting(deviceID: device.id)
            guard !route.enabled else { continue }
            route.enabled = true
            routing[device.id] = route
            enabledCount += 1
        }
        if enabledCount > 0 {
            SyncCastLog.log(
                "AppModel: applied \(enabledCount) remembered whole-home local output(s)"
            )
        }
    }

    /// Persist the currently-enabled local outputs as the remembered
    /// selection. Called after the user changes which local outputs are on in
    /// whole-home mode. Absent-but-remembered UIDs are kept so moving between
    /// an office display and a home display does not forget either one.
    func persistWholeHomeLocalOutputSelection() {
        let presentEnabled: [String] = devices.compactMap { device in
            guard device.transport == .coreAudio,
                  let uid = device.coreAudioUID,
                  routing[device.id]?.enabled == true
            else { return nil }
            return uid
        }
        let presentUIDs = Set(devices.compactMap { $0.coreAudioUID })
        // Keep remembered UIDs that simply are not connected here.
        let rememberedAbsent = wholeHomeLocalMemberUIDs.filter {
            !presentUIDs.contains($0)
        }
        var merged: [String] = []
        for uid in presentEnabled where !merged.contains(uid) { merged.append(uid) }
        for uid in rememberedAbsent where !merged.contains(uid) { merged.append(uid) }
        wholeHomeLocalMemberUIDs = merged
        WholeHomeMemberStore.save(merged)
    }

    // MARK: - Pairing (remote receivers: Mac mini, Xiaomi, …)

    /// Stable key for a device's pairing state. Deliberately delegates rather
    /// than re-deriving: the sidecar looks the same key up, and a second copy
    /// of the fallback rule would eventually disagree with the first —
    /// silently, as a lookup miss.
    func pairingKey(for device: Device) -> String {
        Router.pairingKey(for: device)
    }

    func pairingState(for device: Device) -> PairingState {
        pairingStates[pairingKey(for: device)] ?? .notRequired
    }

    /// Step one of the two-stage flow: warn about the PIN prompt.
    func startPairing(for device: Device) {
        let key = pairingKey(for: device)
        // There is one sheet and one window, but the sidecar tracks attempts
        // per key. Replacing the sheet without ending the previous attempt
        // orphaned it: it stayed alive for the rest of its four-minute window
        // with the old receiver still showing its full-screen PIN, and its
        // popover row rendered as "Pairing…" with no button, so the user had
        // no way to stop it.
        if let existing = pairingSheet, existing.deviceKey != key {
            endPairingAttempt(key: existing.deviceKey)
        }
        beginFreshPairingAttempt(key: key, deviceName: device.name)
        presentPairingWindow()
    }

    /// Stop an in-flight attempt for `key` from the popover, without touching
    /// the sheet. The `.awaitingPIN` / `.verifying` rows use this so an
    /// attempt is always recoverable rather than leaving the user to wait out
    /// the sidecar's window.
    func cancelPairing(for device: Device) {
        let key = pairingKey(for: device)
        if pairingSheet?.deviceKey == key { pairingSheet = nil }
        endPairingAttempt(key: key)
    }

    /// Install a clean sheet for a brand-new attempt.
    ///
    /// Clearing the Router's cached terminal state is the essential half: the
    /// 1 Hz poll re-applies whatever that cache holds, so a stale `failed` /
    /// `timedOut` from the previous attempt would slam this sheet straight
    /// back to the failure screen within a second.
    private func beginFreshPairingAttempt(key: String, deviceName: String) {
        pairingSheet = PairingSheetState(
            deviceKey: key,
            deviceName: deviceName,
            stage: .explainFullScreenPIN
        )
        pairingStates[key] = .required
        pairingErrors.removeValue(forKey: key)
        Task { [weak self] in
            await self?.router.resetPairingState(deviceKey: key)
        }
    }

    /// Bring up (or re-front) the window that hosts the pairing flow.
    ///
    /// This is the only place that shows it. Closing is driven from inside the
    /// window instead — `PairingWindowRootView` watches `pairingSheet` go nil —
    /// so the many places that end a pairing attempt do not each need to
    /// remember to touch the UI.
    private func presentPairingWindow() {
        let controller = pairingWindowController ?? PairingWindowController(model: self)
        pairingWindowController = controller
        controller.present()
    }

    /// Step two: the user acknowledged the warning, so ask the receiver to
    /// show its PIN and open the entry field.
    func confirmPairingWarning() {
        guard var sheet = pairingSheet, sheet.stage == .explainFullScreenPIN else {
            SyncCastLog.log(
                "AppModel: confirmPairingWarning ignored — sheet stage is "
                + "\(pairingSheet.map { "\($0.stage)" } ?? "absent")"
            )
            return
        }
        sheet.stage = .enterPIN
        sheet.secondsRemaining = PairingSheetState.windowSeconds
        sheet.deadline = Date().addingTimeInterval(
            TimeInterval(PairingSheetState.windowSeconds)
        )
        pairingSheet = sheet
        let key = sheet.deviceKey
        Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await self.router.beginPairing(deviceKey: key)
                await MainActor.run {
                    self.pairingStates[key] = state
                    if state == .notRequired {
                        self.pairingSheet = nil
                    } else if state == .failed {
                        self.failPairingSheet(
                            key: key,
                            message: "The receiver did not start pairing. It may not be reachable right now."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.failPairingSheet(key: key, message: "\(error)")
                }
            }
        }
    }

    func submitPairingPIN() {
        guard let sheet = pairingSheet, sheet.stage == .enterPIN else { return }
        let key = sheet.deviceKey
        let pin = sheet.pin
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.router.submitPairingPIN(
                    deviceKey: key, pin: pin
                )
                await MainActor.run {
                    if outcome.accepted {
                        // Clear the PIN from our own state as soon as it has
                        // been handed over; it lives nowhere else.
                        self.pairingSheet?.pin = ""
                    } else {
                        // Use the sidecar's own reason. A rejection can mean
                        // the window already closed, and telling that user
                        // their correct four digits are "not four digits"
                        // sends them to fix the one thing that was right.
                        self.pairingSheet?.stage = .failed(
                            outcome.reason ?? "That code was not accepted."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.failPairingSheet(key: key, message: "\(error)")
                }
            }
        }
    }

    /// "Try again" from the failure screen.
    ///
    /// Must reset the sheet before re-entering the flow:
    /// `confirmPairingWarning` guards on `stage == .explainFullScreenPIN`, so
    /// calling it from `.failed` returned immediately and the button — which
    /// is also the default action, i.e. the Return key — did nothing at all.
    func restartPairing() {
        guard let sheet = pairingSheet else { return }
        beginFreshPairingAttempt(key: sheet.deviceKey, deviceName: sheet.deviceName)
    }

    func cancelPairing() {
        guard let sheet = pairingSheet else { return }
        let key = sheet.deviceKey
        pairingSheet = nil
        endPairingAttempt(key: key)
    }

    /// Tell the sidecar to end the attempt for `key`, then re-sync state.
    /// Split out of `cancelPairing()` so the same teardown can be applied to
    /// an attempt that is NOT the one the sheet is currently showing.
    private func endPairingAttempt(key: String) {
        Task { [weak self] in
            _ = try? await self?.router.cancelPairing(deviceKey: key)
            await self?.refreshPairingStates()
        }
    }

    func refreshPairingStates() async {
        let snapshot = await router.pairingStatesSnapshot()
        await MainActor.run {
            // MERGE, do not replace. Some transitions are known only here —
            // an RPC that threw before the sidecar ever heard about it, a
            // credential we just forgot — and those keys are by definition
            // absent from the Router's cache. A wholesale replace erased them
            // on the next tick, one second later, so the user's action
            // appeared to do nothing.
            self.pairingStates.merge(snapshot) { _, fromRouter in fromRouter }
            self.tickPairingSheetCountdown()
            self.applyPairingSnapshotToSheet(snapshot)
        }
    }

    /// Apply a poll snapshot's terminal outcome to the open sheet.
    ///
    /// Not private: this is the rule worth pinning down in a test, and doing
    /// it through `refreshPairingStates` would need a live sidecar.
    func applyPairingSnapshotToSheet(_ snapshot: [String: PairingState]) {
        guard let sheet = pairingSheet else { return }
        // Terminal outcomes are ATTEMPT-scoped, but the Router's cache is
        // KEY-scoped and this poll runs every second. A sheet sitting on the
        // explain stage belongs to a NEW attempt, so it must not inherit the
        // previous attempt's failure — applying it there bounced the user off
        // "Try again" and back to the failure screen about a second after
        // every press, which made a receiver that failed once effectively
        // impossible to pair.
        let isAwaitingOutcome = sheet.stage == .enterPIN
        switch snapshot[sheet.deviceKey] {
        case .paired:
            pairingSheet = nil
        case .failed where isAwaitingOutcome:
            let detail = pairingErrors[sheet.deviceKey]
            pairingSheet?.stage = .failed(
                detail ?? "Pairing failed. You can try again."
            )
        case .timedOut where isAwaitingOutcome:
            pairingSheet?.stage = .failed(
                "Nobody entered the PIN in time. You can try again."
            )
        default:
            break
        }
    }

    /// Refresh the PIN window countdown, and fail the sheet locally when it
    /// runs out.
    ///
    /// The label always read "240s left" because nothing ever updated it, so
    /// the user had no signal that the window was closing — and if the
    /// sidecar's timeout notification went missing, none that it had closed.
    ///
    /// Derived from `deadline` rather than counted down per tick: this runs
    /// on a poll that sleeps a second and then awaits three RPCs, so ticks lag
    /// wall clock, and the sidecar's window is wall clock. The
    /// count-the-ticks version drifted long, which made the local expiry
    /// fallback fire well after the attempt had already died and showed the
    /// user time they no longer had.
    func tickPairingSheetCountdown() {
        guard let sheet = pairingSheet, sheet.stage == .enterPIN else { return }
        let remaining: Int
        if let deadline = sheet.deadline {
            remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        } else {
            // No deadline recorded (a sheet constructed directly, e.g. in a
            // test). Fall back to the old per-tick decrement.
            remaining = max(0, sheet.secondsRemaining - 1)
        }
        pairingSheet?.secondsRemaining = remaining
        guard remaining <= 0 else { return }
        pairingSheet?.stage = .failed(
            "Nobody entered the PIN in time. You can try again."
        )
    }

    private func failPairingSheet(key: String, message: String) {
        pairingStates[key] = .failed
        pairingErrors[key] = message
        guard pairingSheet?.deviceKey == key else { return }
        pairingSheet?.stage = .failed(message)
    }

    // MARK: - Per-mode selection memory

    /// Stable keys of every currently-enabled device.
    func enabledStableKeys() -> Set<String> {
        var keys = Set<String>()
        for device in devices where routing[device.id]?.enabled == true {
            if let key = device.persistenceKey { keys.insert(key) }
        }
        return keys
    }

    /// Re-enable whatever the user had on last time they were in `mode`,
    /// for devices that exist now and are usable in that mode.
    func restoreRememberedSelection(for mode: Mode) {
        guard let remembered = rememberedEnabledKeysByMode[mode], !remembered.isEmpty
        else { return }
        for device in devices {
            guard let key = device.persistenceKey, remembered.contains(key),
                  isSelectableInMode(device, mode: mode)
            else { continue }
            var route = routing[device.id] ?? DeviceRouting(deviceID: device.id)
            guard !route.enabled else { continue }
            route.enabled = true
            routing[device.id] = route
        }
    }
}
