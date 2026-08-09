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

local BINDING_PROXY    = 5001
local BINDING_SWITCHER = 5001  -- same as BINDING_PROXY: mini-apps live on the main proxy
local BINDING_CONTROL  = 6001
local BINDING_PAIRTLS  = 6002
local BINDING_PEEK     = 6003

--[[
	Universal minidriver support.

	App minidrivers (Netflix, Jellyfin, HBO Max ...) publish one service ID per
	platform and bind to one of the RF_MINI_APP inputs below. Selecting the app in
	Navigator arrives here as SET_INPUT on the switcher proxy; the driver looks up
	the app ID the minidriver published for our platform and launches it.

	MINIAPP_TYPE is deliberately UM_NV_SHIELD. The Shield is also Android TV, so
	its service IDs are plain Android package names - exactly what
	RemoteAppLinkLaunchRequest accepts. That means every stock minidriver carrying
	a Shield entry works here unmodified, with no new service ID to standardise.
]]
local MINIAPP_TYPE          = 'UM_NV_SHIELD'
local MINIAPP_BINDING_START = 3101
local MINIAPP_BINDING_END   = 3125

local ROOM_SELECTED_DEVICE = 1000

local PORT_CONTROL = 6466
local PORT_PAIR    = 6467

local CERT_FILE = 'atv_client.pem'
local KEY_FILE  = 'atv_client_key.pem'

local PERSIST_CERT = 'client_cert_pem'
local PERSIST_KEY  = 'client_key_pem'

--[[
	Reconnect backoff, in seconds. The device drops TCP whenever it sleeps, so
	disconnection is routine rather than exceptional - but retrying every few
	seconds forever against a sleeping device wastes effort and floods the log.
	Back off to a minute and stay there; the last value repeats indefinitely.
]]
local RECONNECT_DELAYS = { 5, 10, 20, 40, 60 }

--[[
	Liveness watchdog.

	A dropped connection is usually reported by Director, but a half-open TCP
	socket is not: the device can vanish (sleep, Wi-Fi drop, reboot) leaving a
	socket that looks fine and never delivers anything again. The device pings us
	on its own schedule, so silence is the signal. Three quiet ticks - 90 seconds
	with nothing at all inbound - means the connection is dead regardless of what
	the socket claims.
]]
local WATCHDOG_INTERVAL = 30
local WATCHDOG_LIMIT    = 3

--[[
	How long a connection attempt may take before it is abandoned.

	Director does not always report a failed attempt. Connecting to a device that
	is still booting can produce neither ONLINE nor OFFLINE, leaving the driver
	waiting forever with no retry scheduled - observed on hardware after pulling
	the device's power. This covers both a TCP connect that never completes and a
	socket that opens but never finishes the protocol handshake.
]]
local CONNECT_TIMEOUT = 30

local PERSIST_MAC = 'device_mac'

--[[
	Play Store fallback.

	Some apps cannot be launched by app link on this hardware - the device cannot
	resolve a launch intent for them and opens their Play Store page instead, with
	the "Open" button focused. Measured against the target device: ESPN, HBO Max and
	Apple TV behave this way while seven other apps launch normally, and eight
	different app_link formats fail for them.

	Pressing OK on that page does launch the app, but only once the page has
	settled - an immediate press does nothing. So: if the Play Store appears shortly
	after we asked for an app, wait, then press OK.

	Timing is the awkward part. The store page reports as current_app within half a
	second but swallows an immediate press, and how long it takes to accept one
	varies by app - measured for HBO Max, 5s failed while 10s worked; ESPN needed
	longer still.

	So rather than guess a delay, press and keep pressing until it takes. The
	device tells us when it worked: current_app becomes the app we asked for, and
	the retries stop. This starts about as fast as a person would and self-corrects
	instead of being tuned.
]]
local PLAYSTORE_PACKAGE   = 'com.android.vending'
local PLAYSTORE_FIRST     = 1.5   -- seconds before the first press
local PLAYSTORE_INTERVAL  = 2     -- seconds between retries
local PLAYSTORE_ATTEMPTS  = 10    -- give up after this many presses
local PLAYSTORE_WINDOW    = 45    -- how long a launch stays "ours" to act on

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
	pairStage    = nil,     -- nil | 'peek' | 'exchange' | 'awaiting_code'

	reconnectTimer  = nil,
	reconnectAttempt = 0,   -- index into RECONNECT_DELAYS
	watchdogTimer   = nil,
	connectTimer    = nil,  -- abandons a connection attempt that never resolves
	ignoreOffline   = false,-- suppresses the OFFLINE our own NetDisconnect causes
	silentTicks     = 0,    -- watchdog ticks with no inbound traffic
	mac             = nil,  -- learned from the connection, used for Wake-on-LAN

	pendingLaunch      = nil,  -- app link we asked for but have not seen open yet
	pendingLaunchTimer = nil,
	storeTarget        = nil,  -- app we are pressing OK for on the Play Store page
	storeTimer         = nil,
	storeAttempts      = 0,
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

	Driver.mac = C4:PersistGetValue(PERSIST_MAC)
	if (Driver.mac ~= nil and Driver.mac ~= '' and
		(Properties['Device MAC'] == nil or Properties['Device MAC'] == '')) then
		C4:UpdateProperty('Device MAC', Driver.mac)
	end

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

