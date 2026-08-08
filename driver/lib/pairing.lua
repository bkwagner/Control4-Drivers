--[[
	Android TV Remote v2 pairing (the "polo" protocol, port 6467).

	NOTE: pairing uses a DIFFERENT protobuf schema from normal operation. The
	envelope here is OuterMessage, not RemoteMessage, and the field numbers below
	have nothing to do with the ones in lib/atv_protocol.lua.

	Exchange, once mTLS is up on 6467:

	  client -> PairingRequest{service_name, client_name}
	  server -> PairingRequestAck
	  client -> Options{preferred_role=INPUT, input_encodings=[HEX, 6]}
	  server -> Options
	  client -> Configuration{client_role=INPUT, encoding=[HEX, 6]}
	  server -> ConfigurationAck          <- the TV now displays the code
	  client -> Secret{secret=<hash>}
	  server -> SecretAck                 <- paired

	Every message carries protocol_version=2 and status=STATUS_OK; a status other
	than STATUS_OK means the exchange has failed and the device will hang up.

	CAUTION: polo.proto is proto2, not proto3. Under proto2 an explicitly set zero
	is still written to the wire, whereas pb.varintField omits zero values. No
	message built here contains a zero-valued field - every enum and length used is
	non-zero - so the encodings match byte-for-byte today, and tools/test_pairing.py
	proves it. But adding a field whose value can legitimately be 0 would silently
	produce a message the device rejects. Encode such a field explicitly.
]]

local pb = require('lib.protobuf')

local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

M.PROTOCOL_VERSION = 2

M.STATUS = {
	OK                = 200,
	ERROR             = 400,
	BAD_CONFIGURATION = 401,
	BAD_SECRET        = 402,
}

M.ROLE_TYPE_INPUT = 1
M.ENCODING_TYPE_HEXADECIMAL = 3
M.SYMBOL_LENGTH = 6

--- OuterMessage field numbers.
M.FIELD = {
	PROTOCOL_VERSION    = 1,
	STATUS              = 2,
	PAIRING_REQUEST     = 10,
	PAIRING_REQUEST_ACK = 11,
	OPTIONS             = 20,
	CONFIGURATION       = 30,
	CONFIGURATION_ACK   = 31,
	SECRET              = 40,
	SECRET_ACK          = 41,
}

--------------------------------------------------------------------------------
-- Outbound messages
--------------------------------------------------------------------------------

local function envelope(field, encoded)
	return pb.frame(
		pb.varintField(M.FIELD.PROTOCOL_VERSION, M.PROTOCOL_VERSION) ..
		pb.varintField(M.FIELD.STATUS, M.STATUS.OK) ..
		pb.messageField(field, encoded)
	)
end

function M.buildPairingRequest(clientName, serviceName)
	local request =
		pb.stringField(1, serviceName or 'atvremote') ..
		pb.stringField(2, clientName or 'Control4')
	return envelope(M.FIELD.PAIRING_REQUEST, request)
end

--- Encoding submessage: { type, symbol_length }.
local function encoding()
	return pb.varintField(1, M.ENCODING_TYPE_HEXADECIMAL) ..
	       pb.varintField(2, M.SYMBOL_LENGTH)
end

function M.buildOptions()
	local options =
		pb.messageField(1, encoding()) ..                      -- input_encodings
		pb.varintField(3, M.ROLE_TYPE_INPUT)                   -- preferred_role
	return envelope(M.FIELD.OPTIONS, options)
end

function M.buildConfiguration()
	local configuration =
		pb.messageField(1, encoding()) ..                      -- encoding
		pb.varintField(2, M.ROLE_TYPE_INPUT)                   -- client_role
	return envelope(M.FIELD.CONFIGURATION, configuration)
end

--- secret is the raw 32-byte SHA-256 digest, not hex.
function M.buildSecret(secret)
	return envelope(M.FIELD.SECRET, pb.stringField(1, secret))
end

--------------------------------------------------------------------------------
-- Inbound messages
--------------------------------------------------------------------------------

--[[
	Returns { kind = <string>, status = <number> }.

	kind is one of: request_ack, options, configuration_ack, secret_ack, unknown.
	Callers must check status before acting on kind - the device reports failure
	by setting a non-OK status rather than by sending an error message.
]]
function M.parseMessage(payload)
	local msg = pb.parse(payload)
	local status = pb.getVarint(msg, M.FIELD.STATUS, M.STATUS.OK)

	local function has(field)
		return msg[field] ~= nil and msg[field].wire == pb.WIRE_LENGTH
	end

	local kind = 'unknown'
	if (has(M.FIELD.PAIRING_REQUEST_ACK)) then
		kind = 'request_ack'
	elseif (has(M.FIELD.OPTIONS)) then
		kind = 'options'
	elseif (has(M.FIELD.CONFIGURATION_ACK)) then
		kind = 'configuration_ack'
	elseif (has(M.FIELD.SECRET_ACK)) then
		kind = 'secret_ack'
	end

	return { kind = kind, status = status }
