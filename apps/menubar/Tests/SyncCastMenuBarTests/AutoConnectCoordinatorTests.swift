import XCTest
@testable import SyncCastMenuBar

/// Everything the auto-connect rule has to get right happens while a monitor
/// is being plugged in, woken, or yanked — none of which a test can do. These
/// drive the same state machine with a hand-cranked clock and a synthetic
/// present-set, which is the only place the flapping and override branches are
/// reachable at all.
final class AutoConnectCoordinatorTests: XCTestCase {

    private let monitor = "00000000-0000-0000-0000-000000000001"
    private let builtIn = AutoConnect.builtInSpeakerUID
    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)

    private func profile(
        id: UUID = UUID(),
        enabled: Bool = true,
        trigger: String? = nil,
        members: [String]? = nil,
        restoreBuiltIn: Bool = true,
        volumePercent: Int? = 0
    ) -> AutoConnectProfile {
        AutoConnectProfile(
            id: id,
            enabled: enabled,
            triggerUID: trigger ?? monitor,
            memberUIDs: members ?? [builtIn, monitor],
            onDisconnect: .init(
                restoreBuiltIn: restoreBuiltIn,
                builtInVolumePercent: volumePercent
            )
        )
    }

    private func input(
        _ profiles: [AutoConnectProfile],
        present: Set<String>,
        enabled: Set<String> = [],
        streaming: Bool = false,
        stereo: Bool = true,
        at offset: TimeInterval
    ) -> AutoConnectCoordinator.Input {
        AutoConnectCoordinator.Input(
            profiles: profiles,
            presentUIDs: present,
            enabledUIDs: enabled,
            isStreaming: streaming,
            isStereoMode: stereo,
            now: t0.addingTimeInterval(offset)
        )
    }

    // MARK: - Debounce

    func testPresenceMustHoldStillBeforeTheRuleFires() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        let first = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        XCTAssertEqual(first.action, .none)
        XCTAssertEqual(first.recheckAfter ?? 0, 1.5, accuracy: 0.001)

        let stillEarly = c.evaluate(input([rule], present: [builtIn, monitor], at: 1.0))
        XCTAssertEqual(stillEarly.action, .none)
        XCTAssertEqual(stillEarly.recheckAfter ?? 0, 0.5, accuracy: 0.001)

        let settled = c.evaluate(input([rule], present: [builtIn, monitor], at: 1.6))
        XCTAssertEqual(settled.action, .activate(profileID: rule.id, memberUIDs: [builtIn, monitor]))
    }

    /// A DisplayPort device that appears, vanishes and reappears inside the
    /// window must produce exactly one activation, not three.
    func testFlappingDeviceListDoesNotStartAndStopRepeatedly() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        var actions: [AutoConnectCoordinator.Action] = []
        actions.append(c.evaluate(input([rule], present: [builtIn, monitor], at: 0.0)).action)
        actions.append(c.evaluate(input([rule], present: [builtIn], at: 0.3)).action)
        actions.append(c.evaluate(input([rule], present: [builtIn, monitor], at: 0.7)).action)
        actions.append(c.evaluate(input([rule], present: [builtIn], at: 1.1)).action)
        actions.append(c.evaluate(input([rule], present: [builtIn, monitor], at: 1.4)).action)
        XCTAssertEqual(actions, [.none, .none, .none, .none, .none])

        let settled = c.evaluate(input([rule], present: [builtIn, monitor], at: 3.0))
        XCTAssertEqual(settled.action, .activate(profileID: rule.id, memberUIDs: [builtIn, monitor]))
    }

    // MARK: - Activation

    func testFiresOnlyOncePerTriggerPresenceEpisode() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        let first = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))
        XCTAssertEqual(first.action, .activate(profileID: rule.id, memberUIDs: [builtIn, monitor]))
        // Same world one tick later, now actually streaming the right set.
        let second = c.evaluate(
            input([rule], present: [builtIn, monitor], enabled: [builtIn, monitor],
                  streaming: true, at: 3)
        )
        XCTAssertEqual(second.action, .none)
    }

    func testDoesNotFireWhenAMemberIsMissing() {
        let rule = profile(members: [builtIn, monitor, "SomeDockUID"])
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        XCTAssertEqual(c.evaluate(input([rule], present: [builtIn, monitor], at: 2)).action, .none)
    }

    func testDisabledRuleNeverFires() {
        let rule = profile(enabled: false)
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        XCTAssertEqual(c.evaluate(input([rule], present: [builtIn, monitor], at: 2)).action, .none)
    }

    /// Launch straight into the wanted state (monitor already plugged in from
    /// a previous session): claim the episode, touch nothing.
    func testAlreadyCorrectStateClaimsTheEpisodeSilently() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(
            input([rule], present: [builtIn, monitor], enabled: [builtIn, monitor],
                  streaming: true, at: 0)
        )
        let settled = c.evaluate(
            input([rule], present: [builtIn, monitor], enabled: [builtIn, monitor],
                  streaming: true, at: 2)
        )
        XCTAssertEqual(settled.action, .none)
        // And the episode is spent, so a later user change is not undone.
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor], enabled: [builtIn],
                             streaming: true, at: 3)).action,
            .none
        )
    }

    /// The monitor is already there at launch but the engine is not running:
    /// this is the "start SyncCast at login and it should just come up
    /// playing" case, and it must produce an activation.
    func testLaunchWithTriggerAlreadyPresentActivatesOnceSettled() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        XCTAssertEqual(c.evaluate(input([rule], present: [builtIn, monitor], at: 0)).action, .none)
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor], at: 1.5)).action,
            .activate(profileID: rule.id, memberUIDs: [builtIn, monitor])
        )
    }

    /// Whole-home with the same devices enabled is NOT the state the rule
    /// wants — the rule means "local Stereo on these outputs".
    func testWholeHomeWithSameMembersStillActivates() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(
            input([rule], present: [builtIn, monitor], enabled: [builtIn, monitor],
                  streaming: true, stereo: false, at: 0)
        )
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor], enabled: [builtIn, monitor],
                             streaming: true, stereo: false, at: 2)).action,
            .activate(profileID: rule.id, memberUIDs: [builtIn, monitor])
        )
    }

    // MARK: - User override

    /// The rule has NOT fired yet this episode (one member is still missing),
    /// so the once-per-episode guard cannot be what holds it back — this is
    /// the suppression flag on its own. Then the missing member turns up and
    /// the rule still has to stay out of the way.
    func testUserOverrideSuppressesUntilTheTriggerLeavesAndComesBack() {
        let dock = "DockUID"
        let rule = profile(members: [builtIn, monitor, dock])
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))  // episode open, not fired
        c.noteUserOverride()

        _ = c.evaluate(input([rule], present: [builtIn, monitor, dock], at: 3))
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor, dock], at: 5)).action,
            .none
        )

        // Unplug the trigger (settles), then plug it back in: new episode.
        _ = c.evaluate(input([rule], present: [builtIn, dock], at: 6))
        _ = c.evaluate(input([rule], present: [builtIn, dock], at: 8))
        _ = c.evaluate(input([rule], present: [builtIn, monitor, dock], at: 9))
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor, dock], at: 11)).action,
            .activate(profileID: rule.id, memberUIDs: [builtIn, monitor, dock])
        )
    }

    func testOverrideDoesNotTouchRulesWhoseTriggerIsAbsent() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn], at: 2))
        c.noteUserOverride()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 3))
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor], at: 5)).action,
            .activate(profileID: rule.id, memberUIDs: [builtIn, monitor])
        )
    }

    func testResetSuppressionReappliesWithoutUnplugging() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))
        c.noteUserOverride()
        XCTAssertEqual(c.evaluate(input([rule], present: [builtIn, monitor], at: 3)).action, .none)
        c.resetSuppression()
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor], at: 4)).action,
            .activate(profileID: rule.id, memberUIDs: [builtIn, monitor])
        )
    }

    // MARK: - Disconnect

    func testTriggerLeavingAfterActivationEmitsTheDisconnectAction() {
        let rule = profile(restoreBuiltIn: true, volumePercent: 0)
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))  // activate
        _ = c.evaluate(input([rule], present: [builtIn], at: 3))
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn], at: 5)).action,
            .deactivate(profileID: rule.id, restoreBuiltIn: true, builtInVolumePercent: 0)
        )
    }

    /// Switching the rule off after it fired must not be answered later by the
    /// loudest thing it can do (stop + force the built-in level).
    func testRuleDisabledAfterFiringDoesNotDeactivateOnUnplug() {
        let id = UUID()
        let on = profile(id: id)
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([on], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([on], present: [builtIn, monitor], at: 2))  // activate

        let off = profile(id: id, enabled: false)
        _ = c.evaluate(input([off], present: [builtIn], at: 3))
        XCTAssertEqual(c.evaluate(input([off], present: [builtIn], at: 5)).action, .none)
    }

    func testTriggerLeavingWithoutHavingActivatedIsSilent() {
        let rule = profile(enabled: false)
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))
        _ = c.evaluate(input([rule], present: [builtIn], at: 3))
        XCTAssertEqual(c.evaluate(input([rule], present: [builtIn], at: 5)).action, .none)
    }

    /// A monitor that blinks out for half a second while it changes resolution
    /// must not tear the engine down.
    func testBriefTriggerDropoutInsideTheWindowDoesNotDeactivate() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))  // activate
        XCTAssertEqual(c.evaluate(input([rule], present: [builtIn], at: 2.2)).action, .none)
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor], at: 2.9)).action, .none
        )
        // Present-set is back to the believed one; nothing to do, no teardown.
        XCTAssertEqual(
            c.evaluate(input([rule], present: [builtIn, monitor], at: 6)).action, .none
        )
    }

    func testDeactivationIsEmittedOnceAndTheEpisodeRestarts() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))
        _ = c.evaluate(input([rule], present: [builtIn], at: 3))
        _ = c.evaluate(input([rule], present: [builtIn], at: 5))  // deactivate
        XCTAssertEqual(c.evaluate(input([rule], present: [builtIn], at: 6)).action, .none)
    }

    // MARK: - Multiple rules

    func testFirstMatchingRuleWins() {
        let dock = "DockUID"
        let first = profile(trigger: dock, members: [dock])
        let second = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([first, second], present: [builtIn, monitor, dock], at: 0))
        XCTAssertEqual(
            c.evaluate(input([first, second], present: [builtIn, monitor, dock], at: 2)).action,
            .activate(profileID: first.id, memberUIDs: [dock])
        )
        // The loser must not fire on the next tick and flip the outputs again.
        XCTAssertEqual(
            c.evaluate(input([first, second], present: [builtIn, monitor, dock],
                             enabled: [dock], streaming: true, at: 3)).action,
            .none
        )
    }

    func testDeletingARuleForgetsItsEpisode() {
        let rule = profile()
        var c = AutoConnectCoordinator()
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 0))
        _ = c.evaluate(input([rule], present: [builtIn, monitor], at: 2))
        c.forgetProfile(rule.id)
        // Recreated with the same trigger: a fresh episode, so it fires again.
        let recreated = profile()
        XCTAssertEqual(
            c.evaluate(input([recreated], present: [builtIn, monitor], at: 3)).action,
            .activate(profileID: recreated.id, memberUIDs: [builtIn, monitor])
        )
    }
}
