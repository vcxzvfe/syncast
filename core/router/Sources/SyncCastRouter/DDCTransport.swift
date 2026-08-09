import Foundation
import IOKit

// DDC/CI transport for external monitor speakers on Apple Silicon.
//
// PRIVATE API NOTICE
// ------------------
// Apple Silicon exposes each external display's DDC/CI I2C channel through
// a DCPAVServiceProxy IORegistry node driven by the private IOAVService API
// in CoreDisplay.framework (IOAVServiceCreateWithService /
// IOAVServiceReadI2C / IOAVServiceWriteI2C). There is no public replacement.
// Protocol framing, checksums, and timing constants follow two MIT-licensed
// reference implementations:
//   - waydabber/m1ddc                  (sources/i2c.m, sources/ioregistry.m)
//   - MonitorControl/MonitorControl    (Support/Arm64DDC.swift)
//
// Symbols are resolved at runtime with dlsym so a missing or renamed symbol
// on a future macOS fails closed (DDC reports "unavailable") instead of
// breaking the link of the whole router. Everything here is best-effort:
// any failure surfaces as nil/false and callers fall back to the existing
// no-volume-control behavior.

// MARK: - VCP constants

/// The only VCP opcodes SyncCast is allowed to touch. Volume control must
/// never write brightness/contrast/input-select registers.
public enum DDCAudioVCP {
    /// MCCS "Audio: Speaker Volume" (0...max, continuous).
    public static let speakerVolume: UInt8 = 0x62
    /// MCCS "Audio: Mute". Write 1 = mute, 2 = unmute.
    public static let mute: UInt8 = 0x8D
    public static let muteOn: UInt16 = 1
    public static let muteOff: UInt16 = 2
}

// MARK: - Pure packet construction / parsing (unit-checkable)

/// Pure DDC/CI packet helpers. No IO — the byte layouts here were derived
/// from vectors captured on real hardware (ASUS ExternalDisplay). The standalone
/// verifier that exercised them (`SyncCastRouterTimingCheck`) was retired
/// with the acoustic-measurement removal on 2026-08-09; these helpers are
/// currently unit-checkable but uncovered.
public enum DDCPacket {
    /// 7-bit I2C address of the DDC/CI peripheral on the display.
    public static let chipAddress: UInt32 = 0x37
    /// DDC/CI "host to display" data sub-address.
    public static let dataAddress: UInt32 = 0x51
    /// "Get VCP Feature Reply" is always 11 bytes.
    public static let replyLength = 11

    /// XOR checksum over `bytes` starting from `seed` (DDC/CI spec).
    public static func checksum(seed: UInt8, bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// "Get VCP Feature" request: [0x82, 0x01, opcode, checksum]. The
    /// checksum seed for a read request is the chip address shifted into
    /// write form (0x37 << 1 == 0x6E).
    public static func readRequest(vcp: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        packet[3] = checksum(
            seed: UInt8(chipAddress << 1),
            bytes: packet[0...2]
        )
        return packet
    }

    /// "Set VCP Feature" request: [0x84, 0x03, opcode, hi, lo, checksum].
    /// The checksum seed additionally XORs the data sub-address.
    public static func writeRequest(vcp: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            0x84, 0x03, vcp,
            UInt8(value >> 8), UInt8(value & 0xFF), 0,
        ]
        packet[5] = checksum(
            seed: UInt8(chipAddress << 1) ^ UInt8(dataAddress),
            bytes: packet[0...4]
        )
        return packet
    }

    /// Parse a "Get VCP Feature Reply". Fails closed (nil) when the reply
    /// is short, the checksum is wrong, the display reported an error
    /// result code (e.g. unsupported VCP), or the opcode echo mismatches.
    public static func parseReadReply(
        _ reply: [UInt8],
        vcp: UInt8
    ) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= replyLength else { return nil }
        let expected = checksum(seed: 0x50, bytes: reply[0...(replyLength - 2)])
        guard expected == reply[replyLength - 1] else { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else {
            return nil
        }
        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return (current, maxValue)
    }
}

// MARK: - Private IOAVService symbols (dlsym, fail closed)

