--[[
	Spike 1 (standalone) - lua-OpenSSL capability probe.

	Paste this whole block into the Composer Pro Lua window of ANY existing
	driver in the project and execute it. It needs no driver install and touches
	nothing persistent beyond two files in that driver's sandbox.

	It answers: is lua-openssl present on this controller, and can it generate an
	RSA keypair and a self-signed x509 certificate?

	It does NOT test the TLS connection - the DriverWorks build of lua-openssl has
	the `ssl` module and all bio socket methods removed, so the handshake has to go
	through Director's own network stack. That is what the atv_spike driver tests.

	Copy every line of output back.
]]

do
	local function log(fmt, ...)
		local ok, msg = pcall(string.format, fmt, ...)
		print('[SPIKE1] ' .. (ok and msg or tostring(fmt)))
	end

	local function try(desc, fn)
		local ok, result = pcall(fn)
		if (ok and result ~= nil) then
			log('  ok   : %s', desc)
			return result
		end
		log('  fail : %s -> %s', desc, tostring(result))
		return nil
	end

	local function firstThatWorks(label, attempts)
		for _, a in ipairs(attempts) do
			local v = try(a.desc, a.fn)
			if (v ~= nil) then
				log('PASS %s  <- %s', label, a.desc)
				return v
			end
		end
		log('FAIL %s - every call shape errored', label)
		return nil
	end

	log('=== begin ===')

	local ok, openssl = pcall(require, 'openssl')
	if (not ok or openssl == nil) then
		log('FAIL require openssl -> %s', tostring(openssl))
		log('=== end (Option B is dead in the water; fall back to a bridge) ===')
		return
	end
	log('PASS require openssl')

	local okv, version = pcall(function() return openssl.version() end)
	log('openssl version: %s', okv and tostring(version) or 'unavailable')

	for _, name in ipairs({ 'pkey', 'x509', 'bio', 'digest', 'hmac', 'cipher', 'ssl', 'rsa', 'ec' }) do
		log('module %-8s : %s', name, tostring(openssl[name] ~= nil))
	end

	local key = firstThatWorks('generate RSA 2048 keypair', {
		{ desc = "pkey.new('rsa', 2048)", fn = function() return openssl.pkey.new('rsa', 2048) end },
		{ desc = "pkey.new('rsa', 2048, 65537)", fn = function() return openssl.pkey.new('rsa', 2048, 65537) end },
		{ desc = "pkey.new('rsa')", fn = function() return openssl.pkey.new('rsa') end },
	})
	if (key == nil) then log('=== end ==='); return end

	local subject = firstThatWorks('build x509 name', {
		{ desc = 'name.new{CN,O,OU}', fn = function()
			return openssl.x509.name.new({ { CN = 'atvremote' }, { O = 'Control4' }, { OU = 'DriverWorks' } })
		end },
		{ desc = 'name.new{CN}', fn = function()
			return openssl.x509.name.new({ { CN = 'atvremote' } })
		end },
	})
	if (subject == nil) then log('=== end ==='); return end

	local req = firstThatWorks('build CSR', {
		{ desc = "req.new(subject, nil, nil, key, 'sha256')", fn = function()
			return openssl.x509.req.new(subject, nil, nil, key, 'sha256')
		end },
		{ desc = 'req.new(subject, key)', fn = function()
			return openssl.x509.req.new(subject, key)
		end },
		{ desc = 'req.new(subject) + sign', fn = function()
			local r = openssl.x509.req.new(subject)
			r:sign(key, 'sha256')
			return r
		end },
	})
	if (req == nil) then log('=== end ==='); return end

	local cert = firstThatWorks('self-sign x509', {
		{ desc = "req:to_x509(key, 3650, 'sha256')", fn = function() return req:to_x509(key, 3650, 'sha256') end },
		{ desc = 'req:to_x509(key, 3650)', fn = function() return req:to_x509(key, 3650) end },
		{ desc = 'req:to_x509(key)', fn = function() return req:to_x509(key) end },
	})
	if (cert == nil) then log('=== end ==='); return end

	local certPem = firstThatWorks('export cert PEM', {
		{ desc = "cert:export('pem')", fn = function() return cert:export('pem') end },
		{ desc = 'cert:export()', fn = function() return cert:export() end },
	})
	local keyPem = firstThatWorks('export key PEM', {
		{ desc = "key:export('pem')", fn = function() return key:export('pem') end },
		{ desc = "key:export('pem', true)", fn = function() return key:export('pem', true) end },
		{ desc = 'key:export()', fn = function() return key:export() end },
	})
	if (certPem == nil or keyPem == nil) then log('=== end ==='); return end

	log('cert PEM %d bytes, starts %q', #certPem, string.sub(certPem, 1, 28))
	log('key  PEM %d bytes, starts %q', #keyPem, string.sub(keyPem, 1, 28))

	-- Can we get them onto disk, and which directory aliases work?
	for _, prefix in ipairs({ 'SANDBOX:/', 'C4Z:/', '' }) do
		local label = (prefix == '') and '(default)' or prefix
		local f, err = openssl.bio.file(prefix .. 'atv_client.pem', 'w+b')
		if (f == nil) then
			log('write %-12s : FAIL -> %s', label, tostring(err))
		else
			f:write(certPem)
			f:close()
			local r = openssl.bio.file(prefix .. 'atv_client.pem', 'r')
			local back = r and r:read(65536) or nil
			if (r) then r:close() end
			log('write %-12s : ok, read-back %s', label,
				(back ~= nil and #back == #certPem) and 'ok' or 'MISMATCH/nil')
		end
	end

	log('=== end - if you got here, in-driver identity generation works ===')
end
