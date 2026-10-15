--[[
	ATV Spike - DriverWorks capability probe
	Part of the Control4 <-> Google TV driver project. See docs/BRIEF.md.

	This driver answers one question: can a native Lua driver speak mutual TLS to
	the Android TV Remote v2 service, using a client certificate it generated
	itself? If yes, Option B (no sidecar bridge) is real.

	Run the actions in order from the Composer Pro Actions tab, watching the Lua
	output window. Every step prints PASS/FAIL lines prefixed with [SPIKE].
]]

NET_BINDING = 6001

CERT_BASENAME = 'atv_client.pem'
KEY_BASENAME  = 'atv_client_key.pem'

-- Populated as the spike progresses.
Spike = {
	openssl      = nil,   -- the module, once required
	certPem      = nil,
	keyPem       = nil,
	writtenPaths = {},    -- alias -> true for each location we managed to write
	results      = {},    -- ordered list of human-readable outcome lines
}

local function log(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	if (not ok) then msg = tostring(fmt) end
	print('[SPIKE] ' .. msg)
end

local function record(line)
	table.insert(Spike.results, line)
	C4:UpdateProperty('Last Result', line)
	log(line)
end

--[[
	Runs fn under pcall and logs the outcome. Returns success, value.
	The spike deliberately tries several call shapes for each openssl operation:
	the lua-openssl docs and the DriverWorks build have drifted, and finding out
	which shape the controller actually accepts is the point.
]]
local function try(desc, fn)
	local ok, result = pcall(fn)
	if (ok and result ~= nil) then
		log('  ok   : %s', desc)
		return true, result
	end
	log('  fail : %s -> %s', desc, tostring(result))
	return false, nil
end

local function firstThatWorks(label, attempts)
	for _, attempt in ipairs(attempts) do
		local ok, value = try(attempt.desc, attempt.fn)
		if (ok) then
			record(string.format('PASS %s via: %s', label, attempt.desc))
			return value, attempt.desc
		end
	end
	record(string.format('FAIL %s - every call shape errored', label))
	return nil, nil
end

--------------------------------------------------------------------------------
-- Step 1: is lua-openssl present, and can it mint an identity?
--------------------------------------------------------------------------------

function SpikeOpenSSL()
	log('--- Step 1: OpenSSL capability test ---')

	local ok, openssl = pcall(require, 'openssl')
	if (not ok or openssl == nil) then
		record('FAIL require openssl -> ' .. tostring(openssl))
		return
	end
	Spike.openssl = openssl
	record('PASS require openssl')

	local okv, version = pcall(function() return openssl.version() end)
	log('  openssl version: %s', okv and tostring(version) or 'unavailable')

	-- Which submodules survived the DriverWorks trim? (ssl, rsa, ec, dh, dsa,
	-- srp are documented as removed - confirm, so we know what we are working with.)
	for _, name in ipairs({ 'pkey', 'x509', 'bio', 'digest', 'hmac', 'ssl', 'rsa', 'ec' }) do
		log('  module %-8s : %s', name, tostring(openssl[name] ~= nil))
	end

	local key = firstThatWorks('generate RSA keypair', {
		{ desc = "pkey.new('rsa', 2048)", fn = function() return openssl.pkey.new('rsa', 2048) end },
		{ desc = "pkey.new('rsa', 2048, 65537)", fn = function() return openssl.pkey.new('rsa', 2048, 65537) end },
		{ desc = "pkey.new('rsa')", fn = function() return openssl.pkey.new('rsa') end },
	})
	if (key == nil) then return end

	local subject = firstThatWorks('build x509 name', {
		{ desc = 'x509.name.new{CN,O,OU}', fn = function()
			return openssl.x509.name.new({ { CN = 'atvremote' }, { O = 'Control4' }, { OU = 'DriverWorks' } })
		end },
		{ desc = 'x509.name.new{CN}', fn = function()
			return openssl.x509.name.new({ { CN = 'atvremote' } })
		end },
	})
	if (subject == nil) then return end

	-- Confirmed on lua-openssl 0.8.5 (OS 3.4.1+): the two-arg form is the one that
	-- works. The signature documented upstream -- new(subject, exts, attrs, pkey, md)
	-- -- is rejected with "bad argument #2 (must be x509_name or evp_pkey)".
	local req = firstThatWorks('build CSR', {
		{ desc = 'req.new(subject, key)', fn = function()
			return openssl.x509.req.new(subject, key)
		end },
		{ desc = "req.new(subject, nil, nil, key, 'sha256')", fn = function()
			return openssl.x509.req.new(subject, nil, nil, key, 'sha256')
		end },
		{ desc = 'req.new(subject) + req:sign(key)', fn = function()
			local r = openssl.x509.req.new(subject)
			r:sign(key, 'sha256')
			return r
		end },
	})
	if (req == nil) then return end

	local cert = firstThatWorks('self-sign x509', {
		{ desc = "req:to_x509(key, 3650, 'sha256')", fn = function() return req:to_x509(key, 3650, 'sha256') end },
		{ desc = 'req:to_x509(key, 3650)', fn = function() return req:to_x509(key, 3650) end },
		{ desc = 'req:to_x509(key)', fn = function() return req:to_x509(key) end },
	})
	if (cert == nil) then return end

	local certPem = firstThatWorks('export cert PEM', {
		{ desc = "cert:export('pem')", fn = function() return cert:export('pem') end },
		{ desc = 'cert:export()', fn = function() return cert:export() end },
	})
	local keyPem = firstThatWorks('export key PEM', {
		{ desc = "key:export('pem')", fn = function() return key:export('pem') end },
		{ desc = "key:export('pem', true)", fn = function() return key:export('pem', true) end },
		{ desc = 'key:export()', fn = function() return key:export() end },
	})

	if (certPem == nil or keyPem == nil) then return end

	-- Sanity-check that what came back is actually PEM and not DER.
	if (string.find(certPem, 'BEGIN CERTIFICATE', 1, true) == nil) then
		record('WARN cert export is not PEM text - may be DER; check export args')
	end
	if (string.find(keyPem, 'BEGIN', 1, true) == nil) then
		record('WARN key export is not PEM text - may be DER; check export args')
	end

	Spike.certPem = certPem
	Spike.keyPem  = keyPem
	log('  cert PEM %d bytes, key PEM %d bytes', #certPem, #keyPem)
	record('PASS Step 1 - lua-openssl can mint a self-signed client identity')
end

--------------------------------------------------------------------------------
-- Step 2: get those PEMs onto disk somewhere NetPortOptions can reach
--------------------------------------------------------------------------------

local function writeVia(openssl, path, contents)
	local f, err = openssl.bio.file(path, 'w+b')
	if (f == nil) then return false, tostring(err) end
	f:write(contents)
	f:close()
	return true, nil
end

local function readBack(openssl, path)
	local f = openssl.bio.file(path, 'r')
	if (f == nil) then return nil end
	local data = f:read(65536)
	f:close()
	return data
end

function SpikeWriteCert()
	log('--- Step 2: write cert + key to disk ---')

	if (Spike.certPem == nil) then
		record('FAIL Step 2 - run Step 1 first (no cert in memory)')
		return
	end

	local openssl = Spike.openssl
	Spike.writtenPaths = {}

	-- Try each directory alias. Which of these the SSL layer can later read is
	-- the open question; write to all of them so Step 3 can test any spelling.
	for _, prefix in ipairs({ 'SANDBOX:/', 'C4Z:/', '' }) do
		local certPath = prefix .. CERT_BASENAME
		local keyPath  = prefix .. KEY_BASENAME

		local okCert, errCert = writeVia(openssl, certPath, Spike.certPem)
		local okKey            = writeVia(openssl, keyPath, Spike.keyPem)

		if (okCert and okKey) then
			local back = readBack(openssl, certPath)
			local verified = (back ~= nil and #back == #Spike.certPem)
			Spike.writtenPaths[prefix == '' and '(default)' or prefix] = true
			record(string.format('PASS wrote cert to %-12s (read-back %s)',
				prefix == '' and '(default)' or prefix,
				verified and 'ok' or 'MISMATCH'))
		else
			record(string.format('FAIL wrote cert to %-12s -> %s',
				prefix == '' and '(default)' or prefix, tostring(errCert)))
		end
	end
end

--------------------------------------------------------------------------------
-- Step 3: the actual question - mutual TLS to the device
--------------------------------------------------------------------------------

function SpikeConnect()
	log('--- Step 3: TLS connect ---')

	local ip = Properties['Device IP']
	if (ip == nil or ip == '') then
		record('FAIL Step 3 - set the Device IP property first')
		return
	end

	local port     = tonumber(Properties['Port']) or 6467
	local method   = Properties['TLS Method']
	local certPath = Properties['Cert Path Form']
	local keyPath  = string.gsub(certPath, CERT_BASENAME, KEY_BASENAME)

	log('  target   : %s:%d', ip, port)
	log('  method   : %s', method)
	log('  cert     : %s', certPath)
	log('  key      : %s', keyPath)

	local tPortParams = {
		AUTO_CONNECT               = false,
		MONITOR_CONNECTION         = false,
		KEEP_CONNECTION            = false,
		KEEP_ALIVE                 = true,
		DELIMITER                  = '',
		CERTIFICATE                = certPath,
		PRIVATE_KEY                = keyPath,
		PROTECTED                  = false,
		VERIFY_MODE                = 'none',   -- device cert is self-signed
		VERIFY_METHOD              = method,
		SUPPRESS_CONNECTION_EVENTS = false,
	}

	-- The SDK sample table spells this key METHOD while the prose says
	-- VERIFY_METHOD. Set both; the unused one is ignored.
	tPortParams.METHOD = method

	pcall(function() C4:NetDisconnect(NET_BINDING, port) end)

	local ok, err = pcall(function()
		C4:CreateNetworkConnection(NET_BINDING, ip, 'SSL')
		C4:NetPortOptions(NET_BINDING, port, 'SSL', tPortParams)
		C4:NetConnect(NET_BINDING, port)
	end)

	if (not ok) then
		record('FAIL Step 3 - connect call errored: ' .. tostring(err))
		return
	end

	record('.... Step 3 - connect requested; watch for ONLINE in OnConnectionStatusChanged')
end

function SpikeDisconnect()
	local port = tonumber(Properties['Port']) or 6467
	pcall(function() C4:NetDisconnect(NET_BINDING, port) end)
	record('.... disconnected from port ' .. tostring(port))
end

function SpikeSummary()
	log('=== SPIKE SUMMARY ===')
	for i, line in ipairs(Spike.results) do
		log('%2d. %s', i, line)
	end
	log('=== END SUMMARY ===')
end

--------------------------------------------------------------------------------
-- DriverWorks entry points
--------------------------------------------------------------------------------

function OnDriverInit()
	log('ATV Spike loaded. Run the actions in order, watching this window.')
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if (idBinding ~= NET_BINDING) then return end

	log('OnConnectionStatusChanged: binding=%s port=%s status=%s',
		tostring(idBinding), tostring(nPort), tostring(strStatus))

	if (strStatus == 'ONLINE') then
		record(string.format(
			'PASS mTLS handshake to port %s SUCCEEDED - Option B transport is viable',
			tostring(nPort)))
	elseif (strStatus == 'OFFLINE') then
		-- On 6467 this is expected: the pairing service wants a PairingRequest the
		-- moment the socket opens, and drops the connection when nothing arrives.
		-- Only treat OFFLINE as a failure if we never saw ONLINE first.
		record(string.format(
			'.... port %s went OFFLINE (expected on 6467 - device drops silent clients)',
			tostring(nPort)))
	end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
	if (idBinding ~= NET_BINDING) then return end
	log('ReceivedFromNetwork: %d bytes from port %s', #strData, tostring(nPort))

	-- Dump as hex; the remote protocol is length-prefixed protobuf, so the first
	-- byte is a varint length and readable bytes are unlikely.
	local hex = {}
	for i = 1, math.min(#strData, 64) do
		table.insert(hex, string.format('%02X', string.byte(strData, i)))
	end
	log('  hex: %s%s', table.concat(hex, ' '), #strData > 64 and ' ...' or '')
end

function ExecuteCommand(strCommand, tParams)
	if (strCommand == 'SPIKE_OPENSSL') then
		SpikeOpenSSL()
	elseif (strCommand == 'SPIKE_WRITE_CERT') then
		SpikeWriteCert()
	elseif (strCommand == 'SPIKE_CONNECT') then
		SpikeConnect()
	elseif (strCommand == 'SPIKE_DISCONNECT') then
		SpikeDisconnect()
	elseif (strCommand == 'SPIKE_SUMMARY') then
		SpikeSummary()
	elseif (strCommand == 'LUA_ACTION' and tParams ~= nil and tParams.ACTION ~= nil) then
		ExecuteCommand(tParams.ACTION, {})
	end
end

function OnPropertyChanged(strProperty)
	log('property changed: %s = %s', strProperty, tostring(Properties[strProperty]))
end
