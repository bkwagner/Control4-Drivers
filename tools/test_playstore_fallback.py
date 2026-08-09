#!/usr/bin/env python3
"""Validate the driver's Play Store fallback end to end, in one connection.

Some apps cannot be launched by app link on this hardware: the device opens their
Play Store page instead, with "Open" focused. Pressing OK there launches the app,
but only once the page has settled - an immediate press is swallowed.

This reproduces exactly what the driver does, on one session, so the settle delay
can be calibrated rather than guessed:

    launch package -> wait for com.android.vending -> wait N -> press OK -> observe

    python tools/test_playstore_fallback.py 10.200.10.50 com.wbd.stream --settle 5
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

try:
    from androidtvremote2 import AndroidTVRemote, CannotConnect, InvalidAuth
except ImportError:
    sys.exit("error: pip install -r tools/requirements.txt")

PLAYSTORE = "com.android.vending"
LAUNCHER = "com.google.android.apps.tv.launcherx"


def _paths(cert_dir: Path, host: str) -> tuple[Path, Path]:
    stem = host.replace(".", "_")
    return cert_dir / f"{stem}_cert.pem", cert_dir / f"{stem}_key.pem"


async def main_async(args: argparse.Namespace) -> int:
    certfile, keyfile = _paths(args.cert_dir, args.host)
    if not certfile.exists():
        return print(f"error: no paired cert for {args.host}") or 1

    remote = AndroidTVRemote("Control4", str(certfile), str(keyfile), args.host)

    seen: list[str] = []
    remote.add_current_app_updated_callback(lambda v: seen.append(v))

    try:
        await remote.async_connect()
    except (InvalidAuth, CannotConnect) as exc:
        return print(f"error: {exc}") or 1

    # Start from the launcher so the result is unambiguous.
    remote.send_key_command("KEYCODE_HOME")
    await asyncio.sleep(4)
    seen.clear()

    print(f"launching {args.package}")
    remote.send_launch_app_command(args.package)

    # Wait for the device to settle on something.
    store_at = None
    for tick in range(args.timeout * 2):
        await asyncio.sleep(0.5)
        if remote.current_app == args.package:
            print(f"  launched directly after {tick / 2:.1f}s - no fallback needed")
            remote.disconnect()
            return 0
        if remote.current_app == PLAYSTORE and store_at is None:
            store_at = tick / 2
            print(f"  Play Store appeared after {store_at:.1f}s")
            break

    if store_at is None:
        print(f"  neither app nor store appeared; current_app={remote.current_app!r}")
        remote.disconnect()
        return 1

    print(f"  waiting {args.settle}s for the page to settle")
    await asyncio.sleep(args.settle)

    print("  pressing OK")
    remote.send_key_command("KEYCODE_DPAD_CENTER")

    for tick in range(args.timeout * 2):
        await asyncio.sleep(0.5)
        if remote.current_app == args.package:
            print(f"\nSUCCESS: {args.package} launched "
                  f"{tick / 2:.1f}s after the OK press")
            print(f"  app trail: {seen}")
            remote.disconnect()
            return 0

    print(f"\nFAILED: still at {remote.current_app!r} after {args.timeout}s")
    print(f"  app trail: {seen}")
    print("  try a longer --settle")
    remote.disconnect()
    return 1


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("package")
    ap.add_argument("--settle", type=float, default=5.0,
                    help="seconds to wait after the store appears (default: 5)")
    ap.add_argument("--timeout", type=int, default=20)
    ap.add_argument("--cert-dir", type=Path, default=Path("certs"))
    sys.exit(asyncio.run(main_async(ap.parse_args())))


if __name__ == "__main__":
    main()
