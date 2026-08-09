#!/usr/bin/env python3
"""Verify driver/lib/der.lua against real certificates.

The driver reads the RSA modulus and exponent straight out of X.509 certificates
rather than going through lua-openssl's pkey:parse(), whose return shape varies by
version and yields nothing usable on the target controller.

Certificates are generated with the openssl CLI and the extracted values compared
against what openssl itself reports. Includes a certificate fetched live from the
device when one is reachable, since that is the certificate that actually matters.

    python tools/test_der.py [device_ip]
"""

from __future__ import annotations

import base64
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import lupa
except ImportError:
    sys.exit("error: pip install lupa")

REPO = Path(__file__).resolve().parent.parent
DRIVER = REPO / "driver"

failures: list[str] = []
checks = 0


def check(label: str, got, want) -> None:
    global checks
    checks += 1
    if got == want:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        if isinstance(got, bytes) and isinstance(want, bytes):
            print(f"       lua      : {got[:32].hex()} ({len(got)} bytes)")
            print(f"       openssl  : {want[:32].hex()} ({len(want)} bytes)")
        else:
            print(f"       got {got!r}, want {want!r}")
        failures.append(label)


def make_cert(bits: int, exponent: int = 65537) -> tuple[bytes, bytes, int, int]:
    """Return (pem, der, modulus, exponent) for a fresh self-signed certificate."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        key, crt = d / "k.pem", d / "c.pem"
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", f"rsa:{bits}", "-keyout", str(key),
             "-out", str(crt), "-days", "3650", "-nodes", "-subj", "//CN=test",
             "-pkeyopt", f"rsa_keygen_pubexp:{exponent}"],
            check=True, capture_output=True,
        )
        pem = crt.read_bytes()
        der = subprocess.run(
            ["openssl", "x509", "-in", str(crt), "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
        modulus_line = subprocess.run(
            ["openssl", "x509", "-in", str(crt), "-noout", "-modulus"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    modulus = int(modulus_line.split("=", 1)[1], 16)
    return pem, der, modulus, exponent


def to_bytes(n: int) -> bytes:
    h = f"{n:X}"
    return bytes.fromhex(h if len(h) % 2 == 0 else "0" + h)


def fetch_device_cert(ip: str) -> bytes | None:
    """Harvest the live device certificate, so the real thing is covered too."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import socket

        from peek_reference import client_hello
        s = socket.socket()
        s.settimeout(6)
        s.connect((ip, 6467))
        s.send(client_hello())
        data = b""
        try:
            while len(data) < 8192:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        s.close()
    except Exception:
        return None

    hs, pos = b"", 0
    while pos + 5 <= len(data):
        ctype = data[pos]
        ln = int.from_bytes(data[pos + 3:pos + 5], "big")
        if ctype == 0x16:
            hs += data[pos + 5:pos + 5 + ln]
        pos += 5 + ln
    pos = 0
    while pos + 4 <= len(hs):
        mtype = hs[pos]
        mlen = int.from_bytes(hs[pos + 1:pos + 4], "big")
        if mtype == 0x0B:
            body = hs[pos + 4:pos + 4 + mlen]
            cert_len = int.from_bytes(body[3:6], "big")
            return body[6:6 + cert_len]
        pos += 4 + mlen
    return None


def main() -> None:
    lua = lupa.LuaRuntime(encoding=None)
    lua.execute(f'package.path = [[{DRIVER.as_posix()}/?.lua]] .. ";" .. package.path'.encode())
    der_lib = lua.eval(b"(function() return (require('lib.der')) end)()")

    print("base64")
    for raw in (b"", b"a", b"ab", b"abc", b"abcd", bytes(range(64)), b"\xff" * 100):
        encoded = base64.b64encode(raw)
        got = der_lib.base64Decode(encoded)
        got = got if isinstance(got, bytes) else (got[0] if got else b"")
        check(f"decode {len(raw)} bytes", got or b"", raw)

    print("\ncertificates (2048-bit, e=65537)")
    pem, der, modulus, exponent = make_cert(2048)
    n, e, status = der_lib.rsaPublicKeyFromCertificate(der)
    check("modulus from DER", n, to_bytes(modulus))
    check("exponent from DER", e, to_bytes(exponent))
    check("status ok", status, b"ok")
    check("modulus is 256 bytes", len(n), 256)

    n2, e2, _ = der_lib.rsaPublicKeyFromPem(pem)
    check("same result from PEM", (n2, e2), (n, e))

    print("\nother key sizes and exponents")
    for bits in (1024, 3072):
        pem, der, modulus, exponent = make_cert(bits)
        n, e, _ = der_lib.rsaPublicKeyFromCertificate(der)
        check(f"{bits}-bit modulus", n, to_bytes(modulus))
        check(f"{bits}-bit length", len(n), bits // 8)

    # e=3 exercises the single-byte exponent path.
    pem, der, modulus, exponent = make_cert(2048, exponent=3)
    n, e, _ = der_lib.rsaPublicKeyFromCertificate(der)
    check("exponent 3 modulus", n, to_bytes(modulus))
    check("exponent 3 value", e, b"\x03")

    print("\nmalformed input is rejected, not misread")
    for bad, why in [(b"", "empty"), (b"\x30\x00", "empty sequence"),
                     (b"\x02\x01\x05", "not a certificate"),
                     (bytes(range(64)), "random bytes")]:
        n, e, status = der_lib.rsaPublicKeyFromCertificate(bad)
        check(f"rejects {why}", n, None)

    ip = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.10"
    print(f"\nlive device certificate ({ip})")
    device_der = fetch_device_cert(ip)
    if device_der is None:
        print("  skip - device not reachable")
    else:
        n, e, status = der_lib.rsaPublicKeyFromCertificate(device_der)
        if n is None:
            check("extracts device public key", status, b"ok")
        else:
            with tempfile.TemporaryDirectory() as tmp:
                p = Path(tmp) / "d.der"
                p.write_bytes(device_der)
                out = subprocess.run(
                    ["openssl", "x509", "-inform", "DER", "-in", str(p),
                     "-noout", "-modulus"],
                    check=True, capture_output=True, text=True,
                ).stdout.strip()
            want = to_bytes(int(out.split("=", 1)[1], 16))
            check("device modulus matches openssl", n, want)
            check("device exponent is 65537", e, b"\x01\x00\x01")
            print(f"       device modulus: {n[:16].hex()}... ({len(n)} bytes)")

    print()
    if failures:
        print(f"{len(failures)}/{checks} FAILED:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print(f"all {checks} checks passed")


if __name__ == "__main__":
    main()
