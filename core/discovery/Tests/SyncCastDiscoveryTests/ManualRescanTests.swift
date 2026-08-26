import XCTest
@testable import SyncCastDiscovery

/// Guards on the manual-rescan entry points.
///
/// The interesting failure they protect against is not a crash but a silent
/// one: a refresh that runs before anyone is subscribed would advance the
/// discovery snapshot with no listener attached, and the subsequent initial
/// scan would then see "nothing changed" and announce no devices at all —
/// an empty device list that no amount of waiting fixes.
final class ManualRescanTests: XCTestCase {
    /// The removal-suppression window must be a real, positive interval:
    /// at zero, a restarted browser's first (routinely incomplete) callback
    /// would report every live receiver as gone.
    func test_removal_grace_window_is_positive() {
        XCTAssertGreaterThan(AirPlayDiscovery.rescanRemovalGraceSeconds, 0)
    }

    /// `refreshNow()` before `events()` must not consume the initial
    /// announcement.
    func test_refresh_before_subscribe_does_not_swallow_initial_devices() async throws {
        let discovery = CoreAudioDiscovery()
        guard !discovery.enumerate().isEmpty else {
            throw XCTSkip("no CoreAudio output devices on this machine")
        }

        // The premature refresh the guard exists for.
        discovery.refreshNow()
        // Give the (guarded) hop onto the discovery queue a chance to run,
        // so this is a real ordering test and not a race we happened to win.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Waited on with a timeout rather than by iterating the stream to a
        // deadline: when this regresses the stream stays silent forever, so
        // a deadline checked per-event never gets checked at all and the
        // test hangs instead of failing. (Verified by reintroducing the
        // bug.)
        let announced = expectation(
            description: "initial scan announced a device"
        )
        let consumer = Task {
            for await event in discovery.events() {
                if case .appeared = event {
                    announced.fulfill()
                    break
                }
            }
        }
        defer { consumer.cancel() }
        await fulfillment(of: [announced], timeout: 5)
    }

    /// `rescan()` before `events()` is a no-op rather than a crash or a
    /// stray browser.
    func test_airplay_rescan_before_subscribe_is_safe() async throws {
        let discovery = AirPlayDiscovery()
        discovery.rescan()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Same for the aggregate: rescanning a service that was never started
    /// must not start anything.
    func test_service_rescan_before_start_is_safe() async {
        let service = DiscoveryService()
        await service.rescan()
        let devices = await service.snapshot()
        XCTAssertTrue(devices.isEmpty)
    }
}
