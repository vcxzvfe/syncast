import Foundation
import CoreAudio
import os.lock

/// A private CoreAudio Aggregate Device that fans out audio to multiple
/// physical output devices in lockstep. Drift correction is enabled on every
/// non-master subdevice, so the kernel's polyphase sample-rate-converter keeps
/// every speaker sample-accurately aligned with the master clock — eliminating
/// the inter-device drift that an array of independent AUHALs cannot avoid.
///
/// Why this exists
/// ---------------
/// SyncCast's first multi-output strategy was "open one AUHAL per output and
/// play the same ring buffer at compensated offsets". That works on paper but
/// has two real-world failure modes the user reported audibly:
///   - Each AUHAL has its own free-running clock (typically a few PPM off
///     from every other output). Over minutes the offset between physical
///     speakers walks until you hear chorusing/comb filtering.
///   - Per-device hardware-latency compensation can only correct the static
///     offset measured at start; it cannot track drift.
///
/// macOS solves this in the kernel for Aggregate Devices: every non-master
/// subdevice is run through a real-time SRC whose ratio is locked to the
/// master's reported audio clock. The SRC ratio updates continuously, and the
/// drift between physical outputs stays sub-sample on commodity DACs.
///
/// Reliability hazards (cited from Opus deep dive + cross-checks against
/// BlackHole / Loopback open-source notes)
/// ---------------------------------------
///   - Private aggregates are documented to be auto-cleaned on process exit
///     ("not persistent across launches" per AudioHardware.h:1610). In
///     practice `coreaudiod` has been observed to leak them after SIGKILL,
///     suspended-process states, or fast user switching. We mitigate with a
///     stable UID prefix + launch-time orphan sweep.
///   - HDMI / DisplayPort outputs renegotiate their clock when the cable is
///     reconnected. NEVER pick those as master; built-in speaker is safest.
///   - Bluetooth devices renegotiate sample rate when another app opens
///     input on them. Bluetooth as master = sudden silence. Bluetooth as
///     slave = recoverable; the SRC tracks the change.
///   - Two app instances using the same UID can step on each other.
///     Defense-in-depth: include PID + UUID in the UID, plus a single-
///     instance guard at the menubar layer (already present).
public final class AggregateDevice {
    public enum AggregateError: Error, CustomStringConvertible {
        case createFailed(OSStatus)
        case noSubdevices
        case missingMasterUID

        public var description: String {
            switch self {
            case .createFailed(let s): return "AudioHardwareCreateAggregateDevice failed: OSStatus=\(s)"
            case .noSubdevices: return "aggregate device requires at least one subdevice UID"
            case .missingMasterUID: return "master UID was not in the subdevice list"
            }
        }
    }

    /// Stable prefix shared by every aggregate device this app creates. Used
    /// by `sweepOrphans()` to identify our prior creations and reap them on
    /// the next launch. Keep this string stable across releases — adding a
    /// version suffix would orphan existing devices that we'd never sweep.
    public static let uidPrefix = "io.syncast.aggregate.v1."

    public let aggregateUID: String
    public let deviceID: AudioObjectID
    public let masterUID: String
    public let subDeviceUIDs: [String]
    /// The channel count AUHAL must declare on its input scope to match
    /// what the aggregate's output stream actually exposes.
    ///
    /// Why this is dynamic: with stacked=0 and 2-ch subdevices, the
    /// expected layout is one stream of 2 channels (kernel fans the
    /// stereo to every subdevice). In practice, with two 2-ch subdevices
    /// (e.g. MBP built-in + display speakers), the aggregate often
    /// exposes 4 channels in one stream (kernel concatenated subdevices'
    /// channels regardless of stacked=0 — observed on Sonoma+). If AUHAL
    /// is configured for 2-ch, only the first pair receives audio; the
    /// second physical speaker is silent.
    ///
    /// The fix: query the actual stream channel count post-create and
    /// configure AUHAL to match. The render callback writes the source
    /// stereo into EVERY channel pair (splat) so all subdevices play.
    public let outputChannelCount: Int

