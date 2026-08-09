import Testing
import Foundation
@testable import SyncCastRouter

/// Layer 3, seeding half: what the AirPlay outputs are actually CARRYING.
///
/// `pushMeasuredAirPlayOffset` will not re-push a value that is already in
/// force, because re-applying the offset costs a disable/enable cycle — an
/// audible dropout on every receiver. The whole correctness of that shortcut
/// rests on seeding the comparison from per-output truth rather than from the
/// sidecar's intent, so this pins the seeding rule down on its own.
struct AirPlayOffsetSeedTests {

    private let measuredMs = 130

    @Test("No sidecar state at all means nothing is known — push")
    func nilStateForcesAPush() {
        #expect(Router.latchedOffsetMs(from: nil) == nil)
    }

    @Test("An empty latched map forces the first push of the session")
    func emptyLatchedMapForcesAPush() {
        let state: [String: Any] = [
            "effective_offset_ms": measuredMs,
            "latched": [String: Any](),
            "write_failures": [String](),
        ]
        #expect(Router.latchedOffsetMs(from: state) == nil)
    }

    /// The regression this exists for. A receiver already selected in OwnTone
    /// when whole-home began kept whatever its live session latched, and the
    /// sidecar still reported its INTENDED value — so seeding from
    /// `effective_offset_ms` suppressed the only push that would have
    /// re-latched it, and that receiver ran ~L_local ahead of the local leg
    /// for the entire session with nothing in the log.
    @Test("Intent is ignored when nothing is latched")
    func intentNeverSeedsTheDeadband() {
        let state: [String: Any] = [
            "effective_offset_ms": measuredMs,
            "offset_ms": measuredMs,
            "latched": [String: Any](),
            "write_failures": [String](),
        ]
        #expect(Router.latchedOffsetMs(from: state) == nil)
    }

    @Test("A latched value is the seed")
    func latchedValueSeedsTheDeadband() {
        let state: [String: Any] = [
            "latched": ["2933476098287": 130],
            "write_failures": [String](),
        ]
        #expect(Router.latchedOffsetMs(from: state) == 130)
    }

    /// The deadband may only suppress a push when EVERY output is close
    /// enough, so the furthest-away one has to be the one that decides.
    @Test("Several outputs at different values reduce to the minimum")
    func mixedLatchedValuesReduceToTheMinimum() {
        let state: [String: Any] = [
            "latched": ["a": 130, "b": 92, "c": 145],
            "write_failures": [String](),
        ]
        #expect(Router.latchedOffsetMs(from: state) == 92)
    }

    /// An output whose offset write failed carries whatever a previous
    /// session persisted. That is not knowledge, so it must not seed.
    @Test("A failed write invalidates the whole seed")
    func aFailedWriteForcesAPush() {
        let state: [String: Any] = [
            "latched": ["a": 130],
            "write_failures": ["b"],
        ]
        #expect(Router.latchedOffsetMs(from: state) == nil)
    }

    /// JSON numbers arrive as `NSNumber` through `JSONSerialization`, so the
    /// element cast has to survive bridging rather than silently yielding an
    /// empty map (which would look like "nothing latched" and push forever).
    @Test("NSNumber-bridged values are read, not dropped")
    func bridgedNumbersAreRead() {
        let state: [String: Any] = [
            "latched": ["a": NSNumber(value: 118), "b": NSNumber(value: 130)],
            "write_failures": [String](),
        ]
        #expect(Router.latchedOffsetMs(from: state) == 118)
    }
}
