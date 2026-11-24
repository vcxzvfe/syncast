import XCTest
@testable import SyncCastMenuBar

final class PlaybackAwakePolicyTests: XCTestCase {

    private let displayUID = "00000000-0000-0000-0000-000000000001"
    private let speakerUID = "BuiltInSpeakerDevice"

    /// Drive the policy one tick per second with the given levels, starting
    /// at `from`. Returns the transitions with the second they happened at.
    @discardableResult
    private func run(
        _ policy: inout PlaybackAwakePolicy,
        _ levels: [Double?],
        from start: TimeInterval = 0,
        eligible: Bool = true
    ) -> [(TimeInterval, PlaybackAwakePolicy.Transition)] {
        var out: [(TimeInterval, PlaybackAwakePolicy.Transition)] = []
        for (i, level) in levels.enumerated() {
            let t = start + TimeInterval(i)
            if let transition = policy.step(.init(now: t, eligible: eligible, levelDbfs: level)) {
                out.append((t, transition))
            }
        }
        return out
    }

    private func repeated(_ level: Double?, _ seconds: Int) -> [Double?] {
        Array(repeating: level, count: seconds)
    }

    // MARK: - Arming

    func testSustainedMusicArmsOnTheThirdLoudSecond() {
        var policy = PlaybackAwakePolicy()
        let transitions = run(&policy, repeated(-20, 5))
        XCTAssertEqual(transitions.map(\.1), [.hold])
        XCTAssertEqual(transitions.first?.0, 2)
        XCTAssertTrue(policy.holding)
    }

    func testANotificationDingDoesNotArm() {
        var policy = PlaybackAwakePolicy()
        let ding: [Double?] = [-12, -18, nil, nil, nil, nil, -15, nil, nil, nil, nil]
        XCTAssertTrue(run(&policy, ding).isEmpty)
        XCTAssertFalse(policy.holding)
    }

    func testPausedPlayerRenderingZerosNeverArms() {
        var policy = PlaybackAwakePolicy()
        XCTAssertTrue(run(&policy, repeated(-.infinity, 600)).isEmpty)
    }

    func testBackgroundNoiseBelowTheArmLevelNeverArms() {
        var policy = PlaybackAwakePolicy()
        // Dither / idle hiss, well under -50 dBFS.
        XCTAssertTrue(run(&policy, repeated(-90, 300)).isEmpty)
        XCTAssertTrue(run(&policy, repeated(-55, 300), from: 300).isEmpty,
                      "between the two thresholds is not enough to ARM")
    }

    func testAQuietIntroArmsOnceItReachesTheArmLevel() {
        var policy = PlaybackAwakePolicy()
        let fadeIn: [Double?] = [-80, -70, -62, -56, -52, -49, -45, -40, -35]
        let transitions = run(&policy, fadeIn)
        XCTAssertEqual(transitions.map(\.1), [.hold])
        XCTAssertEqual(transitions.first?.0, 7, "third second at or above -50 dBFS")
    }

    func testLoudTicksSeparatedBySleepDoNotAddUp() {
        var policy = PlaybackAwakePolicy()
        run(&policy, [-20, -20])                    // two loud seconds, then the Mac sleeps
        let afterWake = policy.step(.init(now: 3600, eligible: true, levelDbfs: -15))
        XCTAssertNil(afterWake, "one ding an hour later is not three of the last five seconds")
        XCTAssertFalse(policy.holding)
    }

    // MARK: - Holding and releasing

    func testQuietPassageAndFadeKeepTheHold() {
        var policy = PlaybackAwakePolicy()
        run(&policy, repeated(-20, 10))
        // A long pianissimo between the two thresholds: still music.
        let transitions = run(&policy, repeated(-58, 600), from: 10)
        XCTAssertTrue(transitions.isEmpty)
        XCTAssertTrue(policy.holding)
    }

    func testReleasesExactlyAfterTheQuietDelay() {
        var policy = PlaybackAwakePolicy()
        run(&policy, repeated(-20, 10))            // loud through t=9
        let transitions = run(&policy, repeated(nil, 200), from: 10)
        XCTAssertEqual(transitions.map(\.1), [.release(.quiet)])
        XCTAssertEqual(transitions.first?.0, 9 + 120, "120 s after the last loud second")
        XCTAssertFalse(policy.holding)
    }

