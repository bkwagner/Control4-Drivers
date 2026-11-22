# Control4 Drivers

Control4 DriverWorks drivers, one per folder.

| Driver | What |
|---|---|
| [GoogleTV](GoogleTV/) | Google TV / Android TV streamers and televisions over the Android TV Remote protocol v2, with in-driver pairing and app launching. Imported from [C4-GTV](https://github.com/bkwagner/C4-GTV) with its history. |
| [WarmlyYours](WarmlyYours/) | WarmlyYours Wi-Fi floor-heating thermostats via the OJ Microline cloud (`mythermostat.info`). Replaces the defunct annex4 driver. |

Each folder has its own README and license.

## Testing

```bash
pip install lupa
python testing/run_tests.py
```

This runs each driver's Lua tests under LuaJIT 2.1, the controller's
interpreter, against a stand-in for the DriverWorks API. See
[testing/README.md](testing/README.md). The `testing/` folder is AGPL-3.0; its
shim comes from
[Finite Labs](https://github.com/finitelabs/control4-finite-labs-essentials).
