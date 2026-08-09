import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// Direction B: this Mac's own AirPlay Receiver is NEVER a target.
///
/// The local speakers participate in whole-home as a plain OwnTone fifo output
/// on OwnTone's player clock — there is no self-target and no full-screen-PIN
/// self-pairing. Making the Receiver an AirPlay target would render into the
/// system default output the whole-home capture tap covers (a feedback loop),
/// and would resurrect the self-pair deadlock direction B exists to remove.
/// These tests pin that invariant so it cannot regress back into self-target.
@MainActor
final class LocalReceiverSelectabilityTests: XCTestCase {

    func testLocalReceiverIsNeverSelectableInWholeHome() {
        let model = AppModel()
        XCTAssertFalse(
            model.isSelectableInMode(Self.localReceiver, mode: .wholeHome),
            "the local machine must never be an AirPlay target (self-target deadlock)"
        )
    }

    func testLocalReceiverIsNeverSelectableInStereo() {
        let model = AppModel()
        XCTAssertFalse(model.isSelectableInMode(Self.localReceiver, mode: .stereo))
    }

    /// Ordinary AirPlay receivers (Mac mini, Xiaomi) remain valid whole-home
    /// targets — this is a rule about the local machine, not about AirPlay.
    func testRemoteReceiversAreSelectableInWholeHome() {
        let model = AppModel()
        XCTAssertTrue(model.isSelectableInMode(Self.remoteReceiver, mode: .wholeHome))
    }

    /// Greying a row out is a UI convention, not an enforcement point. The
    /// refusal has to survive a direct call.
    func testEnablingTheLocalReceiverIsRefused() {
        let model = AppModel()
        model.devices = [Self.localReceiver]

        model.setDeviceEnabled(true, for: Self.localReceiver.id)

        XCTAssertNotEqual(
            model.routing[Self.localReceiver.id]?.enabled, true,
            "the local receiver must never end up enabled — it is not a target"
        )
    }

    /// The pairing key the app writes must be the key the Router (and the
    /// sidecar) look up, or the lookup misses — and a miss reads as "pairing
    /// not required", silently skipping a receiver that does need it.
    func testPairingKeyMatchesTheRoutersDefinition() {
        let model = AppModel()
        XCTAssertEqual(
            model.pairingKey(for: Self.remoteReceiver),
            Router.pairingKey(for: Self.remoteReceiver)
        )
        XCTAssertEqual(
            model.pairingKey(for: Self.namelessReceiver),
            Router.pairingKey(for: Self.namelessReceiver)
        )
        // Pin the concrete fallback form for a deviceid-less AirPlay receiver
        // to the sidecar's `Device.pairing_key` (`name:<name>`). A Swift-only
        // equality check above cannot catch a Swift-vs-Python divergence; this
        // literal does.
        XCTAssertEqual(
            Router.pairingKey(for: Self.namelessReceiver),
            "name:Some Speaker"
        )
    }

    /// Direction B: the local-output selection is persisted by UID and must be
    /// re-applied when the user enters whole-home — including on a fresh launch,
    /// where the app starts in stereo and the in-memory per-mode map is empty.
    /// Regression guard: the persisted UIDs were loaded at bootstrap but the
    /// only code that re-enabled them was gated on already being in whole-home,
    /// so a relaunch dropped the choice and the user had to re-pick their
    /// speakers every session.
    func testRememberedLocalOutputIsReappliedOnWholeHomeEntry() {
        let model = AppModel()
        let speaker = Device(
            id: "builtin",
            transport: .coreAudio,
            name: "MacBook Pro Speakers",
            coreAudioUID: "BuiltInSpeakerUID"
        )
        model.devices = [speaker]
        model.routing[speaker.id] = DeviceRouting(deviceID: speaker.id, enabled: false)
        // Stands in for a previous session's persisted choice, loaded at boot.
        model.wholeHomeLocalMemberUIDs = ["BuiltInSpeakerUID"]

        // App is in stereo (the launch default) and the speaker is off.
        // Entering whole-home must honour the persisted UID.
        model.mode = .wholeHome
        model.applyRememberedWholeHomeLocalOutputs()

        XCTAssertEqual(
            model.routing[speaker.id]?.enabled, true,
            "the remembered local output must be re-enabled on whole-home entry"
        )
    }

    /// The apply step is mode-gated: it must do nothing while still in stereo,
    /// so it can never silently turn a local output on outside whole-home.
    func testRememberedLocalOutputIsNotAppliedInStereo() {
        let model = AppModel()
        let speaker = Device(
            id: "builtin",
            transport: .coreAudio,
            name: "MacBook Pro Speakers",
            coreAudioUID: "BuiltInSpeakerUID"
        )
        model.devices = [speaker]
        model.routing[speaker.id] = DeviceRouting(deviceID: speaker.id, enabled: false)
        model.wholeHomeLocalMemberUIDs = ["BuiltInSpeakerUID"]

        // mode stays .stereo (the default).
        model.applyRememberedWholeHomeLocalOutputs()

        XCTAssertNotEqual(
            model.routing[speaker.id]?.enabled, true,
            "the remembered selection must not be applied outside whole-home"
        )
    }

    /// A remembered UID that is not connected right now must not fabricate a
    /// routing entry — it simply stays absent until the device returns (moving
    /// between an office display and a home display must forget neither).
    func testRememberedButAbsentLocalOutputIsIgnored() {
        let model = AppModel()
        model.devices = []
        model.wholeHomeLocalMemberUIDs = ["SomeOfficeDisplayUID"]
        model.mode = .wholeHome

        model.applyRememberedWholeHomeLocalOutputs()

        XCTAssertNil(
            model.routing["SomeOfficeDisplayUID"],
            "an absent remembered output must not get a fabricated routing entry"
        )
    }

    private static let localReceiver = Device(
        id: "local-receiver",
        transport: .airplay2,
        name: "<this Mac's AirPlay Receiver>",
        airplayDeviceID: "0200CAFE0001",
        isLocalMachineReceiver: true
    )

    private static let remoteReceiver = Device(
        id: "remote-receiver",
        transport: .airplay2,
        name: "Mac mini",
        airplayDeviceID: "0200CAFE0002"
    )

    /// No `deviceid` in the TXT record, so both sides must agree on the
    /// id-based fallback too.
    private static let namelessReceiver = Device(
        id: "nameless",
        transport: .airplay2,
        name: "Some Speaker"
    )
}
