#!/usr/bin/env python3
"""Send key codes to a paired device and watch the state feedback channel.

Desktop smoke test. Use it to confirm the protocol end to end, and as the reference
behaviour the Lua driver has to reproduce.

Requires a paired certificate - run tools/pair.py first.

Usage:
    python tools/send_key.py 192.0.2.10 KEYCODE_DPAD_DOWN
    python tools/send_key.py 192.0.2.10 KEYCODE_DPAD_DOWN --direction START_LONG
    python tools/send_key.py 192.0.2.10 --launch https://www.netflix.com/title/80057281
    python tools/send_key.py 192.0.2.10 --watch 30      # just observe state

    # TV in another room: start it, walk over, watch 10 presses land
    python tools/send_key.py 192.0.2.10 KEYCODE_DPAD_DOWN --delay 30 --repeat 10
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

DEFAULT_CERT_DIR = Path("certs")
CLIENT_NAME = "Control4"


def _paths(cert_dir: Path, host: str) -> tuple[Path, Path]:
    stem = host.replace(".", "_").replace(":", "_")
    return cert_dir / f"{stem}_cert.pem", cert_dir / f"{stem}_key.pem"


async def run(args: argparse.Namespace) -> int:
    certfile, keyfile = _paths(args.cert_dir, args.host)
    if not certfile.exists():
        print(f"error: no paired certificate for {args.host} - run tools/pair.py first")
        return 1

    remote = AndroidTVRemote(CLIENT_NAME, str(certfile), str(keyfile), args.host)

    # Register before connecting so we catch the initial burst of state.
    remote.add_is_on_updated_callback(lambda v: print(f"  [state] is_on       -> {v}"))
    remote.add_current_app_updated_callback(lambda v: print(f"  [state] current_app -> {v!r}"))
    remote.add_volume_info_updated_callback(lambda v: print(f"  [state] volume_info -> {v}"))

    try:
        await remote.async_connect()
    except InvalidAuth:
        print("error: device rejected the certificate - re-pair with tools/pair.py")
        return 1
    except CannotConnect as exc:
        print(f"error: could not reach {args.host}:6466 - {exc}")
        return 1

    print(f"connected to {args.host}:6466")
    print(f"  device      : {remote.device_info}")
    print(f"  is_on       : {remote.is_on}")
    print(f"  current_app : {remote.current_app!r}")
    print(f"  volume_info : {remote.volume_info}")
    print()

    # The controller and the TV are usually in different rooms. --delay gives you
    # time to walk over and actually watch the thing happen.
    if args.delay:
        print(f"waiting {args.delay:.0f}s before acting - go watch the TV ...")
        for remaining in range(int(args.delay), 0, -5):
            print(f"  {remaining}s ...")
            await asyncio.sleep(min(5, remaining))
        print("  go!")

    if args.launch:
        print(f"launching {args.launch}")
        remote.send_launch_app_command(args.launch)
    elif args.keycode:
        for i in range(args.repeat):
            print(f"sending {args.keycode} direction={args.direction}"
                  f"{f'  [{i + 1}/{args.repeat}]' if args.repeat > 1 else ''}")
            remote.send_key_command(args.keycode, args.direction)
            if i + 1 < args.repeat:
                await asyncio.sleep(args.interval)

    # State arrives asynchronously; give the device time to report the consequence.
    print(f"watching for {args.watch}s ...")
    await asyncio.sleep(args.watch)

    print()
    print("final state:")
    print(f"  is_on       : {remote.is_on}")
    print(f"  current_app : {remote.current_app!r}")
    print(f"  volume_info : {remote.volume_info}")

    remote.disconnect()
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("host", help="device IP address")
    parser.add_argument("keycode", nargs="?", help="e.g. KEYCODE_DPAD_DOWN")
    parser.add_argument(
        "--direction", default="SHORT",
        choices=["SHORT", "START_LONG", "END_LONG", "UNKNOWN_DIRECTION"],
        help="key press style (default: SHORT)",
    )
    parser.add_argument("--launch", help="deep link or app id to launch instead of a key")
    parser.add_argument(
        "--delay", type=float, default=0.0,
        help="seconds to wait before acting, so you can go and watch the TV",
    )
    parser.add_argument(
        "--repeat", type=int, default=1, help="send the key this many times (default: 1)",
    )
    parser.add_argument(
        "--interval", type=float, default=1.5,
        help="seconds between repeats (default: 1.5)",
    )
    parser.add_argument(
        "--watch", type=float, default=5.0,
        help="seconds to observe state after acting (default: 5)",
    )
    parser.add_argument("--cert-dir", type=Path, default=DEFAULT_CERT_DIR)
    args = parser.parse_args()

    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        print("\naborted")
        sys.exit(130)


if __name__ == "__main__":
    main()
