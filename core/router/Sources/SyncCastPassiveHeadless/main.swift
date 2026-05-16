import CoreAudio
import Darwin
import Foundation
import SyncCastDiscovery
import SyncCastRouter

struct HeadlessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var targets: [String]
    var micToken: String?
    var socketPath: String
    var settleSeconds: Double
    var runSeconds: Double
    var allowDelayApply: Bool
    var listDevices: Bool
    var statusPath: String?

    static func parse(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Options {
        var targetsRaw = environment["SYNCAST_HEADLESS_TARGETS"]
            ?? environment["SYNCAST_AUTO_TEST"]
            ?? ""
        var micToken = environment["SYNCAST_HEADLESS_MIC"]
            ?? environment["SYNCAST_CALIBRATION_MIC_TOKEN"]
        var socketPath = environment["SYNCAST_HEADLESS_SOCKET"]
            ?? "/tmp/syncast-\(getuid()).calibration.sock"
        var settleSeconds = Self.double(environment["SYNCAST_HEADLESS_SETTLE_SECONDS"], default: 20)
        var runSeconds = Self.double(environment["SYNCAST_HEADLESS_RUN_SECONDS"], default: 3600)
        var allowDelayApply = Self.bool(environment["SYNCAST_HEADLESS_ALLOW_DELAY_APPLY"])
        var listDevices = false
        var statusPath = environment["SYNCAST_HEADLESS_STATUS_PATH"]

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--targets":
                index += 1
                guard index < arguments.count else { throw HeadlessError("--targets requires a value") }
                targetsRaw = arguments[index]
            case "--mic":
                index += 1
                guard index < arguments.count else { throw HeadlessError("--mic requires a value") }
                micToken = arguments[index]
            case "--socket":
                index += 1
                guard index < arguments.count else { throw HeadlessError("--socket requires a value") }
                socketPath = arguments[index]
            case "--settle-sec":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]), value > 0
                else { throw HeadlessError("--settle-sec requires a positive number") }
                settleSeconds = value
            case "--run-sec":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]), value > 0
                else { throw HeadlessError("--run-sec requires a positive number") }
                runSeconds = value
            case "--allow-delay-apply":
                allowDelayApply = true
            case "--list-devices":
                listDevices = true
            case "--status":
                index += 1
                guard index < arguments.count else { throw HeadlessError("--status requires a value") }
                statusPath = arguments[index]
            case "--help", "-h":
                throw HeadlessError(Self.usage)
            default:
                throw HeadlessError("unknown argument: \(arg)\n\(Self.usage)")
            }
            index += 1
        }

        let targets = targetsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !listDevices && targets.isEmpty {
            throw HeadlessError(
                "no targets supplied; set SYNCAST_HEADLESS_TARGETS=display,xiaomi or pass --targets"
            )
        }

        return Options(
            targets: targets,
            micToken: micToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            socketPath: socketPath,
            settleSeconds: settleSeconds,
            runSeconds: runSeconds,
            allowDelayApply: allowDelayApply,
            listDevices: listDevices,
            statusPath: statusPath?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        )
    }

    private static var usage: String {
        """
        Usage: SyncCastPassiveHeadless --targets display,xiaomi [--mic logitech]

        Environment:
          SYNCAST_CAPTURE_BACKEND=tap|sck
          SYNCAST_HEADLESS_TARGETS=display,xiaomi
          SYNCAST_HEADLESS_MIC=logitech
          SYNCAST_HEADLESS_SOCKET=/tmp/syncast-<uid>.calibration.sock
          SYNCAST_HEADLESS_RUN_SECONDS=3600
          SYNCAST_HEADLESS_STATUS_PATH=/tmp/syncast-headless-status.json
        """
    }

    private static func double(_ raw: String?, default fallback: Double) -> Double {
        guard let raw, let value = Double(raw), value > 0 else { return fallback }
        return value
    }

    private static func bool(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on": return true
        default: return false
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

final class HeadlessSidecarLauncher {
    struct Paths {
        let controlSocket: URL
        let audioSocket: URL
        let stateDir: URL
    }

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stderrTask: Task<Void, Never>?
    private(set) var paths: Paths

    init() {
        let uid = getuid()
        let control = URL(fileURLWithPath: "/tmp/syncast-\(uid).sock")
        let audio = URL(fileURLWithPath: "/tmp/syncast-\(uid).audio.sock")
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let stateDir = appSupport
            .appendingPathComponent("SyncCast", isDirectory: true)
            .appendingPathComponent("owntone", isDirectory: true)
        paths = Paths(controlSocket: control, audioSocket: audio, stateDir: stateDir)
    }

    @discardableResult
    func start() throws -> Paths {
        let bins = try resolveBinaries()
        for url in [paths.controlSocket, paths.audioSocket] {
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(
            at: paths.stateDir,
            withIntermediateDirectories: true
        )

        let proc = Process()
        proc.executableURL = bins.sidecar
        var args = [
            "--socket", paths.controlSocket.path,
            "--audio-socket", paths.audioSocket.path,
            "--state-dir", paths.stateDir.path,
            "--log-level", "info",
        ]
        if let owntone = bins.owntone {
            args += ["--owntone-binary", owntone.path]
        }
        if let template = bins.owntoneConfigTemplate {
            args += ["--owntone-config-template", template.path]
        }
        proc.arguments = args
        let err = Pipe()
        proc.standardError = err
        stderrPipe = err
        log("sidecar binary=\(bins.sidecar.path)")
        try proc.run()
        process = proc
        stderrTask = Task.detached { [err] in
            let handle = err.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                FileHandle.standardError.write(data)
            }
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: paths.controlSocket.path) {
                return paths
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HeadlessError("sidecar control socket did not appear at \(paths.controlSocket.path)")
    }

    func stop() {
        stderrTask?.cancel()
        stderrTask = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
    }

    deinit { stop() }

    private struct Binaries {
        let sidecar: URL
        let owntone: URL?
        let owntoneConfigTemplate: URL?
    }

    private func resolveBinaries() throws -> Binaries {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let explicitSidecar = env["SYNCAST_SIDECAR_BINARY"].map(URL.init(fileURLWithPath:))
        let explicitOwntone = env["SYNCAST_OWNTONE_BINARY"].map(URL.init(fileURLWithPath:))
        let explicitTemplate = env["SYNCAST_OWNTONE_CONFIG_TEMPLATE"].map(URL.init(fileURLWithPath:))

        let appResources = URL(fileURLWithPath: "/Applications/SyncCast.app/Contents/Resources")
        let installedSidecar = appResources.appendingPathComponent("sidecar/syncast-sidecar")
        let installedOwntone = appResources.appendingPathComponent("owntone/owntone")
        let installedTemplate = appResources.appendingPathComponent("owntone/owntone.conf.template")

        let home = FileManager.default.homeDirectoryForCurrentUser
        let devSidecar = home.appendingPathComponent("syncast/sidecar/dist-pyinstaller/syncast-sidecar")
        let devOwntone = home.appendingPathComponent("owntone_data/usr/sbin/owntone")

        let sidecarCandidates = [explicitSidecar, installedSidecar, devSidecar].compactMap { $0 }
        guard let sidecar = sidecarCandidates.first(where: {
            fm.isExecutableFile(atPath: $0.path)
        }) else {
            throw HeadlessError("syncast-sidecar binary not found")
        }

        let owntoneCandidates = [explicitOwntone, installedOwntone, devOwntone].compactMap { $0 }
        let owntone = owntoneCandidates.first(where: {
            fm.isExecutableFile(atPath: $0.path)
        })
        let templateCandidates = [explicitTemplate, installedTemplate].compactMap { $0 }
        let template = templateCandidates.first(where: {
            fm.fileExists(atPath: $0.path)
        })
        return Binaries(sidecar: sidecar, owntone: owntone, owntoneConfigTemplate: template)
    }
}

actor HeadlessDeviceState {
    private var devicesByID: [String: Device] = [:]
    private var routing: [String: DeviceRouting] = [:]
    private var discoveryErrors: [String] = []
    private var microphoneDeviceID: AudioDeviceID?
    private var currentDelayMs: Int = 1750
    private var syncContextRevision: UInt64 = 1
    private let syncContextUpdatedUnix = Date().timeIntervalSince1970

    func ingest(_ event: DiscoveryEvent) {
        switch event {
        case .appeared(let device), .updated(let device):
            devicesByID[device.id] = device
        case .disappeared(let deviceID):
            devicesByID.removeValue(forKey: deviceID)
            routing.removeValue(forKey: deviceID)
        case .error(let message):
            discoveryErrors.append(message)
            if discoveryErrors.count > 16 {
                discoveryErrors.removeFirst(discoveryErrors.count - 16)
            }
            log("discovery error: \(message)")
        }
    }

    func devices() -> [Device] {
        devicesByID.values.sorted { $0.name < $1.name }
    }

    func errors() -> [String] {
        discoveryErrors
    }

    func configure(selected: [Device], microphoneDeviceID: AudioDeviceID?) {
        let selectedIDs = Set(selected.map(\.id))
        for device in devicesByID.values {
            routing[device.id] = DeviceRouting(
                deviceID: device.id,
                enabled: selectedIDs.contains(device.id),
                volume: 1.0,
                muted: false,
                manualDelayMs: 0
            )
        }
        self.microphoneDeviceID = microphoneDeviceID
        syncContextRevision &+= 1
    }

    func route(for deviceID: String) -> DeviceRouting? {
        routing[deviceID]
    }

    func resolveTargets(tokens: [String]) -> (selected: [Device], missing: [String]) {
        var selected: [Device] = []
        var missing: [String] = []
        var used = Set<String>()
        let candidates = devices()

        for rawToken in tokens {
            let token = TargetToken(rawToken)
            if let match = candidates.first(where: { device in
                !used.contains(device.id) && token.matches(device)
            }) {
                selected.append(match)
                used.insert(match.id)
            } else {
                missing.append(rawToken)
            }
        }
        return (selected, missing)
    }

    func diagnosticSnapshot(router: Router) async -> CalibrationDiagnosticServer.Snapshot? {
        let all = devices()
        let enabled = all.filter { routing[$0.id]?.enabled == true }
        let enabledAirPlay = enabled.filter { $0.transport == .airplay2 }
        guard enabled.contains(where: { $0.transport == .coreAudio }),
              !enabledAirPlay.isEmpty
        else {
            return nil
        }

        let routerStates = await router.connectionStatesSnapshot()
        let activeAirPlay = enabledAirPlay.filter {
            routerStates.states[$0.id] == .connected
        }
        let airplayConnectionStates = Dictionary(
            uniqueKeysWithValues: enabledAirPlay.map {
                ($0.id, (routerStates.states[$0.id] ?? .unknown).rawValue)
            }
        )
        if let reportedDelay = await router.localFifoCurrentDelayMsForDiagnostics() {
            currentDelayMs = reportedDelay
        }
        let epoch = await router.airplayTimingEpochForDiagnostics()
        return CalibrationDiagnosticServer.Snapshot(
            devices: all,
            microphoneDeviceID: microphoneDeviceID,
            currentDelayMs: currentDelayMs,
            contextSignature: contextSignature(enabled: enabled),
            delayLocked: false,
            enabledAirplayCount: enabledAirPlay.count,
            activeAirplayCount: activeAirPlay.count,
            airplayTimingEpoch: epoch,
            airplayConnectionStates: airplayConnectionStates,
            syncContextState: "suspect",
            syncContextReason: "headless whole-home route started; passive baseline required",
            syncContextRevision: syncContextRevision,
            syncContextUpdatedUnix: syncContextUpdatedUnix
        )
    }

    private func contextSignature(enabled: [Device]) -> String {
        let rows = enabled.map { device -> String in
            let route = routing[device.id] ?? DeviceRouting(deviceID: device.id, enabled: false)
            let volumeBucket = Int((route.volume * 100).rounded())
            return [
                device.id,
                device.transport.rawValue,
                "v\(volumeBucket)",
                "m\(route.muted ? 1 : 0)",
                "d\(route.manualDelayMs)",
            ].joined(separator: ":")
        }
        .sorted()
        .joined(separator: ";")
        return "mode=whole_home|mic=\(microphoneDeviceID.map(String.init) ?? "default")|enabled=\(rows)"
    }
}

struct HeadlessStatusReporter {
    let path: URL?
    private var fields: [String: Any] = [:]

    init(path: String?) {
        self.path = path.map(URL.init(fileURLWithPath:))
    }

    mutating func update(_ values: [String: Any]) {
        guard let path else { return }
        for (key, value) in values {
            fields[key] = value
        }
        fields["schema"] = "syncast.passive_headless_status.v1"
        fields["updatedUnix"] = Date().timeIntervalSince1970
        do {
            let data = try JSONSerialization.data(
                withJSONObject: fields,
                options: [.prettyPrinted, .sortedKeys]
            )
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
        } catch {
            log("status write failed: \(error)")
        }
    }
}

struct TargetToken {
    let transport: Transport?
    let needle: String

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            switch parts[0].lowercased() {
            case "local", "coreaudio", "core_audio":
                transport = .coreAudio
                needle = parts[1].lowercased()
            case "airplay", "airplay2":
                transport = .airplay2
                needle = parts[1].lowercased()
            default:
                transport = nil
                needle = trimmed.lowercased()
            }
        } else {
            transport = nil
            needle = trimmed.lowercased()
        }
    }

    func matches(_ device: Device) -> Bool {
        if let transport, device.transport != transport { return false }
        let name = device.name.lowercased()
        let model = device.model?.lowercased() ?? ""
        let uid = device.coreAudioUID?.lowercased() ?? ""
        switch needle {
        case "mbp", "macbook":
            return device.transport == .coreAudio && name.contains("macbook")
        case "display", "monitor":
            return device.transport == .coreAudio
                && (name.contains("display") || name.contains("monitor") || name.contains("pg27"))
        case "xiaomi":
            return name.contains("xiaomi") || model.contains("xiaomi")
        default:
            return name.contains(needle) || model.contains(needle) || uid.contains(needle)
        }
    }
}

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum InputDeviceResolver {
    static func resolve(token: String?) -> AudioDeviceID? {
        guard let token, !token.isEmpty else { return nil }
        let needle = token.lowercased()
        let devices = enumerate()
        if let match = devices.first(where: {
            $0.name.lowercased().contains(needle) || $0.uid.lowercased().contains(needle)
        }) {
            log("selected microphone \(match.name) id=\(match.id)")
            return match.id
        }
        log("microphone token '\(token)' did not match; using system default input")
        return nil
    }

    private static func enumerate() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard isInputCapable(id) else { return nil }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Input \(id)"
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func isInputCapable(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else {
            return false
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, buffer) == noErr
        else {
            return false
        }
        let abl = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels } > 0
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}

