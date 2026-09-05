import Foundation

/// Where `SyncCastRouter`'s diagnostics go.
///
/// # Why this exists
///
/// Every module in this package used to write its diagnostics with
/// `FileHandle.standardError.write(...)`. That works for `swift test`, for the
/// probes and for a Router driven from a terminal — and it is a black hole for
/// the installed `SyncCast.app`, whose stderr is detached by `open(1)`/launchd.
///
/// Measured on 2026-09-05: a headless system-sink run stalled for 108 s inside
/// `Router.start` and left **no trace at all** in
/// `~/Library/Logs/SyncCast/launch.log` — every line the Router wrote about
/// what it was doing went to a closed file descriptor. Diagnosing it needed a
/// second run under a terminal, which is exactly the run that does not
/// reproduce a user's environment.
///
/// So the router writes through this indirection instead. Unset (the default —
/// tests, probes, CLI) it falls back to stderr and nothing changes. The
/// menubar app sets `sink` at startup to `SyncCastLog.log`, so the same lines
/// land in `launch.log` next to the app's own.
///
/// # Threading
///
/// `write` never blocks its caller: the formatted line is handed to a serial
/// utility queue, which is also what serialises concurrent writers into
/// non-interleaved lines. Callers include CoreAudio delegate queues and the
/// DDC state lock, and the app's own `SyncCastLog.log` opens and closes the
/// log file synchronously per line — doing that on a HAL callback thread is
/// the kind of thing that turns a slow disk into an audio dropout.
///
/// The cost of that choice is that a line is not guaranteed to be on disk the
/// instant `write` returns. `flush()` closes that gap where it matters (tests,
/// and anywhere a caller is about to do something that may hang).
public enum RouterLog {
    /// A destination for one already-formatted line (no trailing newline).
    public typealias Sink = @Sendable (String) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _sink: Sink?
    private static let queue = DispatchQueue(
        label: "io.syncast.router.log", qos: .utility
    )

    /// Install a destination for the router's diagnostics, or `nil` to go back
    /// to stderr. Set once at app startup; safe to read/write from any thread.
    public static var sink: Sink? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    /// Log one diagnostic line.
    ///
    /// The message may or may not end in a newline — callers historically
    /// wrote `"...\n"` for stderr. It is normalised either way: the sink gets
    /// the line WITHOUT a trailing newline (a line-oriented logger adds its
    /// own), stderr gets exactly one.
    public static func write(_ message: String) {
        let line = message.hasSuffix("\n") ? String(message.dropLast()) : message
        guard !line.isEmpty else { return }
        let destination = sink
        queue.async {
            if let destination {
                destination(line)
            } else {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
    }

    /// Block until everything written so far has reached the destination.
    ///
    /// Used by tests, and worth calling before an operation that might hang:
    /// an asynchronously queued "starting phase X" line is no use if the
    /// process never gets back to the queue.
    public static func flush() {
        queue.sync {}
    }
}
