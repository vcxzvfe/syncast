import Foundation
import SyncCastDiscovery

// Usage:
//   syncast-discover                   list devices once and exit
//   syncast-discover --watch           keep listening for hot-plug / mDNS changes
//   syncast-discover --json            machine-readable output

struct Args {
    var watch = false
    var json = false
    var timeoutSeconds: Double = 3.0
}

func parseArgs() -> Args {
    var a = Args()
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        switch argv[i] {
        case "--watch", "-w": a.watch = true
        case "--json": a.json = true
        case "--timeout":
            i += 1
            if i < argv.count, let t = Double(argv[i]) { a.timeoutSeconds = t }
        case "-h", "--help":
            print("""
            syncast-discover — list audio output devices visible to SyncCast

            Usage:
              syncast-discover [--watch] [--json] [--timeout S]

            Options:
              --watch, -w       continue running, print events as devices change
              --json            machine-readable JSON output (one event per line)
              --timeout S       seconds to wait in one-shot mode (default 3)
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown arg: \(argv[i])\n".utf8))
            exit(2)
        }
        i += 1
    }
    return a
}

func formatDevice(_ d: Device) -> String {
    let badge: String
    switch d.transport {
    case .coreAudio: badge = "CA"
    case .airplay2:  badge = "AP"
    }
    let host = d.host.map { " @ \($0):\(d.port ?? 7000)" } ?? ""
    let rate = d.nominalSampleRate.map { String(format: " %.0fHz", $0) } ?? ""
    return "[\(badge)] \(d.name)\(host)\(rate)  id=\(d.id.prefix(8))"
}

let args = parseArgs()
let service = DiscoveryService()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func emitEvent(_ event: DiscoveryEvent) {
    if args.json {
        let envelope: [String: Any]
        switch event {
        case .appeared(let d):
            envelope = ["type": "appeared", "device": (try? JSONSerialization.jsonObject(with: encoder.encode(d))) ?? [:]]
        case .updated(let d):
            envelope = ["type": "updated", "device": (try? JSONSerialization.jsonObject(with: encoder.encode(d))) ?? [:]]
        case .disappeared(let id):
            envelope = ["type": "disappeared", "device_id": id]
        case .error(let msg):
            envelope = ["type": "error", "message": msg]
        }
        if let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    } else {
        switch event {
        case .appeared(let d):    print("+ \(formatDevice(d))")
        case .updated(let d):     print("~ \(formatDevice(d))")
        case .disappeared(let id):print("- \(id.prefix(8))")
        case .error(let msg):     FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
        }
    }
}

await service.start()

if args.watch {
    let stream = await service.subscribe()
    for await event in stream {
        emitEvent(event)
    }
} else {
    // One-shot: subscribe, drain initial replay + a short window for mDNS hits.
    let stream = await service.subscribe()
    let deadline = Date().addingTimeInterval(args.timeoutSeconds)
    let task = Task {
        for await event in stream {
            emitEvent(event)
            if case .error = event { continue }
        }
    }
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    task.cancel()
    await service.stop()
}
