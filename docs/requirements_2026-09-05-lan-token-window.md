# LAN token window crash + LAN-only start — 2026-09-05

Two defects found while enabling a LAN receiver on macOS 26.6.2. They are
unrelated in mechanism and related in symptom: between them, a user who owned
exactly one LAN receiver and nothing else could not use it at all.

## Problem 1 — the app aborted when the token window was presented

Enabling a LAN receiver row and opening the pairing-token window killed the
process with `SIGABRT`: an uncaught Objective-C exception on the main thread.

The exception's own backtrace ended at

```
+[NSException exceptionWithName:reason:userInfo:]
-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]
-[NSView _informContainerThatSubviewsNeedUpdateConstraints]
-[NSView setNeedsUpdateConstraints:]
SwiftUI NSHostingView.setNeedsUpdate()
SwiftUI NSHostingView.requestUpdate(after:)
SwiftUI NSHostingView.invalidateSafeAreaCornerInsets()
SwiftUI @objc NSHostingView.didChangeValue(forKey:)
```

and the crashing thread was inside
`NSDisplayCycleFlush → NSDisplayCycleObserverInvoke →
__NSWindowGetDisplayCycleObserverForLayout_block_invoke`.

Read together: a SwiftUI hosting view asked AppKit for a constraints update
*while a display cycle's layout observer was running*, and AppKit refuses that
— it raises rather than corrupting the layout pass it is in the middle of.

Two things in `LanTokenWindowController` fed it.

**1. The window was created and ordered front synchronously.** The presenter
ran on the stack of the SwiftUI action that had just mutated observable model
state:

```swift
func presentLanTokenWindow(for deviceID: String) {
    lanTokenEditorDeviceID = deviceID          // observable mutation
    ...
    controller.present()                       // → NSWindow + makeKeyAndOrderFront
}
```

A new `NSWindow` joins the display cycle as soon as it has a content view, so
one created inside a flush that is already running can be picked up by that
same flush. `NSApp.activate(ignoringOtherApps:)` and `makeKeyAndOrderFront`
then change key status, which makes AppKit broadcast KVO changes to hosting
views — the `didChangeValue(forKey:)` frame in the trace.

`PairingWindowController` does the same thing and does not crash, which is why
the difference matters: it is presented from a plain button action in a row
that is not simultaneously being rebuilt, whereas the token window is opened
from a control that appears as a *result* of the row's own state change.

**2. The style mask was mutated after the hosting view was installed.**

```swift
let window = NSWindow(contentViewController: NSHostingController(rootView: root))
window.styleMask = [.titled, .closable]
```

`NSWindow(contentViewController:)` defaults to
`[.titled, .closable, .miniaturizable, .resizable]`. Assigning a narrower mask
drops `.resizable`, which rebuilds the window's theme frame — and a theme-frame
rebuild is exactly what makes AppKit recompute corner/safe-area insets and the
hosting view call `invalidateSafeAreaCornerInsets()`. That is the top frame of
the exception backtrace, on a window whose hosting view was already installed.

A third, smaller contributor: the root view rendered a 1-pt `Color.clear`
placeholder whenever no receiver was selected, so the window opened tiny and
resized itself one SwiftUI update later — a window resize driven from inside a
SwiftUI update is more of the same constraint traffic.

### Fix

- `present()` and `dismiss()` do no AppKit work on the caller's stack. Both hop
  to the next main-queue turn (`DispatchQueue.main.async`), by which point the
  display cycle and the SwiftUI transaction that provoked it have unwound.
- Both are idempotent while a hop is in flight, so a double click on the row's
  button cannot schedule two presentations (or two `NSApp.activate` calls), and
  a `present()` that arrives while a close is pending cancels the close instead
  of losing the window to it.
- The window is built once, in its final shape: `NSWindow(contentRect:
  styleMask: [.titled, .closable], backing: .buffered, defer: false)`, with
  title, level, collection behaviour, restorability and delegate all set
  BEFORE the hosting view is assigned to `contentView`. Nothing re-styles the
  window afterwards.
- The hosting view gets an explicit initial frame and
  `sizingOptions = [.standardBounds]`. Not `.preferredContentSize`: that
  forwards the SwiftUI ideal size to the hosting view's *enclosing view
  controller*, and this window deliberately has none — the hosting view is the
  content view directly, which is what keeps an `NSHostingController` from
  re-styling the window. `.standardBounds` (min ∪ intrinsic ∪ max) is what
  makes the window adopt and keep the form's own size.
- The empty state renders the same form, disabled, instead of a 1-pt
  placeholder, so the window never resizes between "opening" and "open".
