--[[
	PEM normalisation for certificate import.

	Composer has no multi-line property type - STRING is a single-line field - so a
	PEM pasted straight in loses its newlines and OpenSSL rejects it. This module
	accepts whatever survives the paste and rebuilds canonical PEM:

	  - a full PEM with real newlines (if it somehow survives)
	  - a PEM with literal backslash-n sequences
	  - the bare base64 body on one line, headers stripped  <- what pair.py emits
	  - any of the above with stray spaces

	Everything is reduced to the base64 payload and re-wrapped at 64 columns with
	the correct header and footer.
]]

local M = {}

M.CERTIFICATE = 'CERTIFICATE'
M.PRIVATE_KEY = 'PRIVATE KEY'

--[[
	Returns normalised PEM text, or nil plus an error message.

	label is M.CERTIFICATE or M.PRIVATE_KEY - the header is rebuilt from it, so a
	body pasted into the wrong field is relabelled rather than silently accepted.
	Note the key that pair.py writes is PKCS#8 ('PRIVATE KEY'), not PKCS#1
	('RSA PRIVATE KEY'); see docs/spike-01-findings.md.
]]
function M.normalize(input, label)
	if (input == nil or input == '') then
		return nil, 'empty'
	end

	local s = input

	-- Literal "\n" typed or pasted as two characters.
	s = string.gsub(s, '\\n', '')
	-- Any BEGIN/END armour, whatever it claims to wrap.
	s = string.gsub(s, '%-%-%-%-%-[^%-]*%-%-%-%-%-', '')
	-- All real whitespace, including the newlines of a genuine PEM.
	s = string.gsub(s, '%s', '')

	if (s == '') then
		return nil, 'no base64 content found'
	end
	if (string.match(s, '[^A-Za-z0-9+/=]') ~= nil) then
		return nil, 'contains characters that are not base64'
	end
	-- base64 is 4 characters per 3 bytes; a wrong length means a truncated paste,
	-- which is the most likely failure when copying out of a terminal.
	if (#s % 4 ~= 0) then
		return nil, string.format('truncated: %d base64 chars is not a multiple of 4', #s)
	end

	local lines = { '-----BEGIN ' .. label .. '-----' }
	for i = 1, #s, 64 do
		table.insert(lines, string.sub(s, i, i + 63))
	end
	table.insert(lines, '-----END ' .. label .. '-----')

	return table.concat(lines, '\n') .. '\n'
end

--[[
	Short human-readable identifier for a normalised PEM, so the driver can show
	which certificate it holds without exposing the key material.
]]
function M.summarize(pem)
	if (pem == nil) then return 'none' end
	local body = string.gsub(pem, '%-%-%-%-%-[^%-]*%-%-%-%-%-', '')
	body = string.gsub(body, '%s', '')
	if (#body < 16) then return 'invalid' end
	return string.format('%s...%s (%d bytes)',
		string.sub(body, 1, 8), string.sub(body, -8), #body)
end

return M
