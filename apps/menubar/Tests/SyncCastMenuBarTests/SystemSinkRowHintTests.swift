import XCTest
import SyncCastRouter
@testable import SyncCastMenuBar

/// The per-row line on the system-sink path.
///
/// # Why these exist
///
/// Every row's slider read 100% while the speakers played at the system
/// volume, because on this path the slider is a balance, not a level. The row
/// line now states the actual level; and a display whose DDC link is down
/// says so instead of showing a number that cannot be true.
final class SystemSinkRowHintTests: XCTestCase {

    func testActualLevelIsTheSystemVolumeWhenTheBalanceIsUntouched() {
        XCTAssertEqual(
            SystemSinkRowHint.actualPercent(masterScalar: 0.9, balance: 1),
            90
        )
        XCTAssertEqual(
            SystemSinkRowHint.text(
                kind: .local(.ddc, isDisplayCandidate: true),
                masterScalar: 0.9, masterMuted: false,
                balance: 1, deviceMuted: false
            ),
            "实际 90% · 显示器 DDC/CI"
        )
    }

    /// Same dB-domain composition the Router uses, so the number matches what
    /// the panel or the hardware scalar really receives.
    func testActualLevelComposesTheBalanceLikeTheRouter() {
        let expected = SystemSinkVolumeLaw.effectiveScalar(
            masterScalar: 0.9, balance: 0.8
        )
        XCTAssertEqual(
            SystemSinkRowHint.actualPercent(masterScalar: 0.9, balance: 0.8),
            Int((expected * 100).rounded())
        )
        XCTAssertLessThan(
            SystemSinkRowHint.actualPercent(masterScalar: 0.9, balance: 0.8),
            90
        )
    }

    func testEveryCarrierIsNamed() {
        func line(_ kind: SystemSinkRowHint.Kind) -> String {
            SystemSinkRowHint.text(
                kind: kind, masterScalar: 1, masterMuted: false,
                balance: 1, deviceMuted: false
            )
        }
        XCTAssertEqual(line(.local(.coreAudioHardware, isDisplayCandidate: false)), "实际 100% · 硬件音量")
        XCTAssertEqual(line(.local(.softwareGain, isDisplayCandidate: false)), "实际 100% · 软件增益")
        XCTAssertEqual(line(.local(nil, isDisplayCandidate: false)), "实际 100% · 跟随系统音量")
        XCTAssertEqual(line(.lanReceiver), "实际 100% · 对端硬件音量")
    }

    func testMuteWins() {
        XCTAssertEqual(
            SystemSinkRowHint.text(
                kind: .local(.coreAudioHardware, isDisplayCandidate: false),
                masterScalar: 0.9, masterMuted: true,
                balance: 1, deviceMuted: false
            ),
            "实际 静音 · 硬件音量"
        )
        XCTAssertEqual(
            SystemSinkRowHint.text(
                kind: .lanReceiver,
                masterScalar: 0.9, masterMuted: false,
                balance: 1, deviceMuted: true
            ),
            "实际 静音 · 对端硬件音量"
        )
    }

    /// A display on software gain has no honest number: the samples are
    /// attenuated under a panel level nobody can read while DDC is down.
    func testDisplayWithoutDDCWarnsInsteadOfShowingANumber() {
        let line = SystemSinkRowHint.text(
            kind: .local(.softwareGain, isDisplayCandidate: true),
            masterScalar: 1, masterMuted: false,
            balance: 1, deviceMuted: false
        )
        XCTAssertFalse(line.contains("实际"))
        XCTAssertTrue(line.contains("DDC"))
    }
}