end

function M.statusName(status)
	for name, value in pairs(M.STATUS) do
		if (value == status) then return name end
	end
	return 'UNKNOWN(' .. tostring(status) .. ')'
end

--------------------------------------------------------------------------------
-- The secret
--------------------------------------------------------------------------------

local function hexToBytes(hex)
	local out = {}
	for i = 1, #hex, 2 do
		local byte = tonumber(string.sub(hex, i, i + 1), 16)
		if (byte == nil) then return nil end
		table.insert(out, string.char(byte))
	end
	return table.concat(out)
end

M.hexToBytes = hexToBytes

--[[
	Validate the code shown on the TV: exactly 6 hexadecimal characters.

	The first byte is a check value, not part of the secret - it must equal the
	first byte of the resulting hash. That is what makes a mistyped code fail
	locally rather than after a round trip.
]]
function M.checkCode(code)
	if (code == nil or #code ~= 6) then
		return false, 'code must be exactly 6 characters'
	end
	if (string.match(code, '^%x%x%x%x%x%x$') == nil) then
		return false, 'code must be hexadecimal'
	end
	return true
end

--[[
	Build the exact byte sequence that gets hashed.

	All four key components are raw big-endian bytes, as produced by OpenSSL's
	BN_bn2bin - i.e. no leading zero byte, no DER wrapper. For a 2048-bit RSA key
	the modulus is 256 bytes and the exponent is 3 bytes (01 00 01).

	The reference implementation writes this as
	    bytes.fromhex(f"{modulus:X}") and bytes.fromhex(f"0{exponent:X}")
	where the "0" prefix exists only to make the hex string even-length. Both are
	equivalent to the plain big-endian encoding used here.

	Only the LAST FOUR characters of the code contribute; the first two are the
	check byte and are deliberately excluded.

	This function is kept pure and free of crypto so it can be tested off-device
	against the reference implementation - it is where the ordering and padding
	subtleties live. The digest itself is a plain SHA-256 over the result.
]]
function M.buildSecretPreimage(clientModulus, clientExponent, serverModulus, serverExponent, code)
	local ok, err = M.checkCode(code)
	if (not ok) then return nil, err end

	local codeBytes = hexToBytes(string.sub(code, 3))
	if (codeBytes == nil) then return nil, 'code is not valid hex' end

	return clientModulus .. clientExponent .. serverModulus .. serverExponent .. codeBytes
end

--[[
	The first byte of the hash must equal the first byte of the code. If it does
	not, the code was mistyped or belongs to a different pairing attempt - fail
	here rather than sending a secret the device will reject.
]]
function M.verifyHash(hash, code)
	if (hash == nil or #hash < 1) then return false, 'empty hash' end
	local expected = tonumber(string.sub(code, 1, 2), 16)
	local actual = string.byte(hash, 1)
	if (actual ~= expected) then
		return false, string.format(
			'code check byte mismatch (expected %02X, computed %02X) - wrong or expired code',
			expected, actual)
	end
	return true
end

--------------------------------------------------------------------------------
-- Key material
--------------------------------------------------------------------------------

--[[
	Extract modulus and exponent as raw big-endian byte strings.

	`key` is a lua-openssl pkey. The shape of pkey:parse() varies between
	lua-openssl versions, so several layouts are tried; the working one is
	reported so it can be pinned in the docs once observed on hardware.

	Returns modulus, exponent, description - or nil, nil, error.
]]
function M.publicNumbers(key)
	local ok, parsed = pcall(function() return key:parse() end)
	if (not ok or parsed == nil) then
		return nil, nil, 'pkey:parse() failed: ' .. tostring(parsed)
	end

	-- Some versions nest the RSA components under .rsa, others hoist them.
	local candidates = {
		{ desc = 'parse().rsa', t = parsed.rsa },
		{ desc = 'parse()',     t = parsed },
	}

	for _, candidate in ipairs(candidates) do
		local t = candidate.t
		if (type(t) == 'table' and t.n ~= nil and t.e ~= nil) then
			-- bn -> raw big-endian bytes. totext() is BN_bn2bin in lua-openssl.
			local okN, n = pcall(function() return t.n:totext() end)
			local okE, e = pcall(function() return t.e:totext() end)
			if (okN and okE and n ~= nil and e ~= nil) then
				return n, e, candidate.desc .. ' + bn:totext()'
			end
		end
	end

	return nil, nil, 'could not locate RSA modulus/exponent in pkey:parse() output'
end

return M
