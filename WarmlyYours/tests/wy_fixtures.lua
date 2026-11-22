-- Shared test data: a WG4 thermostat as mythermostat.info returns it.
-- Field names follow python-ojmicroline-thermostat's WG4 model; temperatures
-- are 1/100 degC. Credentials and the serial are made up.
local F = {}

F.EMAIL = "test@example.com"
F.PASSWORD = "not-a-real-password"
F.SESSION = "test-session-1"
F.SERIAL = "TEST0001"

--- One thermostat; `overrides` replaces fields.
function F.thermostat(overrides)
  local t = {
    SerialNumber = F.SERIAL,
    Room = "Test Bath",
    GroupName = "Home",
    Online = true,
    Heating = true,
    Temperature = 2150,
    SetPointTemp = 2400,
    RegulationMode = 1,
    ManualTemperature = 2400,
    ComfortTemperature = 2400,
    MinTemp = 500,
    MaxTemp = 4000,
    TZOffset = "-05:00",
  }
  for k, v in pairs(overrides or {}) do
    t[k] = v
  end
  return t
end

--- GET api/thermostats: grouped, as the WG4 cloud answers.
function F.thermostatsResponse(overrides)
  return { Groups = { { GroupName = "Home", Thermostats = { F.thermostat(overrides) } } } }
end

return F
