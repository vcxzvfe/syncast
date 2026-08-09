"""REST timeouts on the OwnTone client.

Submitting a pairing PIN is not an ordinary REST call. OwnTone handles it
SYNCHRONOUSLY -- `player_speaker_authorize` blocks on `commands_exec_sync`
while a full AirPlay pair-setup runs (SRP plus three RTSP round trips), and
OwnTone's own RTSP layer budgets 10 s to connect and 15 s per exchange. Held
to the ordinary 2 s ceiling, a perfectly healthy pairing is aborted by the
client -- and the user is then told their correct PIN was rejected, while the
receiver may in fact have paired.
"""

from __future__ import annotations

import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from syncast_sidecar import owntone_backend
from syncast_sidecar.owntone_backend import OwnToneBackend, OwnToneError


class _SlowHandler(BaseHTTPRequestHandler):
    delay_s = 0.0
    status = 204

    def do_PUT(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        time.sleep(type(self).delay_s)
        self.send_response(type(self).status)
        self.end_headers()

    def log_message(self, *_args: object) -> None:
        pass


@pytest.fixture()
def slow_server():
    server = HTTPServer(("127.0.0.1", 0), _SlowHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def _backend(port: int, tmp_path) -> OwnToneBackend:
    return OwnToneBackend(state_dir=tmp_path, rest_port=port)


def test_pairing_timeout_is_far_longer_than_the_ordinary_one() -> None:
    assert owntone_backend.PAIRING_REST_TIMEOUT_S > owntone_backend.REST_TIMEOUT_S
    # The pair-setup exchange alone can legitimately take double digits of
    # seconds, so anything near the ordinary ceiling would abort healthy runs.
    assert owntone_backend.PAIRING_REST_TIMEOUT_S >= 25.0


def test_a_slow_pair_setup_is_not_aborted_by_the_ordinary_rest_ceiling(
    slow_server, tmp_path,
) -> None:
    _SlowHandler.delay_s = owntone_backend.REST_TIMEOUT_S + 1.0
    _SlowHandler.status = 204
    backend = _backend(slow_server.server_address[1], tmp_path)
    try:
        # Would raise on the 2 s ceiling; must survive on the pairing one.
        backend.set_output_pin("2202428899329", "1234")
    finally:
        _SlowHandler.delay_s = 0.0


def test_ordinary_calls_keep_the_short_ceiling(slow_server, tmp_path) -> None:
    _SlowHandler.delay_s = owntone_backend.REST_TIMEOUT_S + 1.0
    backend = _backend(slow_server.server_address[1], tmp_path)
    started = time.monotonic()
    try:
        with pytest.raises(OwnToneError):
            backend.set_output_enabled("2202428899329", True)
    finally:
        _SlowHandler.delay_s = 0.0
    # A slow endpoint must still fail fast on the ordinary path, rather than
    # inheriting the pairing budget and stalling the whole reconcile.
    assert time.monotonic() - started < owntone_backend.PAIRING_REST_TIMEOUT_S


def test_a_rejection_carries_its_http_status(slow_server, tmp_path) -> None:
    """Callers must be able to tell 4xx from "unreachable" without parsing.

    A genuine 400 means the receiver rejected the PIN; a connection error
    means the helper is not answering. Same exception type, opposite advice.
    """
    _SlowHandler.status = 400
    backend = _backend(slow_server.server_address[1], tmp_path)
    try:
        with pytest.raises(OwnToneError) as excinfo:
            backend.set_output_pin("2202428899329", "1234")
    finally:
        _SlowHandler.status = 204
    assert excinfo.value.code == 400


def test_an_unreachable_helper_carries_no_status_code(tmp_path) -> None:
    # Port 1 is reserved and nothing listens there.
    backend = OwnToneBackend(state_dir=tmp_path, rest_port=1)
    with pytest.raises(OwnToneError) as excinfo:
        backend.set_output_pin("2202428899329", "1234")
    assert excinfo.value.code is None


def test_state_dir_and_database_are_owner_only(tmp_path) -> None:
    """`songs.db` holds long-lived AirPlay credentials in cleartext.

    OwnTone creates it 0644 inside a 0755 directory, and there is no second
    copy anywhere, so the file mode is the whole of its protection.
    """
    backend = OwnToneBackend(state_dir=tmp_path, rest_port=1)
    tmp_path.chmod(0o755)
    backend.db_path.write_text("pretend database")
    backend.db_path.chmod(0o644)

    backend._harden_state_dir()

    assert (tmp_path.stat().st_mode & 0o777) == 0o700
    assert (backend.db_path.stat().st_mode & 0o777) == 0o600


def test_hardening_a_missing_database_is_not_an_error(tmp_path) -> None:
    backend = OwnToneBackend(state_dir=tmp_path, rest_port=1)
    backend._harden_state_dir()
    assert (tmp_path.stat().st_mode & 0o777) == 0o700
