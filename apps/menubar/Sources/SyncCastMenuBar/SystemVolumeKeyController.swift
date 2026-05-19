import AppKit

enum SystemVolumeKeyAction: Equatable {
    case volumeUp
    case volumeDown
    case mute
}

/// Watches macOS media volume keys without consuming the event.
///
/// Direct Stereo's public aggregate intentionally exposes no render callback
/// and, on current macOS, no writable aggregate-level volume property. That
/// means the normal CoreAudio default-output slider cannot be bridged through
/// the aggregate itself. Media-key events are still observable, so we mirror
/// the user's keyboard/mouse shortcut intent into SyncCast's routing model and
/// then write physical-device hardware volume where CoreAudio permits it.
final class SystemVolumeKeyController {
    private let onAction: (SystemVolumeKeyAction) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastHandledEventNumber: Int?

    init(onAction: @escaping (SystemVolumeKeyAction) -> Void) {
        self.onAction = onAction
    }

    deinit {
        stop()
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .systemDefined
        ) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .systemDefined
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
        SyncCastLog.log("systemVolumeKey: monitor installed")
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
    }

    private func handle(_ event: NSEvent) {
        guard let action = Self.action(from: event) else { return }
        if lastHandledEventNumber == event.eventNumber {
            return
        }
        lastHandledEventNumber = event.eventNumber
        onAction(action)
    }

    static func action(from event: NSEvent) -> SystemVolumeKeyAction? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == 8
        else {
            return nil
        }
        let keyCode = Int((event.data1 & 0xFFFF_0000) >> 16)
        let keyState = Int((event.data1 & 0x0000_FF00) >> 8)
        guard keyState == 0x0A else {
            return nil
        }
        switch keyCode {
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
}
