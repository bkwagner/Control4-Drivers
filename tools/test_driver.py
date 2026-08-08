#!/usr/bin/env python3
"""Exercise driver/atv/driver.lua without a controller.

Stubs the DriverWorks C4 API and a minimal lua-openssl, loads the real driver,
and drives it through a control session and a pairing exchange - asserting on the
bytes it puts on the wire and the properties it sets.

This catches wiring mistakes (wrong binding, missing ping reply, unmapped key)
that would otherwise cost a Composer round trip each. It does NOT replace testing
on hardware: the stubs are not Director, and lua-openssl is not exercised.

    python tools/test_driver.py
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import lupa
except ImportError:
    sys.exit("error: pip install lupa")

try:
    from androidtvremote2.polo_pb2 import OuterMessage
    from androidtvremote2.remotemessage_pb2 import RemoteMessage
except ImportError:
    sys.exit("error: pip install -r tools/requirements.txt")

REPO = Path(__file__).resolve().parent.parent
DRIVER = REPO / "driver"

failures: list[str] = []
checks = 0

BINDING_CONTROL, PORT_CONTROL = 6001, 6466
BINDING_PROXY = 5001


def check(label: str, got, want) -> None:
    global checks
    checks += 1
    if got == want:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        print(f"       got  {got!r}")
        print(f"       want {want!r}")
        failures.append(label)


LUA_STUBS = rb"""
-- Captures everything the driver sends, plus property writes.
Sent = {}
Props = {}
Calls = {}

Properties = {
    ['Device IP'] = '10.0.0.1',
    ['Client Name'] = 'Control4',
    ['Pairing Code'] = '',
    ['Debug Mode'] = 'Off',
}

local function record(name, ...)
    table.insert(Calls, { name = name, args = { ... } })
end

C4SystemEvents = { OnPIP = 1 }

C4 = {}
function C4:UpdateProperty(name, value)
    Props[name] = value
    Properties[name] = value
end
function C4:SendToNetwork(binding, port, data)
    table.insert(Sent, { binding = binding, port = port, data = data })
end
function C4:PersistGetValue(name) return Persisted and Persisted[name] or nil end
function C4:PersistSetValue(name, value)
    Persisted = Persisted or {}
    Persisted[name] = value
end
function C4:PersistDeleteValue(name)
    if (Persisted) then Persisted[name] = nil end
end
function C4:CreateNetworkConnection(...) record('CreateNetworkConnection', ...) end
function C4:NetPortOptions(...)          record('NetPortOptions', ...) end
function C4:NetConnect(...)              record('NetConnect', ...) end
function C4:NetDisconnect(...)           record('NetDisconnect', ...) end
function C4:AddTimer(...)                record('AddTimer', ...) return 1 end
function C4:KillTimer(...)               record('KillTimer', ...) return nil end
function C4:ErrorLog(...)                record('ErrorLog', ...) end
function C4:GetDeviceID() return 99 end
function C4:RegisterSystemEvent(...) end
function C4:UnregisterSystemEvent(...) end
function C4:RegisterVariableListener(...) end
function C4:UnregisterVariableListener(...) end
function C4:GetDevicesByC4iName(...) return {} end
function C4:GetDeviceVariable(...) return '0' end
function C4:SendToDevice(...) record('SendToDevice', ...) end

-- Mini-app binding chain, configurable per test:
--   switcher proxy 5999 -> device 200
--   input 3101          -> app proxy 300
--   app proxy 5001      -> app protocol driver 400, which publishes the vars
MiniApp = { switcher = 200, byInput = {}, vars = {} }
function C4:GetBoundConsumerDevices(deviceId, binding)
    if (binding == 5999 and MiniApp.switcher) then
        return { [MiniApp.switcher] = 'Google TV Apps' }
    end
    return {}
end
function C4:GetBoundProviderDevice(deviceId, binding)
    if (deviceId == MiniApp.switcher) then return MiniApp.byInput[binding] end
    if (binding == 5001) then return (deviceId and deviceId + 100) end
    return nil