    func testGapsBetweenTracksDoNotRelease() {
        var policy = PlaybackAwakePolicy()
        var levels: [Double?] = []
        for _ in 0..<10 {
            levels += repeated(-18, 180)           // a track
            levels += repeated(-.infinity, 4)      // the gap before the next
        }
        let transitions = run(&policy, levels)
        XCTAssertEqual(transitions.map(\.1), [.hold], "one hold for the whole album")
    }

    func testPauseLongerThanTheDelayReleasesThenResumeRearms() {
        var policy = PlaybackAwakePolicy()
        run(&policy, repeated(-20, 30))
        let paused = run(&policy, repeated(-.infinity, 150), from: 30)
        XCTAssertEqual(paused.map(\.1), [.release(.quiet)])
        let resumed = run(&policy, repeated(-20, 5), from: 180)
        XCTAssertEqual(resumed.map(\.1), [.hold])
    }

    func testCustomReleaseDelay() {
        var policy = PlaybackAwakePolicy(config: .init(releaseAfterSeconds: 300))
        run(&policy, repeated(-20, 5))
        let transitions = run(&policy, repeated(nil, 400), from: 5)
        XCTAssertEqual(transitions.first?.0, 4 + 300)
    }

    func testSleepLongerThanTheDelayReleasesOnTheFirstQuietTickAfterWake() {
        var policy = PlaybackAwakePolicy()
        run(&policy, repeated(-20, 5))
        // The next tick arrives an hour later (the Mac slept), and it is quiet.
        let transition = policy.step(.init(now: 3600, eligible: true, levelDbfs: nil))
        XCTAssertEqual(transition, .release(.quiet))
    }

    func testLosingTheDisplayReleasesAtOnce() {
        var policy = PlaybackAwakePolicy()
        run(&policy, repeated(-20, 5))
        let transition = policy.step(.init(now: 5, eligible: false, levelDbfs: -20))
        XCTAssertEqual(transition, .release(.ineligible))
        XCTAssertNil(policy.step(.init(now: 6, eligible: false, levelDbfs: -20)),
                     "nothing to release twice")
    }

    func testIneligibleTicksDoNotCountTowardArming() {
        var policy = PlaybackAwakePolicy()
        run(&policy, repeated(-20, 2))
        _ = policy.step(.init(now: 2, eligible: false, levelDbfs: -20))
        XCTAssertNil(policy.step(.init(now: 3, eligible: true, levelDbfs: -20)),
                     "the two loud seconds before the display vanished are forgotten")
    }

    // MARK: - Level gating

    func testEachSourceIsGatedByItsOwnPath() {
        // Music on the laptop only: the router captured it, but the display's
        // row is muted. A muted path is silence however loud the capture.
        XCTAssertNil(PlaybackLevel.effectiveDbfs([.init(peak: 0.5, audible: false)]))
        // An app playing to the display by name while the router's capture
        // is silenced: the tap's source still counts.
        let db = PlaybackLevel.effectiveDbfs([
            .init(peak: 0.5, audible: false),
            .init(peak: 0.1, audible: true),
        ])
        XCTAssertEqual(db ?? 0, -20, accuracy: 1e-5)
    }

    func testLoudestAudibleSourceWins() {
        let db = PlaybackLevel.effectiveDbfs([.init(peak: 0.001, audible: true), .init(peak: 0.1, audible: true)])
        XCTAssertEqual(db ?? 0, -20, accuracy: 1e-5)
        XCTAssertNil(PlaybackLevel.effectiveDbfs([]))
        XCTAssertEqual(PlaybackLevel.effectiveDbfs([.init(peak: 0, audible: true)]), -.infinity)
    }

    func testDeviceControlsGateOnlyWhenTheyExist() {
        XCTAssertTrue(PlaybackLevel.deviceLetsAudioOut(muted: nil, scalar: nil),
                      "a display whose level lives in DDC has no CoreAudio controls")
        XCTAssertFalse(PlaybackLevel.deviceLetsAudioOut(muted: true, scalar: 0.8))
        XCTAssertFalse(PlaybackLevel.deviceLetsAudioOut(muted: false, scalar: 0))
        XCTAssertTrue(PlaybackLevel.deviceLetsAudioOut(muted: false, scalar: 0.3))
    }

    // MARK: - Who feeds the display

