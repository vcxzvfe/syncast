import XCTest
import SyncCastDiscovery
import SyncCastRouter
@testable import SyncCastMenuBar

/// The channel-assignment store's contract: what survives a relaunch, what is
/// thrown away, and what a corrupt or hostile blob is allowed to do.
///
/// Everything here goes through the pure encode/decode/sanitize path rather
/// than `UserDefaults`, so the suite never touches the user's own settings.
@MainActor
final class DeviceChannelMatrixPersistenceTests: XCTestCase {

    private func profile(
        _ uid: String,
        _ settings: ChannelMatrixSettings,
        name: String? = nil
    ) -> DeviceChannelMatrixProfile {
        DeviceChannelMatrixProfile(uid: uid, displayName: name, settings: settings)
    }

    // MARK: - Round trip

    func testAPresetSurvivesARoundTrip() throws {
        let stored = [
            profile("uid-a", ChannelMatrixSettings(preset: .left), name: "Left speaker"),
            profile("uid-b", ChannelMatrixSettings(preset: .right)),
        ]
        let data = try XCTUnwrap(DeviceChannelMatrixStore.encode(stored))
        let decoded = DeviceChannelMatrixStore.decode(data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded["uid-a"]?.settings.preset, .left)
        XCTAssertEqual(decoded["uid-a"]?.displayName, "Left speaker")
        XCTAssertEqual(decoded["uid-b"]?.settings.preset, .right)
    }

