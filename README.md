# Control4 ↔ Google TV

Native Control4 DriverWorks drivers for Google TV and Android TV devices, speaking
the **Android TV Remote protocol v2** — the same protocol the Google TV mobile app
uses. No ADB, no bridge, no always-on service.

Two variants, because Control4 needs a different proxy for each:

| Driver | Proxy | For |
|---|---|---|
| `driver/atv` | `media_player` | a streamer/dongle (Chromecast with Google TV, Shield) |
| `driver/atv_tv` | `tv` | a television with Google TV built in |

## What works

- **Pairing entirely in the driver** — no desktop tool. Generate a keypair, harvest
  the device certificate, run the pairing exchange, store the identity encrypted.
- **Full keymap** — D-pad, transport, number pad, coloured buttons, channel/page,
  with genuine press-and-hold via the protocol's long-press directions.
- **State feedback** — power and current app reported back to Navigators.
- **App launching** — Netflix, Disney+, Hulu, and the rest, including apps the device
  refuses to launch directly.
- **Universal minidriver support** — bind Control4's app minidrivers and they appear
  in the room and launch on the device.
- **Resilience** — reconnect backoff, a liveness watchdog for half-open sockets, and
  a connection-attempt timeout.

## Getting started

```bash
python tools/build_c4z.py driver/atv        # or driver/atv_tv
```

Install the `.c4z` from `dist/`, set **Device IP**, run the **Pair with Device**
action, and type the code shown on screen.

## Testing

Everything that can be verified without a controller is:

```bash
for t in protocol pairing tls_peek der driver; do python tools/test_$t.py; done
```

179 checks. The driver's Lua runs under `lupa` and every encoded protocol message is
compared byte-for-byte against Google's own protobuf. `tools/test_driver.py` stubs
the DriverWorks API and drives the real driver through a session.

Tools that talk to a device take the address as an argument; the defaults in this
repository are RFC 5737 documentation addresses, not real ones.

```bash
python tools/send_key.py 192.0.2.10 KEYCODE_HOME
```

## Notes

[CLAUDE.md](CLAUDE.md) is the working reference: architecture, what was measured on
hardware, and the things that are *not* possible and why. Worth reading before
changing anything — several obvious-looking approaches are recorded there as dead
ends with the evidence.

[docs/BRIEF.md](docs/BRIEF.md) is the original project brief and prior art.

## Prior art

- [`tronikos/androidtvremote2`](https://github.com/tronikos/androidtvremote2) — the
  reference implementation; the pairing hash and session flow come from it
- [`louis49/androidtv-remote`](https://github.com/louis49/androidtv-remote) — the
  original reverse engineering, source of the `.proto` schemas
- [`kud/gtv`](https://github.com/kud/gtv) — where the `market://launch?id=` app-link
  form came from, which is what makes app launching work reliably
- [`snap-one/docs-driverworks`](https://github.com/snap-one/docs-driverworks) — the
  Control4 SDK

## Licence

The drivers here are original work. Control4 and Google TV are trademarks of their
respective owners; this project is not affiliated with either.
