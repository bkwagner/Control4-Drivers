# WarmlyYours Control4 drivers

Replaces the annex4 WarmlyYours nSpire drivers (vendor defunct, Lua encrypted).
Those showed stale temperatures because live updates depended on annex4's LiNK
relay, which is gone.

WarmlyYours Wi-Fi thermostats are OJ Microline **WG4** units on the
`mythermostat.info` cloud. Schluter DITRA-HEAT runs on the same OJ cloud with
the same API, so these drivers are the open-source
[Finite Labs Schluter drivers](https://github.com/finitelabs/control4-schluter)
(AGPL-3.0), patched to use WarmlyYours' host.

## Layout

| Path | What |
|---|---|
| `vendor/schluter-v20260816/` | Unmodified upstream release `.c4z` files + LICENSE |
| `tools/build_drivers.py` | Patches upstream into `dist/` (every patch must match exactly once) |
| `docs/*.html` | Composer documentation pages; replace upstream's Schluter docs in the build |
| `tools/wg4_probe.py` | Read-only desktop probe of the cloud: list, `--poll`, `--watch` |
| `dist/warmlyyours_oj.c4z` | Account driver: sign-in, discovery, notification long-poll |
| `dist/warmlyyours_oj_thermostat.c4z` | One per thermostat: `thermostatV2` proxy |

Build: `python tools/build_drivers.py`

## What the patches change

- Host `https://mythermostat.info`, OJ `Application` 2 (Schluter: its own host, 7).
- Login sends `Confirm: ""`, the body verified with `wg4_probe.py`.
- GitHub auto-update disabled and its properties removed. An update would
  install the Schluter build and point the driver back at Schluter's cloud.
- WarmlyYours names in Composer; filenames distinct from the annex4 drivers,
  which already used `warmlyyours_thermostat.c4z`.

- Documentation replaced with WarmlyYours pages from `docs/`. The device icons
  are still upstream's Schluter ones.

## Measured (2026-10-14, one WG4 thermostat, firmware 1012M203)

- `Temperature` is floor temperature in 1/100 °C and updates about once a
  minute in the cloud. The cloud was never the cause of the stale readings.
- `api/notification` delivered app-side setpoint and mode changes.
- `RegulationMode`: 1 schedule, 2 comfort (until `ComfortEndTime`, UTC),
  3 manual, 4 vacation, 6 frost protection.