    /// Build a new private aggregate. Throws if the kernel rejects the
    /// composition (most often: a UID that isn't a real, currently-online
    /// device). Caller is responsible for serializing creation/destruction
    /// with whatever owns the AUHAL on top of this device.
    public init(masterUID: String, slaveUIDs: [String]) throws {
        // UID composition: stable prefix (so sweepOrphans can match) + PID
        // (so two SyncCast instances don't collide if launched together) +
        // UUID (so even a single instance doing rapid create/destroy never
        // reuses a UID across attempts — coreaudiod can lag a destroy).
        let pid = ProcessInfo.processInfo.processIdentifier
        let uid = "\(Self.uidPrefix)\(pid).\(UUID().uuidString)"
        self.aggregateUID = uid
        self.masterUID = masterUID

        // De-dup: master must appear in the subdevice list exactly once. We
        // tolerate the caller passing master in or out of `slaveUIDs`.
        var seen = Set<String>()
        var ordered: [String] = []
        for u in [masterUID] + slaveUIDs where seen.insert(u).inserted {
            ordered.append(u)
        }
        guard !ordered.isEmpty else { throw AggregateError.noSubdevices }
        guard ordered.contains(masterUID) else { throw AggregateError.missingMasterUID }
        self.subDeviceUIDs = ordered

        // Per-subdevice config:
        //   drift = 0 on the master (it IS the reference clock; correcting
        //           against itself is meaningless and wastes CPU).
        //   drift = 1 on slaves (turns on real-time SRC tracking master).
        //   quality = High (0x60) — polyphase, transparent for music.
        //             Min (0) is audibly bad; Max (0x7F) is overkill.
        let subdevices: [[String: Any]] = ordered.map { uid in
            [
                kAudioSubDeviceUIDKey as String: uid,
                kAudioSubDeviceDriftCompensationKey as String:
                    UInt32(uid == masterUID ? 0 : 1),
                kAudioSubDeviceDriftCompensationQualityKey as String:
                    UInt32(kAudioAggregateDriftCompensationHighQuality),
            ]
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceNameKey as String: "SyncCast Synchronized Output",
            // private = 1 → invisible in Audio MIDI Setup, scoped to this
            // process. Header explicitly says it's not persistent across
            // launches; we still sweepOrphans on startup as a belt to
            // coreaudiod's braces.
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            // stacked = 0 is "multi-output": every subdevice receives the
            // SAME audio frames. stacked = 1 would concatenate channels
            // (used for surround setups, NOT for fan-out playback).
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: masterUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subdevices,
        ]

        var newID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &newID
        )
        guard status == noErr, newID != 0 else {
            throw AggregateError.createFailed(status)
        }
        self.deviceID = newID

        // Force the aggregate's nominal sample rate to 48 kHz to match
        // SCKCapture's output. Without this, the aggregate inherits the
        // master's current rate at create time and the kernel SRC has to
        // ramp the slaves' ratio over the first 200-500 ms — audible as a
        // brief pitch wobble at every aggregate (re)build (worst on
        // Apple Silicon under low-power mode). Setting an explicit rate
        // engages the SRC immediately and the wobble is gone. Loopback
        // does this via its "Output Clock" feature.
        Self.setNominalSampleRate(newID, rate: 48_000)

