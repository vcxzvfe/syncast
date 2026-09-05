# LAN link robustness — the sender half

Follow-up to `requirements_2026-09-05-lan-receiver.md`, written after the first
test between two machines.

## The problem

The receiver ran under launchd on a second Mac. Bonjour discovery worked and
the receiver appeared in the popover. The sender logged

```
LAN leg opened … target=90ms
```

and then nothing at all for over ten minutes. The row showed `rtt:- off:- buf:-`
for the whole time.

The cause was outside this repository: the second Mac's Application Firewall
was blocking the (unsigned, ad-hoc-signed) daemon, and the "allow incoming
connections?" dialog had never been answered because nobody was at that
keyboard. What matters here is the SHAPE of that failure:

* the firewall adjudicates **after** the kernel completes the TCP handshake, so
  the sender's connect genuinely succeeded and `nc -z` genuinely reported the
  port open;
* the daemon behind it never saw the connection, so no `hello_ack` came back;
* nothing in the link had a deadline, and nothing logged a transition.

From the sender's side "connected and waiting" and "playing" were
indistinguishable, in the log and in the UI.

## What changed

### Deadlines

| | value | what it catches |
| --- | --- | --- |
| `LanReceiverLink.connectTimeoutSeconds` | 8 s | a control connection that never reaches `.ready` — Network framework will otherwise stay in `waiting` indefinitely on a host that does not answer |
| `LanReceiverLink.helloAckTimeoutSeconds` | 5 s | a connection that DOES reach `.ready` and is then never answered — the firewall case, and also a wrong token on a receiver that closes without saying so |

Both tear the connection down and go through the normal capped backoff, so a
receiver that comes back (the user answers the prompt, or fixes the token)
reconnects within seconds. The hello_ack deadline is the shorter of the two on
purpose: it is the more common fault and should be the one the user hears about
first. Its failure message names both plausible causes, because from here they
cannot be told apart.

Both are injectable at `init` so the state-machine tests run in about a second
instead of thirteen; production always uses the two statics.

### Diagnostics

Every control-channel transition now goes to `RouterLog` behind the
`[LAN] <uid>:` prefix: `preparing`, `waiting(<reason>)`, `ready (host …)`,
`hello sent`, `hello_ack received (…)`, `audio socket ready`, `cancelled`,
`failed: <reason>`, and each reconnect with its backoff. Repeated identical
`waiting` reasons are rate-limited to one per 30 s — a receiver that is off for
the evening otherwise fills the log with the same line — while a *different*
reason is always logged immediately, since a change from "no route" to
"connection refused" is the interesting event.

### A stage, not just an error string

`LanLinkSnapshot` gained `stage` (`idle` / `connecting` / `handshaking` /
`streaming` / `retrying`) and `connectedForSeconds`. The UI needs the stage
because "connecting" and "connected but unanswered" produce the same empty
readout otherwise. `AppModel.lanLinkSummary` now renders per stage and never
returns nothing once a link exists; a stalled handshake reads as
"等待接收端响应（检查对方防火墙/令牌）" with how long it has been sitting there.

### A bug found while testing this

Cancelling an `NWConnection` completes its outstanding `receive` with
`isComplete`. The read loop did not check connection identity, so tearing a
link down immediately produced a second failure — "receiver closed the control
channel" — which burned a reconnect attempt and, worse, **overwrote the real
reason**. That is what hid the handshake timeout on its first test run. The
read loop is now bound to one connection and drops completions from any other.

## Verified

* `swift build` and `swift test` in `core/router` (404 tests) and
  `apps/menubar`.
* New `LanLinkTimeoutTests`: the handshake timeout against an in-process fake
  that accepts TCP and answers nothing (the firewall's shape); the connect
  timeout against an address nothing answers on; and a healthy link that must
  survive both deadlines uncancelled.

Not verified here: the two-machine run itself. That needs the receiver's
firewall allowance, which is the other repository's `--doctor`.

## Known limits

* The connect timeout is a wall-clock deadline on the whole connect, including
  Bonjour resolution. On a network where mDNS resolution routinely takes longer
  than 8 s it would retry rather than wait; nothing observed comes close.
* A receiver that answers `hello_ack` and then goes silent is still caught only
  by the receiver-side keep-alive (5 s without a ping), not by anything here.
  The sender keeps sending UDP into it, which is the correct behaviour for a
  leg that may be one packet away from recovering.
