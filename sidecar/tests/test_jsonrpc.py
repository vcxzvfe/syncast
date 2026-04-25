from __future__ import annotations

import json

import pytest

from syncast_sidecar import jsonrpc


def test_parse_valid() -> None:
    line = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "x", "params": {"a": 1}})
    req = jsonrpc.parse_request(line)
    assert req.id == 1
    assert req.method == "x"
    assert req.params == {"a": 1}


def test_parse_missing_method() -> None:
    line = json.dumps({"jsonrpc": "2.0", "id": 1})
    with pytest.raises(jsonrpc.RpcError) as e:
        jsonrpc.parse_request(line)
    assert e.value.code == jsonrpc.INVALID_REQUEST


def test_parse_bad_jsonrpc_version() -> None:
    line = json.dumps({"jsonrpc": "1.0", "id": 1, "method": "x"})
    with pytest.raises(jsonrpc.RpcError) as e:
        jsonrpc.parse_request(line)
    assert e.value.code == jsonrpc.INVALID_REQUEST


def test_parse_bad_json() -> None:
    with pytest.raises(jsonrpc.RpcError) as e:
        jsonrpc.parse_request("{not json")
    assert e.value.code == jsonrpc.PARSE_ERROR


def test_encode_result_roundtrip() -> None:
    raw = jsonrpc.encode_result(7, {"ok": True})
    obj = json.loads(raw.decode().rstrip("\n"))
    assert obj == {"jsonrpc": "2.0", "id": 7, "result": {"ok": True}}


def test_encode_error_includes_data() -> None:
    err = jsonrpc.RpcError(jsonrpc.INVALID_PARAMS, "bad", data={"hint": "x"})
    raw = jsonrpc.encode_error(99, err)
    obj = json.loads(raw.decode().rstrip("\n"))
    assert obj["error"] == {"code": -32602, "message": "bad", "data": {"hint": "x"}}


def test_encode_notification() -> None:
    raw = jsonrpc.encode_notification("event.x", {"a": 1})
    obj = json.loads(raw.decode().rstrip("\n"))
    assert obj == {"jsonrpc": "2.0", "method": "event.x", "params": {"a": 1}}
    assert "id" not in obj