local function cancelTimer(timer)
	if (timer ~= nil) then pcall(function() timer:Cancel() end) end
	return nil
end

--[[
	Stop watching for liveness. Called whenever the connection goes away, so a
	stale watchdog cannot trigger a reconnect after a deliberate disconnect.
]]
local function stopWatchdog()
	Driver.watchdogTimer = cancelTimer(Driver.watchdogTimer)
	Driver.silentTicks = 0
end

--[[
	Disconnect without the resulting OFFLINE being mistaken for the device
	dropping us. Director reports our own teardown the same way it reports a real
	drop, and acting on it schedules a spurious reconnect and inflates the retry
	counter. The flag is cleared on a short timer because delivery may be
	asynchronous.
]]
local function disconnectQuietly()
	Driver.ignoreOffline = true
	pcall(function() C4:NetDisconnect(BINDING_CONTROL, PORT_CONTROL) end)
	C4:SetTimer(1000, function() Driver.ignoreOffline = false end)
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

	disconnectQuietly()
	C4:CreateNetworkConnection(BINDING_CONTROL, ip, 'SSL')
	C4:NetPortOptions(BINDING_CONTROL, PORT_CONTROL, 'SSL', portParams())
	C4:NetConnect(BINDING_CONTROL, PORT_CONTROL)

	-- Abandon the attempt if it neither succeeds nor fails.
	Driver.connectTimer = cancelTimer(Driver.connectTimer)
	Driver.connectTimer = C4:SetTimer(CONNECT_TIMEOUT * 1000, function()
		Driver.connectTimer = nil
		if (Driver.configured) then return end

		dbg('connection attempt timed out after %ds', CONNECT_TIMEOUT)
		Driver.connected = false
		Driver.configured = false
		stopWatchdog()
		disconnectQuietly()
		ScheduleReconnect()
	end)

	setStatus('Connecting to %s:%d', ip, PORT_CONTROL)
end

function Disconnect()
	Driver.reconnectTimer = cancelTimer(Driver.reconnectTimer)
	Driver.connectTimer = cancelTimer(Driver.connectTimer)
	Driver.reconnectAttempt = 0
	stopWatchdog()

	pcall(function() C4:NetDisconnect(BINDING_CONTROL, PORT_CONTROL) end)
	Driver.connected = false
	Driver.configured = false
	setStatus('Disconnected')
end

