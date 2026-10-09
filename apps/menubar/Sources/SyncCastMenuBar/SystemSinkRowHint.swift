import Foundation
import SyncCastRouter

/// The line under each output row on the system-sink path (pure, testable).
///
/// # Why it states the actual level
///
/// On the sink path a row's slider is a BALANCE under the system volume, and
/// its "100%" means "no offset", not "this speaker plays at 100%". With the
/// system volume at 90 % every row still reads 100% while each speaker plays
/// at 90 %, which reads as a wrong number. The line therefore states the level
/// the output is actually set to: the system volume and the row's balance
/// composed in the dB domain, exactly as the Router composes them.
///
/// # Why a display on software gain gets a warning instead
///
/// A display's level normally rides on DDC/CI. When the panel stops
/// answering, the Router attenuates the samples instead, and those can only
/// go BELOW the panel's own level, which is wherever the panel was when DDC
/// was lost and is unknown here. So there is no honest number to show; the
/// user is told the panel is being re-probed and why turning up stops early.
enum SystemSinkRowHint {

    enum Kind: Equatable {
        /// A CoreAudio output, with the Router's backend verdict if one has
        /// arrived yet.
        case local(SystemSinkVolumeLaw.Backend?, isDisplayCandidate: Bool)
        /// A LAN receiver: the master lands on the receiver's own hardware
        /// volume when it reported one (software gain there otherwise; nil
        /// until its hello_ack arrives), the balance on the samples sent to it.
        case lanReceiver(hardwareVolume: Bool?)
    }

    static func text(
        kind: Kind,
        masterScalar: Float,
        masterMuted: Bool,
        balance: Float,
        deviceMuted: Bool,
        law: SystemSinkVolumeLaw.ScalarDecibelLaw = SystemSinkVolumeLaw.appleBuiltInLaw
    ) -> String {
        if case .local(.softwareGain, isDisplayCandidate: true) = kind {
            return "显示器 DDC 未连上，正在重试：暂用软件增益，只能调到显示器自身音量为止 · DDC retrying"
        }
        let via: String
        switch kind {
        case .local(.ddc, _):
            via = "显示器 DDC/CI"
        case .local(.coreAudioHardware, _):
            via = "硬件音量"
        case .local(.softwareGain, _):
            via = "软件增益"
        case .local(nil, _):
            via = "跟随系统音量"
        case .lanReceiver(hardwareVolume: true):
            via = "对端硬件音量"
        case .lanReceiver(hardwareVolume: false):
            via = "对端软件增益"
        case .lanReceiver(hardwareVolume: nil):
            via = "跟随系统音量"
        }
        if masterMuted || deviceMuted {
            return "实际 静音 · \(via)"
        }
        return "实际 \(actualPercent(masterScalar: masterScalar, balance: balance, law: law))% · \(via)"
    }

    /// The level the output is set to, on the same 0…100 grid the system
    /// volume uses.
    static func actualPercent(
        masterScalar: Float,
        balance: Float,
        law: SystemSinkVolumeLaw.ScalarDecibelLaw = SystemSinkVolumeLaw.appleBuiltInLaw
    ) -> Int {
        let scalar = SystemSinkVolumeLaw.effectiveScalar(
            masterScalar: masterScalar, balance: balance, law: law
        )
        return Int((scalar * 100).rounded())
    }
}
