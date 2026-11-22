#!/usr/bin/env python3
"""Run Lua driver tests under LuaJIT 2.1 with the Control4 shim loaded.

The controller runs LuaJIT 2.1 in Lua 5.1 mode. `import lupa` gives the newest
Lua lupa bundles (5.5 as of lupa 2.x), which accepts code the controller
rejects, so this runner always asks for `lupa.luajit21`.

    python testing/run_tests.py                 # every test in the repository
    python testing/run_tests.py WarmlyYours     # the tests under a folder
    python testing/run_tests.py path/to/test_x.lua

A test is any `test_*.lua` under `testing/tests/` or `<Driver>/tests/`. Each
runs in its own process, because testlib's T.finish() ends with os.exit().

Inside a test these globals are set before it runs:
  REPO_ROOT   repository root, forward slashes
  TEST_DIR    the test's own folder
  ShimHost    Python helpers: read_c4z, c4z_properties, json_encode, json_decode
and c4_shim, then c4_shim_ext, are already loaded. `require` finds modules in
testing/lua/ and in the test's own folder.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUA_DIR = REPO / "testing" / "lua"
TIMEOUT_S = 120


def discover(targets: list[str]) -> list[Path]:
    if not targets:
        roots = [REPO / "testing" / "tests"] + sorted(
            p / "tests" for p in REPO.iterdir() if (p / "tests").is_dir() and p.name != "testing"
        )
    else:
        roots = [Path(t).resolve() for t in targets]
    found: list[Path] = []
    for root in roots:
        if root.is_file():
            found.append(root)
        elif root.is_dir():
            found.extend(sorted(root.rglob("test_*.lua")))
        else:
            sys.exit(f"error: no such test or folder: {root}")
    return found


# ---------------------------------------------------------------------------
# Child: one test file in one LuaJIT runtime
# ---------------------------------------------------------------------------


def child(test: Path) -> None:
    try:
        import lupa.luajit21 as lupa
    except ImportError:
        sys.exit("error: pip install lupa  (needs the bundled LuaJIT 2.1 runtime)")

    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    version = lua.eval("jit and jit.version")
    if not version:
        sys.exit("error: lupa.luajit21 did not give a LuaJIT runtime")

    def resolve(path) -> Path:
        p = Path(str(path))
        return p if p.is_absolute() else REPO / p

    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({k: to_lua(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(v) for v in value])
        return value

    def from_lua(value):
        if lupa.lua_type(value) != "table":
            return value
        keys = list(value.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [from_lua(value[k]) for k in range(1, len(keys) + 1)]
        return {str(k): from_lua(v) for k, v in value.items()}

    def read_c4z(path, member="driver.lua"):
        with zipfile.ZipFile(resolve(path)) as z:
            try:
                return z.read(str(member))
            except KeyError:
                return None

    def c4z_properties(path):
        """driver.xml's <config><properties>: name -> default ("" when none)."""
        with zipfile.ZipFile(resolve(path)) as z:
            root = ET.fromstring(z.read("driver.xml"))
        props = {}
        for prop in root.iterfind("./config/properties/property"):
            name = prop.findtext("name")
            if name:
                props[name] = prop.findtext("default") or ""
        return lua.table_from(props)

    def c4z_config(path):
        """driver.xml's simple <devicedata> fields (name, model, version,
        minimum_os_version...) and its <connections>, as c4_shim's
        ShimSetStaticBindings records."""
        with zipfile.ZipFile(resolve(path)) as z:
            root = ET.fromstring(z.read("driver.xml"))
        fields = {el.tag: (el.text or "").strip() for el in root if len(el) == 0}
        kinds = {"1": "CONTROL", "2": "PROXY"}
        connections = []
        for c in root.iterfind("./connections/connection"):
            classes = [n.text for n in c.iterfind("./classes/class/classname") if n.text]
            connections.append(
                lua.table_from(
                    {
                        "id": int(c.findtext("id")),
                        "type": kinds.get(c.findtext("type") or "", c.findtext("type") or ""),
                        "provider": (c.findtext("consumer") or "").lower() != "true",
                        "name": c.findtext("connectionname") or "",
                        "class": classes[0] if classes else "",
                        "hidden": (c.findtext("hidden") or "").lower() == "true",
                    }
                )
            )
        return lua.table_from({"fields": lua.table_from(fields), "connections": lua.table_from(connections)})

    host = lua.table_from(
        {
            "read_c4z": read_c4z,
            "c4z_properties": c4z_properties,
            "c4z_config": c4z_config,
            "json_encode": lambda t: json.dumps(from_lua(t), separators=(",", ":")),
            "json_decode": lambda s: to_lua(json.loads(s)),
            "luajit": version,
        }
    )
    g = lua.globals()
    g.ShimHost = host
    g.REPO_ROOT = REPO.as_posix()
    g.TEST_DIR = test.parent.as_posix()
    paths = ";".join(f"{d.as_posix()}/?.lua" for d in (LUA_DIR, test.parent))
    lua.execute(f"package.path = [[{paths};]] .. package.path")
    try:
        lua.execute("io.stdout:setvbuf('no'); require('c4_shim'); require('c4_shim_ext')")
        lua.execute(f"dofile([[{test.as_posix()}]])")
    except lupa.LuaError as e:
        lua.execute("io.stdout:flush()")
        print(f"\nLUA ERROR: {e}", flush=True)
        sys.exit(1)
    lua.execute("io.stdout:flush()")
    # A test that returns without T.finish() never reported a result.
    print("\nerror: test ended without calling T.finish()", flush=True)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Parent: run each test in its own process and summarise
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "--child":
        child(Path(argv[1]))
        return 1

    verbose = "-v" in argv
    tests = discover([a for a in argv if a != "-v"])
    if not tests:
        print("no tests found")
        return 1
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    failed: list[str] = []
    for test in tests:
        rel = test.relative_to(REPO).as_posix() if test.is_relative_to(REPO) else str(test)
        start = time.monotonic()
        try:
            proc = subprocess.run(
                [sys.executable, "-P", __file__, "--child", str(test)],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=TIMEOUT_S,
                env=env,
            )
            out, code = proc.stdout + proc.stderr, proc.returncode
        except subprocess.TimeoutExpired as e:
            out, code = (e.stdout or "") + f"\ntimed out after {TIMEOUT_S}s", -1
        lines = [l for l in out.splitlines() if l.strip()]
        summary = lines[-1] if lines else "(no output)"
        ok = code == 0
        print(f"{'PASS' if ok else 'FAIL'}  {rel}  ({summary}, {time.monotonic() - start:.1f}s)")
        if not ok or verbose:
            shown = lines if verbose else [l for l in lines if "FAIL" in l or "ERROR" in l or "error" in l][:40]
            for line in shown or lines[-20:]:
                print(f"      {line}")
        if not ok:
            failed.append(rel)
    print(f"\n{len(tests) - len(failed)}/{len(tests)} test files passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