    func testCustomCoefficientsSurviveARoundTrip() throws {
        let custom = ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: -1.5,
            rightToLeftDb: -12,
            leftToRightDb: ChannelMatrixLimits.silentDb,
            rightToRightDb: 4.5
        )
        let data = try XCTUnwrap(DeviceChannelMatrixStore.encode([profile("uid", custom)]))
        let decoded = DeviceChannelMatrixStore.decode(data)
        XCTAssertEqual(decoded["uid"]?.settings, custom)
    }

    func testTheBlobIsStableAcrossSaves() throws {
        let profiles = [
            profile("z", ChannelMatrixSettings(preset: .mono)),
            profile("a", ChannelMatrixSettings(preset: .left)),
        ]
        let first = try XCTUnwrap(DeviceChannelMatrixStore.encode(profiles))
        let second = try XCTUnwrap(DeviceChannelMatrixStore.encode(profiles.reversed()))
        XCTAssertEqual(first, second, "encoding must sort, or every save churns the plist")
    }

    // MARK: - Corrupt and hostile input

    func testAbsentDataDecodesToNothing() {
        XCTAssertTrue(DeviceChannelMatrixStore.decode(nil).isEmpty)
    }

    func testUnreadableDataDecodesToNothingRatherThanThrowing() {
        XCTAssertTrue(
            DeviceChannelMatrixStore.decode(Data("not json at all".utf8)).isEmpty
        )
    }

    func testNonFiniteCoefficientsAreClampedOnLoad() {
        // A hand-written or corrupt blob. NaN reaching the render thread would
        // turn that speaker into permanent silence or noise.
        let json = Data("""
        [{"uid":"uid","settings":{"preset":"custom","leftToLeftDb":1e400,\
        "rightToLeftDb":-1e400,"leftToRightDb":0,"rightToRightDb":0}}]
        """.utf8)
        let decoded = DeviceChannelMatrixStore.decode(json)
        // `1e400` is not representable, so JSONDecoder rejects the record
        // outright — which is also an acceptable answer. Either way nothing
        // non-finite may survive.
        for profile in decoded.values {
            let matrix = profile.settings.matrix
            XCTAssertTrue(matrix.leftToLeft.isFinite)
            XCTAssertTrue(matrix.rightToLeft.isFinite)
            XCTAssertTrue(matrix.leftToRight.isFinite)
            XCTAssertTrue(matrix.rightToRight.isFinite)
        }
    }

    func testOutOfRangeDecibelsAreClampedOnLoad() {
        let json = Data("""
        [{"uid":"uid","settings":{"preset":"custom","leftToLeftDb":90,\
        "rightToLeftDb":-900,"leftToRightDb":0,"rightToRightDb":0}}]
        """.utf8)
        let decoded = DeviceChannelMatrixStore.decode(json)
        let settings = try? XCTUnwrap(decoded["uid"]?.settings)
        XCTAssertEqual(settings?.leftToLeftDb, ChannelMatrixLimits.maximumDb)
        XCTAssertEqual(settings?.rightToLeftDb, ChannelMatrixLimits.silentDb)
    }

    func testValuesAreSnappedToTheSliderGrid() {
        let messy = ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: -1.4999,
            rightToLeftDb: -11.9,
            leftToRightDb: 2.26,
            rightToRightDb: 0
        )
        let clean = DeviceChannelMatrixStore.normalize(messy)
        XCTAssertEqual(clean.leftToLeftDb, -1.5, accuracy: 1e-9)
        XCTAssertEqual(clean.rightToLeftDb, -12, accuracy: 1e-9)
        XCTAssertEqual(clean.leftToRightDb, 2.5, accuracy: 1e-9)
    }

    func testAPresetIsNotRoundedIntoSomethingElse() {
        // The presets are exact constants — 0.5 for mono, 1.0 for stereo — and
        // running them through the decibel grid would be a way to lose the
        // bit-identical fast path.
        for preset in [ChannelMatrixPreset.stereo, .left, .right, .mono] {
            let clean = DeviceChannelMatrixStore.normalize(
                ChannelMatrixSettings(preset: preset)
            )
            XCTAssertEqual(clean.preset, preset)
            XCTAssertEqual(
                clean.matrix, ChannelMatrixSettings(preset: preset).matrix
            )
        }
    }

    func testAnEmptyUidIsDropped() {
        let sanitized = DeviceChannelMatrixStore.sanitize([
            profile("   ", ChannelMatrixSettings(preset: .left)),
            profile("real", ChannelMatrixSettings(preset: .left)),
        ])
        XCTAssertEqual(sanitized.map(\.uid), ["real"])
    }

    func testUidsAreTrimmedAndDeduplicated() {
        let sanitized = DeviceChannelMatrixStore.sanitize([
            profile("  uid  ", ChannelMatrixSettings(preset: .left)),
            profile("uid", ChannelMatrixSettings(preset: .right)),
        ])
        XCTAssertEqual(sanitized.count, 1)
        XCTAssertEqual(sanitized.first?.uid, "uid")
        XCTAssertEqual(sanitized.first?.settings.preset, .left, "the first record wins")
    }

    func testARecordThatSaysNothingIsDropped() {
        // 立体声 is the default; storing it forever would make every reconcile
        // push an identical no-op.
        let sanitized = DeviceChannelMatrixStore.sanitize([
            profile("uid", ChannelMatrixSettings(preset: .stereo)),
        ])
        XCTAssertTrue(sanitized.isEmpty)
    }

    func testACustomMatrixEqualToUnityIsAlsoDropped() {
        let unity = ChannelMatrixSettings(
            preset: .custom,
            leftToLeftDb: 0,
            rightToLeftDb: ChannelMatrixLimits.silentDb,
            leftToRightDb: ChannelMatrixLimits.silentDb,
            rightToRightDb: 0
        )
        XCTAssertTrue(DeviceChannelMatrixStore.sanitize([profile("uid", unity)]).isEmpty)
    }

    // MARK: - Keying

    func testTheKeyIsTheOutputUidNotTheSessionId() {
        // The whole point of the store: a device that comes back with a fresh
        // per-launch `Device.id` still finds its assignment.
        let stored = [profile("BuiltInSpeakerDevice", ChannelMatrixSettings(preset: .left))]
        let decoded = DeviceChannelMatrixStore.decode(
            DeviceChannelMatrixStore.encode(stored)
        )
        XCTAssertNotNil(decoded["BuiltInSpeakerDevice"])
    }

    func testALanReceiverUidIsALegalKey() {
        // Unlike the equalizer and imager stores, this one is not
        // CoreAudio-only: the sender applies the matrix before packetising, so
        // a receiver is a valid target.
        let uid = try? XCTUnwrap(Device.lanReceiverUID(serviceName: "receiver-a"))
        XCTAssertEqual(uid, "lan:receiver-a")
        let decoded = DeviceChannelMatrixStore.decode(
            DeviceChannelMatrixStore.encode([
                profile("lan:receiver-a", ChannelMatrixSettings(preset: .right)),
            ])
        )
        XCTAssertEqual(decoded["lan:receiver-a"]?.settings.preset, .right)
    }

    func testALanUidCannotCollideWithACoreAudioUid() {
        // Both stores share one key space in the Router, so the namespace
        // prefix is what keeps them apart.
        XCTAssertTrue(Device.lanReceiverUID(serviceName: "x")!.hasPrefix("lan:"))
        XCTAssertNil(Device.lanReceiverUID(serviceName: "   "))
        XCTAssertNil(Device.lanReceiverUID(serviceName: nil))
    }

    // MARK: - Summary

    func testTheRowSummaryNamesThePreset() {
        XCTAssertNil(AppModel.channelMatrixSummary(of: ChannelMatrixSettings(preset: .stereo)))
        XCTAssertEqual(
            AppModel.channelMatrixSummary(of: ChannelMatrixSettings(preset: .left)), "左"
        )
        XCTAssertEqual(
            AppModel.channelMatrixSummary(of: ChannelMatrixSettings(preset: .mono)), "单声道"
        )
        let custom = ChannelMatrixSettings(
            preset: .custom, leftToLeftDb: 0, rightToLeftDb: 0,
            leftToRightDb: ChannelMatrixLimits.silentDb, rightToRightDb: 0
        )
        let summary = try? XCTUnwrap(AppModel.channelMatrixSummary(of: custom))
        XCTAssertEqual(summary?.hasPrefix("自定义"), true)
    }

    func testTheSilentStopIsLabelledAsSuch() {
        XCTAssertEqual(
            AppModel.channelMatrixDecibelLabel(ChannelMatrixLimits.silentDb), "−∞"
        )
        XCTAssertEqual(AppModel.channelMatrixDecibelLabel(0), "0.0 dB")
        XCTAssertEqual(AppModel.channelMatrixDecibelLabel(-6), "−6.0 dB")
        XCTAssertEqual(AppModel.channelMatrixDecibelLabel(3), "+3.0 dB")
    }
}