--[[
	Schedule the next connection attempt, backing off as failures accumulate.

	Deliberately gives up if there is nothing to connect to - no IP or no stored
	identity - rather than retrying forever against a driver that is not
	configured yet.
]]
function ScheduleReconnect()
	Driver.reconnectTimer = cancelTimer(Driver.reconnectTimer)

	local ip = Properties['Device IP']
	if (ip == nil or ip == '') then
		setStatus('Set the Device IP property first')
		return
	end
	if (Driver.certPem == nil) then
		setStatus('Not paired - run the Pair action')
		return
	end

	Driver.reconnectAttempt = Driver.reconnectAttempt + 1
	local index = math.min(Driver.reconnectAttempt, #RECONNECT_DELAYS)
	local delay = RECONNECT_DELAYS[index]

	setStatus('Offline - retrying in %ds (attempt %d)', delay, Driver.reconnectAttempt)

	Driver.reconnectTimer = C4:SetTimer(delay * 1000, function()
		Driver.reconnectTimer = nil
		if (not Driver.connected) then Connect() end
	end)
end

--[[
	Start the liveness watchdog. Any inbound traffic resets the counter; see
	NoteInboundTraffic below.
]]
local function startWatchdog()
	stopWatchdog()
	Driver.watchdogTimer = C4:SetTimer(WATCHDOG_INTERVAL * 1000, function()
		if (not Driver.connected) then return end

		Driver.silentTicks = Driver.silentTicks + 1
		if (Driver.silentTicks < WATCHDOG_LIMIT) then return end

		-- The socket may still look open; Director will not tell us otherwise.
		dbg('watchdog: %d seconds with no traffic, forcing reconnect',
			WATCHDOG_INTERVAL * Driver.silentTicks)
		stopWatchdog()
		Driver.connected = false
		Driver.configured = false
		pcall(function() C4:NetDisconnect(BINDING_CONTROL, PORT_CONTROL) end)
		ScheduleReconnect()
	end, true)
end

function NoteInboundTraffic()
	Driver.silentTicks = 0
end

--[[
	Wake the device with a Wake-on-LAN magic packet.

	This is the fallback path for a device asleep enough to refuse TCP, where a
	key code cannot reach it. Requires Network Standby to be enabled on the device
	(Settings -> Network & Internet), and does not work over Wi-Fi - both are
	limitations of WOL itself, not of this driver.

	The MAC is learned from the connection rather than typed in: while connected,
	the controller's ARP table has an entry, so GetDeviceMAC resolves it. It is
	persisted because once the device is asleep the ARP entry may be gone.
]]
local function learnMac()
	local ok, mac = pcall(function() return C4:GetDeviceMAC(BINDING_CONTROL) end)
	if (not ok or mac == nil or mac == '') then return end
	if (mac == Driver.mac) then return end

	Driver.mac = mac
	C4:PersistSetValue(PERSIST_MAC, mac)
	C4:UpdateProperty('Device MAC', mac)
	dbg('learned device MAC: %s', mac)
end

local function send(binding, port, data)
	C4:SendToNetwork(binding, port, data)
end

--[[
	Press OK on the Play Store page until the app actually opens.

	There is no way to ask the device whether the page is ready, so this presses,
	watches, and presses again. current_app turning into the app we wanted is the
	success signal and stops the loop; anything else in the foreground means the
	user has moved on and it stops too.
]]
function StopStoreFallback()
	Driver.storeTimer = cancelTimer(Driver.storeTimer)
	Driver.storeTarget = nil
	Driver.storeAttempts = 0
end

function StartStoreFallback(wanted)
	StopStoreFallback()
	Driver.storeTarget = wanted
	dbg('Play Store opened for %q; pressing OK until it takes', wanted)

	local function press()
		if (Driver.storeTarget == nil) then return end

		Driver.storeAttempts = Driver.storeAttempts + 1
		if (Driver.storeAttempts > PLAYSTORE_ATTEMPTS) then
			dbg('Play Store fallback gave up after %d presses', PLAYSTORE_ATTEMPTS)
			StopStoreFallback()
			return
		end

		dbg('Play Store fallback: OK press %d', Driver.storeAttempts)
		SendKeyCode(keycodes.KEYCODE.KEYCODE_DPAD_CENTER, keycodes.DIRECTION.SHORT)
	end

	-- First press quickly, as a person would, then keep trying.
	Driver.storeTimer = C4:SetTimer(PLAYSTORE_FIRST * 1000, function()
		press()
		if (Driver.storeTarget == nil) then return end
		Driver.storeTimer = C4:SetTimer(PLAYSTORE_INTERVAL * 1000, press, true)
	end)
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
		-- A completed handshake is the only proof the connection really works, so
		-- the backoff resets here rather than merely on TCP connect.
		Driver.reconnectAttempt = 0
		Driver.connectTimer = cancelTimer(Driver.connectTimer)
		learnMac()
		startWatchdog()
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

		if (package == Driver.storeTarget) then
			dbg('Play Store fallback succeeded after %d press(es)', Driver.storeAttempts)
			StopStoreFallback()
			Driver.pendingLaunch = nil

		elseif (package == Driver.pendingLaunch) then
			-- It opened on its own; nothing more to do.
			Driver.pendingLaunch = nil

		elseif (package == PLAYSTORE_PACKAGE and Driver.pendingLaunch ~= nil) then
			-- The device could not resolve a launch intent and opened the store page.
			local wanted = Driver.pendingLaunch
			Driver.pendingLaunch = nil
			if ((Properties['Play Store Fallback'] or 'On') ~= 'On') then
				dbg('Play Store opened for %q; fallback disabled', wanted)
			else
				StartStoreFallback(wanted)
			end

		elseif (Driver.storeTarget ~= nil and package ~= PLAYSTORE_PACKAGE) then
			-- Somewhere else entirely: the user navigated away, so stop pressing.
			dbg('Play Store fallback abandoned; foreground is now %s', package)
			StopStoreFallback()
		end

	elseif (msg.kind == 'volume') then
		-- Reported but deliberately not acted on: volume routes over CEC to the
		-- TV, which Control4 already controls. See lib/keymap.lua.
		dbg('volume reported (ignored): level=%d max=%d muted=%s',
			msg.level or 0, msg.max or 0, tostring(msg.muted))

	elseif (msg.kind == 'error') then
		-- The device echoes the message it rejected, which is the only useful
		-- thing in a RemoteError.
		dbg('device REJECTED our message: field=%s (%s) value=%s',
			tostring(msg.field), tostring(msg.name), tostring(msg.value))

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

function WakeDevice()
	local mac = Properties['Device MAC']
	if (mac == nil or mac == '') then mac = Driver.mac end

	if (mac == nil or mac == '') then
		dbg('cannot send Wake-on-LAN: no MAC known yet (connect once to learn it)')
		return false
	end

	dbg('sending Wake-on-LAN to %s', mac)
	pcall(function() C4:SendWOL(mac) end)
	return true
end

--[[
	Discrete power on. Tries both routes: a WOL packet for a device that is too
	asleep for TCP, and a WAKEUP key for one that is merely idle. Sending both is
	harmless - waking an awake device does nothing.
]]
function PowerOn()
	WakeDevice()
	if (Driver.connected) then
		SendKeyCode(keycodes.KEYCODE.KEYCODE_WAKEUP, keycodes.DIRECTION.SHORT)
	else
		-- Not connected: WOL is the only route, so retry the connection promptly
		-- rather than waiting out the current backoff.
		Driver.reconnectAttempt = 0
		ScheduleReconnect()
	end
	setStatus('Power on requested')
end

--[[
	Discrete power off. Uses SLEEP rather than POWER: POWER toggles, and on this
	hardware it can reach the TV over CEC, which Control4 controls separately.
]]
function PowerOff()
	if (not Driver.connected) then
		dbg('power off requested but not connected')
		return
	end
	SendKeyCode(keycodes.KEYCODE.KEYCODE_SLEEP, keycodes.DIRECTION.SHORT)
	setStatus('Power off requested')
end

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
	if (appLink == nil) then
		dbg('LaunchApp called with no link')
		return
	end

	--[[
		Trim before sending. The device rejected an app link whose bytes were
		verified byte-identical to Google's protobuf for the same literal, and which
		succeeded when sent from a desktop client - the difference being that the
		driver reads the value out of a Control4 variable, where stray whitespace or
		a trailing newline survives and prints indistinguishably in a log.
	]]
	appLink = string.match(tostring(appLink), '^%s*(.-)%s*$') or ''

	if (appLink == '') then
		dbg('LaunchApp called with an empty link')
		return
	end

	--[[
		A bare package name is REJECTED by the device: it answers with a RemoteError
		naming this message and drops the connection. Wrapping it as a market://
		launch URI is accepted, and the Play Store resolves it to the installed app.

		Measured on hardware from the driver: 'com.netflix.ninja' rejected,
		'market://launch?id=com.espn.score_center' accepted and launched. (Curiously,
		a desktop client sending the identical bare-package bytes is not rejected -
		unexplained, and not worth chasing now that a form which always works is
		known.)

		Anything already carrying a scheme is passed through untouched, so a real
		deep link still works.
	]]
	if (string.find(appLink, '://', 1, true) == nil) then
		appLink = 'market://launch?id=' .. appLink
	end
	if (not requireConnection()) then return end

	-- Quoted and sized, so an unexpected character is visible next time.
	dbg('launching %q (%d bytes)', appLink, #appLink)
	send(BINDING_CONTROL, PORT_CONTROL, atv.buildAppLink(appLink))

	-- Only a Play Store that appears shortly after this counts as ours to act on.
	Driver.pendingLaunch = appLink
	Driver.pendingLaunchTimer = cancelTimer(Driver.pendingLaunchTimer)
	Driver.pendingLaunchTimer = C4:SetTimer(PLAYSTORE_WINDOW * 1000, function()
		Driver.pendingLaunchTimer = nil
		Driver.pendingLaunch = nil
	end)
end

--------------------------------------------------------------------------------
-- Universal minidriver (app launching from Navigator)
--------------------------------------------------------------------------------

--[[
	Read the app ID a minidriver published for our platform.

	Falls back to APP_ID, which is what minidrivers predating the universal scheme
	expose. Copied from the SDK's universal minidriver template.
]]
local function getUniversalAppId(deviceId, source)
	local vars = C4:GetDeviceVariables(deviceId) or {}
	for _, var in pairs(vars) do
		if (var.name == source) then return var.value end
	end
	if (source ~= 'APP_ID') then
		return getUniversalAppId(deviceId, 'APP_ID')
	end
end

--[[
	Map each bound mini-app's proxy device to the app it launches.

	This exists because a media_player proxy does not receive SET_INPUT - measured
	on hardware, where selecting a mini-app produced only ON and SELECT_SOURCE. So
	the driver cannot be told which app was chosen; it has to work it out.

	When a room selects a mini-app, the room's selected-device variable becomes
	that mini-app's proxy id, and we already listen to that variable. Looking the
	id up here turns "some source was selected" into "launch this app".
]]
function RefreshMiniApps()
	MiniAppByProxy = {}

	local switcherId = next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), BINDING_SWITCHER) or {})
	if (switcherId == nil) then return end

	local count = 0
	for input = MINIAPP_BINDING_START, MINIAPP_BINDING_END do
		local appProxyId = C4:GetBoundProviderDevice(switcherId, input)
		if (appProxyId ~= nil and appProxyId ~= 0) then
			local appDeviceId = C4:GetBoundProviderDevice(appProxyId, BINDING_PROXY)
			local appId   = appDeviceId and getUniversalAppId(appDeviceId, MINIAPP_TYPE)
			local appName = appDeviceId and getUniversalAppId(appDeviceId, 'APP_NAME')
			if (appId ~= nil and appId ~= '') then
				MiniAppByProxy[appProxyId] = { id = appId, name = appName, input = input }
				count = count + 1
			end
		end
	end
	dbg('mini-apps available to launch: %d', count)