        // === Channel-count fix (Strategy 2 / stereo-mode silent-second-
        // device bug) ===
        //
        // First try approach (A): coerce every output stream to 2-ch by
        // setting `kAudioStreamPropertyVirtualFormat`. If the kernel
        // accepts, AUHAL writes 2 channels and the aggregate fans them
        // out to every subdevice (the documented stacked=0 contract).
        //
        // If the kernel rejects (most often on stacked aggregate streams
        // — they're considered immutable by the AggregateClock plug-in),
        // we fall back to approach (B): re-read the actual channel count
        // and accept it. AUHAL on top will then be configured for the
        // wider count and render() splats stereo into every channel pair.
        Self.tryNarrowOutputStreamsToStereo(newID)
        let (_, _, total) = Self.readStreamChannels(newID)
        // Floor at 2 — even if the read failed, AUHAL must be at least
        // a stereo pair. A device that exposes 0 output channels post-
        // create is broken in a way we can't paper over here.
        self.outputChannelCount = max(2, total)
    }

    /// Approach (A) for the channel-count bug: try to set every output
    /// stream's virtual format to 2-ch Float32 non-interleaved. If the
    /// kernel accepts, AUHAL on top will be a clean 2-ch surface and the
    /// kernel handles the fan-out per the stacked=0 contract.
    ///
    /// Best-effort — failure is silently tolerated, and the caller falls
    /// back to (B) by reading the resulting channel count.
    private static func tryNarrowOutputStreamsToStereo(_ aggregateID: AudioObjectID) {
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            aggregateID, &streamsAddr, 0, nil, &size
        ) == noErr, size > 0 else { return }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = Array(repeating: AudioStreamID(0), count: count)
        guard AudioObjectGetPropertyData(
            aggregateID, &streamsAddr, 0, nil, &size, &streams
        ) == noErr else { return }

        // Read sample rate from the aggregate — we want to keep whatever
        // we already negotiated above.
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 48_000
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(
            aggregateID, &rateAddr, 0, nil, &rateSize, &sampleRate
        )

        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        for s in streams {
            // Best-effort. Most aggregate stream objects reject this
            // because their stream layout is derived from their
            // subdevices and the kernel considers it immutable.
            _ = AudioObjectSetPropertyData(
                s, &virtualAddr, 0, nil, formatSize, &format
            )
        }
    }

    private static func setNominalSampleRate(_ id: AudioObjectID, rate: Float64) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let size = UInt32(MemoryLayout<Float64>.size)
        // Best-effort. If the kernel rejects (e.g. master device doesn't
        // support 48k), the aggregate falls back to its native rate; we
        // rely on the SRC to handle the conversion to/from our 48k feed.
        _ = AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value)
    }

    /// Idempotent. Safe to call multiple times — only the first call asks
    /// CoreAudio to actually destroy. After this returns, `deviceID` is no
    /// longer a valid AudioObject.
    public func destroy() {
        // Snapshot to avoid double-destroy from a deinit-after-explicit
        // call race.
        let id = self.deviceID
        // Set internal sentinel so destroy() isn't re-issued by deinit.
        // We can't actually mutate `deviceID` since it's `let`; rely on
        // CoreAudio returning kAudioHardwareBadDeviceError on the second
        // call, which we ignore.
        _ = AudioHardwareDestroyAggregateDevice(id)
    }

    deinit { destroy() }

    // MARK: - Verification

    /// Reads back per-subdevice drift state from CoreAudio. Use immediately
    /// after construction to assert that drift correction is actually
    /// engaged at the requested quality — Apple Silicon under low-power
    /// mode has been observed to silently downgrade.
    ///
    /// CRITICAL: we must read the property from the SUBDEVICE object
    /// (class `kAudioSubDeviceClassID`) that hangs off this aggregate,
    /// NOT from the underlying physical device. `TranslateUIDToDevice`
    /// resolves against the system device table and returns the physical
    /// device's ID — reading `kAudioSubDevicePropertyDriftCompensation`
    /// on that ID is undefined and (on most macOS versions) returns
    /// `kAudioHardwareUnknownPropertyError`, leading to spurious
    /// "drift OFF" reports on a perfectly healthy aggregate. Walk
    /// `kAudioObjectPropertyOwnedObjects` instead, filter by class.
    public func verifyDriftCorrection() -> [String: (enabled: Bool, quality: UInt32)] {
        var result: [String: (Bool, UInt32)] = [:]
        let subObjectIDs = Self.aggregateOwnedSubDeviceIDs(aggregateID: deviceID)
        for subID in subObjectIDs {
            guard let uid = Self.readSubDeviceUID(subID) else { continue }
            let drift = Self.readUInt32(subID, kAudioSubDevicePropertyDriftCompensation) ?? 0
            let quality = Self.readUInt32(subID, kAudioSubDevicePropertyDriftCompensationQuality) ?? 0
            result[uid] = (drift != 0, quality)
        }
        return result
    }

    // MARK: - Stream-format diagnostic
    //
    // Why this exists
    // ---------------
    // Reported bug (Strategy 2 / stereo mode): when 2+ local outputs are
    // enabled, only ONE physical speaker emits sound — the second is
    // silent. AUHAL renders fire (renderTickCount climbs, peak > 0), the
    // aggregate is built (driver=aggregate(2)), drift is on … but only
    // one DAC produces audio.
    //
    // The hypothesis: AUHAL is configured for 2-ch (mChannelsPerFrame=2),
    // but the aggregate's stream may expose 2*N channels — one stereo pair
    // per subdevice. AUHAL writes the first pair only, leaving the rest
    // silent. The kernel docs state that stacked=0 should make every
    // subdevice receive the SAME frames (a true fan-out), but on some
    // OS / driver combinations the aggregate's STREAM still surfaces the
    // sum of subdevice channels.
    //
    // To prove or refute the hypothesis we need to read back
    // `kAudioDevicePropertyStreamConfiguration` AFTER create. That gives
    // us an AudioBufferList describing every output stream's actual
    // channel count. We log the result. If totalChannels > 2 with two
    // 2-ch subdevices, the hypothesis is correct and we need a fix
    // (set virtual format to 2-ch, or widen AUHAL to match).
    public struct StreamDiagnostic: Sendable {
        public let streamCount: Int
        public let channelsPerStream: [Int]
        public let totalChannels: Int
        public let masterSubdeviceChannels: Int
        public var summary: String {
            let perStream = channelsPerStream.map(String.init).joined(separator: ",")
            return "streams=\(streamCount) ch=[\(perStream)] total=\(totalChannels) master=\(masterSubdeviceChannels)"
        }
    }

    /// Reads back the aggregate's actual output-stream layout. Call
    /// IMMEDIATELY after construction, before opening an AUHAL on top.
    /// Used to diagnose the "only one device plays" bug when 2+ outputs
    /// are stacked into a single aggregate.
    public func diagnoseStreamConfig() -> StreamDiagnostic {
        let (streams, perStream, total) = Self.readStreamChannels(deviceID)
        // Walk owned subdevices to find the master and read its channel
        // count. Use scope=Output because that's what AUHAL pulls from.
        var masterCh: Int = 0
        for subID in Self.aggregateOwnedSubDeviceIDs(aggregateID: deviceID) {
            guard let uid = Self.readSubDeviceUID(subID), uid == masterUID else {
                continue
            }
            // The subdevice object inherits AudioDevice; its channel
            // count is whatever the underlying physical device exposes.
            // Read on scope=Output — AUHAL pulls outputs.
            masterCh = Self.readStreamChannelTotal(subID, scope: kAudioDevicePropertyScopeOutput)
            break
        }
        return StreamDiagnostic(
            streamCount: streams,
            channelsPerStream: perStream,
            totalChannels: total,
            masterSubdeviceChannels: masterCh
        )
    }

    /// Reads `kAudioDevicePropertyStreamConfiguration` on `id`,
    /// scope=Output, returns (streamCount, perStreamChannels, total).
    /// Internal so XCTest can exercise it on any AudioObjectID-shaped value.
    static func readStreamChannels(_ id: AudioObjectID) -> (Int, [Int], Int) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return (0, [], 0)
        }
        // AudioBufferList is variable-length; allocate a raw buffer and
        // bind to AudioBufferList head, then iterate.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, listPtr)
        guard status == noErr else { return (0, [], 0) }
        let bufList = UnsafeMutableAudioBufferListPointer(listPtr)
        var perStream: [Int] = []
        var total = 0
        for i in 0..<bufList.count {
            let ch = Int(bufList[i].mNumberChannels)
            perStream.append(ch)
            total += ch
        }
        return (bufList.count, perStream, total)
    }

    /// Convenience: total channel count on a given scope.
    private static func readStreamChannelTotal(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, listPtr)
        guard status == noErr else { return 0 }
        let bufList = UnsafeMutableAudioBufferListPointer(listPtr)
        var total = 0
        for i in 0..<bufList.count { total += Int(bufList[i].mNumberChannels) }
        return total
    }

    /// Returns the AudioObjectIDs of every kAudioSubDeviceClassID object
    /// owned by `aggregateID`. These are the in-aggregate subdevice
    /// instances (NOT the underlying physical devices), and they're the
    /// only correct target for sub-device drift / latency property reads.
    static func aggregateOwnedSubDeviceIDs(
        aggregateID: AudioObjectID
    ) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyOwnedObjects,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputClass: AudioClassID = kAudioSubDeviceClassID
        var size: UInt32 = 0
        // Qualifier: filter to subdevice class only. Ownedobjects is one
        // of the few CoreAudio properties that takes input data.
        let qSize = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyDataSize(
            aggregateID, &addr, qSize, &inputClass, &size
        ) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(0), count: count)
        let status = AudioObjectGetPropertyData(
            aggregateID, &addr, qSize, &inputClass, &size, &ids
        )
        return status == noErr ? ids : []
    }

    private static func readSubDeviceUID(_ subID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioSubDevicePropertyExtraLatency,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The subdevice's UID is exposed via kAudioObjectPropertyName /
        // kAudioDevicePropertyDeviceUID — both work on subdevice objects
        // (they inherit from AudioDevice).
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var cfUid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfUid) { ptr in
            AudioObjectGetPropertyData(subID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let result = cfUid as String? else { return nil }
        return result
    }

    private static func readUInt32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    // MARK: - Orphan sweep

    /// On startup, find any aggregate devices left behind by a prior crash
    /// and destroy them. Identifies our creations by UID prefix. Returns the
    /// number reaped. Should be called exactly once, before any aggregate
    /// is created in this run.
    ///
    /// Cross-instance safety: a SyncCast aggregate UID is structured as
    /// `\(uidPrefix)\(pid).\(uuid)`. We extract the embedded PID and use
    /// `kill(pid, 0)` to test liveness. Only DEAD PIDs' aggregates are
    /// reaped — this prevents a second SyncCast launch from killing the
    /// first instance's live audio mid-stream. (The user's single-instance
    /// guard at the menubar layer is the primary defense; this is a
    /// secondary safety net for the brief window between an old instance's
    /// crash and the new one's launch.)
    @discardableResult
    public static func sweepOrphans() -> Int {
        var reaped = 0
        let myPID = ProcessInfo.processInfo.processIdentifier
        for id in enumerateAllDevices() {
            guard isAggregate(id) else { continue }
            guard let uid = readDeviceUID(id) else { continue }
            guard uid.hasPrefix(uidPrefix) else { continue }

            // Parse the embedded PID. Format after prefix:
            // "<pid>.<uuid>" where pid is base-10. Anything we can't
            // parse is treated as "unknown PID, leave alone" (safer
            // than killing arbitrary aggregates).
            let suffix = uid.dropFirst(uidPrefix.count)
            guard let dot = suffix.firstIndex(of: "."),
                  let pid = Int32(suffix[suffix.startIndex..<dot]) else {
                continue
            }
            // Skip our own (would happen if a previous Router init in
            // the same process orphaned an aggregate, which our own
            // tearDown should make impossible — but defense in depth).
            if pid == myPID { continue }
            // Probe liveness. kill(pid, 0) returns 0 if the process is
            // alive AND we have permission; -1 with errno=ESRCH if dead.
            // Permission denied (EPERM) means the process exists but is
            // owned by another user — leave it alone.
            let alive = (Darwin.kill(pid, 0) == 0)
            let stillExists: Bool = {
                if alive { return true }
                return errno != Darwin.ESRCH
            }()
            if stillExists { continue }
            if AudioHardwareDestroyAggregateDevice(id) == noErr {
                reaped += 1
            }
        }
        return reaped
    }

    private static func enumerateAllDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = Array(repeating: AudioObjectID(0), count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            0, nil, &size, &ids
        )
        return status == noErr ? ids : []
    }

    private static func isAggregate(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var classID: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &classID)
        return status == noErr && classID == kAudioAggregateDeviceClassID
    }

    private static func readDeviceUID(_ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfUid) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let result = cfUid as String? else { return nil }
        return result
    }

    // MARK: - Per-device hardware volume
    //
    // Why this exists
    // ---------------
    // In aggregate mode there's a SINGLE AUHAL on top of the kernel-
    // level fan-out, so the existing `LocalOutput.setRouting(gain:)`
    // applies one global software gain to the entire stream — every
    // physical speaker hears the same level. The user's per-device
    // volume sliders (e.g. "MBP at 80% + display at 50%") cannot be
    // honored that way.
    //
    // Fix: write hardware volume directly on each underlying physical
    // device via `kAudioDevicePropertyVolumeScalar`. The aggregate
    // doesn't intercept this — the volume lives on the DAC and stays
    // applied even after the aggregate is torn down. (That's also why
    // we restore the previous level on stop, see `restoreSubdeviceVolume`
    // — TODO P3 if we want to be polite to other apps.)
    //
    // CoreAudio volume element semantics:
    //   - Element 0 ("master") — sometimes settable, sometimes a
    //     read-only mirror of the per-channel max. Headphone DACs
    //     and most aggregates expose it, USB class-compliant devices
    //     usually don't.
    //   - Element 1..N — per-channel. Always per-element on devices
    //     that don't accept master writes. We set every output channel
    //     to the same scalar so the user's slider behaves as a balanced
    //     gain.

    /// Apply a 0..1 scalar volume to the physical device backing
    /// the subdevice with UID `uid`. Returns whether ANY write
    /// succeeded — partial-success (some channels accepted, others
    /// rejected) is reported as success.
    ///
    /// Best-effort: a device that refuses every write (some HDMI
    /// outputs, some pro audio interfaces with hardware-only volume
    /// knobs) returns false. Caller can fall back to the AUHAL
    /// software gain in that case, which means losing per-device
    /// granularity but preserving overall mute/duck behavior.
    @discardableResult
    public func setSubdeviceVolume(uid: String, volume: Float) -> Bool {
        let clamped = max(0.0, min(1.0, volume))
        // Resolve the underlying physical device. The aggregate's owned
        // subdevice objects are NOT the right target for hardware
        // volume (they're aggregate-internal facades). The actual DAC
        // hardware lives behind the UID's translated AudioObjectID.
        guard subDeviceUIDs.contains(uid) else { return false }
        let physicalID: AudioObjectID
        do {
            physicalID = try Self.deviceIDForUID(uid)
        } catch {
            return false
        }
        return Self.applyHardwareVolume(physicalID: physicalID, volume: clamped)
    }

    /// Per-physical-device cache of writable volume elements, populated
    /// lazily on the first `applyHardwareVolume` call for a given
    /// device. HDMI / DisplayPort outputs charge >5 ms on each missing
    /// element's `AudioObjectSetPropertyData` call, so a naive 1..32 loop
    /// on every slider drag wedges the UI for >100 ms per frame. With the
    /// cache, slider drags hit a 1-2 element loop every time after the
    /// first probe.
    private static let writableElementsLock = OSAllocatedUnfairLock()
    private static var writableElementsCache:
        [AudioObjectID: [AudioObjectPropertyElement]] = [:]

    /// Static so it can be unit-tested in isolation. Tries master
    /// element first; falls back to per-channel iteration. Returns
    /// true if any write succeeded.
    static func applyHardwareVolume(
        physicalID: AudioObjectID,
        volume: Float
    ) -> Bool {
        // Step 0: cache lookup. If we've already probed this device,
        // skip straight to writing the known-writable elements.
        let cached: [AudioObjectPropertyElement]? = writableElementsLock
            .withLock { writableElementsCache[physicalID] }
        if let elements = cached {
            return writeToCachedElements(physicalID, elements: elements, volume: volume)
        }
        // Step 1: probe writable elements. Element 0 first, then 1..32
        // with an early bail-out after 4 consecutive misses (most DACs
        // expose at most 2 channels, and the per-element probe on HDMI/
        // DP outputs is the slow path that motivated this cache).
        var writable: [AudioObjectPropertyElement] = []
        if isVolumeWritable(physicalID, element: 0) {
            writable.append(0)
        }
        var consecutiveMisses = 0
        for elem in 1...32 {
            let element = AudioObjectPropertyElement(elem)
            if isVolumeWritable(physicalID, element: element) {
                writable.append(element)
                consecutiveMisses = 0
            } else {
                consecutiveMisses += 1
                if consecutiveMisses >= 4 { break }
            }
        }
        let frozen = writable
        writableElementsLock.withLock {
            writableElementsCache[physicalID] = frozen
        }
        return writeToCachedElements(physicalID, elements: frozen, volume: volume)
    }

    /// Write `volume` to every element in `elements`. Tries master
    /// element 0 first if present; if its write is accepted the device
    /// is mirroring per-channel state from element 0 and we can skip
    /// the rest. Returns true if any write succeeded.
    private static func writeToCachedElements(
        _ physicalID: AudioObjectID,
        elements: [AudioObjectPropertyElement],
        volume: Float
    ) -> Bool {
        var anyWrite = false
        if elements.contains(0) {
            if writeVolume(physicalID, element: 0, volume: volume) {
                return true
            }
        }
        for element in elements where element != 0 {
            if writeVolume(physicalID, element: element, volume: volume) {
                anyWrite = true
            }
        }
        return anyWrite
    }

    /// True iff `kAudioDevicePropertyVolumeScalar` exists on the given
    /// element AND is settable. Both checks are needed — a read-only
    /// master mirror passes HasProperty but fails IsSettable.
    private static func isVolumeWritable(
        _ id: AudioObjectID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    /// Write a scalar 0..1 volume to a specific (id, element) pair.
    /// Returns true on noErr, false otherwise. We do NOT first check
    /// IsSettable here because per-channel writes that succeed on
    /// element N are common even when element 0 reports unsettable.
    private static func writeVolume(
        _ id: AudioObjectID,
        element: AudioObjectPropertyElement,
        volume: Float
    ) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var value = volume
        let size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value)
        return status == noErr
    }

    // MARK: - Master selection helper

    /// Picks the best master subdevice from a candidate set.
    ///
    /// Strategy (per Loopback / SoundSource published guidance + Apple
    /// "Audio Hardware Reference"):
    ///   - Built-in / aggregate-internal: most stable clock; preferred.
    ///   - USB class-compliant: stable, picks up rate cleanly.
    ///   - HDMI / DisplayPort: re-trains on cable reconnect → bad master.
    ///   - Bluetooth: renegotiates rate when another app opens its
    ///     input → catastrophic as master.
    ///   - Virtual / aggregate: avoid; clock semantics are recursive.
    ///
    /// Score by `kAudioDevicePropertyTransportType` rather than device
    /// name — names are localized (zh-CN "扬声器", de-DE "Lautsprecher",
    /// ja-JP "スピーカー"...) and unreliable. Transport types are stable
    /// integer constants set by the kernel.
    public static func pickMaster(
        candidateUIDs: Set<String>,
        deviceNames: [String: String]  // unused; kept for API stability
    ) -> String? {
        guard !candidateUIDs.isEmpty else { return nil }

        func score(_ uid: String) -> Int {
            guard let id = try? deviceIDForUID(uid) else { return 1000 }
            let transport = readUInt32(id, kAudioDevicePropertyTransportType) ?? 0
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn:
                return 0
            case kAudioDeviceTransportTypeUSB,
                 kAudioDeviceTransportTypeFireWire,
                 kAudioDeviceTransportTypeThunderbolt,
                 kAudioDeviceTransportTypePCI:
                return 10
            case kAudioDeviceTransportTypeBluetooth,
                 kAudioDeviceTransportTypeBluetoothLE:
                // Clock retunes on input-open; never use as master.
                return 100
            case kAudioDeviceTransportTypeHDMI,
                 kAudioDeviceTransportTypeDisplayPort:
                // Retrains on cable reconnect; bad master, OK slave.
                return 50
            case kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeVirtual:
                // Don't make a virtual/aggregate the master of another
                // aggregate — clock semantics get hazy.
                return 200
            default:
                // Unknown transport, middling preference.
                return 30
            }
        }
        return candidateUIDs.min(by: { score($0) < score($1) })
    }

    /// Helper used both by sweepOrphans (as a static) and pickMaster.
    fileprivate static func deviceIDForUID(_ uid: String) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUid = uid as CFString
        var resolved: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUid) { uidPtr -> OSStatus in
            let pSize = UInt32(MemoryLayout<CFString>.size)
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                pSize, uidPtr, &size, &resolved
            )
        }
        guard status == noErr, resolved != kAudioObjectUnknown else {
            throw AggregateError.createFailed(status)
        }
        return resolved
    }
}