actor StopFlag {
    private var requested = false
    func stop() { requested = true }
    func isRequested() -> Bool { requested }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[SyncCastPassiveHeadless] \(message)\n".utf8))
}

func sleepSeconds(_ seconds: Double) async throws {
    let clamped = max(0.001, min(seconds, 24 * 60 * 60))
    try await Task.sleep(nanoseconds: UInt64((clamped * 1_000_000_000).rounded()))
}

func deviceSummary(_ device: Device) -> String {
    var parts = ["\(device.name) [\(device.transport.rawValue)]"]
    if let uid = device.coreAudioUID, !uid.isEmpty {
        parts.append("uid=\(uid)")
    }
    if let host = device.host, !host.isEmpty {
        parts.append("host=\(host)")
    }
    return parts.joined(separator: " ")
}

func deviceRecord(_ device: Device) -> [String: Any] {
    var record: [String: Any] = [
        "id": device.id,
        "transport": device.transport.rawValue,
        "name": device.name,
        "isOutputCapable": device.isOutputCapable,
        "supportsHardwareVolume": device.supportsHardwareVolume,
    ]
    if let model = device.model { record["model"] = model }
    if let host = device.host { record["host"] = host }
    if let port = device.port { record["port"] = port }
    if let uid = device.coreAudioUID { record["coreAudioUID"] = uid }
    if let rate = device.nominalSampleRate { record["nominalSampleRate"] = rate }
    return record
}

