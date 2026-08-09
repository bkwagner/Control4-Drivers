# Control4 ↔ Google TV driver

Control a Google TV / Android TV device from Control4 over the **Android TV Remote
protocol v2** (mTLS + length-prefixed protobuf on ports 6467/6466). No ADB.

Full background, prior art, and milestones: [docs/BRIEF.md](docs/BRIEF.md).

## Layout

| Path | What |
|---|---|
| `docs/BRIEF.md` | Original project brief — protocol background, prior art, milestones |
| `docs/spike-01-findings.md` | Capability research + the pending go/no-go test |
| `spikes/01_openssl_capability.lua` | Paste-into-Composer-Lua-window probe, no install needed |
| `driver/atv/` | **The driver.** `media_player` proxy, pairing, full keymap |
| `driver/atv_spike/` | Minimal `.c4z` that tests the mTLS handshake |
| `driver/lib/` | Shared Lua modules, bundled into every `.c4z` under `lib/` |
| `docs/protocol-reference.md` | Generated schema reference — field numbers, framing |
| `tools/pair.py` | **Desktop** one-time pairing tool — produces the client identity |
| `tools/send_key.py` | Desktop smoke test — send keys, watch state feedback |
| `tools/test_protocol.py` | Runs the driver's Lua against real protobuf |
| `tools/dump_protocol.py` | Regenerates the protocol reference and keycode table |
| `tools/build_c4z.py` | Packages a driver dir into an unencrypted `.c4z` |
| `certs/` | Paired identities, one per device. **Gitignored — back these up.** |

Build the driver, then run the full test suite (97 checks):

```bash
python tools/build_c4z.py driver/atv && for t in protocol pairing tls_peek driver; do python tools/test_$t.py || break; done
```

`tools/test_driver.py` stubs the DriverWorks C4 API and loads the real `driver.lua`,
so the state machine, keymap and pairing exchange are exercised off-device. It does
not replace hardware testing — the stubs are not Director, and lua-openssl is not
exercised by it.

`driver/lib/` is bundled as `lib/` in the archive, so driver code uses
`require('lib.protobuf')` — DriverWorks maps dots to directories from the c4z root.

## Architecture — DECIDED (spike passed 2026-08-08)

**Native Lua driver. No sidecar bridge, no container.** The brief framed this as
Option A (bridge) vs Option B (native); the spike settled it in favour of a variant of
B. Full evidence in [docs/spike-01-findings.md](docs/spike-01-findings.md).

**Three facts, all verified on hardware:**

1. lua-openssl (v0.8.5) is available from OS 3.4.1, but its `ssl` module and all `bio`
   socket methods are **removed**. It can mint keys and certs; it cannot open a socket.
2. Director's own network stack **does** do mutual TLS — `C4:NetPortOptions` with
   `CERTIFICATE` + `PRIVATE_KEY` + `VERIFY_METHOD='sslv23'` reached `ONLINE` on 6467.
3. **No API exposes the peer certificate to Lua** — but this is *not* a blocker for
   pairing, as first assumed. See below.

### Pairing can happen in-driver (proven 2026-08-08)

The pairing hash is `SHA256(client_modulus, client_exponent, server_modulus,
server_exponent, code)`. The client half is ours; the server half arrives only as the
TLS peer certificate, which Director will not give us.

It can be fetched independently. **In TLS 1.2 the server's Certificate message is sent
in plaintext**, before ChangeCipherSpec. A raw TCP connection with a hand-rolled
ClientHello is enough to make the device send it — verified against the real device by
`tools/peek_cert.py`, which recovers an 836-byte DER cert whose SHA-256 matches exactly
what `openssl s_client` negotiates. RSA-2048, exponent 65537.

So the driver can be fully self-contained:

```
raw TCP 6467   -> hand-rolled ClientHello -> parse ServerHello/Certificate -> server pubkey
lua-openssl    -> generate client keypair + self-signed x509
mTLS 6467      -> pairing exchange, hash both keys with the on-screen code
persist        -> PersistSetValue(..., encrypted) -> reused forever
mTLS 6466      -> normal operation
```

**Risk to keep in view:** this depends on TLS 1.2 being offered. Under TLS 1.3 the
Certificate message is encrypted and this technique dies. The device currently accepts
both. If Google ever forces 1.3-only, cert harvesting breaks and pairing falls back to
`tools/pair.py` — which is why that tool stays in the repo rather than being deleted.

Verified working call shapes and the PKCS#8 key-format caveat are recorded in
[docs/spike-01-findings.md](docs/spike-01-findings.md) — read it before writing crypto
code, as the upstream lua-openssl docs are wrong about `x509.req.new`.

