# Control4 ↔ Google TV Driver — Project Brief

Handoff document for Claude Code. Drop this in the repo root as `CLAUDE.md` or
`docs/BRIEF.md`.

---

## Goal

Control a Google TV / Android TV streaming device from Control4 over IP, using the
**Android TV Remote protocol v2** — the same protocol the Google TV mobile app uses.
No ADB, no wireless debugging, no developer mode on the target device.

Target capability parity with the commercial drivers (Solidified Systems ~$150,
Chowmain): full D-pad navigation, app launching, volume, power, and **two-way state
feedback** (current app, power, volume) reported back to Control4 Navigators.

---

## Protocol background

Two TCP ports on the device, both **mutual TLS**:

| Port | Purpose |
|------|---------|
| 6467 | Pairing — exchange certs, confirm 6-char code shown on TV |
| 6466 | Remote control — length-prefixed protobuf messages |

Pairing works by hashing both certs' public keys together with the on-screen code.
Once accepted, the client cert *is* the persistent identity — every later session is
just an mTLS handshake on 6466. **Never re-pair unless the cert is lost.**

**Prerequisite check:** on the device, Settings → Apps → See all apps → Android TV
Remote Service. Version must be **≥ 5** for v2. Below that, it's the v1 JSON protocol
(different code path — don't bother).

---

## Prior art — read these before writing anything

### Protocol implementations

| Repo | Language | Why it matters |
|------|----------|----------------|
| [`tronikos/androidtvremote2`](https://github.com/tronikos/androidtvremote2) | Python | **Primary reference.** Apache-2.0, on PyPI, backs the Home Assistant integration. Has `remotemessage.proto`, `TvKeys.txt`, and a working `demo.py`. |
| [`louis49/androidtv-remote`](https://github.com/louis49/androidtv-remote) | Node.js | The original reverse-engineering work. All the `.proto` schemas originate here. Emits `powered`, `volume`, `current_app`, `secret`, `ready` events — this is the feedback model to copy. |
| [`kud/androidtv-remote`](https://github.com/kud/androidtv-remote) | TypeScript | Modern ESM fork of louis49. Adds `sendText()` via IME injection (arbitrary string entry, no keycode mapping) — useful for search boxes. Leaner deps: node-forge + protobufjs only. |
| [`drosoCode/atvremote`](https://github.com/drosoCode/atvremote) | Go | CLI *and* library, supports both v1 and v2. Good for shell-level smoke testing during bring-up. |
| [`nguyluky/ESP32_android_tv_remote_v2`](https://github.com/nguyluky/ESP32_android_tv_remote_v2) | C++ | Existence proof that the whole protocol fits on an ESP32. Relevant to feasibility of a pure-Lua port. |

Protocol writeup: Aymkdn's wiki on v1/v2 (referenced by both drosoCode and tronikos).
Deep links for app launching: send URLs rather than keycodes where possible.

### Control4 side

| Repo | Why it matters |
|------|----------------|
| [`snap-one/docs-driverworks`](https://github.com/snap-one/docs-driverworks) | The SDK itself. Contains **Driver Templates** (`.c4z` per proxy type) and sample drivers — including a **client-side websocket driver sample**. Start from the media_player template. |
| [`snap-one/drivers-common-public`](https://github.com/snap-one/drivers-common-public) | Control4's own Lua helper libs. Use `handlers.lua` (network/proxy callback dispatch), `url.lua` (async HTTP), `timer.lua`, `json.lua`. Don't reinvent these. |
| [API reference](https://snap-one.github.io/docs-driverworks-api/) | Canonical API docs. |
| [Fundamentals](https://snap-one.github.io/docs-driverworks-fundamentals/) | Proxy/protocol driver concepts, `.c4z` structure. |
| [`Pulse-Eight/drivers`](https://github.com/Pulse-Eight/drivers) | Real-world shipping C4 driver source (CEC). Good reference for `ExecuteCommand` structure and project layout. |
| [`sethpjohnson/Driverworks`](https://github.com/sethpjohnson/Driverworks) | Community drivers, misc examples. |

---

## Architecture decision — resolve this first

### Option A — Sidecar bridge (recommended for v1)

Docker container running `androidtvremote2`, exposing a small HTTP/WebSocket API.
Control4 driver is a thin client.

```
Control4 Director ──HTTP/WS──> bridge container ──mTLS/protobuf──> Google TV
```

**Pros:** proven crypto stack, fast to working state, cert persistence is trivial,
reconnect logic already written and battle-tested by Home Assistant users.
**Cons:** another always-on service to maintain; adds a hop.

Bridge requirements:
- Persist the client cert/key to a mounted volume — losing it forces re-pairing.
- Auto-reconnect loop with health check; the device drops TCP when it sleeps.
- Push state changes (`powered`, `volume`, `current_app`) to C4 — WebSocket or
  long-poll, not polling on a timer.
- One-time pairing flow exposed as an endpoint (submit the 6-char code).

### Option B — Native Lua driver, no bridge

**This is more viable than it first appears.** DriverWorks has, since **OS 3.4.1**, a
lua-OpenSSL interface exposing *the majority of the OpenSSL API* to third-party
drivers — explicitly added so developers don't have to request new crypto APIs.
There's also `C4:Sign` (HMAC and RSA).

That means keypair generation, cert handling, and a client-cert TLS handshake may all
be doable in-driver. **Verify this early** — it's the single highest-leverage unknown
in the project.

**Spike task (do this before committing to an architecture):** in the Composer Lua
window on the target controller, confirm you can (1) `require` the openssl module,
(2) generate an RSA keypair and self-signed x509, and (3) open a TLS connection to
port 6467 presenting that cert. If all three work, Option B is real and the bridge
is unnecessary. If any fails, fall back to Option A.

Remaining Lua work if B is viable: length-prefixed protobuf encode/decode. The
message set is small — hand-rolling varint + a few message types is more practical
than porting a full protobuf runtime.

---

## Control4 driver requirements (either option)

- Implement the **`media_player`** proxy so the driver appears natively in Watch and
  maps to the Halo / SR-260 remotes without custom programming.
- Bind D-pad, transport, colored A/B/C/D, number pad, INFO, MENU (long-press OK →
  context menu), RECORD/DVR.
- App launching via deep links, surfaced as discrete commands for Composer programming.
- Discrete power on/off, with WOL as a fallback path.
- Report state to Navigators from the feedback channel — do not guess.
- Expose IP as a property; document the DHCP reservation requirement.
- Require **Network Standby** enabled (Settings → Network & Internet) or wake fails.

---

## Suggested milestones

1. **Spike:** lua-OpenSSL capability test on the controller → architecture decision.
2. Pair successfully with the device from a script; persist and reuse the cert.
3. Send a single keycode end-to-end; confirm on screen.
4. Subscribe to state events; log `current_app` / `powered` / `volume` changes.
5. Minimal `.c4z` with media_player proxy — D-pad only, hardcoded IP.
6. Full keymap + app launching + properties.
7. Reconnect/resilience: controller reboot, device sleep, network drop.
8. Package, sign, test install via Composer Pro.

---

## Known risks

- Google has changed this protocol before (Sept 2021 broke every v1 implementation
  overnight). A DIY driver carries that maintenance tail; the commercial ones ship
  fixes. Budget for it.
- Cert loss = re-pairing = physical access to the TV to read the code.
- Device sleep behavior varies by hardware; the Streamer 4K and the older Chromecast
  with Google TV do not behave identically on wake.
- `.c4z` packaging/encryption: check current SDK guidance for local/unsigned driver
  install during development.

---

## Explicitly out of scope

ADB / wireless debugging. It was the original approach and it's the wrong one:
`input keyevent` round-trips run 200–400ms, there's no feedback channel, ADB auth
requires RSA token signing on every reconnect, and Android 11+ wireless debugging
adds SPAKE2-over-mDNS pairing on a random port. The v2 remote protocol is faster,
gives real state, and leaves no debug surface enabled on the device.
