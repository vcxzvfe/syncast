"""Minimal JSON-RPC 2.0 helpers (newline-delimited, async)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any


PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

DEVICE_NOT_FOUND = -32000
DEVICE_NOT_CONNECTED = -32001
STREAM_NOT_ACTIVE = -32002
CAPABILITY_UNSUPPORTED = -32003
PROTOCOL_VERSION_MISMATCH = -32099


@dataclass
class Request:
    id: int | str | None
    method: str
    params: dict[str, Any]


class RpcError(Exception):
    def __init__(self, code: int, message: str, data: Any | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def parse_request(line: str) -> Request:
    try:
        obj = json.loads(line)
    except json.JSONDecodeError as e:
        raise RpcError(PARSE_ERROR, f"invalid json: {e}") from e
    if not isinstance(obj, dict):
        raise RpcError(INVALID_REQUEST, "request must be object")
    if obj.get("jsonrpc") != "2.0":
        raise RpcError(INVALID_REQUEST, "jsonrpc must be '2.0'")
    method = obj.get("method")
    if not isinstance(method, str):
        raise RpcError(INVALID_REQUEST, "method missing")
    params = obj.get("params") or {}
    if not isinstance(params, dict):
        raise RpcError(INVALID_PARAMS, "params must be object")
    return Request(id=obj.get("id"), method=method, params=params)


def encode_result(req_id: Any, result: Any) -> bytes:
    return (json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result},
                       ensure_ascii=False) + "\n").encode("utf-8")


def encode_error(req_id: Any, err: RpcError) -> bytes:
    payload: dict[str, Any] = {"code": err.code, "message": err.message}
    if err.data is not None:
        payload["data"] = err.data
    return (json.dumps({"jsonrpc": "2.0", "id": req_id, "error": payload},
                       ensure_ascii=False) + "\n").encode("utf-8")


def encode_notification(method: str, params: dict[str, Any]) -> bytes:
    return (json.dumps({"jsonrpc": "2.0", "method": method, "params": params},
                       ensure_ascii=False) + "\n").encode("utf-8")
