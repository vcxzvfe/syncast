import XCTest
@testable import SyncCastRouter

/// Specification for `DelayTrimNormalizer`. Every case here encodes a
/// property the two legs depend on: the local bridge can only ADD delay
/// (it cannot pull a byte out of OwnTone's fifo early) and every AirPlay
/// commit costs a ~0.4 s relatch dropout, so "no change ⇒ no traffic" is a
/// correctness requirement, not an optimisation.
final class DelayTrimNormalizerTests: XCTestCase {

    // MARK: - Degenerate sets

    func testEmptyEnabledSetProducesEmptyResult() {
        XCTAssertEqual(
            DelayTrimNormalizer.normalize(raw: ["a": 40], enabled: []),
            [:]
        )
    }

    func testSingleEnabledDeviceAlwaysNormalizesToZero() {
        // A lone speaker has nothing to be relative to. Honouring its raw
        // value would silently add latency for no audible benefit.
        for value in [-200, -7, 0, 3, 200] {
            XCTAssertEqual(
                DelayTrimNormalizer.normalize(raw: ["a": value], enabled: ["a"]),
                ["a": 0],
                "single device with raw \(value)"
            )
        }
    }

    func testAllZeroStaysAllZero() {
        let out = DelayTrimNormalizer.normalize(
            raw: ["a": 0, "b": 0, "c": 0], enabled: ["a", "b", "c"]
        )
        XCTAssertEqual(out, ["a": 0, "b": 0, "c": 0])
        // The all-zero case must produce no non-zero value at all, so the
        // caller's "only push non-zero changes" filter emits nothing and no
        // AirPlay receiver is relatched by a no-op replan.
        XCTAssertTrue(out.values.allSatisfy { $0 == 0 })
    }

    func testMissingEntriesCountAsZero() {
        // "b" was never touched by the user, but it is still a participant:
        // it must define the minimum here, not be skipped.
        XCTAssertEqual(
            DelayTrimNormalizer.normalize(raw: ["a": 12], enabled: ["a", "b"]),
            ["a": 12, "b": 0]
        )
    }

    // MARK: - Multi-device shifting

    func testAllNegativeShiftsUpToZero() {
        XCTAssertEqual(
            DelayTrimNormalizer.normalize(
                raw: ["a": -20, "b": -5], enabled: ["a", "b"]
            ),
            ["a": 0, "b": 15]
        )
    }

    func testMixedSignsPreservePairwiseDifferences() {
        let raw = ["a": -5, "b": 0, "c": 3]
        let out = DelayTrimNormalizer.normalize(raw: raw, enabled: ["a", "b", "c"])
        XCTAssertEqual(out, ["a": 0, "b": 5, "c": 8])
        for (lhs, rhs) in [("a", "b"), ("b", "c"), ("a", "c")] {
            XCTAssertEqual(
                out[lhs]! - out[rhs]!,
                raw[lhs]! - raw[rhs]!,
                "pairwise \(lhs)-\(rhs) must survive normalization"
            )
        }
    }

    func testResultIsNonNegativeAndAnchoredAtZero() {
        let out = DelayTrimNormalizer.normalize(
            raw: ["a": -134, "b": 77, "c": -9], enabled: ["a", "b", "c"]
        )
        XCTAssertTrue(out.values.allSatisfy { $0 >= 0 })
        XCTAssertEqual(out.values.min(), 0)
    }

    // MARK: - Enabled-set discipline

    func testDisabledDeviceWithExtremeValueShiftsNobody() {
        // Regression guard: computing the minimum over ALL devices instead of
        // the enabled ones would drag every playing speaker 200 ms later
        // because of a speaker that is switched off.
        XCTAssertEqual(
            DelayTrimNormalizer.normalize(
                raw: ["a": 0, "b": 4, "off": -200], enabled: ["a", "b"]
            ),
            ["a": 0, "b": 4]
        )
    }

    func testDisabledDeviceIsAbsentFromResult() {
        let out = DelayTrimNormalizer.normalize(
            raw: ["a": 0, "off": 30], enabled: ["a"]
        )
        XCTAssertNil(out["off"])
    }