end

--- Track which device each room currently has selected.
function RegisterRooms()
	RoomIDs = C4:GetDevicesByC4iName('roomdevice.c4i') or {}
	RoomIDSources = {}
	for roomId, _ in pairs(RoomIDs) do
		RoomIDSources[roomId] = tonumber(C4:GetDeviceVariable(roomId, ROOM_SELECTED_DEVICE)) or 0
		C4:UnregisterVariableListener(roomId, ROOM_SELECTED_DEVICE)
		C4:RegisterVariableListener(roomId, ROOM_SELECTED_DEVICE)
	end
end

--[[
	The switcher proxy is an implementation detail of mini-app support; without
	this it shows up in Navigator as a device of its own.
]]
local function hideSwitcherProxy()
	-- Only meaningful with a dedicated switcher. When the mini-app inputs live on
	-- the main proxy, hiding it would hide the device itself.
	if (BINDING_SWITCHER == BINDING_PROXY) then return end

	local id, name = next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), BINDING_SWITCHER) or {})
	if (id == nil) then return end

	for roomId, _ in pairs(C4:GetDevicesByC4iName('roomdevice.c4i') or {}) do
		C4:SendToDevice(roomId, 'SET_DEVICE_HIDDEN_STATE',
			{ PROXY_GROUP = 'ALL', DEVICE_ID = id, IS_HIDDEN = true })
	end
	dbg('hid switcher proxy (%s) in all rooms', tostring(name))
