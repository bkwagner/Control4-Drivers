--[[
	Minimal protobuf encoder/decoder for the Android TV Remote v2 protocol.

	Deliberately not a general protobuf runtime. The whole schema uses exactly two
	wire types - varint (0) and length-delimited (2) - so this handles those and
	skips anything else it meets. See docs/protocol-reference.md.

	Lua 5.1 dialect, no bit library: DriverWorks' interpreter has no guaranteed
	bitops, so shifts are done with arithmetic. All values in this protocol are
	small enough that float precision is not a concern.
]]

local M = {}

M.WIRE_VARINT = 0
M.WIRE_LENGTH = 2

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

function M.encodeVarint(n)
	if (n < 0) then
		error('encodeVarint: negative values are not used by this protocol')
	end
	local bytes = {}
	repeat
		local b = n % 128
		n = math.floor(n / 128)
		if (n > 0) then b = b + 128 end
		table.insert(bytes, string.char(b))
	until n == 0
	return table.concat(bytes)
end

--[[
	Decode a varint starting at 1-based `pos`.
	Returns value, nextPos - or nil if the buffer ends mid-varint, which is the
	normal case when a TCP read splits a message.
]]
function M.decodeVarint(s, pos)
	local result, shift = 0, 1
	while true do
		local b = string.byte(s, pos)
		if (b == nil) then return nil, pos end
		result = result + (b % 128) * shift
		pos = pos + 1
		if (b < 128) then return result, pos end
		shift = shift * 128
	end
end

local function tag(field, wire)
	return M.encodeVarint(field * 8 + wire)
end

--------------------------------------------------------------------------------
-- Field encoders. Each returns '' for a nil value so callers can concatenate
-- unconditionally and let unset fields disappear, matching proto3 semantics.
--------------------------------------------------------------------------------

function M.varintField(field, value)
	if (value == nil) then return '' end
	if (value == true) then value = 1 end
	if (value == false) then value = 0 end
	-- proto3 omits zero-valued scalars on the wire.
	if (value == 0) then return '' end
	return tag(field, M.WIRE_VARINT) .. M.encodeVarint(value)
end

function M.stringField(field, value)
	if (value == nil or value == '') then return '' end
	return tag(field, M.WIRE_LENGTH) .. M.encodeVarint(#value) .. value
end

--[[
	Nested message. Unlike scalars, an EMPTY encoded message is still emitted -
	presence is meaningful. RemoteMessage selects its variant purely by which
	submessage field is present, so an empty one is a valid, meaningful message.
	Pass nil to omit.
]]
function M.messageField(field, encoded)
	if (encoded == nil) then return '' end
	return tag(field, M.WIRE_LENGTH) .. M.encodeVarint(#encoded) .. encoded
end

--------------------------------------------------------------------------------
-- Decoding
--------------------------------------------------------------------------------

--[[
	Parse a buffer into { [fieldNumber] = { wire = n, value = x } }.

	Varint fields yield numbers; length-delimited yield the raw string, which the
	caller re-parses if it is a nested message. Repeated fields are not used by
	this protocol, so a later field of the same number simply wins.
]]
function M.parse(s)
	local pos, out, len = 1, {}, #s
	while (pos <= len) do
		local key
		key, pos = M.decodeVarint(s, pos)
		if (key == nil) then return out end

		local field = math.floor(key / 8)
		local wire  = key % 8
		local value

		if (wire == M.WIRE_VARINT) then
			value, pos = M.decodeVarint(s, pos)
			if (value == nil) then return out end
		elseif (wire == M.WIRE_LENGTH) then
			local n
			n, pos = M.decodeVarint(s, pos)
			if (n == nil or pos + n - 1 > len) then return out end
			value = string.sub(s, pos, pos + n - 1)
			pos = pos + n
		elseif (wire == 5) then          -- fixed32, unused here but skip cleanly
			pos = pos + 4
			value = nil
		elseif (wire == 1) then          -- fixed64, ditto
			pos = pos + 8
			value = nil
		else
			return out                    -- unknown wire type: cannot resync, stop
		end

		out[field] = { wire = wire, value = value }
	end
	return out
end

--- Convenience readers that tolerate a missing field.
function M.getVarint(parsed, field, default)
	local f = parsed[field]
	if (f == nil or f.wire ~= M.WIRE_VARINT) then return default end
	return f.value
end

function M.getString(parsed, field, default)
	local f = parsed[field]
	if (f == nil or f.wire ~= M.WIRE_LENGTH) then return default end
	return f.value
end

function M.getBool(parsed, field)
	return M.getVarint(parsed, field, 0) ~= 0
end

--------------------------------------------------------------------------------
-- Stream framing
--
-- Every message on 6466/6467 is a varint length followed by that many bytes.
-- TCP splits and coalesces freely, so a receiver must buffer and re-frame.
--------------------------------------------------------------------------------

function M.frame(payload)
	return M.encodeVarint(#payload) .. payload
end

function M.newBuffer()
	return { data = '' }
end

function M.push(buf, chunk)
	buf.data = buf.data .. chunk
end

--[[
	Pop one complete message, or nil if the buffer does not yet hold one.
	Call repeatedly until nil - a single TCP read can carry several messages.
]]
function M.nextMessage(buf)
	if (#buf.data == 0) then return nil end

	local len, pos = M.decodeVarint(buf.data, 1)
	if (len == nil) then return nil end          -- length prefix itself incomplete

	local headerLen = pos - 1
	if (#buf.data < headerLen + len) then return nil end   -- payload incomplete

	local msg = string.sub(buf.data, pos, pos + len - 1)
	buf.data = string.sub(buf.data, pos + len)
	return msg
end

return M