**Consequence — pair out of band, run natively:**

```
one time:   desktop pairing tool  ──mTLS 6467──> Google TV   (reads on-screen code)
                    │
                    └─> client cert + key ──> imported into the driver
                    
every day:  Control4 driver ──mTLS 6466──> Google TV         (no bridge, no container)
```

This keeps the driver self-contained — no always-on service — while routing around
the peer-cert limitation. It hinges on one unverified assumption: that Director can
complete an mTLS handshake with this device. **That is what the spike measures, and
nothing else should be built until it resolves.**

## Status: the driver works

Paired and connected entirely from the controller on 2026-08-08, with no desktop
tool involved. Observed sequence:

```
generating client identity -> reading device certificate
  harvested server certificate: 836 bytes
  server public key: modulus 256 bytes, exponent 3 bytes
connecting to pairing service -> enter code -> secret sent
Paired. Connecting. -> Connected
  device: Google Chromecast (features 639)
  power state: true
  current app: com.google.android.apps.tv.launcherx
```

The device advertises feature mask **639** (everything, including APP_LINK).

## Verified end to end

Milestones 1-4 of [docs/BRIEF.md](docs/BRIEF.md) are complete against the real device:

1. Capability spike → architecture decided (native Lua, no bridge).
2. Paired; cert persisted in `certs/` and reused to connect on 6466.
3. Key codes round-trip. `KEYCODE_DPAD_RIGHT` × 12 moved the launcher highlight
   **visually confirmed on screen**, with `current_app` reporting `launcherx`.
4. State events subscribe and fire (`is_on`, `current_app`).

Reproduce any of it with `tools/send_key.py`. Note `--delay` / `--repeat`: the
controller and the TV are usually in different rooms, and a single fire-and-check
keypress is not a confirmation — repeat over a window you can walk to.

## Resilience model

The device drops TCP whenever it sleeps, so disconnection is routine, not a fault.

- **Reconnect backs off** 5 → 10 → 20 → 40 → 60s and stays at 60. The counter resets
  only on a *completed handshake*, not on TCP connect — the handshake is the first
  real proof the connection works.
- **A liveness watchdog** catches half-open sockets, which Director does not report.
  The device pings on its own schedule, so silence is the signal: 90 seconds with
  nothing inbound forces a reconnect regardless of what the socket claims.
- **Wake-on-LAN** is the fallback for a device too asleep for TCP. The MAC is learned
  via `GetDeviceMAC` while connected (the ARP entry exists then) and persisted,
  because once the device sleeps the ARP entry may be gone.

  ⚠️ **The target device is on Wi-Fi, so WOL cannot work for it.** Magic packets need
  a NIC that stays powered and listening; Wi-Fi adapters do not. This is a limitation
  of WOL, not something the driver can route around. The code path is kept because it
  is correct for a wired device, and sending a packet that goes nowhere is harmless.

  On Wi-Fi the wake path is **Network Standby** (Settings → Network & Internet)
  instead: with it enabled the device keeps its connection alive in standby, so the
  driver stays connected and a wake keycode reaches it over the existing session. If
  the connection does *not* survive standby, waking a Wi-Fi device is not achievable
  through this protocol.
- **Retrying stops** when there is no IP or no stored identity. Nothing to connect to
  is a configuration state, not a transient failure.

## App launching — send a market:// URI, never a bare package

**The device rejects a bare package name as `app_link`.** It answers with a
`RemoteError` naming field 90 and drops the connection. Wrapping the package as
`market://launch?id=<package>` is accepted, and the Play Store resolves it to the
installed app.

Measured from the driver against the target Chromecast:

| Sent | Result |
|---|---|
| `com.netflix.ninja` | RemoteError, connection dropped |
| `market://launch?id=com.espn.score_center` | accepted, ESPN launched |

`LaunchApp` therefore wraps anything without a `://` scheme. A value that already
carries a scheme is passed through untouched, so real deep links still work. This
means minidrivers can keep publishing plain package names in `UM_NV_SHIELD`.

Credit for the form: `kud/gtv`, whose app catalog calls `market://launch?id=` "the
most reliable method on Google TV, verified on a real device". It was the one form
never tried from the driver.

**Unexplained, and left alone:** a desktop client sending the identical bare-package
bytes is *not* rejected — Netflix launches from `tools/send_key.py --launch
com.netflix.ninja`. The driver's bytes were verified byte-identical, on the
controller itself, against the same value. Feature masks match (615 both), and
swapping the driver onto the desktop's paired certificate changed nothing. Since a
form that always works is known, this is not worth chasing further.

