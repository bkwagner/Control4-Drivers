#!/usr/bin/env python3
"""Verify driver/lib/pairing.lua against the reference implementation.

Two things are checked:

1. Every polo message the Lua builds is byte-identical to the same message
   serialized by Google's protobuf.
2. The secret pre-image matches what androidtvremote2 hashes, for real RSA key
   material. A mistake here fails exactly like a mistyped pairing code, which is
   miserable to diagnose on hardware - so it is pinned down off-device.

    python tools/test_pairing.py
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import lupa
except ImportError:
    sys.exit("error: pip install lupa")

try:
    from androidtvremote2.polo_pb2 import Options, OuterMessage
except ImportError:
    sys.exit("error: pip install -r tools/requirements.txt")

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
            print(f"       lua       : {got[:64].hex(' ')} ({len(got)} bytes)")
            print(f"       reference : {want[:64].hex(' ')} ({len(want)} bytes)")
        else:
            print(f"       got {got!r}, want {want!r}")
        failures.append(label)


def unpack1(value):
    """Lua returns one value on success and (nil, err) on failure; lupa surfaces
    the latter as a tuple. Normalise to just the first value."""
    return value[0] if isinstance(value, tuple) else value


def framed(msg) -> bytes:
    body = msg.SerializeToString()
    out, n = bytearray(), len(body)
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | 0x80 if n else b)
        if not n:
            break
    return bytes(out) + body


def base() -> OuterMessage:
    msg = OuterMessage()
    msg.protocol_version = 2
    msg.status = OuterMessage.Status.STATUS_OK
    return msg


def rsa_numbers() -> tuple[int, int]:
    """Generate a real RSA key and return (modulus, exponent) via the openssl CLI."""
    with tempfile.TemporaryDirectory() as tmp:
        key = Path(tmp) / "k.pem"
        subprocess.run(
            ["openssl", "genrsa", "-out", str(key), "2048"],
            check=True, capture_output=True,
        )
        out = subprocess.run(
            ["openssl", "rsa", "-in", str(key), "-noout", "-modulus"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    modulus = int(out.split("=", 1)[1], 16)
    return modulus, 65537


def reference_preimage(cn: int, ce: int, sn: int, se: int, code: str) -> bytes:
    """Exactly what androidtvremote2 feeds to sha256."""
    return (
        bytes.fromhex(f"{cn:X}")
        + bytes.fromhex(f"0{ce:X}")
        + bytes.fromhex(f"{sn:X}")
        + bytes.fromhex(f"0{se:X}")
        + bytes.fromhex(code[2:])
    )


def main() -> None:
    lua = lupa.LuaRuntime(encoding=None)
    lua.execute(f'package.path = [[{DRIVER.as_posix()}/?.lua]] .. ";" .. package.path'.encode())
    p = lua.eval(b"(function() return (require('lib.pairing')) end)()")

    print("polo messages vs google protobuf")

    m = base()
    m.pairing_request.service_name = "atvremote"
    m.pairing_request.client_name = "Control4"
    check("buildPairingRequest", p.buildPairingRequest(b"Control4", b"atvremote"), framed(m))

    m = base()
    m.options.preferred_role = Options.RoleType.ROLE_TYPE_INPUT
    enc = m.options.input_encodings.add()
    enc.type = Options.Encoding.ENCODING_TYPE_HEXADECIMAL
    enc.symbol_length = 6
    check("buildOptions", p.buildOptions(), framed(m))

    m = base()
    m.configuration.client_role = Options.RoleType.ROLE_TYPE_INPUT
    m.configuration.encoding.type = Options.Encoding.ENCODING_TYPE_HEXADECIMAL
    m.configuration.encoding.symbol_length = 6
    check("buildConfiguration", p.buildConfiguration(), framed(m))

    secret = bytes(range(32))
    m = base()
    m.secret.secret = secret
    check("buildSecret", p.buildSecret(secret), framed(m))

    print("\ninbound parsing")
    # polo.proto is proto2: secret_ack.secret is a *required* field, so it has to
    # be populated for the message to serialize at all.
    for field, kind in [
        ("pairing_request_ack", b"request_ack"),
        ("configuration_ack", b"configuration_ack"),
        ("secret_ack", b"secret_ack"),
    ]:
        m = base()
        getattr(m, field).SetInParent()
        if field == "secret_ack":
            m.secret_ack.secret = bytes(range(32))
        r = p.parseMessage(m.SerializeToString())
        check(f"parse {field}", r[b"kind"], kind)
        check(f"parse {field} status", r[b"status"], 200)

    m = base()
    m.status = OuterMessage.Status.STATUS_BAD_SECRET
    m.secret_ack.secret = bytes(range(32))
    r = p.parseMessage(m.SerializeToString())
    check("non-OK status surfaced", r[b"status"], 402)

    print("\nsecret pre-image with real RSA key material")
    client_n, client_e = rsa_numbers()
    server_n, server_e = rsa_numbers()

    def to_bytes(n: int) -> bytes:
        h = f"{n:X}"
        return bytes.fromhex(h if len(h) % 2 == 0 else "0" + h)

    for code in ("42D3D8", "00abcd", "FFFFFF"):
        want = reference_preimage(client_n, client_e, server_n, server_e, code)
        got = unpack1(p.buildSecretPreimage(
            to_bytes(client_n), to_bytes(client_e),
            to_bytes(server_n), to_bytes(server_e), code.encode()))
        check(f"preimage for code {code}", got, want)
        if got == want:
            # The digest is a plain SHA-256 over this, so matching pre-images
            # guarantee matching secrets.
            print(f"       sha256 -> {hashlib.sha256(want).hexdigest()[:32]}...")

    print("\ncode validation")
    for bad, why in [(b"12345", "too short"), (b"1234567", "too long"),
                     (b"12345g", "not hex"), (b"", "empty")]:
        ok = unpack1(p.checkCode(bad))
        check(f"rejects {why}", ok, False)

    ok = unpack1(p.checkCode(b"42D3D8"))
    check("accepts valid code", ok, True)

    # The check byte guards against a mistyped code before anything is sent.
    digest = hashlib.sha256(b"anything").digest()
    good = f"{digest[0]:02X}0000"
    ok = unpack1(p.verifyHash(digest, good.encode()))
    check("verifyHash accepts matching check byte", ok, True)
    ok, err = p.verifyHash(digest, f"{(digest[0] + 1) % 256:02X}0000".encode())
    check("verifyHash rejects wrong check byte", ok, False)
    print(f"       ({err.decode() if isinstance(err, bytes) else err})")

    print()
    if failures:
        print(f"{len(failures)}/{checks} FAILED:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print(f"all {checks} checks passed")


if __name__ == "__main__":
    main()
