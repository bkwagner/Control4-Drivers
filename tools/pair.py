#!/usr/bin/env python3
"""Pair with a Google TV / Android TV device and persist the client certificate.

This runs on a desktop, not on the controller. Pairing is impossible in-driver: the
Android TV Remote v2 pairing handshake hashes BOTH certificates' public keys together
with the on-screen code, and DriverWorks never exposes the peer certificate to Lua.

Pairing is one-time. The client certificate produced here IS the persistent identity -
every later session is just an mTLS handshake on port 6466. Guard these files; losing
them means re-pairing, which needs physical access to read a code off the TV.

Usage:
    python tools/pair.py 10.200.10.50
    python tools/pair.py 10.200.10.50 --verify        # test an existing cert
    python tools/pair.py 10.200.10.50 --print-pem     # emit PEMs for driver import
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

try:
    from androidtvremote2 import (
        AndroidTVRemote,
        CannotConnect,
        ConnectionClosed,
        InvalidAuth,
    )
except ImportError:
    sys.exit(
        "error: androidtvremote2 is not installed.\n"
        "       pip install -r tools/requirements.txt"
    )

DEFAULT_CERT_DIR = Path("certs")
CLIENT_NAME = "Control4"


def _paths(cert_dir: Path, host: str) -> tuple[Path, Path]:
    """One identity per device, so several TVs can be paired side by side."""
    stem = host.replace(".", "_").replace(":", "_")
    return cert_dir / f"{stem}_cert.pem", cert_dir / f"{stem}_key.pem"


async def pair(host: str, cert_dir: Path, client_name: str) -> int:
    certfile, keyfile = _paths(cert_dir, host)
    cert_dir.mkdir(parents=True, exist_ok=True)

    if certfile.exists():
        print(f"note: {certfile} already exists - pairing again will overwrite the")
        print("      identity, and the device will show a new code.")
        if input("continue? [y/N] ").strip().lower() != "y":
            return 1

    remote = AndroidTVRemote(client_name, str(certfile), str(keyfile), host)

    if await remote.async_generate_cert_if_missing():
        print(f"generated a new client certificate -> {certfile}")

    print(f"starting pairing with {host} ...")
    try:
        await remote.async_start_pairing()
    except CannotConnect as exc:
        print(f"error: could not reach {host}:6467 - {exc}")
        print("       check the IP, and that the device is awake with Network Standby on.")
        return 1

    print()
    print("  >> A 6-character code should now be on the TV screen. <<")
    print()
    code = input("  enter the code: ").strip()

    try:
        await remote.async_finish_pairing(code)
    except InvalidAuth as exc:
        print(f"error: pairing rejected - {exc}")
        print("       wrong code, or it expired. Run again for a fresh one.")
        return 1
    except ConnectionClosed as exc:
        print(f"error: device closed the connection - {exc}")
        return 1

    print()
    print("PAIRED.")
    print(f"  cert : {certfile}")
    print(f"  key  : {keyfile}")
    print()
    print("These are the device identity. They are gitignored - keep a backup somewhere")
    print("safe, because losing them means re-pairing at the TV.")
    print()
    print("Verifying by opening a control connection ...")
    return await verify(host, cert_dir, client_name)


async def verify(host: str, cert_dir: Path, client_name: str) -> int:
    """Connect on 6466 with the paired cert and read back live state.

    This is the real proof the certificate was accepted - a TLS 1.3 handshake can
    look successful before the server validates the client cert, so only a
    connection that stays open and yields state actually confirms pairing.
    """
    certfile, keyfile = _paths(cert_dir, host)
    if not certfile.exists() or not keyfile.exists():
        print(f"error: no certificate for {host} in {cert_dir}/ - pair first")
        return 1

    remote = AndroidTVRemote(client_name, str(certfile), str(keyfile), host)
    try:
        await remote.async_connect()
    except InvalidAuth as exc:
        print(f"error: the device rejected this certificate - {exc}")
        print("       the cert is not paired (or was invalidated). Pair again.")
        return 1
    except CannotConnect as exc:
        print(f"error: could not reach {host}:6466 - {exc}")
        return 1

    print("  connected on 6466 - certificate accepted.")
    print()
    print(f"  device_info  : {remote.device_info}")
    print(f"  is_on        : {remote.is_on}")
    print(f"  current_app  : {remote.current_app}")
    print(f"  volume_info  : {remote.volume_info}")
    print()
    print("Those four are the feedback channel the driver will report to Navigators.")

    remote.disconnect()
    return 0


def print_pem(host: str, cert_dir: Path) -> int:
    """Dump the PEMs for pasting into a driver property."""
    certfile, keyfile = _paths(cert_dir, host)
    if not certfile.exists() or not keyfile.exists():
        print(f"error: no certificate for {host} in {cert_dir}/ - pair first")
        return 1

    for label, path in (("CERTIFICATE", certfile), ("PRIVATE KEY", keyfile)):
        print(f"===== {label} ({path}) =====")
        print(path.read_text().strip())
        print()
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("host", help="device IP address, e.g. 10.200.10.50")
    parser.add_argument(
        "--cert-dir", type=Path, default=DEFAULT_CERT_DIR,
        help=f"where certs live (default: {DEFAULT_CERT_DIR}/)",
    )
    parser.add_argument(
        "--client-name", default=CLIENT_NAME,
        help=f"name the TV shows for this client (default: {CLIENT_NAME})",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--verify", action="store_true",
        help="skip pairing; just test an existing certificate on port 6466",
    )
    group.add_argument(
        "--print-pem", action="store_true",
        help="print the stored PEMs for pasting into a driver property",
    )
    args = parser.parse_args()

    if args.print_pem:
        sys.exit(print_pem(args.host, args.cert_dir))

    coro = (
        verify(args.host, args.cert_dir, args.client_name)
        if args.verify
        else pair(args.host, args.cert_dir, args.client_name)
    )
    try:
        sys.exit(asyncio.run(coro))
    except KeyboardInterrupt:
        print("\naborted")
        sys.exit(130)


if __name__ == "__main__":
    main()
