"""The TLS 1.2 ClientHello that the real device is verified to answer.

Single source of truth, shared by:
  - tools/peek_cert.py     - the live probe against the device
  - tools/test_tls_peek.py - compares driver/lib/tls_peek.lua against these bytes

Keep this and the Lua implementation in step. If the device ever stops replying,
change it here, re-run peek_cert.py against hardware, then let the test drag the
Lua into line.
"""

from __future__ import annotations

import struct

# What the device actually negotiates is ECDHE-RSA-AES128-GCM-SHA256 (0xC02F);
# the rest are offered as fallbacks.
CIPHER_SUITES = [0xC02F, 0xC030, 0xC027, 0x009C, 0x002F]


def client_hello(random: bytes = b"\xAA" * 32) -> bytes:
    """Build a complete TLS 1.2 ClientHello record. `random` must be 32 bytes."""
    if len(random) != 32:
        raise ValueError("random must be exactly 32 bytes")

    body = b"\x03\x03"                        # client_version TLS 1.2
    body += random
    body += b"\x00"                           # session_id: empty

    body += struct.pack(">H", len(CIPHER_SUITES) * 2)
    for c in CIPHER_SUITES:
        body += struct.pack(">H", c)
    body += b"\x01\x00"                       # compression: null only

    ext = b""
    groups = struct.pack(">HH", 0x0017, 0x001D)          # secp256r1, x25519
    ext += struct.pack(">HHH", 0x000A, len(groups) + 2, len(groups)) + groups
    ext += struct.pack(">HHB", 0x000B, 2, 1) + b"\x00"   # ec_point_formats
    sigs = struct.pack(">HHHH", 0x0401, 0x0403, 0x0501, 0x0804)
    ext += struct.pack(">HHH", 0x000D, len(sigs) + 2, len(sigs)) + sigs
    body += struct.pack(">H", len(ext)) + ext

    hs = b"\x01" + struct.pack(">I", len(body))[1:] + body   # handshake header
    return b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs  # record header
