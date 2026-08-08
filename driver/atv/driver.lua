--[[
	Google TV driver - Android TV Remote protocol v2.

	See CLAUDE.md for the architecture and docs/protocol-reference.md for the wire
	format. The protocol modules under lib/ are tested off-device against Google's
	own protobuf; this file is the DriverWorks plumbing around them.

	THREE CONNECTIONS, used at different times:

	  6003  plain TCP  6467  harvest the device's certificate (pairing only)
	  6002  mTLS       6467  the pairing exchange              (pairing only)
	  6001  mTLS       6466  normal operation

	Pairing sequence, driven by the Pair action:

	  1. generate an RSA keypair and self-signed certificate
	  2. plain TCP to 6467, hand-rolled ClientHello, lift the server certificate
	     out of the cleartext TLS 1.2 Certificate message
	  3. mTLS to 6467 presenting our certificate; run the polo exchange
	  4. the TV shows a code; the installer types it into the Pairing Code property
	  5. hash both public keys with the code, send the secret
	  6. on acknowledgement, persist the identity and switch to 6466

	The persisted identity is the source of truth. The PEM files in the c4z
	directory are a cache rewritten on every init, because a driver update wipes
	that directory.
]]

local pb       = require('lib.protobuf')
local atv      = require('lib.atv_protocol')
local pairing  = require('lib.pairing')
local tlspeek  = require('lib.tls_peek')
local keymap   = require('lib.keymap')
local keycodes = require('lib.keycodes')

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local BINDING_PROXY   = 5001
local BINDING_CONTROL = 6001
local BINDING_PAIRTLS = 6002
local BINDING_PEEK    = 6003

local PORT_CONTROL = 6466
local PORT_PAIR    = 6467

local CERT_FILE = 'atv_client.pem'
local KEY_FILE  = 'atv_client_key.pem'

local PERSIST_CERT = 'client_cert_pem'
local PERSIST_KEY  = 'client_key_pem'

-- Retry backoff for the control connection, in seconds. The device drops TCP
-- when it sleeps, so disconnection is normal rather than exceptional.
local RECONNECT_DELAY = 15

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

Driver = {
	certPem      = nil,
	keyPem       = nil,
	serverNumbers = nil,    -- { modulus, exponent } harvested from the device
	peekSession  = nil,
	controlBuf   = nil,
	pairBuf      = nil,
	connected    = false,
	configured   = false,   -- server has sent RemoteConfigure and we replied
	features     = nil,     -- negotiated feature mask
	reconnectTimer = nil,
	pairStage    = nil,     -- nil | 'peek' | 'exchange' | 'awaiting_code'
}

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

local function dbg(fmt, ...)
	local mode = Properties['Debug Mode']
	if (mode == nil or mode == 'Off') then return end

	local ok, msg = pcall(string.format, fmt, ...)
	if (not ok) then msg = tostring(fmt) end
	msg = '[ATV] ' .. msg

	print(msg)
	if (mode == 'Print and Log') then
		C4:ErrorLog(msg)
	end
end

