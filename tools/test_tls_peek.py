#!/usr/bin/env python3
"""Verify the Lua TLS certificate harvester.

Two things must hold:

1. The ClientHello the Lua builds is byte-identical to the one tools/peek_cert.py
   sends, since that exact byte sequence is verified to make the real device reply
   with its certificate.
2. The record parser recovers the certificate regardless of how the response is
   split - across TLS records, across TCP reads, or both.

The certificate used here is synthetic. A real capture would embed the device's
MAC address (it appears in the certificate CN), which has no business in a repo.

    python tools/test_tls_peek.py
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import lupa
except ImportError:
    sys.exit("error: pip install lupa")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peek_reference import client_hello  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DRIVER = REPO / "driver"

failures: list[str] = []
checks = 0


def check(label: str, got, want) -> None:
    global checks
    checks += 1
    if got == want:
        detail = f" ({len(got)} bytes)" if isinstance(got, bytes) else ""
        print(f"  ok   {label}{detail}")
    else:
        print(f"  FAIL {label}")
        if isinstance(got, bytes) and isinstance(want, bytes):
            print(f"       lua       : {got[:48].hex(' ')}  ({len(got)} bytes)")
            print(f"       reference : {want[:48].hex(' ')}  ({len(want)} bytes)")
        else:
            print(f"       got {got!r}, want {want!r}")
        failures.append(label)


def build_handshake(der: bytes) -> bytes:
    """A ServerHello followed by a Certificate message carrying one certificate."""
    hs = b"\x02" + (78).to_bytes(3, "big") + b"\x5a" * 78
    body = (len(der) + 3).to_bytes(3, "big") + len(der).to_bytes(3, "big") + der
    hs += b"\x0b" + len(body).to_bytes(3, "big") + body
    return hs


def to_records(payload: bytes, size: int) -> bytes:
    """Split a handshake stream across TLS records of at most `size` bytes."""
    out = b""
    for i in range(0, len(payload), size):
        chunk = payload[i:i + size]
        out += b"\x16\x03\x03" + len(chunk).to_bytes(2, "big") + chunk
    return out


def main() -> None:
    lua = lupa.LuaRuntime(encoding=None)
    lua.execute(f'package.path = [[{DRIVER.as_posix()}/?.lua]] .. ";" .. package.path'.encode())
    tls = lua.eval(b"(function() return (require('lib.tls_peek')) end)()")

    print("ClientHello")
    random = b"\xaa" * 32
    check("matches the bytes the real device accepted",
          tls.buildClientHello(random), client_hello(random))

    rejected, err = tls.buildClientHello(b"short")
    check("rejects wrong-length random", rejected, None)
    print(f"       (error: {err.decode() if isinstance(err, bytes) else err})")

    print("\ncertificate recovery under fragmentation")
    der = bytes(range(256)) * 3          # 768 bytes standing in for a certificate
    handshake = build_handshake(der)

    for rec_size in (64, 512, 4096):
        for tcp_chunk in (1, 7, 333, 100_000):
            stream = to_records(handshake, rec_size)
            sess = tls.newSession()
            for i in range(0, len(stream), tcp_chunk):
                tls.push(sess, stream[i:i + tcp_chunk])
            # certificate() returns (der, status); lupa surfaces that as a tuple.
            got, _status = tls.certificate(sess)
            check(f"records={rec_size:<5} tcp_chunk={tcp_chunk:<6}", got, der)

    print("\nfailure modes")
    # A truncated stream must yield nothing rather than a corrupt certificate.
    stream = to_records(handshake, 512)
    sess = tls.newSession()
    tls.push(sess, stream[:len(stream) // 2])
    got, status = tls.certificate(sess)
    check("truncated stream yields no certificate", got, None)
    print(f"       (status: {status.decode() if isinstance(status, bytes) else status})")

    # An alert must be surfaced, not silently swallowed.
    sess = tls.newSession()
    tls.push(sess, b"\x15\x03\x03\x00\x02\x02\x46")   # fatal, handshake_failure
    got, status = tls.certificate(sess)
    check("alert yields no certificate", got, None)
    print(f"       (status: {status.decode() if isinstance(status, bytes) else status})")

    print()
    if failures:
        print(f"{len(failures)}/{checks} FAILED:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print(f"all {checks} checks passed")


if __name__ == "__main__":
    main()