    func testEnablingADeviceBelowTheMinimumShiftsEveryoneElse() {
        // Device add: "c" joins holding -10, which becomes the new anchor.
        let raw = ["a": 0, "b": 6, "c": -10]
        let before = DelayTrimNormalizer.normalize(raw: raw, enabled: ["a", "b"])
        let after = DelayTrimNormalizer.normalize(raw: raw, enabled: ["a", "b", "c"])
        XCTAssertEqual(before, ["a": 0, "b": 6])
        XCTAssertEqual(after, ["a": 10, "b": 16, "c": 0])
    }

    func testRemovingTheAnchorDeviceShiftsEveryoneDown() {
        // Device remove: "c" defined the minimum; without it the set slides
        // back down. Relative alignment is preserved, absolute latency drops.
        let raw = ["a": 0, "b": 6, "c": -10]
        let after = DelayTrimNormalizer.normalize(raw: raw, enabled: ["a", "b"])
        XCTAssertEqual(after, ["a": 0, "b": 6])
    }

    // MARK: - Algebraic properties

    func testIdempotence() {
        let raw = ["a": -5, "b": 0, "c": 3]
        let enabled: Set<String> = ["a", "b", "c"]
        let once = DelayTrimNormalizer.normalize(raw: raw, enabled: enabled)
        let twice = DelayTrimNormalizer.normalize(raw: once, enabled: enabled)
        XCTAssertEqual(once, twice)
    }

    func testTranslationInvariance() {
        let enabled: Set<String> = ["a", "b", "c"]
        let base = ["a": -5, "b": 0, "c": 3]
        let expected = DelayTrimNormalizer.normalize(raw: base, enabled: enabled)
        for offset in [-40, -1, 1, 60] {
            let shifted = base.mapValues { $0 + offset }
            XCTAssertEqual(
                DelayTrimNormalizer.normalize(raw: shifted, enabled: enabled),
                expected,
                "adding \(offset) ms to every device must change nothing"
            )
        }
    }

    func testOrderIndependence() {
        // Dictionaries have no defined iteration order; run the same input
        // repeatedly through freshly-built dictionaries to catch any
        // accidental dependence on it.
        let pairs = [("a", -5), ("b", 0), ("c", 3), ("d", 11)]
        let enabled = Set(pairs.map(\.0))
        let expected = DelayTrimNormalizer.normalize(
            raw: Dictionary(uniqueKeysWithValues: pairs), enabled: enabled
        )
        for _ in 0..<32 {
            let shuffled = Dictionary(uniqueKeysWithValues: pairs.shuffled())
            XCTAssertEqual(
                DelayTrimNormalizer.normalize(raw: shuffled, enabled: enabled),
                expected
            )
        }
    }

    // MARK: - Range discipline

    func testRawValuesAreClampedToTheUserRange() {
        let out = DelayTrimNormalizer.normalize(
            raw: ["a": -9_999, "b": 9_999], enabled: ["a", "b"]
        )
        XCTAssertEqual(
            out,
            ["a": 0, "b": DeviceDelayTrim.rangeMs.upperBound
                - DeviceDelayTrim.rangeMs.lowerBound]
        )
    }

    func testRangeExtremesProduceTheFullSpan() {
        // -200 and +200 together are the widest legal request: 400 ms of
        // added delay on the later speaker. The local leg clamps this again
        // against its real ring headroom; this test only pins the arithmetic.
        let out = DelayTrimNormalizer.normalize(
            raw: [
                "near": DeviceDelayTrim.rangeMs.lowerBound,
                "far": DeviceDelayTrim.rangeMs.upperBound,
            ],
            enabled: ["near", "far"]
        )
        XCTAssertEqual(out["near"], 0)
        XCTAssertEqual(out["far"], 400)
    }

    func testDistanceHintMatchesSpeedOfSound() {
        // 1 ms ≈ 34.3 cm — the number the UI shows the user.
        XCTAssertEqual(DeviceDelayTrim.distanceMeters(forMs: 1), 0.343, accuracy: 1e-9)
        XCTAssertEqual(DeviceDelayTrim.distanceMeters(forMs: -3), 1.029, accuracy: 1e-9)
        XCTAssertEqual(DeviceDelayTrim.distanceMeters(forMs: 0), 0.0, accuracy: 1e-9)
    }
}