- No exception is caught anywhere. An Objective-C exception through Swift
  frames is unrecoverable; the fix is not to raise it.

## Problem 2 — enabling only the LAN receiver refused to start

With a LAN receiver as the sole enabled output, `Router.start` failed:

```
router.start FAILED: Error Domain=SyncCastRouter Code=112
  "system sink is the default output but no local output could be opened"
```

followed by a clean sink restore, so the user got no audio and no explanation
that made sense — the receiver was discovered, tokened and ready.

The check was literal:

```swift
guard !localOutputs.isEmpty else { throw … 112 … }
```

`localOutputs` holds CoreAudio AUHALs only. A `LanReceiverOutput` reads the
same tap ring and ends in a loudspeaker on another machine; it is an output by
every definition that matters here, and it was not counted.

### Fix

`SystemSinkOutputPolicy.hasRenderableOutput(localOutputCount:
lanReceiverLegCount:)` — a pure predicate with its own tests. The sink path
fails only when there is neither a CoreAudio output nor an open LAN leg, which
is still the case the guard exists for: the sink is already the system default
and nothing is rendering it, so the start must unwind and give the default
output back.

"Open LAN leg" is the right count rather than "enabled LAN row":
`reconcileLanReceivers` opens nothing for a receiver with no token yet, so an
untokened receiver contributes zero and the path correctly refuses to run.

The failure message now says "no CoreAudio output and no LAN receiver leg",
because the old wording sent readers looking for a CoreAudio problem that was
not there.

Nothing else in the sink path needed changing for a zero-AUHAL configuration:

- The LAN legs already take their ring from `activeCapture`, which resolves to
  the pinned Process Tap because `sinkCapture` is assigned before
  `reconcileLanReceivers` runs.
- `ringFloorFrames` keys on which producer is feeding the ring (tap vs
  ScreenCaptureKit), not on how many AUHALs are open.
- `lanAlignmentHoldFrames` / `lanTotalLagMs` read the largest *local device*
  latency out of the delay-trim seeds, which is `0` when no local device is
  open — the honest answer, and the one that makes the alignment reduce to the
  receiver's own target.
- `replan`, `applySystemSinkVolumes` and `applyLocalPairDelays` all iterate
  `localOutputs` and are no-ops over an empty one.

A failed `start` now also tears the LAN legs down, alongside the local driver:
they are opened by the same reconcile, and a leg left running would be reading
a ring whose producer is about to stop.

## What was verified

- `swift build` + `swift test` in `core/router`: 399 XCTest cases + 11 Swift
  Testing cases, 0 failures. Includes the 8 new
  `SystemSinkOutputPolicyTests`.
- `swift build` + `swift test` in `apps/menubar`: 338 cases, 0 failures (1
  skipped — see below). Includes 9 new `LanTokenWindowControllerTests` and 3
  `UiSmokeHookTests`.
- The on-screen smoke test (`SYNCAST_UI_SMOKE=token swift test --filter
  LanTokenWindowControllerTests`) builds the window in its production shape,
  orders it front, drives it through two display cycles with a model mutation
  in between, and closes it. Passes; no exception.

## What was NOT verified

The original crash reproduction is a window-server behaviour: it needs a real
menu-bar panel, a real click on the row's button, and the app running as an
`LSUIElement` accessory. `swift test` cannot stage that. The unit tests pin the
two properties that make the crash impossible (nothing AppKit happens on the
caller's stack; the window is never re-styled after the hosting view is in),
and the on-screen smoke test proves the window shape itself lays out cleanly,
but the end-to-end "click the row's button in the real app" path is a human
verification step.

`SYNCAST_UI_SMOKE=token` exists for that. Launched with it set, the app opens
the token window ~3 s after bootstrap — targeting a discovered receiver if
there is one, a placeholder id otherwise — so the presentation path can be
exercised without anyone clicking through the popover. Dev only, off unless the
variable is set, and inert under XCTest.

Problem 2's fix is likewise verified by a unit test on the predicate and by
reading the code paths a zero-AUHAL sink start touches; the audible end of it
(a LAN receiver playing as the sole output) needs a second machine running the
receiver daemon.

## Known gaps

- `Router.replan()` gives every enabled device that has no `LocalOutput` an
  AirPlay latency entry (~1.8 s), which now includes enabled LAN receivers.
  It is harmless — `LocalOutput._readBackoffFrames` is diagnostic only and does
  not move the render cursor, and LAN alignment comes from
  `LanAlignmentPlanner` instead — but the diagnostic number it produces for a
  LAN row is meaningless. Left alone rather than changed under a crash fix.
