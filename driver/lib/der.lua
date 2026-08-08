--[[
	Just enough DER/ASN.1 to pull an RSA public key out of an X.509 certificate.

	Why this exists rather than lua-openssl's pkey:parse(): the shape of that
	function's return value varies between lua-openssl versions, and DriverWorks
	ships a build with the rsa module removed. On the target controller
	(lua-openssl 0.8.5) it yields no reachable modulus or exponent at all.

	Reading the certificate directly is version-independent and, unlike anything
	that touches lua-openssl, can be tested off-device against real certificates.

	Both key halves needed by the pairing hash come from certificates we already
	hold: the device's is harvested by lib/tls_peek, and ours is the certificate
	the driver generated, converted from PEM here.
]]

local M = {}

--------------------------------------------------------------------------------
-- Base64 (PEM bodies)
--------------------------------------------------------------------------------

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local B64_INDEX = {}
for i = 1, #B64 do
	B64_INDEX[string.sub(B64, i, i)] = i - 1
end

function M.base64Decode(data)
	data = string.gsub(data, '[^' .. B64 .. '=]', '')

	local out = {}
	local bits, count = 0, 0

	for i = 1, #data do
		local c = string.sub(data, i, i)
		if (c ~= '=') then
			local v = B64_INDEX[c]
			if (v == nil) then return nil, 'invalid base64 character' end
			bits = bits * 64 + v
			count = count + 1
			if (count == 4) then
				table.insert(out, string.char(
					math.floor(bits / 65536) % 256,
					math.floor(bits / 256) % 256,
					bits % 256))
				bits, count = 0, 0
			end
		end
	end

	-- Trailing group: 3 symbols -> 2 bytes, 2 symbols -> 1 byte.
	if (count == 3) then
		bits = bits * 64
		table.insert(out, string.char(
			math.floor(bits / 65536) % 256, math.floor(bits / 256) % 256))
	elseif (count == 2) then
		bits = bits * 4096
		table.insert(out, string.char(math.floor(bits / 65536) % 256))
	elseif (count == 1) then
		return nil, 'truncated base64'
	end

	return table.concat(out)
end

--- Strip PEM armour and decode the body to DER.
function M.pemToDer(pem)
	if (pem == nil or pem == '') then return nil, 'empty PEM' end
	local body = string.gsub(pem, '%-%-%-%-%-[^%-]*%-%-%-%-%-', '')
	return M.base64Decode(body)
end

--------------------------------------------------------------------------------
-- DER
--------------------------------------------------------------------------------

local TAG_INTEGER    = 0x02
local TAG_BIT_STRING = 0x03
local TAG_SEQUENCE   = 0x30

--[[
	Read one tag-length-value at 1-based `pos`.
	Returns tag, contentStart, contentLength, nextPos - or nil on malformed input.
]]
local function readTLV(s, pos)
	local tag = string.byte(s, pos)
	if (tag == nil) then return nil end

	local first = string.byte(s, pos + 1)
	if (first == nil) then return nil end

	local length, header
	if (first < 128) then
		length, header = first, 2
	else
		local count = first - 128
		-- Certificates in this protocol are ~1 KB; more than 4 length bytes means
		-- the input is not what we think it is.
		if (count == 0 or count > 4) then return nil end
		length = 0
		for i = 1, count do
			local b = string.byte(s, pos + 1 + i)
			if (b == nil) then return nil end
			length = length * 256 + b
		end
		header = 2 + count
	end

	local contentStart = pos + header
	if (contentStart + length - 1 > #s) then return nil end
	return tag, contentStart, length, contentStart + length
end

M.readTLV = readTLV

--[[
	DER INTEGERs are signed, so a leading 0x00 is prepended when the top bit of
	the first byte is set. OpenSSL's BN_bn2bin - and therefore the pairing hash -
	has no such byte, so it must come off.
]]
local function stripLeadingZero(bytes)
	while (#bytes > 1 and string.byte(bytes, 1) == 0) do
		bytes = string.sub(bytes, 2)
	end
	return bytes
end

--[[
	Parse an RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER publicExponent }.
	Returns modulus, exponent as raw big-endian bytes.
]]
function M.rsaPublicKeyFromDer(der)
	local tag, contentStart = readTLV(der, 1)
	if (tag ~= TAG_SEQUENCE) then return nil, nil, 'RSAPublicKey is not a SEQUENCE' end

	local nTag, nStart, nLen, afterN = readTLV(der, contentStart)
	if (nTag ~= TAG_INTEGER) then return nil, nil, 'modulus is not an INTEGER' end

	local eTag, eStart, eLen = readTLV(der, afterN)
	if (eTag ~= TAG_INTEGER) then return nil, nil, 'exponent is not an INTEGER' end

	return stripLeadingZero(string.sub(der, nStart, nStart + nLen - 1)),
	       stripLeadingZero(string.sub(der, eStart, eStart + eLen - 1)),
	       'ok'
end

--[[
	Pull the RSA public key out of an X.509 certificate.

	Rather than indexing tbsCertificate by field position - which shifts depending
	on whether the optional version tag is present - this scans its children for
	the first SEQUENCE shaped like a SubjectPublicKeyInfo, i.e. an
	AlgorithmIdentifier SEQUENCE followed by a BIT STRING. That is unambiguous
	within a certificate and survives the optional fields.

	Returns modulus, exponent as raw big-endian bytes, plus a status string.
]]
function M.rsaPublicKeyFromCertificate(der)
	if (der == nil or #der < 8) then return nil, nil, 'certificate too short' end

	local tag, certStart = readTLV(der, 1)
	if (tag ~= TAG_SEQUENCE) then return nil, nil, 'certificate is not a SEQUENCE' end

	local tbsTag, tbsStart, tbsLen = readTLV(der, certStart)
	if (tbsTag ~= TAG_SEQUENCE) then return nil, nil, 'no tbsCertificate' end

	local pos = tbsStart
	local tbsEnd = tbsStart + tbsLen

	while (pos < tbsEnd) do
		local childTag, childStart, _, nextPos = readTLV(der, pos)
		if (childTag == nil) then break end

		if (childTag == TAG_SEQUENCE) then
			local algTag, _, _, afterAlg = readTLV(der, childStart)
			if (algTag == TAG_SEQUENCE and afterAlg ~= nil) then
				local bitTag, bitStart, bitLen = readTLV(der, afterAlg)
				if (bitTag == TAG_BIT_STRING and bitLen ~= nil and bitLen > 1) then
					-- First content byte of a BIT STRING counts unused trailing bits;
					-- it is always 0 here and is not part of the key.
					local keyDer = string.sub(der, bitStart + 1, bitStart + bitLen - 1)
					return M.rsaPublicKeyFromDer(keyDer)
				end
			end
		end

		pos = nextPos
	end

	return nil, nil, 'no SubjectPublicKeyInfo found in certificate'
end

--- Convenience: same thing starting from PEM.
function M.rsaPublicKeyFromPem(pem)
	local der, err = M.pemToDer(pem)
	if (der == nil) then return nil, nil, tostring(err) end
	return M.rsaPublicKeyFromCertificate(der)
end

return M
