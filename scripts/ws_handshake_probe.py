"""Probe the SHE V3 WebSocket handshake's subprotocol negotiation.

RFC 6455 4.1: the client MUST fail the connection if the server's chosen
subprotocol was not among the ones the client offered. dart:io enforces this
with close code 1002, which is why the app's socket died the instant it opened.

This performs a raw upgrade handshake so we can see exactly what the server
echoes back, with no WebSocket library in the way.
"""
import base64
import json
import os
import socket
import sys
import urllib.request

HOST = "192.168.1.7"
PORT = 8080
PATH = "/ws/v3"
API = f"http://{HOST}:{PORT}/api/v3"
EMAIL = "kemalai695@gmail.com"
PASSWORD = "SheV3Temp!2026"


def login() -> str:
    req = urllib.request.Request(
        API + "/auth/login",
        data=json.dumps({"email": EMAIL, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)["data"]["access_token"]


def handshake(token: str, offered: list[str]) -> tuple[str, dict]:
    key = base64.b64encode(os.urandom(16)).decode()
    lines = [
        f"GET {PATH} HTTP/1.1",
        f"Host: {HOST}:{PORT}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}",
        "Sec-WebSocket-Version: 13",
        f"Sec-WebSocket-Protocol: {', '.join(offered)}",
        "",
        "",
    ]
    with socket.create_connection((HOST, PORT), timeout=10) as s:
        s.sendall("\r\n".join(lines).encode())
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
    head = raw.split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace")
    status = head.splitlines()[0]
    headers = {}
    for ln in head.splitlines()[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return status, headers


def main() -> int:
    token = login()
    print(f"got access_token ({len(token)} chars)\n")

    cases = [
        ("[1] only  bearer.<jwt>", [f"bearer.{token}"]),
        ("[2] bearer , bearer.<jwt>", ["bearer", f"bearer.{token}"]),
        ("[3] bearer.<jwt> , bearer  (reversed)", [f"bearer.{token}", "bearer"]),
        ("[4] only  bearer", ["bearer"]),
    ]
    rc = 0
    for label, offered in cases:
        status, headers = handshake(token, offered)
        echoed = headers.get("sec-websocket-protocol")
        ok = echoed is not None and echoed in offered
        print(f"{label}")
        print(f"   status   : {status}")
        print(f"   offered  : {offered[0][:28]}{'...' if len(offered[0]) > 28 else ''}"
              f"{' + bearer' if len(offered) > 1 else ''}")
        print(f"   echoed   : {echoed!r}")
        print(f"   RFC-safe : {'YES' if ok else 'NO -> dart:io closes with 1002'}")
        print()
        if not ok:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
