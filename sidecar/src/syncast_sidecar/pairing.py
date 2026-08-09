"""AirPlay pairing coordinator.

Pairing an AirPlay 2 receiver that demands authentication is a two-stage
human interaction, not a function call:

  1. We ask the receiver to start pairing. macOS puts a FULL-SCREEN four-digit
     PIN on the receiving Mac. There is no way to read it programmatically.
  2. A human reads it, comes back to SyncCast, and types it in. Only then can
     we finish the exchange.

Step 2 is measured in tens of seconds, and can legitimately take minutes. The
sidecar's JSON-RPC loop awaits each handler inline before reading the next
request (``server._read_loop``), so a handler that blocked for that window
would freeze *every* other call, including ``stream.stop`` — leaving the user
unable to stop their audio. So the wait lives in a background task here, and
progress is reported by ``event.pairing_state`` notifications.

Secret handling rules enforced in this module:

  * the PIN is held only in memory, for the life of one attempt;
  * no PIN and no credential ever reaches a log record, an exception message,
    or a URL — OwnTone accepts the PIN in the request body, and its own log
    file is world-readable inside Application Support;
  * failures are reported as fixed strings chosen here, never as
    ``str(exception)`` from a layer that may have interpolated the secret.
"""

from __future__ import annotations

import asyncio
import re
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from . import log

logger = log.get("sidecar.pairing")

# How long the user gets to read the full-screen PIN and type it back.
# Deliberately generous: the receiving Mac may be in another room, and an
# expired window means starting over with another full-screen takeover.
PAIRING_PIN_WINDOW_S = 240.0
# Bound on the single short REST round trip that submits the PIN. This is a
# loopback call to our own OwnTone; anything slower is a fault, not latency.
PAIRING_SUBMIT_TIMEOUT_S = 30.0
# A PIN is exactly four digits. Validated here so a malformed value never
# reaches OwnTone or a log line.
PAIRING_PIN_LENGTH = 4
# Confirming a pairing means reading the freshly-written auth_key back out of
# OwnTone's songs.db. OwnTone writes it as part of handling the PIN submission,
# but the write and our read can race a brief DB lock, so a single miss must
# not be reported as "unpaired". Retry a few times before giving up, to tell a
# transient lock apart from a genuinely absent credential. Kept small: the
# whole confirm should still resolve well under a second.
PAIRING_CONFIRM_ATTEMPTS = 5
PAIRING_CONFIRM_RETRY_DELAY_S = 0.2

STATE_NOT_REQUIRED = "not_required"
STATE_REQUIRED = "required"
STATE_AWAITING_PIN = "awaiting_pin"
STATE_VERIFYING = "verifying"
STATE_PAIRED = "paired"
STATE_FAILED = "failed"
STATE_CANCELLED = "cancelled"
STATE_TIMED_OUT = "timed_out"

# Fixed, secret-free failure messages. Anything the user sees comes from this
# table, never from an upstream exception string.
ERROR_NO_OUTPUT = "the receiver is not visible to the audio engine right now"
ERROR_REJECTED = "the receiver rejected that PIN"
ERROR_BACKEND = "the audio engine could not complete pairing"
ERROR_BAD_PIN = "a PIN is four digits"
ERROR_NO_ATTEMPT = "that pairing window has closed; start again"
ERROR_UNCONFIRMED = "could not confirm the pairing; try again"


@dataclass
class _Attempt:
    device_key: str
    output_id: str
    pin_event: asyncio.Event
    pin_value: str | None = None
    cancelled: bool = False
    started_at: float = field(default_factory=time.monotonic)


