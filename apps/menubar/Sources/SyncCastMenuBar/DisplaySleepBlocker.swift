import Foundation
import IOKit.pwr_mgt

/// Holds or drops the "do not let the display sleep for idleness" claim.
///
/// Behind a protocol so the controller can be exercised under XCTest without
/// creating a real power assertion on the developer's machine.
@MainActor
protocol DisplaySleepBlocker: AnyObject {
    var isHolding: Bool { get }
    /// Idempotent. Returns false when the system refused the assertion.
    @discardableResult func hold() -> Bool
    /// Idempotent. Returns false when the assertion could not be released
    /// and is still held; the caller retries.
    @discardableResult func release() -> Bool
}

/// `kIOPMAssertPreventUserIdleDisplaySleep`, and nothing stronger.
///
/// Deliberately NOT `UserIsActive` / `IOPMAssertionDeclareUserActivity`:
/// declaring user activity turns a sleeping display back on and resets the
/// idle clock the lock screen uses, so a Mac playing music would never lock.
/// This assertion only stops the idle timer from switching the display off;
/// it does not wake a display that is already off, and it lets the user put
/// the display to sleep by hand. It also implies "no idle system sleep",
/// which is what keeps the audio itself going.
///
/// macOS drops the assertion when the process exits, so a crash cannot leave
/// the display stuck on.
@MainActor
final class IOPMDisplaySleepBlocker: DisplaySleepBlocker {
    /// Shown by `pmset -g assertions`; the name the user looks for.
    static let assertionName = "SyncCast: audio playing"

    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    var isHolding: Bool { assertionID != IOPMAssertionID(kIOPMNullAssertionID) }

    @discardableResult
    func hold() -> Bool {
        guard !isHolding else { return true }
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )
        guard status == kIOReturnSuccess else {
            SyncCastLog.log("[awake] IOPMAssertionCreateWithName failed: 0x\(String(UInt32(bitPattern: status), radix: 16))")
            return false
        }
        assertionID = id
        return true
    }

    @discardableResult
    func release() -> Bool {
        guard isHolding else { return true }
        let status = IOPMAssertionRelease(assertionID)
        // NotFound / BadArgument: powerd no longer knows the ID, so there is
        // nothing left to hold. Anything else may mean it is still held;
        // keep the ID so the next attempt can release it.
        guard status == kIOReturnSuccess
            || status == kIOReturnNotFound
            || status == kIOReturnBadArgument else {
            SyncCastLog.log("[awake] IOPMAssertionRelease failed: 0x\(String(UInt32(bitPattern: status), radix: 16)); will retry")
            return false
        }
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        return true
    }
}