end

--[[
	Navigator selected a mini-app. Walk the binding chain to the minidriver that
	owns this input, read the app ID it published for us, and launch it.
]]
local function selectMiniApp(input)
	if (input < MINIAPP_BINDING_START or input > MINIAPP_BINDING_END) then
		dbg('SET_INPUT %s is not a mini-app input', tostring(input))
		return
	end

	local proxyDeviceId = next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), BINDING_SWITCHER) or {})
	if (proxyDeviceId == nil) then
		dbg('mini-app %d selected but the switcher proxy is not bound', input)
		return
	end

	local appProxyId = C4:GetBoundProviderDevice(proxyDeviceId, input)
	if (appProxyId == nil or appProxyId == 0) then
		dbg('nothing bound to mini-app input %d', input)
		return
	end

	local appDeviceId = C4:GetBoundProviderDevice(appProxyId, BINDING_PROXY)
	if (appDeviceId == nil or appDeviceId == 0) then
		dbg('mini-app proxy %s has no protocol driver behind it', tostring(appProxyId))
		return
	end

	local appId   = getUniversalAppId(appDeviceId, MINIAPP_TYPE)
	local appName = getUniversalAppId(appDeviceId, 'APP_NAME')

	if (appId == nil or appId == '') then
		dbg('minidriver %s publishes no %s app id (name=%s) - add one to its ' ..
			'serviceIds table', tostring(appDeviceId), MINIAPP_TYPE, tostring(appName))
		return
	end

	dbg('mini-app input %d -> %s (%s)', input, tostring(appName), appId)
	LaunchApp(appId)