class PairingCoordinator:
    """Owns the pairing state machine for every known receiver.

    ``resolve_output`` maps a device key to the OwnTone output id (and whether
    that output currently demands authentication); ``submit_pin`` performs the
    actual, short REST call. Both are injected so this module has no OwnTone
    dependency of its own and can be exercised in isolation.
    """

    def __init__(
        self,
        notify: Callable[[str, dict[str, Any]], None],
        resolve_output: Callable[[str], tuple[str, bool] | None],
        submit_pin: Callable[[str, str], None],
        read_auth_key: Callable[[str], str | None] | None = None,
        on_paired: Callable[[str], None] | None = None,
    ) -> None:
        self._notify = notify
        self._resolve_output = resolve_output
        self._submit_pin = submit_pin
        self._read_auth_key = read_auth_key
        self._on_paired = on_paired
        self._states: dict[str, str] = {}
        self._errors: dict[str, str] = {}
        self._attempts: dict[str, _Attempt] = {}
        self._tasks: dict[str, asyncio.Task[None]] = {}

    # ---------- queries ----------

    def status(self, device_key: str) -> dict[str, Any]:
        state = self._states.get(device_key, STATE_NOT_REQUIRED)
        return {
            "device_key": device_key,
            "state": state,
            "required": state
            not in (STATE_NOT_REQUIRED, STATE_PAIRED),
            "paired": state == STATE_PAIRED,
            "last_error": self._errors.get(device_key),
        }

    def note_authorization_required(self, device_key: str, required: bool) -> None:
        """Record what OwnTone reports about an output's ``needs_auth_key``.

        Called from the reconcile path so the UI learns a receiver needs
        pairing at the moment we try to enable it, instead of the user seeing
        an opaque connection failure.
        """
        if device_key in self._attempts:
            return  # an interactive attempt owns the state right now
        current = self._states.get(device_key)
        target = STATE_REQUIRED if required else STATE_PAIRED
        if not required and current is None:
            target = STATE_NOT_REQUIRED
        if current != target:
            self._set_state(device_key, target)

    # ---------- commands ----------

    def begin(self, device_key: str) -> dict[str, Any]:
        """Start an attempt. Returns in milliseconds; the wait happens in a
        background task."""
        if device_key in self._attempts:
            return {"state": self._states.get(device_key, STATE_AWAITING_PIN)}
        resolved = self._resolve_output(device_key)
        if resolved is None:
            self._set_state(device_key, STATE_FAILED, ERROR_NO_OUTPUT)
            return {"state": STATE_FAILED, "last_error": ERROR_NO_OUTPUT}
        output_id, needs_auth = resolved
        if not needs_auth:
            self._set_state(device_key, STATE_NOT_REQUIRED)
            # The output already holds a credential, but it may still be sitting
            # disabled — e.g. a previous attempt's confirm read raced a DB lock,
            # so pairing succeeded on the receiver but the enable retry never
            # fired. Re-run the post-pair enable path so re-initiating pairing
            # (the "Try again" button, which re-enters begin() with the
            # credential now present) self-heals into audio instead of silently
            # closing the sheet on a still-disabled output.
            self._notify_paired(device_key)
            return {"state": STATE_NOT_REQUIRED}

        attempt = _Attempt(
            device_key=device_key,
            output_id=output_id,
            pin_event=asyncio.Event(),
        )
        self._attempts[device_key] = attempt
        self._set_state(device_key, STATE_AWAITING_PIN)
        # Same pattern as device_manager's deferred reconcile: spawn and
        # return, so the request loop stays free for stream.stop et al.
        task = asyncio.get_running_loop().create_task(self._run(attempt))
        self._tasks[device_key] = task
        task.add_done_callback(self._forget_task(device_key))
        return {"state": STATE_AWAITING_PIN}

    def submit_pin(self, device_key: str, pin: str) -> dict[str, Any]:
        attempt = self._attempts.get(device_key)
        if attempt is None:
            # No attempt in flight is a completely different problem from a
            # malformed PIN — the window closed, or it was cancelled. Say so.
            # Collapsing both into a bare `accepted: False` is what lets the
            # UI tell someone their correct four digits are not four digits.
            return {
                "accepted": False,
                "state": self._states.get(device_key, STATE_FAILED),
                "reason": ERROR_NO_ATTEMPT,
            }
        cleaned = (pin or "").strip()
        if len(cleaned) != PAIRING_PIN_LENGTH or not cleaned.isdigit():
            # Do NOT echo the value back, not even truncated.
            self._errors[device_key] = ERROR_BAD_PIN
            return {
                "accepted": False,
                "state": STATE_AWAITING_PIN,
                "reason": ERROR_BAD_PIN,
            }
        attempt.pin_value = cleaned
        attempt.pin_event.set()
        return {"accepted": True, "state": STATE_VERIFYING, "reason": None}

    def cancel(self, device_key: str) -> dict[str, Any]:
        attempt = self._attempts.get(device_key)
        if attempt is None:
            return {"cancelled": False}
        attempt.cancelled = True
        attempt.pin_event.set()
        return {"cancelled": True}

    async def shutdown(self) -> None:
        for attempt in list(self._attempts.values()):
            attempt.cancelled = True
            attempt.pin_event.set()
        tasks = list(self._tasks.values())
        for task in tasks:
            task.cancel()
        for task in tasks:
            try:
                await task
            except asyncio.CancelledError:
                pass
            except Exception:
                logger.warning("pairing_shutdown_task_failed")
        self._attempts.clear()
        self._tasks.clear()

    # ---------- internals ----------

    @staticmethod
    def _classify_submit_error(error: BaseException) -> str:
        """Map a submit failure onto one of the fixed, secret-free messages.

        Only an actual HTTP rejection from OwnTone means "the receiver said
        no". Everything else — helper not running, connection refused, read
        timeout — is a backend fault, and telling those apart is the
        difference between "type the code again" and "your PIN was wrong".
        """
        # Duck-typed on purpose: this module deliberately has no OwnTone
        # import, so it reads `.code` the way `urllib`'s HTTPError and our
        # own wrapper both expose it.
        http_error = getattr(error, "code", None)
        if isinstance(http_error, int):
            return ERROR_REJECTED if 400 <= http_error < 500 else ERROR_BACKEND
        # Fall back to the status code embedded in the message. Matching on
        # the CODE rather than on wording keeps this working across the two
        # phrasings we see ("HTTP 400 …" and "HTTP Error 400: …").
        match = re.search(r"http[^0-9]{0,12}(\d{3})", str(error).lower())
        if match and 400 <= int(match.group(1)) < 500:
            return ERROR_REJECTED
        return ERROR_BACKEND

    def _notify_paired(self, device_key: str) -> None:
        """Tell the owner that this receiver is now usable.

        Nothing else re-runs reconciliation: the enable was refused earlier
        precisely BECAUSE the receiver was unpaired, and that refusal returned
        before the output was ever added to any watch set. Without this hook a
        successful pairing produces a sheet that closes, a row with no error,
        and no audio — until the user happens to toggle something else.
        """
        callback = self._on_paired
        if callback is None:
            return
        try:
            callback(device_key)
        except Exception:
            logger.warning("pairing_on_paired_failed", extra={"device_key": device_key})

    def _forget_task(
        self, device_key: str,
    ) -> Callable[[asyncio.Task[None]], None]:
        def _done(_task: asyncio.Task[None]) -> None:
            self._tasks.pop(device_key, None)

        return _done

    async def _run(self, attempt: _Attempt) -> None:
        key = attempt.device_key
        try:
            try:
                await asyncio.wait_for(
                    attempt.pin_event.wait(), timeout=PAIRING_PIN_WINDOW_S,
                )
            except TimeoutError:
                self._set_state(key, STATE_TIMED_OUT)
                return
            if attempt.cancelled or not attempt.pin_value:
                self._set_state(key, STATE_CANCELLED)
                return

            self._set_state(key, STATE_VERIFYING)
            pin = attempt.pin_value
            attempt.pin_value = None  # drop the secret as soon as it is used
            loop = asyncio.get_running_loop()
            try:
                await asyncio.wait_for(
                    loop.run_in_executor(
                        None, self._submit_pin, attempt.output_id, pin,
                    ),
                    timeout=PAIRING_SUBMIT_TIMEOUT_S,
                )
            except TimeoutError:
                self._set_state(key, STATE_FAILED, ERROR_BACKEND)
                return
            except Exception as e:
                # Log the TYPE only. The exception text may quote the request
                # body, which contains the PIN.
                logger.warning(
                    "pairing_submit_failed",
                    extra={"device_key": key, "error_kind": type(e).__name__},
                )
                # A transport fault ("OwnTone is not running", "connection
                # refused", "timed out") is not the receiver rejecting the
                # PIN. Reporting it as one sends the user off to re-pair —
                # the one action that cannot help — and hides the real cause.
                self._set_state(key, STATE_FAILED, self._classify_submit_error(e))
                return

            if self._read_auth_key is None:
                self._set_state(key, STATE_PAIRED)
                return
            # A missing credential here means the exchange really did not
            # produce one — but the read itself can also fail transiently (the
            # database is briefly locked while OwnTone finishes its own write),
            # which is "unconfirmed", not "rejected". Retry a few times so a
            # transient lock does not masquerade as an unpaired receiver and
            # strand a device that actually paired.
            paired = False
            for attempt_no in range(PAIRING_CONFIRM_ATTEMPTS):
                try:
                    if bool(self._read_auth_key(attempt.output_id)):
                        paired = True
                        break
                except Exception:
                    logger.warning(
                        "pairing_confirm_failed", extra={"device_key": key},
                    )
                if attempt_no + 1 < PAIRING_CONFIRM_ATTEMPTS:
                    await asyncio.sleep(PAIRING_CONFIRM_RETRY_DELAY_S)
            # `_read_auth_key` returns None for both a genuine absence and a
            # transient miss, so after exhausting retries the honest message is
            # the softer "unconfirmed".
            self._set_state(
                key,
                STATE_PAIRED if paired else STATE_FAILED,
                None if paired else ERROR_UNCONFIRMED,
            )
            if paired:
                self._notify_paired(key)
        except asyncio.CancelledError:
            self._set_state(key, STATE_CANCELLED)
            raise
        finally:
            self._attempts.pop(key, None)

    def _set_state(
        self, device_key: str, state: str, last_error: str | None = None,
    ) -> None:
        self._states[device_key] = state
        if last_error:
            self._errors[device_key] = last_error
        elif state in (STATE_PAIRED, STATE_NOT_REQUIRED):
            self._errors.pop(device_key, None)
        logger.info(
            "pairing_state", extra={"device_key": device_key, "state": state},
        )
        self._notify(
            "event.pairing_state",
            {
                "device_key": device_key,
                "state": state,
                "last_error": self._errors.get(device_key),
            },
        )