func waitForTargets(
    state: HeadlessDeviceState,
    tokens: [String],
    timeout: Double
) async throws -> [Device] {
    let deadline = Date().addingTimeInterval(timeout)
    var lastMissing: [String] = tokens
    while Date() < deadline {
        let resolved = await state.resolveTargets(tokens: tokens)
        lastMissing = resolved.missing
        let hasLocal = resolved.selected.contains { $0.transport == .coreAudio }
        let hasAirPlay = resolved.selected.contains { $0.transport == .airplay2 }
        if lastMissing.isEmpty, hasLocal, hasAirPlay {
            return resolved.selected
        }
        try await sleepSeconds(0.5)
    }
    let devices = await state.devices()
    let seen = devices.map { "\($0.name) [\($0.transport.rawValue)]" }.joined(separator: ", ")
    throw HeadlessError(
        "timed out waiting for targets \(tokens.joined(separator: ",")); "
        + "missing=\(lastMissing.joined(separator: ",")); seen=\(seen)"
    )
}

func installSignalHandlers(flag: StopFlag) -> [DispatchSourceSignal] {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    return [SIGINT, SIGTERM].map { sig in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            Task { await flag.stop() }
        }
        source.resume()
        return source
    }
}

@main
struct SyncCastPassiveHeadlessMain {
    static func main() async {
        do {
            try await run()
            Darwin.exit(0)
        } catch {
            log("ERROR: \(error)")
            Darwin.exit(1)
        }
    }