end
function C4:GetDeviceVariables(deviceId)
    return MiniApp.vars[deviceId] or {}
end
function SetMiniApp(input, proxyId, serviceId, appName)
    MiniApp.byInput[input] = proxyId
    MiniApp.vars[proxyId + 100] = {
        { name = 'UM_NV_SHIELD', value = serviceId },
        { name = 'UM_SONY_TV',   value = 'Some Title' },
        { name = 'APP_NAME',     value = appName },
    }
end
function ClearMiniApps() MiniApp.byInput = {}; MiniApp.vars = {} end

-- Minimal lua-openssl. Only the calls the driver makes on paths under test.
package.preload['openssl'] = function()
    local bio = {}
    function bio.file(path, mode)
        return { write = function() end, close = function() end }
    end
    return {
        bio = bio,
        random = function(n) return string.rep('\170', n) end,
        digest = { digest = function(alg, data, raw) return string.rep('\1', 32) end },
    }
end

function ClearSent() Sent = {} end
function SentCount() return #Sent end
function SentData(i) return Sent[i] and Sent[i].data or nil end
function SentBinding(i) return Sent[i] and Sent[i].binding or nil end
function Prop(name) return Props[name] end
function SetPaired(cert, key)
    Persisted = { client_cert_pem = cert, client_key_pem = key }
