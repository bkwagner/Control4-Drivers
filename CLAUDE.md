# Control4-Drivers

Control4 DriverWorks drivers, one per folder (`GoogleTV/`, `WarmlyYours/`).
Each has its own README, license and build. `GoogleTV/CLAUDE.md` covers that
driver in depth.

## This repository is public

Keep real IP addresses, serial numbers, emails, account names and pairing keys
out of it. Use RFC 5737 addresses (`192.0.2.x`) and made-up serials in docs,
tool defaults and test fixtures. `GoogleTV/certs/` is gitignored.

## Testing

```bash
python testing/run_tests.py          # Lua tests: testing/tests, */tests
cd GoogleTV && python tools/build_c4z.py driver/atv && for t in protocol pairing tls_peek driver der; do python tools/test_$t.py || break; done
```

`testing/README.md` documents the shim and its helpers. Tests run under
**`lupa.luajit21`**, never plain `import lupa`, which is Lua 5.5 and accepts
code the controller rejects. A new driver's tests go in `<Driver>/tests/test_*.lua`
and load the built `.c4z` with `ShimLoadC4z`. When a driver talks to a cloud
API, script that API with `ShimHttpRespond` rather than reaching the real service.

## DriverWorks traps

The controller behaves this way, and the shim reproduces it:

- Target Lua 5.1 on LuaJIT 2.1: no `table.unpack` (use `unpack`), no `//`,
  `&`, `<<`, no `utf8`. `string.pack` is lpack's, where `b` is unsigned8 and
  `c` is signed8 (the reverse of 5.3).
- The controller checks arguments by count: `C4:SendToProxy(b, cmd, params, nil)`
  is an error, while `C4:SendToProxy(b, cmd, params)` is fine. A wrapper must
  forward `...`, not re-spread named locals.
- `OPC.*` and `OVC[]` keys use underscores where the display name has spaces
  (`Log Mode` is `OPC.Log_Mode`). A handler keyed by the display name never
  fires.
- `C4:AddEvent` does not work before `OnDriverLateInit`.
- `CLOSED`/`OPENED` fire programming events even when the state hasn't
  changed, while `STATE_CLOSED`/`STATE_OPENED` don't. Use the `STATE_` forms
  during init and binding restore, or every automation replays at boot.
- Dynamic binding ids depend on type: CONTROL uses 10–999, PROXY uses
  5012–5999. Contact sensors are PROXY.
- `C4:url()`'s `OnDone(transfer, responses, errCode, errMsg)` runs once.
  `errCode` is 0 on success and -1 when aborted, and a transfer can't be
  reused.
- Local API docs: `Z:\Source\C4 Development\c4docs` and `docs-driverworks`.
