import AppKit
import ApplicationServices
import CoreGraphics
import os

enum SystemVolumeKeyAction: Equatable {
    case volumeUp
    case volumeDown
    case mute
}

/// How media volume keys are currently being captured.
enum SystemVolumeKeyCaptureState: String, Equatable, Sendable {
    /// CGEventTap is live: keys are observed system-wide and consumed
    /// while Direct Stereo is running (no "forbidden" OSD).
    case eventTap
    /// Accessibility is granted but the tap could not be created; only
    /// the NSEvent monitors are active. Functionally equivalent to the
    /// pre-tap behavior (keys only visible while the app is frontmost,
    /// which an LSUIElement menubar app almost never is).
    case monitorFallback
    /// Accessibility permission missing — a session event tap for
    /// key-class events cannot be created until the user grants it.
    case needsPermission
}

/// Captures macOS media volume keys (volume up / down / mute) for Direct
/// Stereo mode.
///
/// Why a CGEventTap and not NSEvent monitors: a GLOBAL NSEvent monitor for
/// key-class events (which `.systemDefined` media keys are) silently
/// receives nothing without Accessibility authorization, and a LOCAL
/// monitor only fires while the app is frontmost — which an LSUIElement
/// menubar app essentially never is. launch.log proved the old monitors
/// never observed a single key press across 8 launches. The session-level
/// `.defaultTap` (active) tap both observes the keys system-wide AND lets
/// us consume them, suppressing the system "forbidden" volume OSD that
/// macOS shows when the default output (our aggregate) has no volume
/// control.
///
/// Threading: the tap runs its own dedicated thread + run loop so the
/// consume/pass decision is never blocked by main-thread work. The
/// decision reads only a lock-protected eligibility flag pushed in by
/// `AppModel` (direct stereo running gate). Actions hop to the main actor
/// inside the `onAction` closure.
///
/// Degradation: without Accessibility we keep the NSEvent monitors
/// installed (no worse than the previous behavior) and expose
/// `.needsPermission` so the UI can point the user at System Settings.
/// Permission changes are observed via the "com.apple.accessibility.api"
/// distributed notification plus an explicit recheck whenever the popover
/// opens; the tap installs automatically once granted — no app restart.
final class SystemVolumeKeyController {
    // MARK: Constants (NX event encoding)

    /// NX_SYSDEFINED — CGEventType for system-defined events. There is no
    /// public CGEventType case; the raw value is stable ABI (IOKit's
    /// ev_types.h) and equals NSEvent.EventType.systemDefined.
    static let nxSystemDefinedTypeRawValue: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS — media key subtype.
    static let auxControlSubtype = 8
    private static let keyDownState = 0x0A
    private static let keyUpState = 0x0B
    /// NX_KEYTYPE_SOUND_UP / NX_KEYTYPE_SOUND_DOWN / NX_KEYTYPE_MUTE.
    private static let volumeKeyCodes: Set<Int> = [0, 1, 7]

    // MARK: State

    private let onAction: (SystemVolumeKeyAction) -> Void
    private let onStateChange: (SystemVolumeKeyCaptureState) -> Void

    private var started = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastHandledEventNumber: Int?
    private var accessibilityObserver: NSObjectProtocol?

    /// Last state reported through `onStateChange`. Main-thread only.
    private(set) var captureState: SystemVolumeKeyCaptureState = .needsPermission

    /// "Direct stereo running" gate, pushed in by AppModel. Read
    /// synchronously from the tap thread on every system-defined event,
    /// hence the lock instead of a MainActor property.
    private let eligibleState = OSAllocatedUnfairLock(initialState: false)

    private struct TapHandles {
        var machPort: CFMachPort?
        var runLoop: CFRunLoop?
        /// Pure stop/start state machine — see
        /// `SystemVolumeKeyTapLifecycle` for the race windows it closes.
        var lifecycle = SystemVolumeKeyTapLifecycle.State()
    }
    /// Tap mach port + run loop + lifecycle state, shared between the
    /// main thread (start/stop) and the tap thread (publish/teardown,
    /// timeout re-enable). Every lifecycle transition happens inside
    /// this lock so stop and publish serialize against each other.
    private let tapHandles = OSAllocatedUnfairLock(initialState: TapHandles())
    private var tapThread: Thread?

