"""Build WarmlyYours Control4 drivers from the Finite Labs Schluter release.

Schluter DITRA-HEAT and WarmlyYours both run on the OJ Microline cloud, with
the same REST API on different hosts. The Finite Labs driver is generic over
host + OJ Application id, so this script takes the unmodified upstream .c4z
files from vendor/ and patches them to:

  * talk to mythermostat.info (Application 2) instead of Schluter's cloud
  * never auto-update from GitHub (an update would restore Schluter's host)
  * show WarmlyYours names in Composer
  * use their own .c4z filenames, distinct from both Schluter and the old
    annex4 drivers (annex4 already used warmlyyours_thermostat.c4z)

Every patch must match exactly once, so a changed upstream release fails the
build rather than shipping half-patched.

Upstream: https://github.com/finitelabs/control4-schluter (AGPL-3.0, see
vendor/<release>/LICENSE). Copyright notices are left intact.

Usage:
    python build_drivers.py            # writes ../dist/*.c4z
"""

import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "schluter-v20260816"
DIST = ROOT / "dist"

HOST = "https://mythermostat.info"
APPLICATION = 2

CONSTANTS_LUA = [
    ('M.LEGACY_HOST = "https://ditra-heat-e-wifi.schluter.com"',
     f'M.LEGACY_HOST = "{HOST}"'),
    ("M.LEGACY_APPLICATION = 7", f"M.LEGACY_APPLICATION = {APPLICATION}"),
]

ACCOUNT_LUA = CONSTANTS_LUA + [
    # Match the login body verified against mythermostat.info by wg4_probe.py
    # and used by python-ojmicroline-thermostat; Schluter echoes the password.
    ("local payload = { Email = email, Password = password, Confirm = password }",
     'local payload = { Email = email, Password = password, Confirm = "" }'),
    ('DRIVER_GITHUB_REPO = "finitelabs/control4-schluter"',
     'DRIVER_GITHUB_REPO = ""'),
    ('  "schluter.c4z",\n  "schluter_thermostat.c4z",\n',
     '  "warmlyyours_oj.c4z",\n  "warmlyyours_oj_thermostat.c4z",\n'),
    ('function UpdateDrivers(forceUpdate)\n',
     'function UpdateDrivers(forceUpdate)\n'
     '  do return end -- WarmlyYours build: GitHub updates would restore the Schluter host\n'),
]

ACCOUNT_XML = [
    ("<name>Schluter</name>", "<name>WarmlyYours (OJ Cloud)</name>"),
    ("<model>Schluter DITRA-HEAT</model>", "<model>WarmlyYours nSpire WiFi</model>"),
    (re.compile(r"\s*<property>\s*<name>Cloud</name>.*?</property>"
                r"\s*<property>\s*<name>Automatic Updates</name>.*?</property>"
                r"\s*<property>\s*<name>Update Channel</name>.*?</property>", re.S), ""),
    (re.compile(r"\s*<action>\s*<name>Update Drivers</name>.*?</action>", re.S), ""),
]

THERMOSTAT_XML = [
    ("<name>Schluter Thermostat</name>", "<name>WarmlyYours Thermostat (OJ Cloud)</name>"),
    ("<model>Schluter DITRA-HEAT Thermostat</model>", "<model>WarmlyYours nSpire WiFi</model>"),
    ('name="Schluter Thermostat">thermostatV2', 'name="WarmlyYours Thermostat">thermostatV2'),
    ("<connectionname>Schluter Thermostat</connectionname>",
     "<connectionname>WarmlyYours Thermostat</connectionname>"),
]

DRIVERS = [
    # (upstream file, output file, {member: patches}, documentation page)
    ("schluter.c4z", "warmlyyours_oj.c4z",
     {"driver.lua": ACCOUNT_LUA, "driver.xml": ACCOUNT_XML}, "account.html"),
    ("schluter_thermostat.c4z", "warmlyyours_oj_thermostat.c4z",
     {"driver.lua": CONSTANTS_LUA, "driver.xml": THERMOSTAT_XML}, "thermostat.html"),
]

# Upstream's documentation folder (Schluter page, markdown source, screenshots) is
# dropped and replaced by our page. driver.xml already points at index.html.
DOCS_DIR = "www/documentation/"
DOCS_PAGE = DOCS_DIR + "index.html"


def apply(text, patches, label):
    for old, new in patches:
        if isinstance(old, re.Pattern):
            text, count = old.subn(new, text)
            shown = old.pattern[:60]
        else:
            count = text.count(old)
            text = text.replace(old, new)
            shown = old.splitlines()[0][:60]
        if count != 1:
            sys.exit(f"error: {label}: expected 1 match, found {count}: {shown!r}")
        print(f"  patched {label}: {shown}")
    return text


def build(upstream, output, member_patches, docs_page):
    src = VENDOR / upstream
    target = DIST / output
    print(f"{src.name} -> {target.name}")
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zout:
        if f'<documentation file="{DOCS_PAGE}"/>' not in zin.read("driver.xml").decode("utf-8"):
            sys.exit(f"error: {upstream} driver.xml no longer points at {DOCS_PAGE}")
        zout.write(ROOT / "docs" / docs_page, DOCS_PAGE)
        print(f"  replaced documentation with docs/{docs_page}")
        for info in zin.infolist():
            if info.filename.startswith(DOCS_DIR):
                continue
            data = zin.read(info.filename)
            if info.filename in member_patches:
                text = data.decode("utf-8")
                data = apply(text, member_patches[info.filename], info.filename).encode("utf-8")
            zout.writestr(info, data)
        missing = set(member_patches) - set(zin.namelist())
        if missing:
            sys.exit(f"error: {upstream} has no {sorted(missing)}")
    print(f"  built {target} ({target.stat().st_size:,} bytes)")


def main():
    DIST.mkdir(exist_ok=True)
    for upstream, output, patches, docs_page in DRIVERS:
        build(upstream, output, patches, docs_page)


if __name__ == "__main__":
    main()
