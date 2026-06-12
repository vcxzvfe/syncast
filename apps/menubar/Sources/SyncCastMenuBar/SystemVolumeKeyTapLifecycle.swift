/// Pure stop/start state machine for the CGEventTap thread lifecycle in
/// `SystemVolumeKeyController`.
///
/// Why this exists: `stopTapThread()` and the tap thread race in windows
/// that a bare `CFRunLoopStop` cannot close —
///
///   1. A stop lands after `thread.start()` but before the thread has
///      published its run loop. There is nothing to `CFRunLoopStop`, so
///      the thread would enter `CFRunLoopRun` with nobody left to stop
///      it: a session-level CONSUMING event tap leaked until logout, and
///      the stale `machPort` would short-circuit every later
///      `startTapThread` ("already installed") — media keys dead for the
///      whole session.
///   2. A quick stop→start pair spawns a new thread while the old one is
///      still pre-publication. The old thread must not publish (two live
///      taps) and its teardown must never wipe the successor's handles.
///
/// Every transition is a pure function over `State`. The controller runs
/// them inside its `tapHandles` lock, so the rules asserted by the unit
/// tests are exactly the rules the runtime obeys — no CoreGraphics
/// needed to test the race windows.
enum SystemVolumeKeyTapLifecycle {
    struct State: Equatable {
        /// A tap thread has published its mach port + run loop handles.
        var installed = false
        /// `stopTapThread` ran after the most recent accepted start.
        var stopRequested = false
        /// Bumped by every accepted start. A tap thread may only publish
        /// (or clear handles at teardown) while its own generation is
        /// still current — a superseded thread discards its tap instead.
        var generation: UInt64 = 0
    }

    struct StartDecision: Equatable {
        let state: State
        /// False when a published tap still exists (possibly mid-teardown
        /// after a stop); the caller must not spawn a second thread.
        let shouldSpawnThread: Bool
        /// The generation the spawned thread must carry into
        /// `resolveInstall` / `finishTeardown`.
        let threadGeneration: UInt64
    }

    /// `startTapThread`: refuse while a tap is still installed; otherwise
    /// bump the generation (invalidating any pre-publication thread from
    /// an earlier start) and clear a stale stop request so the new thread
    /// is not killed by history.
    static func beginStart(_ state: State) -> StartDecision {
        guard !state.installed else {
            return StartDecision(
                state: state,
                shouldSpawnThread: false,
                threadGeneration: state.generation
            )
        }
        var next = state
        next.generation &+= 1
        next.stopRequested = false
        return StartDecision(
            state: next,
            shouldSpawnThread: true,
            threadGeneration: next.generation
        )
    }

    /// `stopTapThread`: record the request. The caller additionally
    /// queues a stop block on the published run loop, if one exists; a
    /// thread that has not published yet observes `stopRequested` in
    /// `resolveInstall` instead.
    static func requestStop(_ state: State) -> State {
        var next = state
        next.stopRequested = true
        return next
    }

    /// Tap thread, after `CGEvent.tapCreate` succeeded: publish only if
    /// no stop raced in and no newer start superseded this thread.
    /// `shouldPublish == false` ⇒ the thread must disable + invalidate
    /// its tap and exit WITHOUT entering `CFRunLoopRun`.
    static func resolveInstall(
        _ state: State,
        threadGeneration: UInt64
    ) -> (state: State, shouldPublish: Bool) {
        guard !state.stopRequested,
              state.generation == threadGeneration
        else {
            return (state, false)
        }
        var next = state
        next.installed = true
        return (next, true)
    }

    /// Tap thread teardown after `CFRunLoopRun` exits: clear `installed`
    /// (and the caller clears the CF handles) only if this thread's
    /// publication is still the current one — a restarted lifecycle's
    /// successor handles must survive a stale thread's teardown.
    static func finishTeardown(
        _ state: State,
        threadGeneration: UInt64
    ) -> (state: State, shouldClearHandles: Bool) {
        guard state.generation == threadGeneration else {
            return (state, false)
        }
        var next = state
        next.installed = false
        return (next, true)
    }
}