    private static func run() async throws {
        let options = try Options.parse()
        var status = HeadlessStatusReporter(path: options.statusPath)
        let captureBackend = ProcessInfo.processInfo.environment["SYNCAST_CAPTURE_BACKEND"]
        var startingStatus: [String: Any] = [
            "stage": "starting",
            "targets": options.targets,
            "socketPath": options.socketPath,
            "settleSeconds": options.settleSeconds,
            "runSeconds": options.runSeconds,
            "emitsAudio": false,
            "opensMicrophone": false,
            "appliesDelay": false,
        ]
        if let captureBackend {
            startingStatus["captureBackend"] = captureBackend
        }
        status.update(startingStatus)
        log("active acoustic diagnostics disabled; passive no-probe runner starting")
        if let backend = captureBackend {
            log("capture backend requested: \(backend)")
        }

        let directCoreAudioDevices = CoreAudioDiscovery().enumerate()
        status.update([
            "stage": "direct_coreaudio_enumerated",
            "directCoreAudioOutputCount": directCoreAudioDevices.count,
            "directCoreAudioOutputs": directCoreAudioDevices.map(deviceRecord),
        ])
        if directCoreAudioDevices.isEmpty {
            log("direct CoreAudio enumerate returned 0 output devices")
        } else {
            log(
                "direct CoreAudio enumerate returned \(directCoreAudioDevices.count) output device(s): "
                    + directCoreAudioDevices.map(deviceSummary).joined(separator: ", ")
            )
        }

        let state = HeadlessDeviceState()
        let discovery = DiscoveryService()
        await discovery.start()
        let stream = await discovery.subscribe()
        let discoveryTask = Task {
            for await event in stream {
                await state.ingest(event)
            }
        }
        defer {
            discoveryTask.cancel()
            Task { await discovery.stop() }
        }

        try await sleepSeconds(options.listDevices ? options.settleSeconds : 1.0)
        let initialDevices = await state.devices()
        let initialErrors = await state.errors()
        status.update([
            "stage": "discovery_settled",
            "discoveredDeviceCount": initialDevices.count,
            "discoveredDevices": initialDevices.map(deviceRecord),
            "discoveryErrors": initialErrors,
        ])
        if options.listDevices {
            log(
                "discovery list after \(String(format: "%.1f", options.settleSeconds))s: "
                    + "\(initialDevices.count) device(s)"
            )
            for device in initialDevices {
                print("\(device.transport.rawValue)\t\(device.name)\t\(device.id)")
            }
            status.update(["stage": "listed_devices"])
            return
        }

        let selected: [Device]
        do {
            selected = try await waitForTargets(
                state: state,
                tokens: options.targets,
                timeout: options.settleSeconds
            )
        } catch {
            let devices = await state.devices()
            let resolved = await state.resolveTargets(tokens: options.targets)
            status.update([
                "stage": "targets_failed",
                "error": String(describing: error),
                "missingTargets": resolved.missing,
                "selectedDevices": resolved.selected.map(deviceRecord),
                "discoveredDeviceCount": devices.count,
                "discoveredDevices": devices.map(deviceRecord),
                "discoveryErrors": await state.errors(),
            ])
            throw error
        }
        let micID = InputDeviceResolver.resolve(token: options.micToken)
        await state.configure(selected: selected, microphoneDeviceID: micID)
        var selectedStatus: [String: Any] = [
            "stage": "targets_selected",
            "selectedDevices": selected.map(deviceRecord),
        ]
        if let micID {
            selectedStatus["microphoneDeviceID"] = Int(micID)
        }
        status.update(selectedStatus)
        log("selected outputs: \(selected.map { "\($0.name) [\($0.transport.rawValue)]" }.joined(separator: ", "))")

        let sidecar = HeadlessSidecarLauncher()
        let router = Router()
        let stopFlag = StopFlag()
        let signalSources = installSignalHandlers(flag: stopFlag)
        _ = signalSources

        let paths = try sidecar.start()
        status.update([
            "stage": "sidecar_started",
            "sidecarControlSocket": paths.controlSocket.path,
            "sidecarAudioSocket": paths.audioSocket.path,
        ])
        defer { sidecar.stop() }

        var attachError: Error?
        for attempt in 0..<10 {
            do {
                try await router.attachSidecar(.init(control: paths.controlSocket, audio: paths.audioSocket))
                attachError = nil
                break
            } catch {
                attachError = error
                try await Task.sleep(nanoseconds: UInt64(200_000_000) << UInt64(min(attempt, 4)))
            }
        }
        if let attachError { throw attachError }
        status.update(["stage": "sidecar_attached"])

        let devices = await state.devices()
        for device in devices {
            if let route = await state.route(for: device.id) {
                await router.setRouting(route)
                if route.enabled {
                    await router.enable(deviceID: device.id)
                } else {
                    await router.disable(deviceID: device.id)
                }
            }
        }

        await router.setMode(.wholeHome)
        let selectedAirPlay = selected.filter { $0.transport == .airplay2 }
        for device in selectedAirPlay {
            await router.registerAirplayDevice(
                id: device.id,
                name: device.name,
                host: device.host ?? "",
                port: device.port ?? 7000
            )
            await router.setAirplayVolume(id: device.id, volume: 1.0)
        }
        await router.setActiveAirplayDevices(selectedAirPlay.map(\.id))

        try await router.start(devices: devices)
        await router.startWholeHome(devices: devices)
        status.update(["stage": "router_started"])
        await router.startCalibrationDiagnosticServer(
            socketPath: URL(fileURLWithPath: options.socketPath),
            provider: {
                await state.diagnosticSnapshot(router: router)
            },
            activeProbeMethodsEnabled: false,
            delayApplier: { ms in
                guard options.allowDelayApply else {
                    throw HeadlessError(
                        "headless runner started without SYNCAST_HEADLESS_ALLOW_DELAY_APPLY=1"
                    )
                }
                return try await router.setLocalFifoDelayMs(ms)
            }
        )
        status.update([
            "stage": "diagnostic_socket_ready",
            "diagnosticSocket": options.socketPath,
        ])
        log("diagnostic socket ready at \(options.socketPath)")
        log("runner emits no probe audio; keep real program audio playing for passive_capture")

        let deadline = Date().addingTimeInterval(options.runSeconds)
        while Date() < deadline {
            if await stopFlag.isRequested() { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        await router.setActiveAirplayDevices([])
        await router.stop()
        status.update(["stage": "stopped"])
        log("stopped")
    }
}
