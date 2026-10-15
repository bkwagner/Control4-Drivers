--[[
	Harvest the device's server certificate over a PLAIN TCP connection.

	Why this exists: pairing hashes the client and server public keys together with
	the on-screen code. DriverWorks never exposes the TLS peer certificate to Lua,
	so the server half has to be obtained some other way.

	In TLS 1.2 the server's Certificate handshake message is sent in cleartext,
	before ChangeCipherSpec. So: open a plain TCP socket, send a hand-rolled
	ClientHello offering only TLS 1.2, read the reply, and lift the DER certificate
	straight out of the handshake bytes. The handshake is then abandoned - we never
	send a key exchange and never complete it.

	Verified against a real device by tools/peek_cert.py: the certificate recovered
	this way is byte-identical to the one `openssl s_client` negotiates.

	LIMITATION: this depends on the device offering TLS 1.2. Under TLS 1.3 the
	Certificate message is encrypted and this cannot work. See CLAUDE.md.
]]

local M = {}

--------------------------------------------------------------------------------
-- Byte packing. Lua 5.1 has no string.pack, so these are done by hand.
--------------------------------------------------------------------------------

local function u8(n)
	return string.char(n % 256)
end

local function u16(n)
	return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u24(n)
	return string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function readU16(s, i)
	local a, b = string.byte(s, i, i + 1)
	if (a == nil or b == nil) then return nil end
	return a * 256 + b
end

local function readU24(s, i)
	local a, b, c = string.byte(s, i, i + 2)
	if (a == nil or b == nil or c == nil) then return nil end
	return a * 65536 + b * 256 + c
end

--------------------------------------------------------------------------------
-- ClientHello
--------------------------------------------------------------------------------

-- Cipher suites the device is known to accept. ECDHE-RSA-AES128-GCM-SHA256 is
-- what it actually negotiates; the rest are offered as fallbacks.
local CIPHER_SUITES = { 0xC02F, 0xC030, 0xC027, 0x009C, 0x002F }

--[[
	Build a complete TLS 1.2 ClientHello record.

	random must be 32 bytes. Pass openssl.random(32); the value is never used for
	anything cryptographic here because the handshake is abandoned, but sending a
	constant would be needlessly odd.
]]
function M.buildClientHello(random)
	if (random == nil or #random ~= 32) then
		return nil, 'random must be exactly 32 bytes'
	end

	local body = {}
	table.insert(body, u16(0x0303))            -- client_version: TLS 1.2
	table.insert(body, random)
	table.insert(body, u8(0))                  -- session_id: empty

	local ciphers = {}
	for _, c in ipairs(CIPHER_SUITES) do
		table.insert(ciphers, u16(c))
	end
	ciphers = table.concat(ciphers)
	table.insert(body, u16(#ciphers))
	table.insert(body, ciphers)

	table.insert(body, u8(1))                  -- compression methods: 1 entry
	table.insert(body, u8(0))                  -- null compression

	-- Extensions. supported_groups and ec_point_formats are needed for the ECDHE
	-- suites; signature_algorithms is mandatory in TLS 1.2.
	local ext = {}

	local groups = u16(0x0017) .. u16(0x001D)  -- secp256r1, x25519
	table.insert(ext, u16(0x000A) .. u16(#groups + 2) .. u16(#groups) .. groups)

	table.insert(ext, u16(0x000B) .. u16(2) .. u8(1) .. u8(0))  -- uncompressed point

	local sigs = u16(0x0401) .. u16(0x0403) .. u16(0x0501) .. u16(0x0804)
	table.insert(ext, u16(0x000D) .. u16(#sigs + 2) .. u16(#sigs) .. sigs)

	ext = table.concat(ext)
	table.insert(body, u16(#ext))
	table.insert(body, ext)

	body = table.concat(body)

	local handshake = u8(0x01) .. u24(#body) .. body            -- client_hello
	return u8(0x16) .. u16(0x0301) .. u16(#handshake) .. handshake
end

--------------------------------------------------------------------------------
-- Response parsing
--------------------------------------------------------------------------------

function M.newSession()
	return { raw = '', handshake = '', alert = nil }
end

function M.push(session, chunk)
	session.raw = session.raw .. chunk
end

--[[
	Walk complete TLS records out of the buffer, accumulating handshake payload.
	Records can be split or coalesced by TCP exactly like anything else, so this
	only consumes records that have fully arrived.
]]
local function consumeRecords(session)
	local pos = 1
	local raw = session.raw

	while (pos + 5 <= #raw + 1) do
		local ctype = string.byte(raw, pos)
		if (ctype == nil) then break end
		local length = readU16(raw, pos + 3)
		if (length == nil) then break end
		if (pos + 5 + length - 1 > #raw) then break end       -- record incomplete

		local payload = string.sub(raw, pos + 5, pos + 5 + length - 1)

		if (ctype == 0x16) then                                -- handshake
			session.handshake = session.handshake .. payload
		elseif (ctype == 0x15) then                            -- alert
			local level, desc = string.byte(payload, 1, 2)
			session.alert = string.format('alert level=%s description=%s',
				tostring(level), tostring(desc))
		end

		pos = pos + 5 + length
	end

	session.raw = string.sub(raw, pos)
end

--[[
	Returns the first certificate in the chain as DER, or nil if it has not
	arrived yet. Also returns a status string for logging.
]]
function M.certificate(session)
	consumeRecords(session)

	if (session.alert ~= nil) then
		return nil, 'device sent ' .. session.alert
	end

	local hs = session.handshake
	local pos = 1

	while (pos + 4 <= #hs + 1) do
		local mtype = string.byte(hs, pos)
		if (mtype == nil) then break end
		local mlen = readU24(hs, pos + 1)
		if (mlen == nil) then break end
		if (pos + 4 + mlen - 1 > #hs) then break end          -- message incomplete

		if (mtype == 0x0B) then                                -- Certificate
			local body = string.sub(hs, pos + 4, pos + 4 + mlen - 1)
			-- 3-byte chain length, then per-cert 3-byte length + DER.
			local certLen = readU24(body, 4)
			if (certLen == nil or certLen + 6 > #body) then
				return nil, 'malformed Certificate message'
			end
			return string.sub(body, 7, 6 + certLen), 'ok'
		end

		pos = pos + 4 + mlen
	end

	return nil, 'waiting for Certificate message'
end

return M
