# LAN receiver rows get the same four controls as local outputs (2026-09-06)

## Problem

A LAN receiver row showed only the channel-assignment button. The equalizer,
stereo-image and delay-trim controls were gated on the device having a
CoreAudio UID, which a LAN receiver does not have; the channel-matrix gate had
its own transport-aware lookup, so it alone appeared. The equalizer editor's
target-based setters used the same CoreAudio-only lookup, so once the sliders
were made visible they rendered but every write was dropped and they sat at
0.0.

Meanwhile the LAN leg had no way to be moved later against the local legs.
The local legs are held to the receiver's schedule automatically
(`LanAlignmentPlanner`), and the per-pair delay trim normalises to the
earliest local pair, so a listener who hears the receiver early — because a
display panel adds latency it never declares, say — had no control that could
fix it.

## Design

* `AppModel.dspUID(forDeviceID:)` is the one key for every per-output DSP
  setting: CoreAudio UID for a CoreAudio device, `Device.lanReceiverUID` for
  a LAN receiver, nil for AirPlay (one stream fans out to all of them, so a
  per-receiver setting is not expressible; they have the group EQ). The
  equalizer, stereo-image, channel-matrix and delay-trim gates and setters all
  resolve through it. The Router already keyed all of these by the same
  string, so nothing changed on its side for the first three.
* Delay trim on a LAN row is a **presentation trim**: `LanReceiverOutput`
  adds it to every `play_at_ns`, so the receiver alone moves later. It is
  clamped to 0…+100 ms — a LAN leg can only be delayed; "earlier" is
  expressed by trimming the local legs instead, which the existing control
  does. It shares the local trim store and the local trim control, keyed by
  the receiver's UID, and is re-pushed whenever the trim map changes.
* The local alignment hold deliberately does NOT include the trim: the hold
  aligns the local set to the receiver's schedule, the trim moves the receiver
  off that schedule by the amount the listener asked for.

## Verified

* Unit tests: availability and setters on a LAN row (`LanReceiverDspAvailabilityTests`),
  the trim's non-negative clamp, and an end-to-end loopback test that a 30 ms
  trim steps the receiver's playout grid by exactly 5 + 30 ms once and never
  runs it backwards (`LanReceiverOutputTests`).
* On real hardware the three buttons appear on the LAN row and the curve is
  remembered per receiver.

## Known limits

* A negative LAN trim is not representable; delay the local legs instead.
* A raised effective target on the receiver (`extra` in its stats) is not
  yet reflected in the local hold.
