"""Read-only probe for the OJ Microline WG4 cloud (mythermostat.info).

Signs in, prints each thermostat's live readings, and optionally long-polls
the notification endpoint to show how quickly changes arrive.

Usage:
    python wg4_probe.py               # list thermostats once
    python wg4_probe.py --watch 10    # also watch notifications for 10 minutes
    python wg4_probe.py --poll 60     # log readings every minute for 60 minutes

The password is prompted for and never written to disk. Raw responses are
saved next to this script (session id redacted) for building the C4 driver.
"""

import argparse
import getpass
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

HOST = "https://mythermostat.info"
APPLICATION = 2
OUT_DIR = Path(__file__).resolve().parent / "probe_output"


def request(method, path, params=None, body=None, timeout=30):
    url = f"{HOST}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode() or "null")


def find_key(obj, name):
    """Case-insensitive lookup, since field casing isn't documented."""
    for key, value in (obj or {}).items():
        if key.lower() == name.lower():
            return value
    return None


def save(name, data, session_id):
    OUT_DIR.mkdir(exist_ok=True)
    text = json.dumps(data, indent=2).replace(session_id, "<SESSION>")
    (OUT_DIR / f"{name}.json").write_text(text)


def temp(value):
    """WG4 reports temperatures in hundredths of a degree C."""
    if value is None:
        return "?"
    c = value / 100
    return f"{c:.1f}C / {c * 9 / 5 + 32:.1f}F"


def show(t):
    print(f"  {find_key(t, 'ThermostatName') or find_key(t, 'Room') or '?'}"
          f"  serial={find_key(t, 'SerialNumber')}")
    print(f"    current   {temp(find_key(t, 'Temperature'))}"
          f"   floor {temp(find_key(t, 'FloorTemperature'))}")
    print(f"    setpoint  {temp(find_key(t, 'SetPointTemp'))}"
          f"   heating={find_key(t, 'Heating')}"
          f"   online={find_key(t, 'Online')}"
          f"   mode={find_key(t, 'RegulationMode')}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--watch", type=float, default=0,
                        help="minutes to watch change notifications")
    parser.add_argument("--poll", type=float, default=0,
                        help="minutes to log readings once a minute")
    args = parser.parse_args()

    email = input("mythermostat.info email: ").strip()
    password = getpass.getpass("password (hidden): ")

    login = request("POST", "api/authenticate/user", body={
        "Application": APPLICATION, "Confirm": "",
        "Email": email, "Password": password,
    })
    session_id = find_key(login, "SessionId")
    if not session_id:
        print("Login failed:", {k: v for k, v in login.items()
                                 if "session" not in k.lower()})
        return
    print(f"Signed in. Login response fields: {sorted(login)}")
    save("login", login, session_id)

    data = request("GET", "api/thermostats", params={"sessionid": session_id})
    save("thermostats", data, session_id)
    thermostats = [t for g in data.get("Groups", []) for t in g.get("Thermostats", []) if t]
    print(f"\n{len(thermostats)} thermostat(s) at {datetime.now():%H:%M:%S}:")
    for t in thermostats:
        show(t)
    if thermostats:
        print(f"\nThermostat fields: {sorted(thermostats[0])}")

    if args.poll > 0:
        poll(session_id, args.poll)
    if args.watch > 0:
        watch(session_id, args.watch)


def log_line(name, line):
    OUT_DIR.mkdir(exist_ok=True)
    with open(OUT_DIR / name, "a") as f:
        f.write(line + "\n")


def poll(session_id, minutes):
    """Log readings every minute to see how often the cloud's temperature changes."""
    print(f"\nLogging readings every minute for {minutes:g} min to probe_output/poll.csv")
    log_line("poll.csv", "time,serial,temperature,setpoint,heating,online,mode")
    end = time.time() + minutes * 60
    while time.time() < end:
        try:
            data = request("GET", "api/thermostats", params={"sessionid": session_id})
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"[{datetime.now():%H:%M:%S}] poll error: {exc}")
            data = {}
        for g in data.get("Groups", []):
            for t in g.get("Thermostats", []):
                line = ",".join(str(v) for v in (
                    f"{datetime.now():%Y-%m-%d %H:%M:%S}", t.get("SerialNumber"),
                    t.get("Temperature"), t.get("SetPointTemp"), t.get("Heating"),
                    t.get("Online"), t.get("RegulationMode")))
                log_line("poll.csv", line)
                print(line)
        time.sleep(60)


def watch(session_id, minutes):
    print(f"\nWatching notifications for {minutes:g} min "
          "(change a setpoint in the app to test)...")
    end = time.time() + minutes * 60
    count = 0
    while time.time() < end:
        started = time.time()
        try:
            note = request("GET", "api/notification",
                           params={"sessionid": session_id}, timeout=120)
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"[{datetime.now():%H:%M:%S}] notification error: {exc}")
            time.sleep(5)
            continue
        waited = time.time() - started
        t = find_key(note, "Thermostat")
        action = find_key(note, "Action")
        stamp = f"{datetime.now():%Y-%m-%d %H:%M:%S}"
        if t:
            count += 1
            save(f"notification_{count}", note, session_id)
            print(f"[{stamp}] action={action} after {waited:.0f}s wait:")
            show(t)
            log_line("watch.log", f"{stamp} #{count} action={action} waited={waited:.0f}s "
                     f"temp={t.get('Temperature')} setpoint={t.get('SetPointTemp')} "
                     f"mode={t.get('RegulationMode')} heating={t.get('Heating')}")
        else:
            print(f"[{stamp}] no change (action={action}, waited {waited:.0f}s)")
            log_line("watch.log", f"{stamp} no change action={action} waited={waited:.0f}s")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}: {exc.read().decode(errors='replace')[:500]}")
