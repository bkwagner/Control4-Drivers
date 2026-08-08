--[[
	Android TV Remote v2 message construction and parsing.

	Field numbers come from docs/protocol-reference.md, generated from the schema.
	The session state machine mirrors tronikos/androidtvremote2, which is the
	reference implementation named in docs/BRIEF.md.

	Session flow on port 6466 once mTLS is up:

	  server -> RemoteConfigure       client replies RemoteConfigure (our device info)
	  server -> RemoteSetActive       client replies RemoteSetActive (agreed features)
	  server -> RemoteStart{started}  device power state; connection is now live
	  server -> RemotePingRequest     client MUST reply RemotePingResponse or be dropped
	  server -> RemoteImeKeyInject    current app changed
	  server -> RemoteSetVolumeLevel  volume changed

	The client drives nothing until the server has configured it. Sending a key
	before RemoteStart arrives is silently dropped.
]]

local pb = require('lib.protobuf')

local M = {}

--------------------------------------------------------------------------------
-- RemoteMessage envelope field numbers
--------------------------------------------------------------------------------

M.FIELD = {
	CONFIGURE          = 1,
	SET_ACTIVE         = 2,
	ERROR              = 3,
	PING_REQUEST       = 8,
	PING_RESPONSE      = 9,
	KEY_INJECT         = 10,
	IME_KEY_INJECT     = 20,
	IME_BATCH_EDIT     = 21,
	START              = 40,
	SET_VOLUME_LEVEL   = 50,
	APP_LINK_LAUNCH    = 90,
}

--- Feature bitmask the device advertises in RemoteConfigure.code1.
M.FEATURE = {
	PING     = 1,
	KEY      = 2,
	IME      = 4,
	VOICE    = 8,
	UNKNOWN1 = 16,
	POWER    = 32,
	VOLUME   = 64,
	APP_LINK = 512,
}

--- What we ask for. Voice is excluded: it needs a separate audio stream.
M.DEFAULT_FEATURES = M.FEATURE.PING + M.FEATURE.KEY + M.FEATURE.IME
	+ M.FEATURE.POWER + M.FEATURE.VOLUME + M.FEATURE.APP_LINK

--------------------------------------------------------------------------------
-- Outbound messages
--------------------------------------------------------------------------------

--[[
	Reply to the server's RemoteConfigure.

	The device_info values are what the TV shows as the connected client. unknown1
	and unknown2 are named that way in every reverse-engineered implementation; the
	values below are what the reference client sends and the device expects.
]]
function M.buildConfigure(features, packageName, appVersion)
	local deviceInfo =
		pb.varintField(3, 1) ..                                  -- unknown1
		pb.stringField(4, '1') ..                                -- unknown2
		pb.stringField(5, packageName or 'atvremote') ..         -- package_name
		pb.stringField(6, appVersion or '1.0.0')                 -- app_version

	local configure =
		pb.varintField(1, features) ..                           -- code1
		pb.messageField(2, deviceInfo)                           -- device_info

	return pb.frame(pb.messageField(M.FIELD.CONFIGURE, configure))
end

function M.buildSetActive(features)
	local setActive = pb.varintField(1, features)
	return pb.frame(pb.messageField(M.FIELD.SET_ACTIVE, setActive))
end

--- Must be sent for every RemotePingRequest, echoing val1, or the device hangs up.
function M.buildPingResponse(val1)
	local response = pb.varintField(1, val1)
	return pb.frame(pb.messageField(M.FIELD.PING_RESPONSE, response))
end

--[[
	direction: 3 = SHORT (a normal press). For a long press send START_LONG (1),
	wait, then END_LONG (2) with the same key code - that is how the context menu
	on OK is reached.
]]
function M.buildKeyInject(keyCode, direction)
	local inject =
		pb.varintField(1, keyCode) ..
		pb.varintField(2, direction or 3)
	return pb.frame(pb.messageField(M.FIELD.KEY_INJECT, inject))
end

--- app_link is a deep link URL, or a bare package name.
function M.buildAppLink(appLink)
	local request = pb.stringField(1, appLink)
	return pb.frame(pb.messageField(M.FIELD.APP_LINK_LAUNCH, request))
end

--------------------------------------------------------------------------------
-- Inbound messages
--------------------------------------------------------------------------------

--[[
	Parse one framed-and-stripped RemoteMessage payload.

	Returns a table { kind = <string>, ... } where kind is one of:
	  configure    features
	  set_active
	  start        started (bool)
	  ping_request val1
	  current_app  package
	  volume       level, max, muted
	  error
	  unknown      field (the envelope field number we did not recognise)
]]
function M.parseMessage(payload)
	local msg = pb.parse(payload)

	local configure = pb.getString(msg, M.FIELD.CONFIGURE)
	if (configure ~= nil) then
		local c = pb.parse(configure)
		local info = pb.getString(c, 2)
		local result = { kind = 'configure', features = pb.getVarint(c, 1, 0) }
		if (info ~= nil) then
			local d = pb.parse(info)
			result.model      = pb.getString(d, 1)
			result.vendor     = pb.getString(d, 2)
			result.appVersion = pb.getString(d, 6)
		end
		return result
	end

	if (pb.getString(msg, M.FIELD.SET_ACTIVE) ~= nil) then
		return { kind = 'set_active' }
	end

	local start = pb.getString(msg, M.FIELD.START)
	if (start ~= nil) then
		return { kind = 'start', started = pb.getBool(pb.parse(start), 1) }
	end

	local ping = pb.getString(msg, M.FIELD.PING_REQUEST)
	if (ping ~= nil) then
		return { kind = 'ping_request', val1 = pb.getVarint(pb.parse(ping), 1, 0) }
	end

	-- Current app arrives inside RemoteImeKeyInject.app_info.app_package.
	local ime = pb.getString(msg, M.FIELD.IME_KEY_INJECT)
	if (ime ~= nil) then
		local appInfo = pb.getString(pb.parse(ime), 1)
		if (appInfo ~= nil) then
			return { kind = 'current_app', package = pb.getString(pb.parse(appInfo), 12) }
		end
		return { kind = 'current_app', package = nil }
	end

	local volume = pb.getString(msg, M.FIELD.SET_VOLUME_LEVEL)
	if (volume ~= nil) then
		local v = pb.parse(volume)
		return {
			kind  = 'volume',
			max   = pb.getVarint(v, 6, 0),
			level = pb.getVarint(v, 7, 0),
			muted = pb.getBool(v, 8),
		}
	end

	if (pb.getString(msg, M.FIELD.ERROR) ~= nil) then
		return { kind = 'error' }
	end

	for field, _ in pairs(msg) do
		return { kind = 'unknown', field = field }
	end
	return { kind = 'empty' }
end

return M
