-- The built account driver (dist/warmlyyours_oj.c4z) against a scripted
-- mythermostat.info. Checks the patches build_drivers.py makes to the Schluter
-- release, then login -> discovery -> handoff -> write -> session recovery.
--
--   python testing/run_tests.py WarmlyYours
local T = require("testlib")
local F = require("wy_fixtures")

local HOST = "https://mythermostat.info"

ShimLoadC4z("WarmlyYours/dist/warmlyyours_oj.c4z")
ShimStartDriver()

T.section("patched constants and filenames")
T.eq("legacy host", require("constants").LEGACY_HOST, HOST)
T.eq("OJ application id", require("constants").LEGACY_APPLICATION, 2)
T.eq("own filename", C4:GetDriverFileName(), "warmlyyours_oj.c4z")
T.eq("GitHub repo cleared", DRIVER_GITHUB_REPO, "")
T.eq("no Automatic Updates property", Properties["Automatic Updates"], nil)

T.section("no credentials: waits, sends nothing")
T.eq("Driver Status", Properties["Driver Status"], "Awaiting credentials")
ShimFireTimers()
T.eq("no requests", #ShimHttpRequests(), 0)

T.section("login with the body mythermostat.info expects")
ShimSetProperty("Email", F.EMAIL)
ShimSetProperty("Password", F.PASSWORD)
T.eq("Login Status while waiting", Properties["Login Status"], "Logging in...")
ShimFireTimers() -- the 600 ms login debounce
local login = ShimHttpRespond("POST", "^" .. HOST .. "/api/authenticate/user$", {
  body = { ErrorCode = 0, SessionId = F.SESSION },
})
local body = ShimJSON.decode(login.body)
T.eq("Application", body.Application, 2)
T.eq("Email", body.Email, F.EMAIL)
T.eq("Password", body.Password, F.PASSWORD)
T.eq("Confirm is empty, not the password", body.Confirm, "")
T.eq("Login Status", Properties["Login Status"], "Logged In")

T.section("discovery: one binding and a handoff per thermostat")
local list = ShimHttpRespond("GET", "/api/thermostats%?", { body = F.thermostatsResponse() })
T.eq("session on the list request", ShimQuery(list.url).sessionid, F.SESSION)
local binding
for id, b in pairs(ShimDynamicBindings()) do
  if b.class == "SCHLUTER_THERMOSTAT" then
    binding = b
  end
end
T.truthy("binding added", binding)
T.eq("named after the room", binding and binding.name, "Test Bath")
T.truthy("a PROXY id (5012-5999)", binding and binding.id >= 5012 and binding.id <= 5999, binding and binding.id)
T.eq("provider", binding and binding.provider, true)
local handoff = ShimLastProxySend(binding and binding.id, "updateThermostat")
T.truthy("UPDATE_THERMOSTAT sent", handoff)
local device = handoff and ShimJSON.decode(handoff.params.JSON) or {}
T.eq("handoff carries the serial", device.SerialNumber, F.SERIAL)
T.eq("handoff carries raw 1/100 C", device.Temperature, 2150)
T.eq("Driver Status", Properties["Driver Status"], "Connected (1 thermostat)")

T.section("long poll for notifications")
local poll = ShimHttpFind("/api/notification%?")
T.eq("one poll open", #poll, 1)
local q = ShimQuery(poll[1] and poll[1].url or "")
T.eq("poll session", q.sessionid, F.SESSION)
T.eq("poll starts at sequence 0", q.sequencenr, "0")
T.eq("poll timeout 240 s", poll[1] and poll[1].options.timeout, 240)

T.section("a notification for a known thermostat updates it without a list refresh")
ShimResetCalls()
local before = #ShimHttpFind("/api/thermostats%?")
ShimHttpRespond("GET", "/api/notification%?", {
  body = { SequenceNr = 7, Action = 0, Thermostat = F.thermostat({ Temperature = 2230 }) },
})
T.eq("no extra list request", #ShimHttpFind("/api/thermostats%?"), before)
local pushed = ShimLastProxySend(binding and binding.id, "updateThermostat")
T.eq("new temperature handed off", pushed and ShimJSON.decode(pushed.params.JSON).Temperature, 2230)
ShimFireTimers() -- the 2 s minimum gap between polls
local polls = ShimHttpFind("/api/notification%?")
T.eq("next poll asks for sequence 8", ShimQuery(polls[#polls].url).sequencenr, "8")

T.section("a write from the thermostat driver posts to the cloud")
ShimHttpReset()
ReceivedFromProxy(binding.id, "setThermostat", {
  JSON = ShimJSON.encode(F.thermostat({ SetPointTemp = 2200, ComfortTemperature = 2200, RegulationMode = 2 })),
})
ShimFireTimers() -- write debounce
local write = ShimHttpRespond("POST", "/api/thermostat%?", { body = { Success = true } })
local wq = ShimQuery(write.url)
T.eq("write session", wq.sessionid, F.SESSION)
T.eq("write serial", wq.serialnumber, F.SERIAL)
local sent = ShimJSON.decode(write.body)
T.eq("a temporary hold writes ComfortTemperature", sent.ComfortTemperature, 2200)
T.eq("RegulationMode 2 (until next)", sent.RegulationMode, 2)
T.eq("SetPointTemp is the cloud's to report, not sent", sent.SetPointTemp, nil)
T.eq("Temperature is read-only, not sent", sent.Temperature, nil)

T.section("a 401 on the poll drops the session and logs in again")
-- The write's completion re-opens the notification poll.
ShimHttpRespond("GET", "/api/notification%?", { code = 401, body = "" })
for _ = 1, 3 do
  ShimFireTimers() -- poll retry -> no session -> login debounce
end
T.truthy("re-login posted", #ShimHttpFind("/api/authenticate/user$", "POST") >= 1)

T.section("bad credentials stop retrying")
ShimHttpReset()
ShimSetProperty("Password", "wrong")
ShimFireTimers()
ShimHttpRespond("POST", "/api/authenticate/user$", { body = { ErrorCode = 1 } })
T.eq("Login Status", Properties["Login Status"], "Invalid username or password")
T.eq("Driver Status", Properties["Driver Status"], "Not connected")
ShimHttpReset()
ShimFireTimers()
T.eq("no retry", #ShimHttpFind("/api/authenticate/user$"), 0)

T.section("nothing ever leaves for GitHub or Schluter")
UpdateDrivers(true)
if EC and EC.Update_Drivers then
  EC.Update_Drivers()
end
local strays = {}
for _, r in ipairs(ShimHttpAllRequests()) do
  if not r.url:find("^" .. HOST .. "/") then
    strays[#strays + 1] = r.url
  end
end
T.eq("every request went to mythermostat.info", strays, {})

T.finish()