end
"""


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


def load_driver():
    lua = lupa.LuaRuntime(encoding=None)
    lua.execute(f'package.path = [[{DRIVER.as_posix()}/?.lua]] .. ";" .. package.path'.encode())
    lua.execute(LUA_STUBS)
    lua.execute((DRIVER / "atv" / "driver.lua").read_bytes())
    return lua


def print_miniapp_tests(lua, g) -> None:
    """Navigator selecting a bound app minidriver must launch it on the device."""
    print()
    print("mini-app launching")

    g.SetMiniApp(3101, 300, b"org.jellyfin.androidtv", b"Jellyfin")
    g.SetMiniApp(3102, 310, b"com.wbd.stream", b"HBO Max")

    def set_input(value):
        params = lua.table()
        params[b"INPUT"] = value
        g.ClearSent()
        g.ReceivedFromProxy(5999, b"SET_INPUT", params)

    for input_id, want in [(3101, b"org.jellyfin.androidtv"), (3102, b"com.wbd.stream")]:
        set_input(input_id)
        data = g.SentData(1)
        if data is None:
            check(f"input {input_id} launches {want.decode()}", "nothing sent", want)
            continue
        msg = RemoteMessage()
        msg.ParseFromString(data[1:])
        check(f"input {input_id} launches {want.decode()}",
              msg.remote_app_link_launch_request.app_link.encode(), want)

    set_input(3110)
    check("unbound mini-app input launches nothing", g.SentCount(), 0)

    set_input(9999)
    check("out-of-range input ignored", g.SentCount(), 0)

    # While a mini-app is the selected source, remote keys arrive wrapped as
    # PASSTHROUGH on the switcher binding and must still reach the device.
    params = lua.table()
    params[b"PASSTHROUGH_COMMAND"] = b"UP"
    g.ClearSent()
    g.ReceivedFromProxy(5999, b"PASSTHROUGH", params)
    data = g.SentData(1)
    if data is None:
        check("PASSTHROUGH UP reaches the device", "nothing sent", "key 19")
    else:
        msg = RemoteMessage()
        msg.ParseFromString(data[1:])
        check("PASSTHROUGH UP reaches the device", msg.remote_key_inject.key_code, 19)


def main() -> None:
    lua = load_driver()
    g = lua.globals()

    print("control session")
    g.OnDriverInit()
    g.OnConnectionStatusChanged(BINDING_CONTROL, PORT_CONTROL, b"ONLINE")
    g.ClearSent()

    # Device configures us; the driver must answer with its own RemoteConfigure.
    m = RemoteMessage()
    m.remote_configure.code1 = 622
    m.remote_configure.device_info.model = "Chromecast"
    m.remote_configure.device_info.vendor = "Google"
    g.ReceivedFromNetwork(BINDING_CONTROL, PORT_CONTROL, framed(m))
    check("replies to RemoteConfigure", g.SentCount(), 1)
    reply = RemoteMessage()
    reply.ParseFromString(g.SentData(1)[1:])
    check("reply is a remote_configure", reply.HasField("remote_configure"), True)
    check("reply carries package name",
          reply.remote_configure.device_info.package_name, "atvremote")
    # We want 615; the device offers 622; the intersection is 614 (PING dropped).
    check("features masked to what the device offers", reply.remote_configure.code1, 614)

    # Ping must be answered or the device hangs up.
    g.ClearSent()
    m = RemoteMessage()
    m.remote_ping_request.val1 = 4242
    g.ReceivedFromNetwork(BINDING_CONTROL, PORT_CONTROL, framed(m))
    reply = RemoteMessage()
    reply.ParseFromString(g.SentData(1)[1:])
    check("answers ping", reply.HasField("remote_ping_response"), True)
    check("echoes ping val1", reply.remote_ping_response.val1, 4242)

    # State reporting.
    m = RemoteMessage()
    m.remote_ime_key_inject.app_info.app_package = "com.netflix.ninja"
    g.ReceivedFromNetwork(BINDING_CONTROL, PORT_CONTROL, framed(m))
    check("updates Current App", g.Prop(b"Current App"), b"com.netflix.ninja")

    m = RemoteMessage()
    m.remote_start.started = True
    g.ReceivedFromNetwork(BINDING_CONTROL, PORT_CONTROL, framed(m))
    check("updates Power State", g.Prop(b"Power State"), b"On")

    # Two messages arriving in one TCP read must both be handled.
    g.ClearSent()
    a, b = RemoteMessage(), RemoteMessage()
    a.remote_ping_request.val1 = 1
    b.remote_ping_request.val1 = 2
    g.ReceivedFromNetwork(BINDING_CONTROL, PORT_CONTROL, framed(a) + framed(b))
    check("handles two messages in one read", g.SentCount(), 2)

    print("\nproxy commands")
    cases = [(b"UP", 19, 3), (b"ENTER", 23, 3), (b"CANCEL", 4, 3),
             (b"NUMBER_7", 14, 3), (b"PROGRAM_C", 185, 3),
             (b"START_SCAN_FWD", 90, 1), (b"STOP_SCAN_FWD", 90, 2)]
    for command, want_key, want_dir in cases:
        g.ClearSent()
        g.ReceivedFromProxy(BINDING_PROXY, command, lua.table())
        data = g.SentData(1)
        if data is None:
            check(f"{command.decode()} sent", "nothing", f"key {want_key}")
            continue
        msg = RemoteMessage()
        msg.ParseFromString(data[1:])
        check(f"{command.decode():<15} -> key {want_key} dir {want_dir}",
              (msg.remote_key_inject.key_code, msg.remote_key_inject.direction),
              (want_key, want_dir))

    g.ClearSent()
    g.ReceivedFromProxy(BINDING_PROXY, b"NONSENSE_COMMAND", lua.table())
    check("unmapped command sends nothing", g.SentCount(), 0)

    # Observed on hardware: a tap is NAME then END_NAME. The tap is already a
    # complete SHORT press, so the release must not produce a second key event.
    for command in (b"END_DOWN", b"END_ENTER", b"END_MENU", b"END_CANCEL"):
        g.ClearSent()
        g.ReceivedFromProxy(BINDING_PROXY, command, lua.table())
        check(f"{command.decode():<15} ignored, sends nothing", g.SentCount(), 0)

    # Press-and-hold on a navigation key: START_/STOP_ are a real key down and up.
    for command, want_key, want_dir in [(b"START_RIGHT", 22, 1), (b"STOP_RIGHT", 22, 2),
                                        (b"START_DOWN", 20, 1), (b"STOP_DOWN", 20, 2)]:
        g.ClearSent()
        g.ReceivedFromProxy(BINDING_PROXY, command, lua.table())
        data = g.SentData(1)
        if data is None:
            check(f"{command.decode()} sent", "nothing", f"key {want_key}")
            continue
        msg = RemoteMessage()
        msg.ParseFromString(data[1:])
        check(f"{command.decode():<15} -> key {want_key} dir {want_dir}",
              (msg.remote_key_inject.key_code, msg.remote_key_inject.direction),
              (want_key, want_dir))

    # Room selection should wake the streamer, not toggle power (CEC would reach
    # the TV, which Control4 already controls).
    for command, want_key in [(b"ON", 224), (b"SELECT_SOURCE", 224),
                              (b"OFF", 223), (b"ROOM_OFF", 223)]:
        g.ClearSent()
        g.ReceivedFromProxy(BINDING_PROXY, command, lua.table())
        data = g.SentData(1)
        if data is None:
            check(f"{command.decode()} sent", "nothing", f"key {want_key}")
            continue
        msg = RemoteMessage()
        msg.ParseFromString(data[1:])
        check(f"{command.decode():<15} -> key {want_key}",
              msg.remote_key_inject.key_code, want_key)

    # Volume must not be mapped - Control4 owns it over CEC.
    for command in (b"START_VOL_UP", b"MUTE_TOGGLE", b"STOP_VOL_DOWN", b"END_VOL_UP"):
        g.ClearSent()
        g.ReceivedFromProxy(BINDING_PROXY, command, lua.table())
        check(f"{command.decode():<15} deliberately unmapped", g.SentCount(), 0)

    print("\npairing exchange")
    print_miniapp_tests(lua, g)

    lua2 = load_driver()
    h = lua2.globals()
    h.OnDriverInit()
    # Jump straight to the polo exchange; cert harvesting needs a real socket.
    h.Driver.pairStage = b"exchange"
    h.Driver.pairBuf = lua2.eval(b"(function() return (require('lib.protobuf')) end)()").newBuffer()
    h.ClearSent()

    def polo(**kw):
        msg = OuterMessage()
        msg.protocol_version = 2
        msg.status = OuterMessage.Status.STATUS_OK
        for field, value in kw.items():
            getattr(msg, field).SetInParent()
            if field == "secret_ack":
                msg.secret_ack.secret = bytes(range(32))
        return framed(msg)

    h.ReceivedFromNetwork(6002, 6467, polo(pairing_request_ack=True))
    sent = OuterMessage()
    sent.ParseFromString(h.SentData(1)[1:])
    check("request_ack -> options", sent.HasField("options"), True)
    check("options requests hex encoding",
          sent.options.input_encodings[0].symbol_length, 6)

    h.ClearSent()
    h.ReceivedFromNetwork(6002, 6467, polo(options=True))
    sent = OuterMessage()
    sent.ParseFromString(h.SentData(1)[1:])
    check("options -> configuration", sent.HasField("configuration"), True)

    h.ClearSent()
    h.ReceivedFromNetwork(6002, 6467, polo(configuration_ack=True))
    check("configuration_ack -> awaits code", h.Driver.pairStage, b"awaiting_code")
    check("prompts for the code", b"Pairing Code" in (h.Prop(b"Status") or b""), True)

    # A non-OK status must abort rather than continue.
    lua3 = load_driver()
    k = lua3.globals()
    k.OnDriverInit()
    k.Driver.pairStage = b"exchange"
    k.Driver.pairBuf = lua3.eval(b"(function() return (require('lib.protobuf')) end)()").newBuffer()
    bad = OuterMessage()
    bad.protocol_version = 2
    bad.status = OuterMessage.Status.STATUS_BAD_SECRET
    bad.secret_ack.secret = bytes(range(32))
    k.ReceivedFromNetwork(6002, 6467, framed(bad))
    check("non-OK status aborts pairing", k.Driver.pairStage, None)
    check("reports rejection", b"rejected" in (k.Prop(b"Status") or b""), True)

    print()
    if failures:
        print(f"{len(failures)}/{checks} FAILED:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print(f"all {checks} checks passed")


if __name__ == "__main__":
    main()