private typealias IOAVServiceCreateWithServiceFn =
    @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias IOAVServiceI2CFn =
    @convention(c) (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

private struct DDCIOAVSymbols {
    let createWithService: IOAVServiceCreateWithServiceFn
    let readI2C: IOAVServiceI2CFn
    let writeI2C: IOAVServiceI2CFn

    /// Loaded once per process. nil on non-arm64 or when CoreDisplay no
    /// longer exports the private symbols.
    static let shared: DDCIOAVSymbols? = load()

    private static func load() -> DDCIOAVSymbols? {
        #if arch(arm64)
        let path = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else {
            // Fail closed: a future macOS renamed/removed a symbol, so DDC
            // is unavailable — release the library reference instead of
            // leaking the handle.
            dlclose(handle)
            return nil
        }
        // On success the handle is intentionally never dlclose'd: the
        // function pointers below stay valid only while CoreDisplay remains
        // loaded, and `shared` lives for the whole process anyway.
        return DDCIOAVSymbols(
            createWithService: unsafeBitCast(
                create, to: IOAVServiceCreateWithServiceFn.self
            ),
            readI2C: unsafeBitCast(read, to: IOAVServiceI2CFn.self),
            writeI2C: unsafeBitCast(write, to: IOAVServiceI2CFn.self)
        )
        #else
        return nil
        #endif
    }
}

// MARK: - I2C transactions

/// One display's DDC/CI I2C channel. I2C is slow (each transaction sleeps
/// 10-50 ms and retries); callers MUST serialize access on a non-actor
/// queue — see DDCDisplayVolumeController.
///
/// @unchecked Sendable: the wrapped IOAVService CFTypeRef is only ever used
/// from the owner's serial DDC queue (or single-threaded probe tools).
public final class DDCI2CChannel: @unchecked Sendable {
    /// MonitorControl-derived timing: 10 ms before each write cycle,
    /// 50 ms before the reply read, 20 ms between retry attempts,
    /// 2 write cycles per attempt, 5 attempts total.
    static let writeSleepUs: UInt32 = 10_000
    static let readSleepUs: UInt32 = 50_000
    static let retrySleepUs: UInt32 = 20_000
    static let writeCycles = 2
    static let attempts = 5

    private let symbols: DDCIOAVSymbols
    private let service: CFTypeRef

    fileprivate init(symbols: DDCIOAVSymbols, service: CFTypeRef) {
        self.symbols = symbols
        self.service = service
    }

    /// Blocking VCP read (tens of ms). Returns nil on any IO/parse failure.
    public func readVCP(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        var request = DDCPacket.readRequest(vcp: vcp)
        for attempt in 0..<Self.attempts {
            if attempt > 0 { usleep(Self.retrySleepUs) }
            guard writeRaw(&request) else { continue }
            usleep(Self.readSleepUs)
            var reply = [UInt8](repeating: 0, count: DDCPacket.replyLength)
            let readStatus = reply.withUnsafeMutableBytes { buf in
                symbols.readI2C(
                    service, DDCPacket.chipAddress, 0,
                    buf.baseAddress, UInt32(buf.count)
                )
            }
            guard readStatus == KERN_SUCCESS else { continue }
            if let parsed = DDCPacket.parseReadReply(reply, vcp: vcp) {
                return parsed
            }
        }
        return nil
    }

    /// Blocking VCP write (tens of ms). Returns false when every attempt
    /// failed at the I2C layer (DDC/CI writes have no acknowledgment).
    public func writeVCP(_ vcp: UInt8, value: UInt16) -> Bool {
        var request = DDCPacket.writeRequest(vcp: vcp, value: value)
        for attempt in 0..<Self.attempts {
            if attempt > 0 { usleep(Self.retrySleepUs) }
            if writeRaw(&request) { return true }
        }
        return false
    }

    private func writeRaw(_ packet: inout [UInt8]) -> Bool {
        // Up to `writeCycles` transmissions per attempt; ANY cycle reaching
        // the wire means the packet was delivered, so report success on the
        // first KERN_SUCCESS. A success-then-failure sequence must not turn
        // into a false negative — three of those in a row would wrongly
        // demote a working display to unsupported.
        for _ in 0..<Self.writeCycles {
            usleep(Self.writeSleepUs)
            if symbols.writeI2C(
                service, DDCPacket.chipAddress, DDCPacket.dataAddress,
                &packet, UInt32(packet.count)
            ) == KERN_SUCCESS {
                return true
            }
        }
        return false
    }
}

// MARK: - External display enumeration

/// One external display reachable over DDC/CI.
public struct DDCExternalDisplay: @unchecked Sendable {
    /// EDID product name (e.g. "ExternalDisplay") from the framebuffer node's
    /// DisplayAttributes; empty when the display didn't report one.
    public let productName: String
    public let edidUUID: String
    public let registryPath: String
    public let channel: DDCI2CChannel
}

public enum DDCDisplayEnumerator {
    /// True when the private IOAVService API is available (arm64 + symbols).
    public static var isSupported: Bool {
        DDCIOAVSymbols.shared != nil
    }

    /// Walk the IORegistry pairing framebuffer nodes (AppleCLCD2 /
    /// IOMobileFramebufferShim — these carry EDID product info) with the
    /// DCPAVServiceProxy node that follows them, keeping only
    /// Location == "External" services (internal panels reject DDC).
    /// Same traversal as MonitorControl's Arm64DDC.getIoregServicesForMatching.
    public static func externalDisplays() -> [DDCExternalDisplay] {
        guard let symbols = DDCIOAVSymbols.shared else { return [] }
        var results: [DDCExternalDisplay] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else {
            return results
        }
        defer { IOObjectRelease(iterator) }

        let framebufferClasses = ["AppleCLCD2", "IOMobileFramebufferShim"]
        var currentProductName = ""
        var currentEDIDUUID = ""

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](
                repeating: 0, count: MemoryLayout<io_name_t>.size
            )
            guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS else {
                continue
            }
            let name = String(cString: nameBuffer)

            if framebufferClasses.contains(name) {
                currentProductName = ""
                currentEDIDUUID = ""
                if let attrs = IORegistryEntryCreateCFProperty(
                    entry, "DisplayAttributes" as CFString,
                    kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any],
                   let product = attrs["ProductAttributes"] as? [String: Any],
                   let productName = product["ProductName"] as? String {
                    currentProductName = productName
                }
                if let edid = IORegistryEntryCreateCFProperty(
                    entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String {
                    currentEDIDUUID = edid
                }
            } else if name == "DCPAVServiceProxy" {
                guard let location = IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String, location == "External" else {
                    continue
                }
                guard let service = symbols.createWithService(
                    kCFAllocatorDefault, entry
                )?.takeRetainedValue() else {
                    continue
                }
                var pathBuffer = [CChar](
                    repeating: 0, count: MemoryLayout<io_string_t>.size
                )
                _ = IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuffer)
                results.append(DDCExternalDisplay(
                    productName: currentProductName,
                    edidUUID: currentEDIDUUID,
                    registryPath: String(cString: pathBuffer),
                    channel: DDCI2CChannel(symbols: symbols, service: service)
                ))
            }
        }
        return results
    }
}
