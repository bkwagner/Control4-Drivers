#!/usr/bin/env python3
"""Can we harvest the device's server certificate over RAW TCP, no TLS library?

In TLS 1.2 the server's Certificate handshake message is sent in plaintext, before
ChangeCipherSpec. If a hand-rolled ClientHello is enough to make the device send it,
then a Lua driver could do the same and extract the server's public key - which is
the one missing input to the pairing hash.

This is the feasibility probe for in-driver pairing.
"""

import socket
import struct
import sys

HOST, PORT = sys.argv[1] if len(sys.argv) > 1 else "10.200.10.50", 6467


def client_hello() -> bytes:
    body = b""
    body += b"\x03\x03"                       # client_version TLS 1.2
    body += b"\xAA" * 32                      # random (fixed; we never finish)
    body += b"\x00"                           # session_id length
    ciphers = [0xC02F, 0xC030, 0xC027, 0x009C, 0x002F]
    body += struct.pack(">H", len(ciphers) * 2)
    for c in ciphers:
        body += struct.pack(">H", c)
    body += b"\x01\x00"                       # compression: null

    ext = b""
    groups = struct.pack(">HH", 0x0017, 0x001D)          # secp256r1, x25519
    ext += struct.pack(">HHH", 0x000A, len(groups) + 2, len(groups)) + groups
    ext += struct.pack(">HHB", 0x000B, 2, 1) + b"\x00"   # ec_point_formats
    sigs = struct.pack(">HHHH", 0x0401, 0x0403, 0x0501, 0x0804)
    ext += struct.pack(">HHH", 0x000D, len(sigs) + 2, len(sigs)) + sigs
    body += struct.pack(">H", len(ext)) + ext

    hs = b"\x01" + struct.pack(">I", len(body))[1:] + body       # handshake header
    return b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs      # record header


def main() -> None:
    s = socket.socket()
    s.settimeout(8)
    s.connect((HOST, PORT))
    s.send(client_hello())

    data = b""
    try:
        while len(data) < 16384:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\x0b" in data[5:6] or len(data) > 2000:
                pass
    except socket.timeout:
        pass
    finally:
        s.close()

    print(f"received {len(data)} bytes")
    if not data:
        print("FAIL: device sent nothing")
        return

    # Walk TLS records, concatenating handshake payloads.
    hs, pos = b"", 0
    while pos + 5 <= len(data):
        ctype, _ver, ln = data[pos], data[pos + 1:pos + 3], struct.unpack(">H", data[pos + 3:pos + 5])[0]
        payload = data[pos + 5:pos + 5 + ln]
        if ctype == 0x16:
            hs += payload
        elif ctype == 0x15:
            print(f"  alert record: {payload.hex()}")
        pos += 5 + ln

    # Walk handshake messages looking for Certificate (11).
    pos = 0
    while pos + 4 <= len(hs):
        mtype = hs[pos]
        mlen = int.from_bytes(hs[pos + 1:pos + 4], "big")
        body = hs[pos + 4:pos + 4 + mlen]
        name = {1: "ClientHello", 2: "ServerHello", 11: "Certificate",
                12: "ServerKeyExchange", 13: "CertificateRequest", 14: "ServerHelloDone"}
        print(f"  handshake msg type={mtype} ({name.get(mtype, '?')}) len={mlen}")
        if mtype == 11:
            list_len = int.from_bytes(body[0:3], "big")
            cert_len = int.from_bytes(body[3:6], "big")
            der = body[6:6 + cert_len]
            print(f"\nSUCCESS: harvested server certificate, {cert_len} bytes DER")
            print(f"  first bytes: {der[:24].hex(' ')}")
            try:
                import hashlib
                print(f"  sha256: {hashlib.sha256(der).hexdigest()}")
            except Exception:
                pass
            open("server_cert.der", "wb").write(der)
            print("  written to server_cert.der")
            return
        pos += 4 + mlen

    print("FAIL: no Certificate message found")


if __name__ == "__main__":
    main()
