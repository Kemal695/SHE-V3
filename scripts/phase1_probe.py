"""Python replacements for the two Phase 1 checks that used to SKIP.

`verify-phase1.sh` skipped Criterion 5 (mTLS enforced) and Criterion 3 (WebSocket)
whenever `mosquitto_pub` / `websocat` were not installed — which they never are on this
machine. Two of the five Phase 1 exit criteria were therefore never actually verified.

Both are simple to do with the standard library, so they no longer depend on extra tooling.

Usage:
    phase1_probe.py mqtt-anon --host H --port 8883 --cafile PATH
        exit 0 => anonymous connect REJECTED (mTLS enforced, good)
        exit 1 => anonymous connect SUCCEEDED (mTLS NOT enforced, bad)

    phase1_probe.py ws --host H --port 8080 --token JWT
        exit 0 => handshake 101 and the server echoed an offered subprotocol
        exit 1 => anything else
"""
import argparse
import base64
import os
import socket
import ssl
import sys


def mqtt_anon(args) -> int:
    """Try to complete a TLS handshake with NO client certificate.

    Exit codes matter: 0 = rejected (good), 1 = accepted (bad), 2 = INCONCLUSIVE.
    Distinguishing 2 from 0 is the whole point — if the broker is down, the TCP connect
    fails, and treating that as "rejected" would report mTLS as enforced when nothing
    was ever tested. Never let an inconclusive result look like a pass.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if args.cafile:
        try:
            ctx.load_verify_locations(args.cafile)
        except Exception as e:
            print(f"  could not load cafile {args.cafile}: {e}")

    # Step 1: reach the port at all. Failing here is inconclusive, not a pass.
    try:
        raw = socket.create_connection((args.host, args.port), timeout=10)
    except Exception as e:
        print(f"  INCONCLUSIVE: cannot reach {args.host}:{args.port} — {type(e).__name__}: {e}")
        return 2

    # Step 2: handshake without a client cert.
    try:
        with raw:
            with ctx.wrap_socket(raw, server_hostname=args.host) as tls:
                print(f"  TLS handshake COMPLETED without a client cert ({tls.version()})")
                return 1
    except (ssl.SSLError, ConnectionResetError, BrokenPipeError, OSError) as e:
        # The port answered, then refused the handshake: that is mTLS doing its job.
        print(f"  TLS handshake rejected as expected: {type(e).__name__}: {e}")
        return 0
    except Exception as e:
        print(f"  INCONCLUSIVE: unexpected failure — {type(e).__name__}: {e}")
        return 2


def ws(args) -> int:
    """Raw upgrade so the subprotocol negotiation is visible."""
    offered = [f"bearer.{args.token}"]
    key = base64.b64encode(os.urandom(16)).decode()
    req = "\r\n".join([
        "GET /ws/v3 HTTP/1.1",
        f"Host: {args.host}:{args.port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}",
        "Sec-WebSocket-Version: 13",
        f"Sec-WebSocket-Protocol: {', '.join(offered)}",
        "", "",
    ])
    try:
        with socket.create_connection((args.host, args.port), timeout=10) as s:
            s.sendall(req.encode())
            raw = b""
            while b"\r\n\r\n" not in raw:
                chunk = s.recv(4096)
                if not chunk:
                    break
                raw += chunk
    except Exception as e:
        # Could not reach the backend at all — inconclusive, not a handshake failure.
        print(f"  INCONCLUSIVE: cannot reach {args.host}:{args.port} — {type(e).__name__}: {e}")
        return 2

    head = raw.split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace")
    status = head.splitlines()[0] if head else "<no response>"
    echoed = None
    for ln in head.splitlines()[1:]:
        if ln.lower().startswith("sec-websocket-protocol:"):
            echoed = ln.split(":", 1)[1].strip()

    print(f"  status  : {status}")
    print(f"  echoed  : {echoed!r}")

    if "101" not in status:
        # A 200 here means beforeHandshake returned false: auth rejected, not a
        # missing route. Worth saying out loud so nobody hunts the wrong bug.
        print("  -> not an upgrade; if this is 200, the handshake auth was rejected")
        return 1
    if echoed not in offered:
        print("  -> server echoed a subprotocol the client never offered "
              "(RFC 6455 4.1 => dart:io closes with 1002)")
        return 1
    print("  -> 101 and RFC-compliant subprotocol: client will accept")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("mqtt-anon")
    a.add_argument("--host", required=True)
    a.add_argument("--port", type=int, default=8883)
    a.add_argument("--cafile", default="")
    a.set_defaults(fn=mqtt_anon)

    w = sub.add_parser("ws")
    w.add_argument("--host", required=True)
    w.add_argument("--port", type=int, default=8080)
    w.add_argument("--token", required=True)
    w.set_defaults(fn=ws)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
