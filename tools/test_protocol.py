#!/usr/bin/env python3
"""Verify the Lua protobuf encoder byte-for-byte against Google's implementation.

The Lua encoder is hand-rolled, so every message it builds is compared against the
same message serialized by the real protobuf library. Parsing is checked in the
other direction: Python serializes, Lua parses, fields must match.

Runs the actual driver Lua under lupa - no reimplementation, no mocks.

    python tools/test_protocol.py
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import lupa
except ImportError:
    sys.exit("error: pip install lupa")

try:
    from androidtvremote2.remotemessage_pb2 import RemoteMessage
except ImportError:
    sys.exit("error: pip install -r tools/requirements.txt")

REPO = Path(__file__).resolve().parent.parent
DRIVER = REPO / "driver"

failures: list[str] = []
checks = 0


def lua_runtime() -> lupa.LuaRuntime:
    # encoding=None keeps Lua strings as Python bytes. Protobuf payloads are binary
    # and are not valid UTF-8, so any decoding on the boundary corrupts them.
    # Not unpack_returned_tuples: `require` returns (module, loader) in Lua 5.4 and
    # unpacking turns every module handle into a tuple.
    lua = lupa.LuaRuntime(encoding=None)
    lua.execute(f'package.path = [[{DRIVER.as_posix()}/?.lua]] .. ";" .. package.path'.encode())
    return lua


def require(lua, module: str):
    """`require` yields (module, loader) in Lua 5.4; wrap so one value comes back."""
    return lua.eval(f"(function() return (require('{module}')) end)()".encode())


def g(table, key: str):
    """Lua table keys arrive as bytes under encoding=None."""
    return table[key.encode()]


def norm(v):
    """Compare Lua bytes and Python str on equal terms."""
    if isinstance(v, bytes):
        return v.decode("latin-1")
    if isinstance(v, (list, tuple)):
        return [norm(x) for x in v]
    return v


def framed(msg: RemoteMessage) -> bytes:
    """Length-delimited encoding, matching pb.frame() in Lua."""
    body = msg.SerializeToString()
    out, n = bytearray(), len(body)
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | 0x80 if n else b)
        if not n:
            break
    return bytes(out) + body


def check(label: str, got: bytes, want: bytes) -> None:
    global checks
    checks += 1
    if got == want:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        print(f"       lua      : {got.hex(' ')}")
        print(f"       protobuf : {want.hex(' ')}")
        failures.append(label)


def check_eq(label: str, got, want) -> None:
    global checks
    checks += 1
    got, want = norm(got), norm(want)
    if got == want:
        print(f"  ok   {label}  ({got!r})")
    else:
        print(f"  FAIL {label}: got {got!r}, want {want!r}")
        failures.append(label)


def test_varint(lua) -> None:
    print("varint encoding")
    pb = require(lua, "lib.protobuf")
    for value, expect in [
        (0, b"\x00"), (1, b"\x01"), (127, b"\x7f"), (128, b"\x80\x01"),
        (300, b"\xac\x02"), (16384, b"\x80\x80\x01"), (622, b"\xee\x04"),
    ]:
        got = pb.encodeVarint(value)
        check(f"encodeVarint({value})", got, expect)


def test_outbound(lua) -> None:
    print("\noutbound messages vs google protobuf")
    atv = require(lua, "lib.atv_protocol")

    # key inject
    m = RemoteMessage()
    m.remote_key_inject.key_code = 22      # KEYCODE_DPAD_RIGHT
    m.remote_key_inject.direction = 3      # SHORT
    check("buildKeyInject(22, SHORT)",
          atv.buildKeyInject(22, 3), framed(m))

    m = RemoteMessage()
    m.remote_key_inject.key_code = 3       # KEYCODE_HOME
    m.remote_key_inject.direction = 1      # START_LONG
    check("buildKeyInject(3, START_LONG)",
          atv.buildKeyInject(3, 1), framed(m))

    # set active
    m = RemoteMessage()
    m.remote_set_active.active = 622
    check("buildSetActive(622)",
          atv.buildSetActive(622), framed(m))

    # ping response
    m = RemoteMessage()
    m.remote_ping_response.val1 = 42
    check("buildPingResponse(42)",
          atv.buildPingResponse(42), framed(m))

    # app link
    link = "https://www.netflix.com/title/80057281"
    m = RemoteMessage()
    m.remote_app_link_launch_request.app_link = link
    check("buildAppLink(netflix)",
          atv.buildAppLink(link.encode()), framed(m))

    # configure - the nested device_info is where field ordering bugs surface
    m = RemoteMessage()
    m.remote_configure.code1 = 622
    m.remote_configure.device_info.unknown1 = 1
    m.remote_configure.device_info.unknown2 = "1"
    m.remote_configure.device_info.package_name = "atvremote"
    m.remote_configure.device_info.app_version = "1.0.0"
    check("buildConfigure(622)",
          atv.buildConfigure(622, b"atvremote", b"1.0.0"), framed(m))


def test_inbound(lua) -> None:
    print("\ninbound parsing (python serializes, lua parses)")
    atv = require(lua, "lib.atv_protocol")

    def parse(m: RemoteMessage):
        return atv.parseMessage(m.SerializeToString())

    m = RemoteMessage()
    m.remote_start.started = True
    r = parse(m)
    check_eq("remote_start.kind", g(r, "kind"), "start")
    check_eq("remote_start.started", g(r, "started"), True)

    m = RemoteMessage()
    m.remote_ping_request.val1 = 9999
    r = parse(m)
    check_eq("ping_request.kind", g(r, "kind"), "ping_request")
    check_eq("ping_request.val1", g(r, "val1"), 9999)

    m = RemoteMessage()
    m.remote_configure.code1 = 622
    m.remote_configure.device_info.model = "Chromecast"
    m.remote_configure.device_info.vendor = "Google"
    m.remote_configure.device_info.app_version = "6.9.906821247"
    r = parse(m)
    check_eq("configure.kind", g(r, "kind"), "configure")
    check_eq("configure.features", g(r, "features"), 622)
    check_eq("configure.model", g(r, "model"), "Chromecast")
    check_eq("configure.vendor", g(r, "vendor"), "Google")

    # current app - nested two levels deep, the fiddliest parse
    m = RemoteMessage()
    m.remote_ime_key_inject.app_info.app_package = "com.google.android.apps.tv.launcherx"
    r = parse(m)
    check_eq("current_app.kind", g(r, "kind"), "current_app")
    check_eq("current_app.package", g(r, "package"), "com.google.android.apps.tv.launcherx")

    m = RemoteMessage()
    m.remote_set_volume_level.volume_max = 100
    m.remote_set_volume_level.volume_level = 37
    m.remote_set_volume_level.volume_muted = False
    r = parse(m)
    check_eq("volume.kind", g(r, "kind"), "volume")
    check_eq("volume.max", g(r, "max"), 100)
    check_eq("volume.level", g(r, "level"), 37)
    check_eq("volume.muted", g(r, "muted"), False)


def test_framing(lua) -> None:
    """TCP splits wherever it likes. This is the classic driver bug, so test it hard."""
    print("\nstream re-framing under fragmentation")
    pb = require(lua, "lib.protobuf")

    msgs = []
    for kc in (19, 20, 21, 22, 23):
        m = RemoteMessage()
        m.remote_key_inject.key_code = kc
        m.remote_key_inject.direction = 3
        msgs.append(m)
    stream = b"".join(framed(m) for m in msgs)
    expected = [m.SerializeToString() for m in msgs]

    for chunk_size in (1, 2, 3, 5, 7, len(stream)):
        buf = pb.newBuffer()
        got = []
        for i in range(0, len(stream), chunk_size):
            pb.push(buf, stream[i:i + chunk_size])
            while True:
                msg = pb.nextMessage(buf)
                if msg is None:
                    break
                got.append(msg)
        check_eq(f"reassembled in {chunk_size}-byte chunks", got, expected)

    # A partial message must yield nothing rather than a corrupt one.
    buf = pb.newBuffer()
    pb.push(buf, stream[:3])
    check_eq("partial message yields nil", pb.nextMessage(buf), None)


def main() -> None:
    lua = lua_runtime()
    test_varint(lua)
    test_outbound(lua)
    test_inbound(lua)
    test_framing(lua)

    print()
    if failures:
        print(f"{len(failures)}/{checks} FAILED:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print(f"all {checks} checks passed")


if __name__ == "__main__":
    main()
