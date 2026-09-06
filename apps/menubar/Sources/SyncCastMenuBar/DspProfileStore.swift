import Foundation
import SyncCastRouter

/// One saved "调音方案": a snapshot of every per-output DSP setting the app
/// remembers — equalizer curves, stereo-image settings, channel assignments
/// and delay trims — so a whole configuration can be put back with one click.
///
/// The point is A/B listening. Tuning three speakers against each other
/// means touching a dozen numbers across four panels; comparing two such
/// configurations by ear is hopeless unless both can be recalled intact.
/// Snapshots are keyed by device UID like the settings they contain, so a
/// profile saved with a device unplugged still applies to it when it returns.
struct DspProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
    var equalizers: [DeviceEqualizerProfile]
    var stereoImages: [DeviceStereoImageProfile]
    var channelMatrices: [DeviceChannelMatrixProfile]
    var delayTrims: [LocalDelayTrimProfile]

    init(id: String = UUID().uuidString,
         name: String,
         createdAt: Date = Date(),
         equalizers: [DeviceEqualizerProfile],
         stereoImages: [DeviceStereoImageProfile],
         channelMatrices: [DeviceChannelMatrixProfile],
         delayTrims: [LocalDelayTrimProfile]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.equalizers = equalizers
        self.stereoImages = stereoImages
        self.channelMatrices = channelMatrices
        self.delayTrims = delayTrims
    }

    /// Whether this profile describes exactly the given live state, ignoring
    /// order and display names (which are cosmetic and may be refreshed).
    func matches(equalizers live: [String: DeviceEqualizerProfile],
                 stereoImages: [String: DeviceStereoImageProfile],
                 channelMatrices: [String: DeviceChannelMatrixProfile],
                 delayTrims: [String: LocalDelayTrimProfile]) -> Bool {
        Self.keyed(self.equalizers).mapValues(\.settings) == live.mapValues(\.settings)
            && Self.keyed(self.stereoImages).mapValues(\.settings) == stereoImages.mapValues(\.settings)
            && Self.keyed(self.channelMatrices).mapValues(\.settings) == channelMatrices.mapValues(\.settings)
            && Self.keyed(self.delayTrims).mapValues(\.delayMs) == delayTrims.mapValues(\.delayMs)
    }

    static func keyed<T: Identifiable>(_ items: [T]) -> [T.ID: T] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
}

enum DspProfileStore {
    static let defaultsKey = "syncast.dspProfiles.v1"
    /// Enough for A/B/C comparisons; a list longer than this is a filing
    /// cabinet, not a tuning tool.
    static let maximumCount = 8

    static func load(defaults: UserDefaults = .standard) -> [DspProfile] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([DspProfile].self, from: data)
        } catch {
            SyncCastLog.log("dspProfiles: stored list is unreadable, starting empty: \(error)")
            return []
        }
    }

    static func save(_ profiles: [DspProfile], defaults: UserDefaults = .standard) {
        guard !profiles.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: defaultsKey)
        } catch {
            SyncCastLog.log("dspProfiles: could not encode \(profiles.count) profile(s): \(error)")
        }
    }

    /// A name for a snapshot the user did not name: the panel cannot take
    /// keyboard input (see `LanTokenEntryView` for why), so names are minted
    /// here — numbered, with the time, which is what one needs to tell two
    /// A/B candidates apart.
    static func defaultName(existing: [DspProfile], now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "方案 \(existing.count + 1) · \(formatter.string(from: now))"
    }
}