end

--------------------------------------------------------------------------------
-- DriverWorks entry points
--------------------------------------------------------------------------------

function OnDriverInit()
	Driver.controlBuf = pb.newBuffer()
	-- OnPIP fires when the project's bindings change, so mini-app wiring and room
	-- tracking stay current without a Director restart.
	C4:RegisterSystemEvent(C4SystemEvents.OnPIP, 0)
	dbg('driver init')
end

function OnDriverLateInit()
	hideSwitcherProxy()
	RegisterRooms()
	RefreshMiniApps()

	if (loadIdentity()) then
		setStatus('Paired - connecting')
		Connect()
	else
		setStatus('Not paired - set Device IP, then run Pair with Device')
	end
end

function OnDriverDestroyed()
	pcall(function() C4:UnregisterSystemEvent(C4SystemEvents.OnPIP, 0) end)
	Disconnect()
end

function OnSystemEvent(event)
	local name = string.match(tostring(event), '.-name="(.-)"')
	if (name == 'OnPIP') then
		dbg('project bindings changed; re-registering rooms')
		RegisterRooms()
		RefreshMiniApps()
	end
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
	if (idVariable ~= ROOM_SELECTED_DEVICE) then return end

	local selected = tonumber(strValue) or 0
	if (RoomIDs ~= nil and RoomIDs[idDevice] ~= nil) then
		RoomIDSources[tonumber(idDevice)] = selected
	end

	-- The selected source is a mini-app bound to us: launch it.
	local app = MiniAppByProxy and MiniAppByProxy[selected]
	if (app ~= nil) then
		dbg('room %s selected mini-app %s (%s)', tostring(idDevice),
			tostring(app.name), app.id)
		LaunchApp(app.id)
	end
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
			if (Driver.ignoreOffline) then
				dbg('ignoring OFFLINE from our own disconnect')
				return
			end
			Driver.connected = false
			Driver.configured = false
			stopWatchdog()
			-- Routine when the device sleeps, so this is a retry, not a failure.
			ScheduleReconnect()
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
		NoteInboundTraffic()
		pb.push(Driver.controlBuf, strData)
		while true do
			local payload = pb.nextMessage(Driver.controlBuf)
			if (payload == nil) then break end
			handleControlMessage(atv.parseMessage(payload))
		end
	end