    // MARK: Lifecycle

    init(
        onAction: @escaping (SystemVolumeKeyAction) -> Void,
        onStateChange: @escaping (SystemVolumeKeyCaptureState) -> Void
    ) {
        self.onAction = onAction
        self.onStateChange = onStateChange
    }

    deinit {
        stop()
    }

    func start() {
        guard !started else { return }
        started = true
        installMonitors()
        observeAccessibilityChanges()
        if AXIsProcessTrusted() {
            startTapThread()
        } else {
            updateCaptureState(.needsPermission)
            SyncCastLog.log(
                "systemVolumeKey: accessibility NOT granted — media keys invisible globally; NSEvent monitor fallback active (frontmost only)"
            )
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        if let accessibilityObserver {
            DistributedNotificationCenter.default()
                .removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
        stopTapThread()
        started = false
    }

    // MARK: Eligibility (pushed from AppModel)

    /// Direct-stereo-running gate. Only when eligible does the tap consume
    /// volume keys; otherwise every event passes through untouched and
    /// macOS keeps its native behavior.
    func setEligible(_ eligible: Bool) {
        let changed = eligibleState.withLock { state -> Bool in
            guard state != eligible else { return false }
            state = eligible
            return true
        }
        if changed {
            SyncCastLog.log("systemVolumeKey: eligible=\(eligible) (direct stereo running gate)")
        }
    }

    // MARK: Permission handling

    /// Re-evaluate Accessibility trust and install / tear down the tap to
    /// match. Called on permission notifications and every popover open.
    /// Main thread.
    func recheckPermission(reason: String) {
        let trusted = AXIsProcessTrusted()
        switch (trusted, captureState) {
        case (true, .needsPermission), (true, .monitorFallback):
            SyncCastLog.log("systemVolumeKey: accessibility granted (\(reason)) — installing event tap")
            startTapThread()
        case (false, .eventTap):
            SyncCastLog.log("systemVolumeKey: accessibility revoked (\(reason)) — removing event tap")
            stopTapThread()
            updateCaptureState(.needsPermission)
        default:
            break
        }
    }

    /// Show the system "grant Accessibility" prompt. The caller (AppModel)
    /// rate-limits this to once via UserDefaults.
    func promptForAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        SyncCastLog.log("systemVolumeKey: accessibility prompt requested (trusted=\(trusted))")
    }

    private func observeAccessibilityChanges() {
        // macOS posts this distributed notification whenever any process's
        // Accessibility authorization changes. The TCC database write can
        // lag the notification slightly, so re-check twice.
        accessibilityObserver = DistributedNotificationCenter.default()
            .addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.recheckPermission(reason: "accessibility notification")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.recheckPermission(reason: "accessibility notification settle")
                }
            }
    }

    private func updateCaptureState(_ state: SystemVolumeKeyCaptureState) {
        guard captureState != state else { return }
        captureState = state
        SyncCastLog.log("systemVolumeKey: capture state → \(state.rawValue)")
        onStateChange(state)
    }

    // MARK: NSEvent monitor fallback

    /// The pre-existing monitors. Kept as the no-permission fallback: the
    /// local monitor works while the app is frontmost regardless of
    /// Accessibility; the global one starts delivering if the user grants
    /// permission. Both are harmless next to the tap because a consumed
    /// event never reaches them, and `handleMonitorEvent` applies the
    /// same eligibility gate as the tap path (AppModel's guard remains
    /// as defense in depth).
    private func installMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .systemDefined
        ) { [weak self] event in
            self?.handleMonitorEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .systemDefined
        ) { [weak self] event in
            self?.handleMonitorEvent(event)
            return event
        }
        SyncCastLog.log("systemVolumeKey: NSEvent monitors installed")
    }

    private func handleMonitorEvent(_ event: NSEvent) {
        guard let action = Self.action(from: event) else { return }
        // Same eligibility gate as the tap path: when direct stereo is
        // not running this controller must be inert on its own — not
        // rely on AppModel's downstream guard (which stays in place as
        // defense in depth).
        guard eligibleState.withLock({ $0 }) else { return }
        // Local + global monitors can both fire for the same event when
        // the app is frontmost AND trusted; dedupe by event number.
        if lastHandledEventNumber == event.eventNumber {
            return
        }
        lastHandledEventNumber = event.eventNumber
        SyncCastLog.log("systemVolumeKey: \(action) via NSEvent monitor")
        onAction(action)
    }

    // MARK: CGEventTap

    private func startTapThread() {
        // Main-thread `tapThread` guard FIRST: while a spawned thread is
        // still alive and un-stopped, bumping the generation below would
        // invalidate it (its tap discarded) without starting a successor.
        guard tapThread == nil else { return }
        let decision = tapHandles.withLock { handles in
            let decision = SystemVolumeKeyTapLifecycle.beginStart(
                handles.lifecycle
            )
            handles.lifecycle = decision.state
            return decision
        }
        // Refused ⇔ a published tap still exists (possibly mid-teardown
        // right after a stop). recheckPermission runs again on the
        // accessibility-notification settle pass and on every popover
        // open, so a refused start self-heals.
        guard decision.shouldSpawnThread else {
            SyncCastLog.log(
                "systemVolumeKey: startTapThread refused — previous tap still installed (teardown in flight)"
            )
            return
        }
        let generation = decision.threadGeneration
        let thread = Thread { [weak self] in
            self?.tapThreadMain(generation: generation)
        }
        thread.name = "SyncCast.SystemVolumeKeyTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func stopTapThread() {
        // Record the stop request and read the published run loop in ONE
        // critical section. The tap thread publishes / re-checks under
        // the same lock, so exactly one side observes the other: either
        // we see its run loop (and stop it below), or it sees our
        // stopRequested in resolveInstall and discards the tap before
        // ever entering CFRunLoopRun.
        let runLoop = tapHandles.withLock { handles -> CFRunLoop? in
            handles.lifecycle = SystemVolumeKeyTapLifecycle.requestStop(
                handles.lifecycle
            )
            return handles.runLoop
        }
        if let runLoop {
            // CFRunLoopStop on a loop that is not running (yet) is a
            // silent no-op — exactly the published-but-not-yet-running
            // window. A queued block survives until the loop actually
            // runs, so the stop cannot be lost; WakeUp covers the
            // already-running case promptly.
            CFRunLoopPerformBlock(
                runLoop, CFRunLoopMode.commonModes.rawValue
            ) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
        }
        tapThread = nil
    }

    private func tapThreadMain(generation: UInt64) {
        let mask = CGEventMask(1) << Self.nxSystemDefinedTypeRawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: SystemVolumeKeyController.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else {
            SyncCastLog.log(
                "systemVolumeKey: CGEventTap create FAILED (axTrusted=\(AXIsProcessTrusted())) — NSEvent monitor fallback only"
            )
            let failedThread = Thread.current
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A concurrent stop→start pair may already have replaced
                // `tapThread` with a successor; only clear our own ref.
                if self.tapThread === failedThread {
                    self.tapThread = nil
                }
                self.updateCaptureState(
                    AXIsProcessTrusted() ? .monitorFallback : .needsPermission
                )
            }
            return
        }
        let runLoop = CFRunLoopGetCurrent()
        // Publish the handles AND re-check for a stop / newer start that
        // raced in while tapCreate was in flight — one critical section,
        // same lock as stopTapThread/startTapThread.
        let published = tapHandles.withLock { handles -> Bool in
            let resolution = SystemVolumeKeyTapLifecycle.resolveInstall(
                handles.lifecycle, threadGeneration: generation
            )
            handles.lifecycle = resolution.state
            guard resolution.shouldPublish else { return false }
            handles.machPort = tap
            handles.runLoop = runLoop
            return true
        }
        guard published else {
            // stopTapThread (or a superseding startTapThread) won the
            // race during tapCreate. Without this check the tap would
            // enter CFRunLoopRun with nobody left to stop it — a
            // session-level CONSUMING tap leaked until logout, its stale
            // machPort short-circuiting every later startTapThread.
            // Discard before the tap ever becomes active.
            // CFMachPortInvalidate also invalidates `source` (which was
            // never added to a run loop here). `tapThread` needs no
            // cleanup: a stop nil'ed it; a supersede re-pointed it at
            // the newer thread.
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            SyncCastLog.log(
                "systemVolumeKey: CGEventTap discarded — stop/restart raced during install"
            )
            return
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        SyncCastLog.log("systemVolumeKey: CGEventTap installed (session, headInsert, consumes volume keys while direct stereo runs)")
        DispatchQueue.main.async { [weak self] in
            self?.updateCaptureState(.eventTap)
        }
        CFRunLoopRun()
        // The queued stop block fired (stop() / permission revoked) —
        // tear down: disable, detach the run-loop source, invalidate.
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        tapHandles.withLock { handles in
            let resolution = SystemVolumeKeyTapLifecycle.finishTeardown(
                handles.lifecycle, threadGeneration: generation
            )
            handles.lifecycle = resolution.state
            // Clear only OUR publication — a stale thread must never
            // wipe a successor's handles.
            if resolution.shouldClearHandles {
                handles.machPort = nil
                handles.runLoop = nil
            }
        }
        SyncCastLog.log("systemVolumeKey: CGEventTap removed")
    }

    /// C-convention trampoline — `userInfo` carries the controller.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let controller = Unmanaged<SystemVolumeKeyController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return controller.handleTapEvent(type: type, event: event)
    }

    /// Runs on the tap thread. Must stay fast: a stalled tap gets disabled
    /// by the window server and every key on the system lags.
    private func handleTapEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The window server disables taps that stall (or via the
            // user-input guard). Our handling is microseconds, so a
            // timeout means transient system pressure — re-enable.
            if let port = tapHandles.withLock({ $0.machPort }) {
                CGEvent.tapEnable(tap: port, enable: true)
                SyncCastLog.log(
                    "systemVolumeKey: event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user-input") disable"
                )
            }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.nxSystemDefinedTypeRawValue,
              let nsEvent = NSEvent(cgEvent: event)
        else {
            return Unmanaged.passUnretained(event)
        }
        let eligible = eligibleState.withLock { $0 }
        let subtypeRaw = Int(nsEvent.subtype.rawValue)
        let data1 = nsEvent.data1
        guard Self.shouldConsume(
            eligible: eligible,
            subtypeRaw: subtypeRaw,
            data1: data1
        ) else {
            // Not our key, or direct stereo not running — pass through so
            // macOS behaves exactly as if we did not exist.
            return Unmanaged.passUnretained(event)
        }
        // Consume BOTH the key-down and the matching key-up so the system
        // never sees half an event; act only on the key-down.
        if let action = Self.action(subtypeRaw: subtypeRaw, data1: data1) {
            SyncCastLog.log("systemVolumeKey: \(action) via event tap (consumed)")
            onAction(action)
        }
        return nil
    }

    // MARK: Pure event decoding (unit tested)

    static func keyCode(fromData1 data1: Int) -> Int {
        (data1 & 0xFFFF_0000) >> 16
    }

    static func keyState(fromData1 data1: Int) -> Int {
        (data1 & 0x0000_FF00) >> 8
    }

    /// Decode a media-key ACTION from raw system-defined event payload.
    /// Returns nil for key-up halves, non-aux subtypes and non-volume keys
    /// (play/pause, brightness, ...).
    static func action(
        subtypeRaw: Int,
        data1: Int
    ) -> SystemVolumeKeyAction? {
        guard subtypeRaw == auxControlSubtype,
              keyState(fromData1: data1) == keyDownState
        else {
            return nil
        }
        switch keyCode(fromData1: data1) {
        case 0:
            return .volumeUp
        case 1:
            return .volumeDown
        case 7:
            return .mute
        default:
            return nil
        }
    }

    static func action(from event: NSEvent) -> SystemVolumeKeyAction? {
        guard event.type == .systemDefined else { return nil }
        return action(
            subtypeRaw: Int(event.subtype.rawValue),
            data1: event.data1
        )
    }

    /// Exact consumption rule for the tap: only when direct stereo is
    /// running AND the event is one of the three volume keys, in either
    /// its key-down (0x0A) or key-up (0x0B) phase. Everything else —
    /// other media keys, other subtypes, ineligible states — passes
    /// through untouched.
    static func shouldConsume(
        eligible: Bool,
        subtypeRaw: Int,
        data1: Int
    ) -> Bool {
        guard eligible, subtypeRaw == auxControlSubtype else { return false }
        let state = keyState(fromData1: data1)
        guard state == keyDownState || state == keyUpState else { return false }
        return volumeKeyCodes.contains(keyCode(fromData1: data1))
    }
}
