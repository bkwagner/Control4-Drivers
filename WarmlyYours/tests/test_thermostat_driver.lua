-- The built thermostat driver (dist/warmlyyours_oj_thermostat.c4z): cloud
-- device JSON in from the account driver, thermostat proxy state out, and
-- setpoint/mode commands back to the account driver.
--
--   python testing/run_tests.py WarmlyYours
local T = require("testlib")
local F = require("wy_fixtures")

local PROXY, ACCOUNT, TEMP_OUT = 5001, 5002, 5010

ShimLoadC4z("WarmlyYours/dist/warmlyyours_oj_thermostat.c4z")
ShimStartDriver()

local function proxyParam(command, key)
  local send = ShimLastProxySend(PROXY, command)
  return send and send.params[key]
end

local function lastWrite()
  local send = ShimLastProxySend(ACCOUNT, "setThermostat")
  return send and ShimJSON.decode(send.params.JSON)
end

T.section("before the account driver reports: offline, waiting")
T.eq("own filename", C4:GetDriverFileName(), "warmlyyours_oj_thermostat.c4z")
T.eq("Driver Status", Properties["Driver Status"], "Waiting for thermostat")
T.eq("proxy told offline", proxyParam("ONLINE_CHANGED", "STATE"), false)
T.eq("no HTTP from the thermostat driver", #ShimHttpAllRequests(), 0)

T.section("a cloud update becomes proxy state (temperatures are 1/100 C)")
ShimResetCalls()
ReceivedFromProxy(ACCOUNT, "updateThermostat", { JSON = ShimJSON.encode(F.thermostat()) })
T.eq("Driver Status", Properties["Driver Status"], "Online")
T.eq("Serial ID", Properties["Serial ID"], F.SERIAL)
T.eq("online", proxyParam("ONLINE_CHANGED", "STATE"), true)
T.eq("2150 -> 21.5 C", proxyParam("TEMPERATURE_CHANGED", "TEMPERATURE"), "21.5")
T.eq("reported in C", proxyParam("TEMPERATURE_CHANGED", "SCALE"), "C")
T.eq("setpoint 2400 -> 24 C", tonumber(proxyParam("HEAT_SETPOINT_CHANGED", "SETPOINT")), 24)
T.eq("heating", proxyParam("HVAC_STATE_CHANGED", "STATE"), "Heat")
T.eq("mode", proxyParam("HVAC_MODE_CHANGED", "MODE"), "Heat")
T.eq("schedule mode 1 -> no hold", proxyParam("HOLD_MODE_CHANGED", "MODE"), "Off")
local temp = ShimLastProxySend(TEMP_OUT, "VALUE_CHANGED")
T.eq("temperature output C", temp and temp.params.CELSIUS, "21.5")
T.eq("temperature output F", temp and tonumber(temp.params.FAHRENHEIT), 70.7)
local caps = ShimProxySends(PROXY, "DYNAMIC_CAPABILITIES_CHANGED")
local range = {}
for _, c in ipairs(caps) do
  for k, v in pairs(c.params) do
    range[k] = v
  end
end
T.eq("min setpoint from MinTemp 500", tonumber(range.SETPOINT_HEAT_MIN_C), 5)
T.eq("max setpoint from MaxTemp 4000", tonumber(range.SETPOINT_HEAT_MAX_C), 40)

T.section("a fresh reading replaces a stale one")
ReceivedFromProxy(ACCOUNT, "updateThermostat", { JSON = ShimJSON.encode(F.thermostat({ Temperature = 1985 })) })
T.eq("1985 -> 19.85 C", proxyParam("TEMPERATURE_CHANGED", "TEMPERATURE"), "19.85")

T.section("a setpoint from Navigator goes to the account driver as 1/100 C")
ShimResetCalls()
ReceivedFromProxy(PROXY, "SET_SETPOINT_HEAT", { CELSIUS = "22" })
local w = lastWrite()
T.truthy("write sent", w)
T.eq("ComfortTemperature 2200", w and w.ComfortTemperature, 2200)
T.eq("held until next event (mode 2)", w and w.RegulationMode, 2)
T.eq("shown at once", tonumber(proxyParam("HEAT_SETPOINT_CHANGED", "SETPOINT")), 22)

T.section("Fahrenheit setpoints round to the thermostat's 0.5 C steps")
ShimResetCalls()
ReceivedFromProxy(PROXY, "SET_SETPOINT_HEAT", { FAHRENHEIT = "75" }) -- 23.89 C
w = lastWrite()
T.eq("75 F -> 24.0 C -> 2400", w and w.ComfortTemperature, 2400)

T.section("Off holds the minimum temperature permanently")
ShimResetCalls()
ReceivedFromProxy(PROXY, "SET_MODE_OFF", {})
w = lastWrite()
T.eq("permanent (mode 3)", w and w.RegulationMode, 3)
T.eq("ManualTemperature = MinTemp", w and w.ManualTemperature, 500)
T.eq("proxy shows Off", proxyParam("HVAC_MODE_CHANGED", "MODE"), "Off")

T.section("Heat returns to the schedule")
ShimResetCalls()
ReceivedFromProxy(PROXY, "SET_MODE_HEAT", {})
w = lastWrite()
T.eq("schedule (mode 1)", w and w.RegulationMode, 1)

T.section("the account driver can take it offline")
ReceivedFromProxy(ACCOUNT, "goOffline", {})
T.eq("proxy told offline", proxyParam("ONLINE_CHANGED", "STATE"), false)

T.finish()