local function setStatus(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	if (not ok) then msg = tostring(fmt) end
	C4:UpdateProperty('Status', msg)
	dbg('status: %s', msg)
end

--------------------------------------------------------------------------------
-- Identity: generate, persist, materialise
--------------------------------------------------------------------------------

local function fingerprint(pem)
	if (pem == nil) then return 'none' end
	local body = string.gsub(pem, '%-%-%-%-%-[^%-]*%-%-%-%-%-', '')
	body = string.gsub(body, '%s', '')
	if (#body < 16) then return 'invalid' end
	return string.sub(body, 1, 8) .. '...' .. string.sub(body, -8)
end

--[[
	Write the PEMs into the c4z directory, where NetPortOptions can reach them
	via a './' relative path. Confirmed writable at runtime - see
	docs/spike-01-findings.md.
]]
local function materialiseCert()
	if (Driver.certPem == nil or Driver.keyPem == nil) then
		return false, 'no identity in memory'
	end

	local openssl = require('openssl')
	for _, pair in ipairs({ { CERT_FILE, Driver.certPem }, { KEY_FILE, Driver.keyPem } }) do
		local f, err = openssl.bio.file('C4Z:/' .. pair[1], 'w+b')
		if (f == nil) then
			return false, 'could not write ' .. pair[1] .. ': ' .. tostring(err)
		end
		f:write(pair[2])
		f:close()
	end
	return true
end

local function loadIdentity()
	Driver.certPem = C4:PersistGetValue(PERSIST_CERT, true)
	Driver.keyPem  = C4:PersistGetValue(PERSIST_KEY, true)

	local have = (Driver.certPem ~= nil and Driver.certPem ~= ''
		and Driver.keyPem ~= nil and Driver.keyPem ~= '')

	C4:UpdateProperty('Paired Identity', have and fingerprint(Driver.certPem) or 'none')
	return have
end

local function storeIdentity(certPem, keyPem)
	-- Encrypted at rest: this key is the device identity.
	C4:PersistSetValue(PERSIST_CERT, certPem, true)
	C4:PersistSetValue(PERSIST_KEY, keyPem, true)
	Driver.certPem = certPem
	Driver.keyPem  = keyPem
	C4:UpdateProperty('Paired Identity', fingerprint(certPem))
end

--[[
	Generate a fresh client identity. Verified working on OS 3.4.1 with
	lua-openssl 0.8.5 - note req.new takes (subject, key); the upstream-documented
	five-argument form is rejected. See docs/spike-01-findings.md.
]]
local function generateIdentity()
	local openssl = require('openssl')

	local ok, result = pcall(function()
		local key = openssl.pkey.new('rsa', 2048)
		local subject = openssl.x509.name.new({
			{ CN = 'atvremote' }, { O = 'Control4' }, { OU = 'DriverWorks' },
		})
		local req  = openssl.x509.req.new(subject, key)
		local cert = req:to_x509(key, 3650, 'sha256')
		return { certPem = cert:export('pem'), keyPem = key:export('pem') }
	end)

	if (not ok or result == nil) then
		return nil, 'key generation failed: ' .. tostring(result)
	end
	return result
end

--------------------------------------------------------------------------------
-- Control connection (6466)
--------------------------------------------------------------------------------

local function portParams()
	return {
		AUTO_CONNECT               = false,
		MONITOR_CONNECTION         = false,
		KEEP_CONNECTION            = false,
		KEEP_ALIVE                 = true,
		DELIMITER                  = '',
		CERTIFICATE                = './' .. CERT_FILE,
		PRIVATE_KEY                = './' .. KEY_FILE,
		PROTECTED                  = false,
		VERIFY_MODE                = 'none',      -- device cert is self-signed
		-- Must be sslv23. The device requires TLS 1.2 minimum and rejects 1.0/1.1
		-- with alert 70; sslv23 negotiates the highest mutually supported version.
		VERIFY_METHOD              = 'sslv23',
		METHOD                     = 'sslv23',
		SUPPRESS_CONNECTION_EVENTS = false,
	}
end

function Connect()
	local ip = Properties['Device IP']
	if (ip == nil or ip == '') then
		setStatus('Set the Device IP property first')
		return
	end
	if (not loadIdentity()) then
		setStatus('Not paired - run the Pair action')
		return
	end

	local ok, err = materialiseCert()
	if (not ok) then
		setStatus('Cannot write certificate: %s', tostring(err))
		return
	end

	Driver.controlBuf = pb.newBuffer()
	Driver.configured = false

	pcall(function() C4:NetDisconnect(BINDING_CONTROL, PORT_CONTROL) end)
	C4:CreateNetworkConnection(BINDING_CONTROL, ip, 'SSL')
	C4:NetPortOptions(BINDING_CONTROL, PORT_CONTROL, 'SSL', portParams())
	C4:NetConnect(BINDING_CONTROL, PORT_CONTROL)

	setStatus('Connecting to %s:%d', ip, PORT_CONTROL)
end

function Disconnect()
	if (Driver.reconnectTimer ~= nil) then
		Driver.reconnectTimer = C4:KillTimer(Driver.reconnectTimer)
	end
	pcall(function() C4:NetDisconnect(BINDING_CONTROL, PORT_CONTROL) end)
	Driver.connected = false
	Driver.configured = false
	setStatus('Disconnected')
end

local function scheduleReconnect()
	if (Driver.reconnectTimer ~= nil) then
		Driver.reconnectTimer = C4:KillTimer(Driver.reconnectTimer)
	end
	Driver.reconnectTimer = C4:AddTimer(RECONNECT_DELAY, 'SECONDS', false)
	dbg('reconnect in %d seconds', RECONNECT_DELAY)
end

local function send(binding, port, data)
	C4:SendToNetwork(binding, port, data)
end

--[[
	Handle one decoded message from the control connection.

	The server drives: it configures us, then activates, then reports state. We
	must answer every ping or it hangs up.
]]
local function handleControlMessage(msg)
	if (msg.kind == 'configure') then
		dbg('device: %s %s (features %d)', tostring(msg.vendor), tostring(msg.model),
			msg.features or 0)
		-- Claim only what the device offers, intersected with what we want.
		Driver.features = atv.negotiateFeatures(msg.features)
		dbg('negotiated features: %d (device offered %d)', Driver.features, msg.features or 0)
		send(BINDING_CONTROL, PORT_CONTROL,
			atv.buildConfigure(Driver.features, 'atvremote', '1.0.0'))
		Driver.configured = true

	elseif (msg.kind == 'set_active') then
		send(BINDING_CONTROL, PORT_CONTROL,
			atv.buildSetActive(Driver.features or atv.DEFAULT_FEATURES))
		setStatus('Connected')

	elseif (msg.kind == 'ping_request') then
		send(BINDING_CONTROL, PORT_CONTROL, atv.buildPingResponse(msg.val1))

	elseif (msg.kind == 'start') then
		C4:UpdateProperty('Power State', msg.started and 'On' or 'Off')
		dbg('power state: %s', tostring(msg.started))

	elseif (msg.kind == 'current_app') then
		local package = msg.package or 'unknown'
		C4:UpdateProperty('Current App', package)
		dbg('current app: %s', package)

	elseif (msg.kind == 'volume') then
		-- Reported but deliberately not acted on: volume routes over CEC to the
		-- TV, which Control4 already controls. See lib/keymap.lua.
		dbg('volume reported (ignored): level=%d max=%d muted=%s',
			msg.level or 0, msg.max or 0, tostring(msg.muted))

	elseif (msg.kind == 'error') then
		dbg('device reported a protocol error')

	else
		dbg('unhandled message kind=%s field=%s', tostring(msg.kind), tostring(msg.field))
	end
end

--------------------------------------------------------------------------------
-- Pairing
--------------------------------------------------------------------------------

--- Step 1-2: generate an identity, then harvest the device certificate.
function PairStart()
	local ip = Properties['Device IP']
	if (ip == nil or ip == '') then
		setStatus('Set the Device IP property first')
		return
	end

	Disconnect()
	setStatus('Pairing: generating client identity')

	local identity, err = generateIdentity()
	if (identity == nil) then
		setStatus('Pairing failed: %s', tostring(err))
		return
	end

	Driver.certPem   = identity.certPem
	Driver.keyPem    = identity.keyPem

	local ok, writeErr = materialiseCert()
	if (not ok) then
		setStatus('Pairing failed: %s', tostring(writeErr))
		return
	end

	-- Harvest the device's certificate over plain TCP.
	Driver.peekSession = tlspeek.newSession()
	Driver.pairStage = 'peek'

	pcall(function() C4:NetDisconnect(BINDING_PEEK, PORT_PAIR) end)
	C4:CreateNetworkConnection(BINDING_PEEK, ip, 'TCP')
	C4:NetConnect(BINDING_PEEK, PORT_PAIR)

	setStatus('Pairing: reading device certificate')
end

--- Step 3: mTLS to the pairing port and begin the polo exchange.
local function pairConnectTls()
	local ip = Properties['Device IP']

	Driver.pairBuf = pb.newBuffer()
	Driver.pairStage = 'exchange'

	pcall(function() C4:NetDisconnect(BINDING_PAIRTLS, PORT_PAIR) end)
	C4:CreateNetworkConnection(BINDING_PAIRTLS, ip, 'SSL')
	C4:NetPortOptions(BINDING_PAIRTLS, PORT_PAIR, 'SSL', portParams())
	C4:NetConnect(BINDING_PAIRTLS, PORT_PAIR)

	setStatus('Pairing: connecting to pairing service')
end

--[[
	Extract the harvested certificate's modulus and exponent.

	Read directly out of the DER rather than via lua-openssl - see the note in
	lib/pairing.lua. This path is covered by tools/test_der.py against the live
	device certificate.
]]
local function adoptServerCertificate(der)
	local modulus, exponent, status = pairing.publicNumbersFromCertificate(der)
	if (modulus == nil) then
		return false, 'could not read server public key: ' .. tostring(status)
	end

	dbg('server public key: modulus %d bytes, exponent %d bytes',
		#modulus, #exponent)
	Driver.serverNumbers = { modulus = modulus, exponent = exponent }
	return true
end

--- Step 5: the installer has typed the code.
function SubmitPairingCode(code)
	if (Driver.pairStage ~= 'awaiting_code') then
		setStatus('Not waiting for a pairing code - run the Pair action first')
		return
	end

	local ok, err = pairing.checkCode(code)
	if (not ok) then
		setStatus('Pairing code rejected: %s', tostring(err))
		return
	end

	local openssl = require('openssl')

	-- Our own public key comes from the certificate we just generated, read the
	-- same way as the device's.
	local clientModulus, clientExponent, status = pairing.publicNumbersFromPem(Driver.certPem)
	if (clientModulus == nil) then
		setStatus('Pairing failed: could not read our own public key (%s)', tostring(status))
		return
	end

	if (Driver.serverNumbers == nil) then
		setStatus('Pairing failed: no device public key - run Pair with Device again')
		return
	end

	local preimage, perr = pairing.buildSecretPreimage(
		clientModulus, clientExponent,
		Driver.serverNumbers.modulus, Driver.serverNumbers.exponent,
		code)
	if (preimage == nil) then
		setStatus('Pairing failed: %s', tostring(perr))
		return
	end

	local hash = openssl.digest.digest('sha256', preimage, true)

	-- The first byte of the code is a check byte over the hash. Catching a
	-- mistyped code here avoids a round trip that fails indistinguishably.
	local valid, verr = pairing.verifyHash(hash, code)
	if (not valid) then
		setStatus('Pairing failed: %s', tostring(verr))
		return
	end

	send(BINDING_PAIRTLS, PORT_PAIR, pairing.buildSecret(hash))
	setStatus('Pairing: secret sent, awaiting acknowledgement')
end

local function handlePairMessage(msg)
	if (msg.status ~= pairing.STATUS.OK) then
		setStatus('Pairing rejected by device: %s', pairing.statusName(msg.status))
		Driver.pairStage = nil
		pcall(function() C4:NetDisconnect(BINDING_PAIRTLS, PORT_PAIR) end)
		return
	end

	if (msg.kind == 'request_ack') then
		send(BINDING_PAIRTLS, PORT_PAIR, pairing.buildOptions())

	elseif (msg.kind == 'options') then
		send(BINDING_PAIRTLS, PORT_PAIR, pairing.buildConfiguration())

	elseif (msg.kind == 'configuration_ack') then
		Driver.pairStage = 'awaiting_code'
		setStatus('Pairing: enter the 6-character code from the TV in Pairing Code')

	elseif (msg.kind == 'secret_ack') then
		storeIdentity(Driver.certPem, Driver.keyPem)
		Driver.pairStage = nil
		Driver.serverNumbers = nil
		pcall(function() C4:NetDisconnect(BINDING_PAIRTLS, PORT_PAIR) end)
		setStatus('Paired. Connecting.')
		Connect()

	else
		dbg('unexpected pairing message: %s', tostring(msg.kind))
	end
end

function Unpair()
	Disconnect()
	C4:PersistDeleteValue(PERSIST_CERT)
	C4:PersistDeleteValue(PERSIST_KEY)
	Driver.certPem = nil
	Driver.keyPem  = nil
	C4:UpdateProperty('Paired Identity', 'none')
	C4:UpdateProperty('Current App', 'unknown')
	C4:UpdateProperty('Power State', 'unknown')
	setStatus('Unpaired - stored identity discarded')
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

local function requireConnection()
	if (not Driver.connected) then
		dbg('not connected; command dropped')
		return false
	end
	return true
end

function SendKeyCode(keyCode, direction)
	if (not requireConnection()) then return end
	send(BINDING_CONTROL, PORT_CONTROL, atv.buildKeyInject(keyCode, direction))
end

function SendKeyName(name)
	local code = keycodes.KEYCODE[name]
	if (code == nil) then
		dbg('unknown key code name: %s', tostring(name))
		return
	end
	SendKeyCode(code, keycodes.DIRECTION.SHORT)
end

function LaunchApp(appLink)
	if (appLink == nil or appLink == '') then
		dbg('LaunchApp called with no link')
		return
	end
	if (not requireConnection()) then return end
	send(BINDING_CONTROL, PORT_CONTROL, atv.buildAppLink(appLink))
	dbg('launching %s', appLink)
end

--------------------------------------------------------------------------------
-- DriverWorks entry points
--------------------------------------------------------------------------------

function OnDriverInit()
	Driver.controlBuf = pb.newBuffer()
	dbg('driver init')
end

function OnDriverLateInit()
	if (loadIdentity()) then
		setStatus('Paired - connecting')
		Connect()
	else
		setStatus('Not paired - set Device IP, then run Pair with Device')
	end
end

function OnDriverDestroyed()
	Disconnect()
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	dbg('connection %s port %s -> %s', tostring(idBinding), tostring(nPort), tostring(strStatus))

	if (idBinding == BINDING_PEEK) then
		if (strStatus == 'ONLINE') then
			local hello, err = tlspeek.buildClientHello(require('openssl').random(32))
			if (hello == nil) then
				setStatus('Pairing failed: %s', tostring(err))
				return
			end
			send(BINDING_PEEK, PORT_PAIR, hello)
		end
		return
	end

	if (idBinding == BINDING_PAIRTLS) then
		if (strStatus == 'ONLINE' and Driver.pairStage == 'exchange') then
			send(BINDING_PAIRTLS, PORT_PAIR,
				pairing.buildPairingRequest(Properties['Client Name'], 'atvremote'))
		elseif (strStatus == 'OFFLINE' and Driver.pairStage ~= nil) then
			setStatus('Pairing: device closed the connection')
			Driver.pairStage = nil
		end
		return
	end

	if (idBinding == BINDING_CONTROL) then
		if (strStatus == 'ONLINE') then
			Driver.connected = true
			Driver.controlBuf = pb.newBuffer()
			setStatus('Connected - waiting for device configuration')
		elseif (strStatus == 'OFFLINE') then
			Driver.connected = false
			Driver.configured = false
			-- Normal when the device sleeps; retry rather than treating it as failure.
			setStatus('Offline - retrying in %ds', RECONNECT_DELAY)
			scheduleReconnect()
		end
	end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
	if (strData == nil or strData == '') then return end

	if (idBinding == BINDING_PEEK) then
		tlspeek.push(Driver.peekSession, strData)
		local der, status = tlspeek.certificate(Driver.peekSession)
		if (der == nil) then
			if (status ~= nil and string.sub(status, 1, 6) == 'device') then
				setStatus('Pairing failed: %s', status)
				Driver.pairStage = nil
				pcall(function() C4:NetDisconnect(BINDING_PEEK, PORT_PAIR) end)
			end
			return
		end

		dbg('harvested server certificate: %d bytes', #der)
		pcall(function() C4:NetDisconnect(BINDING_PEEK, PORT_PAIR) end)

		local ok, err = adoptServerCertificate(der)
		if (not ok) then
			setStatus('Pairing failed: %s', tostring(err))
			Driver.pairStage = nil
			return
		end
		pairConnectTls()
		return
	end

	if (idBinding == BINDING_PAIRTLS) then
		pb.push(Driver.pairBuf, strData)
		while true do
			local payload = pb.nextMessage(Driver.pairBuf)
			if (payload == nil) then break end
			handlePairMessage(pairing.parseMessage(payload))
		end
		return
	end

	if (idBinding == BINDING_CONTROL) then
		pb.push(Driver.controlBuf, strData)
		while true do
			local payload = pb.nextMessage(Driver.controlBuf)
			if (payload == nil) then break end
			handleControlMessage(atv.parseMessage(payload))
		end
	end
end

function OnTimerExpired(idTimer)
	if (idTimer == Driver.reconnectTimer) then
		Driver.reconnectTimer = nil
		if (not Driver.connected) then Connect() end
	end
end

--[[
	Navigator, Halo and SR-260 key presses arrive here. Unmapped commands are
	logged rather than dropped silently - the proxy forwards anything it does not
	recognise, so unexpected names are expected.
]]
function ReceivedFromProxy(idBinding, strCommand, tParams)
	if (idBinding ~= BINDING_PROXY) then return end

	local keyCode, direction, disposition = keymap.resolve(strCommand)

	if (disposition == 'mapped') then
		dbg('proxy %s -> %s dir=%s', strCommand,
			keycodes.KEYCODE_NAME[keyCode] or keyCode, tostring(direction))
		SendKeyCode(keyCode, direction)

	elseif (disposition == 'ignored') then
		-- Key release following a tap we already delivered in full. Expected on
		-- every press, so it is not worth reporting as a problem.

	else
		dbg('proxy command not mapped: %s', tostring(strCommand))
	end
end

function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}

	if (strCommand == 'PAIR_START') then
		PairStart()
	elseif (strCommand == 'CONNECT') then
		Connect()
	elseif (strCommand == 'DISCONNECT') then
		Disconnect()
	elseif (strCommand == 'UNPAIR') then
		Unpair()
	elseif (strCommand == 'DIAGNOSTICS') then
		Diagnostics()
	elseif (strCommand == 'Launch App') then
		LaunchApp(tParams['App Link'])
	elseif (strCommand == 'Send Key') then
		SendKeyName(tParams['Key Code'])
	elseif (strCommand == 'LUA_ACTION' and tParams.ACTION ~= nil) then
		ExecuteCommand(tParams.ACTION, {})
	else
		dbg('unhandled command: %s', tostring(strCommand))
	end
end

function OnPropertyChanged(strProperty)
	local value = Properties[strProperty]

	if (strProperty == 'Pairing Code') then
		if (value ~= nil and value ~= '') then
			SubmitPairingCode(value)
			-- Clear it either way; a code is single use and shows on screen.
			C4:UpdateProperty('Pairing Code', '')
		end
		return
	end

	if (strProperty == 'Device IP') then
		if (Driver.connected) then Disconnect() end
		if (value ~= nil and value ~= '' and loadIdentity()) then Connect() end
	end
end

function Diagnostics()
	dbg('--- diagnostics ---')
	dbg('  device IP     : %s', tostring(Properties['Device IP']))
	dbg('  paired        : %s', tostring(loadIdentity()))
	dbg('  identity      : %s', tostring(Properties['Paired Identity']))
	dbg('  connected     : %s', tostring(Driver.connected))
	dbg('  configured    : %s', tostring(Driver.configured))
	dbg('  pair stage    : %s', tostring(Driver.pairStage))
	dbg('  current app   : %s', tostring(Properties['Current App']))
	dbg('  power state   : %s', tostring(Properties['Power State']))
	dbg('  mapped keys   : %d', #keymap.commandNames())
	dbg('--- end ---')
end
