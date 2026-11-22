-- Additions to c4_shim for this repository. Not from upstream: c4_shim.lua is kept
-- byte-for-byte as Finite Labs ships it, so a newer copy can be dropped in, and
-- everything this repository needs beyond it lives here.
--
--   Call recording   C4:UpdateProperty, C4:SendToProxy and C4:SendToDevice are
--                    recorded (after the shim's own argument checks), and
--                    UpdateProperty writes Properties[] as a controller does.
--   HTTP             C4:url() transfers that record each request and wait for the
--                    test to answer it, so a cloud API can be scripted.
--   .c4z loading     load a built driver with its driver.xml property defaults.
--
-- Run under testing/run_tests.py, which provides ShimHost.

local Ext = {}

---------------------------------------------------------------------------
-- JSON (through the Python host, so tests need no Lua JSON library)
---------------------------------------------------------------------------

ShimJSON = {
  encode = function(value)
    return ShimHost.json_encode(value)
  end,
  decode = function(text)
    return ShimHost.json_decode(text)
  end,
}

---------------------------------------------------------------------------
-- Call recording
---------------------------------------------------------------------------

local calls = {}

local function record(name, args)
  calls[name] = calls[name] or {}
  table.insert(calls[name], args)
end

-- Arguments are forwarded as received (...), never re-spread from named locals:
-- the controller checks arguments by count, so an explicit trailing nil differs
-- from an absent one and the shim's checks would reject it.
local shimUpdateProperty = C4.UpdateProperty
function C4:UpdateProperty(...)
  shimUpdateProperty(self, ...)
  local name, value = ...
  Properties[name] = value
  record("UpdateProperty", { name = name, value = value })
end

local shimSendToProxy = C4.SendToProxy
function C4:SendToProxy(...)
  shimSendToProxy(self, ...)
  local binding, command, params, callType = ...
  record("SendToProxy", { binding = binding, command = command, params = params, callType = callType })
end

local shimSendToDevice = C4.SendToDevice
function C4:SendToDevice(...)
  shimSendToDevice(self, ...)
  local device, command, params = ...
  record("SendToDevice", { device = device, command = command, params = params })
end

--- Every recorded call to `name` ("UpdateProperty", "SendToProxy", "SendToDevice").
function ShimCalls(name)
  return calls[name] or {}
end

function ShimResetCalls()
  calls = {}
end

--- Recorded SendToProxy calls, filtered by binding and/or command (nil matches any).
function ShimProxySends(binding, command)
  local out = {}
  for _, c in ipairs(calls.SendToProxy or {}) do
    if (binding == nil or c.binding == binding) and (command == nil or c.command == command) then
      out[#out + 1] = c
    end
  end
  return out
end

--- The most recent SendToProxy matching binding/command, or nil.
function ShimLastProxySend(binding, command)
  local list = ShimProxySends(binding, command)
  return list[#list]
end

--- Every value a property was set to through C4:UpdateProperty, in order.
function ShimPropertyHistory(name)
  local out = {}
  for _, c in ipairs(calls.UpdateProperty or {}) do
    if c.name == name then
      out[#out + 1] = c.value
    end
  end
  return out
end

---------------------------------------------------------------------------
-- HTTP: C4:url()
--
-- Shape from the DriverWorks API docs (35_url): each method returns the
-- transfer; OnDone(transfer, responses, errCode, errMsg) runs once, with
-- errCode 0 on success and -1 when aborted. A started transfer is held until
-- the test answers it with ShimHttpRespond / ShimHttpServe, or the driver
-- cancels it. That Cancel() calls OnDone with -1 is what drivers here expect;
-- it is not verified on a controller.
---------------------------------------------------------------------------

local httpAll = {} -- every request since load; ShimHttpReset leaves it
local httpLog = {} -- every request started since the last reset, in order
local httpPending = {} -- started and not yet answered or cancelled
local httpRoutes = {}
local ticket = 0

local Transfer = {}
Transfer.__index = Transfer

local function finish(t, responses, errCode, errMsg)
  for i, req in ipairs(httpPending) do
    if req.transfer == t then
      table.remove(httpPending, i)
      break
    end
  end
  t._done = true
  if t._onDone then
    t._onDone(t, responses, errCode, errMsg)
  end
end

local function start(t, method, url, body, headers)
  assert(not t._started, "C4LuaUrl: a transfer cannot be re-used")
  t._started = true
  local req = {
    method = method,
    url = url,
    body = body,
    headers = headers or {},
    options = t._options,
    transfer = t,
  }
  httpLog[#httpLog + 1] = req
  httpAll[#httpAll + 1] = req
  httpPending[#httpPending + 1] = req
  return t
end

function Transfer:SetOptions(options)
  for k, v in pairs(options or {}) do
    self._options[k] = v
  end
  return self
end
function Transfer:SetOption(key, value)
  self._options[key] = value
  return self
end
function Transfer:OnHeaders(fn)
  self._onHeaders = fn
  return self
end
function Transfer:OnBody(fn)
  self._onBody = fn
  return self
end
function Transfer:OnBodyChunk(fn)
  self._onBodyChunk = fn
  return self
end
function Transfer:OnDone(fn)
  self._onDone = fn
  return self
end
function Transfer:Get(url, headers)
  return start(self, "GET", url, nil, headers)
end
function Transfer:Post(url, data, headers)
  return start(self, "POST", url, data, headers)
end
function Transfer:Put(url, data, headers)
  return start(self, "PUT", url, data, headers)
end
function Transfer:Delete(url, headers)
  return start(self, "DELETE", url, nil, headers)
end
function Transfer:Custom(url, method, data, headers)
  return start(self, method, url, data, headers)
end
function Transfer:TicketId()
  return self._ticket
end
function Transfer:Cancel()
  if self._started and not self._done then
    finish(self, {}, -1, nil)
  end
  return self
end

function C4:url()
  ticket = ticket + 1
  return setmetatable({ _options = {}, _ticket = ticket }, Transfer)
end

local function matches(req, method, urlPattern)
  return (method == nil or req.method == method) and (urlPattern == nil or req.url:find(urlPattern) ~= nil)
end

--- Answer a pending request. `response` is {code=, body=, headers=}, where a
--- table body is JSON-encoded; or {error="message", errCode=n} for a transfer
--- failure (curl-style, before any HTTP status).
local function answer(req, response)
  local t = req.transfer
  if response.error then
    return finish(t, {}, response.errCode or 28, response.error)
  end
  local body = response.body
  if type(body) == "table" then
    body = ShimJSON.encode(body)
  end
  local resp = { code = response.code or 200, headers = response.headers or {}, body = body or "" }
  if t._onHeaders and t._onHeaders(t, resp) then
    return finish(t, { resp }, -1, nil)
  end
  if t._onBodyChunk then
    local chunk = resp.body
    resp.body = nil
    if t._onBodyChunk(t, resp, chunk) then
      return finish(t, { resp }, -1, nil)
    end
  end
  if t._onBody and t._onBody(t, resp) then
    return finish(t, { resp }, -1, nil)
  end
  finish(t, { resp }, 0, nil)
end

--- Answer the oldest pending request matching method (nil = any) and a Lua
--- pattern on the URL. Raises when nothing matches, so a test fails loudly.
--- Returns the request answered.
function ShimHttpRespond(method, urlPattern, response)
  for _, req in ipairs(httpPending) do
    if matches(req, method, urlPattern) then
      answer(req, response)
      return req
    end
  end
  local open = {}
  for _, req in ipairs(httpPending) do
    open[#open + 1] = req.method .. " " .. req.url
  end
  error(
    string.format(
      "no pending %s request matches %q; pending: %s",
      method or "*",
      tostring(urlPattern),
      #open > 0 and table.concat(open, " | ") or "(none)"
    ),
    2
  )
end

--- Register a standing answer: responder is a response table, or
--- function(req) -> response (nil leaves the request pending).
function ShimHttpRoute(method, urlPattern, responder)
  httpRoutes[#httpRoutes + 1] = { method = method, pattern = urlPattern, responder = responder }
end

--- Answer pending requests from the routes until none can be answered, which
--- covers a chain where one answer starts the next request. Returns how many
--- were answered. Requests no route answers stay pending (a long poll, say).
function ShimHttpServe(limit)
  limit = limit or 100
  local served = 0
  local progress = true
  while progress and served < limit do
    progress = false
    for _, req in ipairs(httpPending) do
      for _, route in ipairs(httpRoutes) do
        if matches(req, route.method, route.pattern) then
          local response = route.responder
          if type(response) == "function" then
            response = response(req)
          end
          if response then
            answer(req, response)
            served = served + 1
            progress = true
            break
          end
        end
      end
      if progress then
        break -- httpPending changed; scan again from the start
      end
    end
  end
  return served
end

--- Every request started, in order (answered or not).
function ShimHttpRequests()
  return httpLog
end

--- Every request since the shim loaded, resets included: for "never calls X" checks.
function ShimHttpAllRequests()
  return httpAll
end

--- Requests started and not yet answered or cancelled.
function ShimHttpPending()
  return httpPending
end

--- Requests whose URL matches a Lua pattern.
function ShimHttpFind(urlPattern, method)
  local out = {}
  for _, req in ipairs(httpLog) do
    if matches(req, method, urlPattern) then
      out[#out + 1] = req
    end
  end
  return out
end

function ShimHttpReset()
  httpLog, httpPending, httpRoutes = {}, {}, {}
end

--- Parse a URL's query string into a table (values percent-decoded).
function ShimQuery(url)
  local out = {}
  local query = url:match("%?(.*)$") or ""
  for pair in query:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    local function unescape(s)
      return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
      end))
    end
    out[unescape(k)] = unescape(v)
  end
  return out
end

---------------------------------------------------------------------------
-- Loading a built driver
---------------------------------------------------------------------------

local driverFileName
local configFields = {}

local shimGetDriverFileName = C4.GetDriverFileName
function C4:GetDriverFileName()
  return driverFileName or shimGetDriverFileName(self)
end

-- The loaded driver.xml's simple fields (minimum_os_version, model, version...);
-- everything else, connections included, is the shim's.
local shimGetDriverConfigInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if configFields[section] ~= nil then
    return configFields[section]
  end
  return shimGetDriverConfigInfo(self, section)
end

--- Load a built .c4z (path relative to the repository root, or absolute):
--- reset Properties to driver.xml's defaults, overlay `properties`, make
--- C4:GetDriverFileName and C4:GetDriverConfigInfo answer from the .c4z,
--- seed its driver.xml connections, and run its driver.lua.
--- Does not call OnDriverInit; see ShimStartDriver.
function ShimLoadC4z(path, properties)
  local source = ShimHost.read_c4z(path, "driver.lua")
  assert(source, "no driver.lua in " .. tostring(path))
  driverFileName = tostring(path):match("([^/\\]+)$")
  local config = ShimHost.c4z_config(path)
  configFields = {}
  for k, v in pairs(config.fields) do
    configFields[k] = v
  end
  local statics = {}
  for _, c in pairs(config.connections) do
    statics[#statics + 1] = c
  end
  ShimSetStaticBindings(statics)
  for k in pairs(Properties) do
    Properties[k] = nil
  end
  for name, default in pairs(ShimHost.c4z_properties(path)) do
    Properties[name] = default
  end
  for name, value in pairs(properties or {}) do
    Properties[name] = value
  end
  local chunk, err = loadstring(source, "@" .. driverFileName .. "/driver.lua")
  assert(chunk, err)
  chunk()
end

--- Director's start-up order: OnDriverInit, then OnDriverLateInit.
function ShimStartDriver()
  if OnDriverInit then
    OnDriverInit()
  end
  if OnDriverLateInit then
    ShimLateInit()
  end
end

--- Change a property as Composer does: set it, then OnPropertyChanged.
function ShimSetProperty(name, value)
  Properties[name] = value
  if OnPropertyChanged then
    OnPropertyChanged(name)
  end
end

return Ext