### Play Store fallback

Some apps still land on their Play Store page rather than opening, with "Open"
focused. The driver presses OK and keeps pressing until the app opens — first press
after 1.5s, then every 2s, stopping the moment `current_app` becomes the app it
asked for. Verified: ESPN 2 presses, HBO Max 2, Apple TV 3.

A fixed delay was tried first and was wrong: HBO Max needed 10s while ESPN failed
even at 20s. Readiness is not a fixed interval. Do not replace the retry with a
delay.

The fallback only fires for a store page appearing within 45s of a launch this
driver requested, stops if the user navigates elsewhere, and gives up after 10
presses. **If a bound app is not installed the focused button is Install, not Open,
and pressing it starts an installation** — the `Play Store Fallback` property turns
it off.

## Mini-apps and the remote going dead in-app

While a mini-app is the selected source, Navigator sends key presses to the
**minidriver**, not to this driver. The minidriver forwards them as `PASSTHROUGH`
only to a device that is both bound to its mini-app connection **and in the room's
audio path**:

```lua
for _, id in ipairs (RoomIDRoutes [roomId]) do    -- room's CURRENT_AUDIO_PATH
    if (ConnectedDevices [id]) then RoomIDTargets [roomId] = id
```

Mini-apps bound to this driver have **no audio path**, because installers bind
`HDMI OUT` and nothing else. Composer shows this directly — its Available Video
Sources list has an Audio Path column, and the apps bound here read `no` while the
Sony's read `yes`. The minidriver therefore finds no target and silently drops
every key: the remote does nothing inside an app and works again the moment the
Google TV is reselected.

Two fixes, and the driver ships the second:

1. **Bind `AUDIO OUT`** so this device really is in the room's audio path. Keeps the
   app showing as the source in Navigator. Needs a connection binding, and the
   audio out may need an HDMI class added to bind against a TV's HDMI input.
2. **`Reselect Room Source`** (default On) — after launching, the driver makes
   itself the room's source again, so keys arrive on its own proxy. Lua only, works
   immediately. Cost: Navigator shows "Google TV" rather than the app.

This is the same trade-off the SDK template makes with its Passthrough Mode
property. Set the property Off if you have bound `AUDIO OUT`.

## State feedback — measured behaviour

Verified against the target device on 2026-08-08 via `tools/send_key.py`.

- **State is event-driven, not readable on demand.** `current_app` was `''` at connect
  and only populated after a keypress caused a change. The driver must subscribe and
  treat "not yet reported" as a distinct state — never assume connect-time state is
  complete. The brief's "do not guess" rule cuts both ways: don't guess, but also
  don't assume silence means idle.
- **`volume_info` reports `max: 0` on this hardware.** The Chromecast routes volume to
  the TV over CEC and has no volume scale of its own. Volume *commands* work
  (`KEYCODE_VOLUME_UP` / `_DOWN` / `_MUTE`), but there is **no volume state to feed
  back**. The brief lists volume as part of the feedback target; on this device that
  part is not achievable and the Navigator UI should not imply a level.
- `is_on` and `device_info` are reliable and available at connect.

## Conventions

- Lua targets the DriverWorks embedded interpreter (Lua 5.1 dialect). No external
  modules beyond what DriverWorks ships.
- Driver source lives unpacked in `driver/<name>/`; `.c4z` files are build output and
  are gitignored.
- Spike and probe code prints with a bracketed tag (`[SPIKE]`) so output is greppable
  in the Composer Lua window.
- Protocol code is hand-rolled varint + the handful of messages actually used, not a
  ported protobuf runtime. The schema needs only two wire types.
- **Test the Lua, don't eyeball it.** `tools/test_protocol.py` runs the real driver
  modules under `lupa` and compares every encoded message byte-for-byte against
  Google's protobuf. Anything touching the wire format gets a test there before it
  goes near a controller — Composer round-trips are the slowest thing in this project.

## Hardware assumptions

- Target device: `10.200.10.50`, Android TV Remote Service **6.9** → protocol v2.
- The device **requires TLS 1.2 minimum** (measured — it rejects 1.0/1.1 with alert
  70). Always use `VERIFY_METHOD = 'sslv23'`; `tlsv1`/`tlsv1_1` cannot work.
- Google TV device with **Android TV Remote Service ≥ 5** (Settings → Apps → See all
  apps). Below 5 is the v1 JSON protocol — different project.
- **Network Standby** enabled, or wake fails.
- DHCP reservation on the device.
- Controller on **OS 3.4.1+** for lua-openssl.