    func testFeedSeparatesSyncCastFromOtherProcesses() {
        let processes: [DisplayFeed.ProcessOutput] = [
            .init(objectID: 10, pid: 100, runningOutput: true, outputDeviceUIDs: [speakerUID, displayUID]),
            .init(objectID: 20, pid: 200, runningOutput: true, outputDeviceUIDs: ["SyncCastAudio_UID"]),
        ]
        XCTAssertEqual(
            DisplayFeed.classify(processes, ownPID: 100, displayUID: displayUID),
            DisplayFeed(bySyncCast: true, otherProcesses: []),
            "an app playing into the sink is metered through the router, not by a second tap"
        )
        XCTAssertEqual(
            DisplayFeed.classify(processes, ownPID: 300, displayUID: displayUID),
            DisplayFeed(bySyncCast: false, otherProcesses: [10])
        )
    }

    func testFeedIgnoresProcessesThatAreNotRunningOrUseOtherDevices() {
        let processes: [DisplayFeed.ProcessOutput] = [
            .init(objectID: 20, pid: 200, runningOutput: false, outputDeviceUIDs: [displayUID]),
            .init(objectID: 21, pid: 201, runningOutput: true, outputDeviceUIDs: [speakerUID]),
        ]
        XCTAssertEqual(DisplayFeed.classify(processes, ownPID: 100, displayUID: displayUID), .none)
    }

    func testFeedIsNotFooledByAUIDPrefix() {
        let processes: [DisplayFeed.ProcessOutput] = [
            .init(objectID: 20, pid: 200, runningOutput: true, outputDeviceUIDs: [displayUID + "-other"]),
        ]
        XCTAssertEqual(DisplayFeed.classify(processes, ownPID: 100, displayUID: displayUID), .none)
    }

    func testOtherRenderersAreListedOnceAndSorted() {
        let processes: [DisplayFeed.ProcessOutput] = [
            .init(objectID: 31, pid: 301, runningOutput: true, outputDeviceUIDs: [displayUID]),
            .init(objectID: 12, pid: 302, runningOutput: true, outputDeviceUIDs: [speakerUID, displayUID]),
        ]
        XCTAssertEqual(DisplayFeed.classify(processes, ownPID: 100, displayUID: displayUID).otherProcesses, [12, 31])
    }
}

/// The keep-awake setting rides on the stored auto-connect rule.
final class PlaybackAwakeProfileTests: XCTestCase {

    private let monitorUID = "00000000-0000-0000-0000-000000000001"

    func testRulesStoredBeforeTheFeatureDecodeWithItOff() throws {
        let legacy = """
        [{"id": "11111111-2222-3333-4444-555555555555", "enabled": true,
          "triggerUID": "\(monitorUID)",
          "memberUIDs": ["BuiltInSpeakerDevice", "\(monitorUID)"],
          "onDisconnect": {"restoreBuiltIn": false}, "displayNames": {},
          "arriveSystemVolumePercent": 90}]
        """
        let decoded = AutoConnectProfileStore.decode(Data(legacy.utf8))
        let profile = try XCTUnwrap(decoded.first)
        XCTAssertNil(profile.keepDisplayAwakeWhilePlaying)
        XCTAssertFalse(profile.keepsDisplayAwakeWhilePlaying)
        XCTAssertEqual(profile.resolvedPlaybackAwakeReleaseSeconds, 120)
        XCTAssertEqual(profile.arriveSystemVolumePercent, 90, "existing fields untouched")
    }

    func testSettingsRoundTripAndAreClamped() throws {
        let profile = AutoConnectProfile(
            triggerUID: monitorUID,
            memberUIDs: [monitorUID],
            keepDisplayAwakeWhilePlaying: true,
            playbackAwakeReleaseSeconds: 300
        )
        let data = try XCTUnwrap(AutoConnectProfileStore.encode([profile]))
        let decoded = try XCTUnwrap(AutoConnectProfileStore.decode(data).first)
        XCTAssertTrue(decoded.keepsDisplayAwakeWhilePlaying)
        XCTAssertEqual(decoded.resolvedPlaybackAwakeReleaseSeconds, 300)

        var tampered = profile
        tampered.playbackAwakeReleaseSeconds = 5
        let sanitized = try XCTUnwrap(AutoConnectProfileStore.sanitize([tampered]).first)
        XCTAssertEqual(sanitized.playbackAwakeReleaseSeconds, 60,
                       "a few seconds would let the display drop between tracks")
        tampered.playbackAwakeReleaseSeconds = 1_000_000
        XCTAssertEqual(AutoConnectProfileStore.sanitize([tampered]).first?.playbackAwakeReleaseSeconds, 1800)
    }
}
