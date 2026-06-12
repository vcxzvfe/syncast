import Foundation
import SyncCastRouter

// SyncCastDDCProbe — hardware feasibility probe for DDC/CI monitor-speaker
// volume on Apple Silicon.
//
// All transport logic lives in SyncCastRouter (DDCTransport.swift), so this
// probe exercises exactly the code path the Direct Stereo volume fallback
// uses. See DDCTransport.swift for the private-API (IOAVService) notice and
// the m1ddc / MonitorControl (MIT) references.
//
// SAFETY: this probe only ever touches VCP 0x62 (Audio Speaker Volume) and
// reads VCP 0x8D (Audio Mute). It never writes brightness/contrast/input.
// `--verify-write` restores the original volume before exiting.
//
// Usage:
//   SyncCastDDCProbe                 read-only report (VCP 0x62 + 0x8D)
//   SyncCastDDCProbe --set-volume N  write VCP 0x62 = N (0...max)
//   SyncCastDDCProbe --verify-write  read -> write +/-5 -> read back -> restore

func report(_ display: DDCExternalDisplay) {
    print("display: \"\(display.productName)\" edid=\(display.edidUUID)")
    print("  ioreg: \(display.registryPath)")
    if let volume = display.channel.readVCP(DDCAudioVCP.speakerVolume) {
        print("  VCP 0x62 (Audio Speaker Volume): current=\(volume.current) max=\(volume.max)")
    } else {
        print("  VCP 0x62 (Audio Speaker Volume): READ FAILED")
    }
    if let mute = display.channel.readVCP(DDCAudioVCP.mute) {
        print("  VCP 0x8D (Audio Mute): current=\(mute.current) max=\(mute.max)")
    } else {
        print("  VCP 0x8D (Audio Mute): READ FAILED (mute likely unsupported)")
    }
}

func verifyWrite(_ display: DDCExternalDisplay) -> Bool {
    print("verify-write on \"\(display.productName)\" (VCP 0x62 only)")
    guard let before = display.channel.readVCP(DDCAudioVCP.speakerVolume) else {
        print("  FAIL: initial read failed")
        return false
    }
    print("  initial: current=\(before.current) max=\(before.max)")
    let delta: Int = before.current + 5 <= before.max ? 5 : -5
    let target = UInt16(max(0, min(Int(before.max), Int(before.current) + delta)))
    print("  writing test value \(target) ...")
    guard display.channel.writeVCP(DDCAudioVCP.speakerVolume, value: target) else {
        print("  FAIL: write returned error")
        return false
    }
    usleep(50_000)
    guard let after = display.channel.readVCP(DDCAudioVCP.speakerVolume) else {
        print("  FAIL: read-back failed; attempting restore")
        _ = display.channel.writeVCP(
            DDCAudioVCP.speakerVolume, value: before.current
        )
        return false
    }
    print("  read-back: current=\(after.current) (expected \(target))")
    print("  restoring original value \(before.current) ...")
    let restored = display.channel.writeVCP(
        DDCAudioVCP.speakerVolume, value: before.current
    )
    usleep(50_000)
    let final = display.channel.readVCP(DDCAudioVCP.speakerVolume)
    print("  final: current=\(final.map { String($0.current) } ?? "READ FAILED") restoreWrite=\(restored ? "ok" : "FAILED")")
    return after.current == target
        && restored
        && final?.current == before.current
}

let arguments = CommandLine.arguments
guard DDCDisplayEnumerator.isSupported else {
    print("DDC unavailable: IOAVService symbols could not be loaded (non-arm64 or missing CoreDisplay private API)")
    exit(2)
}
let displays = DDCDisplayEnumerator.externalDisplays()
print("external DDC displays found: \(displays.count)")
guard !displays.isEmpty else { exit(2) }

if let flagIndex = arguments.firstIndex(of: "--set-volume") {
    guard flagIndex + 1 < arguments.count,
          let value = UInt16(arguments[flagIndex + 1]) else {
        print("usage: SyncCastDDCProbe --set-volume <0...max>")
        exit(64)
    }
    let display = displays[0]
    let ok = display.channel.writeVCP(DDCAudioVCP.speakerVolume, value: value)
    print("set VCP 0x62 = \(value) on \"\(display.productName)\": \(ok ? "ok" : "FAILED")")
    usleep(50_000)
    if let readBack = display.channel.readVCP(DDCAudioVCP.speakerVolume) {
        print("read-back: current=\(readBack.current) max=\(readBack.max)")
    }
    exit(ok ? 0 : 1)
}

if arguments.contains("--verify-write") {
    var allOK = true
    for display in displays {
        report(display)
        if display.channel.readVCP(DDCAudioVCP.speakerVolume) != nil {
            allOK = verifyWrite(display) && allOK
        }
    }
    print(allOK ? "verify-write: PASS" : "verify-write: FAIL")
    exit(allOK ? 0 : 1)
}

for display in displays {
    report(display)
}