end

--[[
	Navigator, Halo and SR-260 key presses arrive here. Unmapped commands are
	logged rather than dropped silently - the proxy forwards anything it does not
	recognise, so unexpected names are expected.
]]
function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}

	--[[
		While a mini-app is the selected source, Navigator sends its key presses to
		the minidriver, which forwards them here wrapped as PASSTHROUGH. Unwrapping
		must happen before anything else looks at the command.
	]]
	if (strCommand == 'PASSTHROUGH') then
		strCommand = tParams.PASSTHROUGH_COMMAND or ''
	end

	if (idBinding ~= BINDING_PROXY and idBinding ~= BINDING_SWITCHER) then return end

	-- Selecting a mini-app in Navigator. Ordered before the keymap so it still
	-- works whether the mini-app inputs sit on this proxy or a separate switcher.
	if (strCommand == 'SET_INPUT') then
		selectMiniApp(tonumber(tParams.INPUT) or 0)
		return
	end

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
	elseif (strCommand == 'POWER_ON') then
		PowerOn()
	elseif (strCommand == 'POWER_OFF') then
		PowerOff()
	elseif (strCommand == 'WAKE') then
		WakeDevice()
	elseif (strCommand == 'DIAGNOSTICS') then
		Diagnostics()
	elseif (strCommand == 'Launch App') then
		LaunchApp(tParams['App Link'])
	elseif (strCommand == 'Power On') then
		PowerOn()
	elseif (strCommand == 'Power Off') then
		PowerOff()
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
	dbg('  device MAC    : %s', tostring(Properties['Device MAC']))
	dbg('  retry attempt : %d', Driver.reconnectAttempt or 0)
	dbg('  silent ticks  : %d', Driver.silentTicks or 0)
	dbg('  mapped keys   : %d', #keymap.commandNames())

	--[[
		Walk the mini-app binding chain and report what the driver can actually
		see. If a minidriver is bound in Composer but does not appear here, the
		problem is the binding or the AV path, not the launch code.
	]]
	--[[
		The AV path. A mini-app only appears in a room if the switcher can reach a
		display, so an unbound HDMI OUT explains "bound but invisible" exactly.
	]]
	local function reportBinding(label, binding)
		local id, name = next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding) or {})
		if (id == nil) then
			id, name = C4:GetBoundProviderDevice(C4:GetDeviceID(), binding), nil
		end
		if (id == nil or id == 0) then
			dbg('  %-22s: NOT BOUND', label)
		else
			dbg('  %-22s: bound to %s%s', label, tostring(id),
				name and (' (' .. tostring(name) .. ')') or '')
		end
	end

	dbg('  --- AV path ---')
	reportBinding('HDMI OUT (2001)', 2001)
	reportBinding('AUDIO OUT (4001)', 4001)

	local switcherId, switcherName = next(
		C4:GetBoundConsumerDevices(C4:GetDeviceID(), BINDING_SWITCHER) or {})
	dbg('  switcher proxy: %s (%s)', tostring(switcherId), tostring(switcherName))

	if (switcherId == nil) then
		dbg('  !! switcher proxy is not bound - no mini-app can work')
	else
		local found = 0
		for input = MINIAPP_BINDING_START, MINIAPP_BINDING_END do
			local appProxyId = C4:GetBoundProviderDevice(switcherId, input)
			if (appProxyId ~= nil and appProxyId ~= 0) then
				found = found + 1
				local appDeviceId = C4:GetBoundProviderDevice(appProxyId, BINDING_PROXY)
				local appId   = appDeviceId and getUniversalAppId(appDeviceId, MINIAPP_TYPE)
				local appName = appDeviceId and getUniversalAppId(appDeviceId, 'APP_NAME')
				dbg('  input %d: proxy=%s protocol=%s name=%s id=%s',
					input, tostring(appProxyId), tostring(appDeviceId),
					tostring(appName), tostring(appId))
				if (appId == nil or appId == '') then
					dbg('    !! no %s service id - this app cannot be launched', MINIAPP_TYPE)
				end
			end
		end
		dbg('  mini-apps bound: %d', found)
	end

	dbg('--- end ---')
end
