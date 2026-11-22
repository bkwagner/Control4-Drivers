# Driver tests

Runs drivers' Lua off the controller: under LuaJIT 2.1, the interpreter
Director uses, with a stand-in for the DriverWorks `C4` API.

```bash
pip install lupa
python testing/run_tests.py                # every test
python testing/run_tests.py WarmlyYours    # one driver's tests
python testing/run_tests.py -v path/to/test_x.lua
```

`run_tests.py` finds `test_*.lua` in `testing/tests/` and in each driver
folder's `tests/`, and runs each in its own process (testlib's `T.finish()`
calls `os.exit`).

## Why LuaJIT, through lupa

The controller runs LuaJIT 2.1 in Lua 5.1 mode. A plain `import lupa` gives the
newest Lua lupa bundles, **Lua 5.5** as of lupa 2.x. That version accepts
`table.unpack`, `//`, `&`, `goto` and 5.3-style `string.pack`, all of which
fail on a controller or behave differently there. `lupa.luajit21` is a real
LuaJIT bundled in the same wheel, so nothing else needs installing. The GoogleTV
tests (`GoogleTV/tools/test_*.py`) use it for the same reason.

## Files

| File | What | From |
|---|---|---|
| `lua/c4_shim.lua` | Stand-in for the `C4` API: bindings, timers, Persist, files, variables, events, TCP, Encrypt/Hash, lpack-compatible `string.pack` | Finite Labs, verbatim |
| `lua/testlib.lua` | `T.section`, `T.eq`, `T.check`, `T.raises`, `T.finish` | Finite Labs, verbatim |
| `lua/c4_fixtures.lua` | Fixtures on top of the shim (fake clock, TCP client) | Finite Labs, verbatim |
| `lua/c4_shim_ext.lua` | This repository's additions, listed below | here |
| `run_tests.py` | Runner, and the Python helpers the extension uses | here |
| `tests/test_shim_ext.lua` | Tests the extension, and that the runtime has no Lua 5.2+ features | here |

The three upstream files come from
[finitelabs/control4-finite-labs-essentials](https://github.com/finitelabs/control4-finite-labs-essentials)
`test/` at commit `3cfef37` (2026-11-19), which was template v0.9.115. They are
AGPL-3.0 (see `LICENSE`) and are kept unmodified so a newer copy can be dropped
in. Changes go in `c4_shim_ext.lua`.

## What `c4_shim_ext.lua` adds

**Loading a built driver.** `ShimLoadC4z("WarmlyYours/dist/x.c4z")` runs the
`.c4z`'s `driver.lua` with `Properties` set to the `driver.xml` defaults. It
makes `C4:GetDriverFileName` and `C4:GetDriverConfigInfo` answer from that
`driver.xml`, and seeds its connections. `ShimStartDriver()` calls
`OnDriverInit`, then `OnDriverLateInit`. `ShimSetProperty(name, value)` changes
a property the way Composer does.

**Recording.** `C4:UpdateProperty` writes `Properties[]` and is recorded, and
so are `C4:SendToProxy` and `C4:SendToDevice`. The shim still checks their
arguments first. To inspect them, use `ShimProxySends(binding, command)`,
`ShimLastProxySend(...)`, `ShimPropertyHistory(name)` and `ShimResetCalls()`.

**HTTP (`C4:url()`).** A started transfer waits until the test answers it:

```lua
local req = ShimHttpRespond("POST", "/api/login$", { code = 200, body = { SessionId = "x" } })
ShimJSON.decode(req.body)          -- what the driver sent
ShimQuery(req.url).sessionid       -- query string, decoded
ShimHttpRespond("GET", "/slow", { error = "Timeout was reached", errCode = 28 })
ShimHttpRoute("GET", "/api/list", { body = {...} }); ShimHttpServe()   -- standing answers
ShimHttpPending(), ShimHttpFind(pattern), ShimHttpAllRequests(), ShimHttpReset()
```

A table body is sent as JSON. `ShimHttpRespond` raises when nothing pending
matches, and the error lists what is pending. The callback order follows the
DriverWorks docs (`OnHeaders`, `OnBodyChunk`, `OnBody`, then `OnDone`). One
assumption has not been checked on a controller: that `Cancel()` calls
`OnDone` with `-1`.

**Timers.** These come from the shim. Without luasocket nothing is ever due,
and `ShimFireTimers()` fires every pending timer once. That includes repeating
ones, so a test drives time explicitly.

## Writing a test

```lua
local T = require("testlib")             -- testing/lua/ and the test's folder are on the path
ShimLoadC4z("MyDriver/dist/my.c4z")
ShimStartDriver()
T.section("what is under test")
T.eq("name", Properties["Driver Status"], "Online")
T.finish()                               -- required: prints the totals and sets the exit code
```

See `WarmlyYours/tests/` for full examples: a cloud login scripted end to end,
plus proxy commands into a driver and the writes it sends back out.

The shim is not Director. It cannot exercise lua-openssl, real sockets or
Composer, so hardware testing still applies.
