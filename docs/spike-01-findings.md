# Spike 01 — DriverWorks crypto & TLS capability

Status: **research done, hardware test pending**

The brief's spike task was: "confirm you can (1) `require` the openssl module,
(2) generate an RSA keypair and self-signed x509, and (3) open a TLS connection to
port 6467 presenting that cert."

Reading the actual SDK docs changes step 3 and adds a fourth question. Findings below,
then the revised test.

---

## What the SDK docs establish (no hardware needed)

### 1. lua-openssl exists, but the `ssl` module is removed

From `docs-driverworks-api/source/includes/13.5_openssl/_0-Header.md`, the DriverWorks
build of lua-openssl has these removed:

| Removed | Stated reason |
|---|---|
| Module `ssl` | "designed for use with sockets that the OpenSSL socket API blocks" |
| `bio:connect`, `bio:handshake`, `bio:get_ssl`, `bio:accept`, `bio:shutdown` | socket methods |
| Modules `rsa`, `ec`, `dh`, `dsa`, `srp` | deprecated in OpenSSL 3 — use `pkey` instead |

So **lua-openssl cannot open the TLS connection**. Key/cert generation should work
(via `pkey` and `x509`), but the handshake has to go through Director's network stack.

Note the `rsa` module removal: generate RSA keys with `pkey.new('rsa', 2048)`, not
`rsa.generate()`.

### 2. Director's network stack *does* support client certificates

`C4:NetPortOptions` accepts `CERTIFICATE`, `PRIVATE_KEY`, `CACERTFILE`, `VERIFY_MODE`,
and `VERIFY_METHOD`. That is mutual TLS. The `generic_tcp` sample driver ships a
`cert/` directory inside its `.c4z`, confirming this is a supported pattern.

Two caveats worth measuring:

- **Cert paths are documented as relative to the driver's `.c4z` directory.** Our cert
  is generated (or pasted) at runtime, so it lands in the sandbox. Whether the SSL
  layer will read a `SANDBOX:/` path is untested.
- **`VERIFY_METHOD` documents only `sslv2, sslv23, sslv3, tlsv1, tlsv1_1`.** No
  TLS 1.2+ is listed. If that list is literal rather than stale, and the Android TV
  Remote service requires TLS 1.2, native Lua is dead. `sslv23` maps to OpenSSL's
  "negotiate the highest mutually supported version", so it is the one to try first.
  The docs also contradict themselves — the prose says `VERIFY_METHOD`, the sample
  table says `METHOD`. The spike sets both.

### 3. ⚠️ The peer certificate is never exposed to Lua — this reshapes the project

Pairing on port 6467 requires hashing **both** certificates' public keys together with
the on-screen code. That means the client needs the *server's* public key.

Grepping the entire API reference for any way to retrieve the peer certificate from a
connection turns up nothing — `VERIFY_MODE` and the server-socket `verifyMode` bitmask
are the only peer-cert-adjacent APIs, and both only control verification. There is no
getter.

**Therefore in-driver pairing is not possible**, regardless of how the other questions
resolve.

This is less bad than it sounds. Pairing is a **one-time** operation, and the brief
already notes the client cert *is* the persistent identity. So:

> Pair once, out of band, with a desktop tool. Import the resulting cert + key into
> the driver. The driver then only ever does mTLS on 6466, which needs no peer-cert
> introspection.

That removes the need for an always-on sidecar container **and** sidesteps the
limitation — it is strictly better than Option A, and better than the Option B the
brief imagined. The remaining risk collapses to a single question: can Director do
mTLS to this device at all?

---

## Revised spike

The pairing port (6467) accepts **any** self-signed client certificate — that is the
whole point of pairing. So a self-generated throwaway cert is enough to test the
transport, and no pairing is needed first.

| Step | Question | How |
|---|---|---|
| 1 | Is lua-openssl present and can it mint an identity? | `spikes/01_openssl_capability.lua`, pasted into the Composer Lua window |
| 2 | Can the PEMs be written where the SSL layer can read them? | Same script — tries `SANDBOX:/`, `C4Z:/`, and the default alias |
| 3 | **Does Director complete an mTLS handshake to 6467?** | `driver/atv_spike` — the decisive test |
| 4 | Which `VERIFY_METHOD` value works? | Flip the TLS Method property, repeat step 3 |

Step 3 going `ONLINE` is the go/no-go for a native Lua driver.

### Decision matrix

| Result | Consequence |
|---|---|
| Step 3 ONLINE with `sslv23` | Native Lua driver. Pairing tool on desktop, driver does 6466 only. No bridge, no container. |
| Step 3 ONLINE only with a fixed cert baked into the `.c4z` | Same, but the pairing tool's output gets pasted into a driver property and written to `C4Z:/` at install time. Slightly worse UX, still no bridge. |
| Step 3 OFFLINE on every method | TLS 1.2 is likely unreachable from Director. Fall back to the sidecar bridge (Option A). |

---

## Results

### Steps 1 & 2 — lua-openssl and file writing: **PASS**

Run 2026-08-08 against the target controller. lua-openssl reports version **0.8.5**.

Module availability exactly matches the documented trim:

| Present | Absent |
|---|---|
| `pkey`, `x509`, `bio`, `digest`, `hmac`, `cipher` | `ssl`, `rsa`, `ec` |

Working call shapes — **use these, the upstream docs are wrong in one place**:

```lua
local key     = openssl.pkey.new('rsa', 2048)
local subject = openssl.x509.name.new({ { CN = 'atvremote' }, { O = 'Control4' }, { OU = 'DriverWorks' } })
local req     = openssl.x509.req.new(subject, key)      -- two-arg form
local cert    = req:to_x509(key, 3650, 'sha256')
local certPem = cert:export('pem')                       -- 1086 bytes
local keyPem  = key:export('pem')                        -- 1704 bytes
```

The upstream-documented `req.new(subject, exts, attrs, pkey, md)` is **rejected** on
0.8.5 with `bad argument #2 to 'new' (must be x509_name or evp_pkey)`.

RSA-2048 keygen completes without tripping any Director watchdog.

**File writing: all three aliases work**, write and read-back both verified:

| Alias | Result |
|---|---|
| `SANDBOX:/` | ok, read-back ok |
| `C4Z:/` | ok, read-back ok |
| (default) | ok, read-back ok |

`C4Z:/` being runtime-writable is the significant one — `CERTIFICATE` paths are
documented as relative to the `.c4z` directory, so `./atv_client.pem` should resolve
to a file we can create at runtime. This was the open question from the research phase
and it resolves favourably.

**Caveat to remember:** the private key exports as PKCS#8 (`BEGIN PRIVATE KEY`), not
PKCS#1 (`BEGIN RSA PRIVATE KEY`). If the handshake fails inexplicably, eliminate key
format as a cause before anything else.

**Caveat for production:** the `.c4z` directory is extracted from the driver archive,
so anything written there is presumed lost on driver update. The production driver
should re-materialise the cert from its stored property on `OnDriverInit` rather than
assuming the file survives.

### Device TLS profile — measured from a desktop, 2026-08-08

Target: `10.200.10.50`, Android TV Remote Service **6.9** (≥ 5, so protocol v2).
Both ports open. Probed with `openssl s_client` presenting a self-signed RSA-2048
client cert, `@SECLEVEL=0` to force the old versions to be offered.

| TLS version | Device response |
|---|---|
| 1.0 | alert 70 `protocol_version` — refused **by the device** |
| 1.1 | alert 70 `protocol_version` — refused **by the device** |
| 1.2 | ✅ handshake OK, `ECDHE-RSA-AES128-GCM-SHA256` |
| 1.3 | ✅ handshake OK, `TLS_AES_256_GCM_SHA384` |

**The device requires TLS 1.2 minimum.** mTLS on 6467 succeeds with an arbitrary
self-signed client cert, confirming the pairing port accepts any identity.

Consequences for the driver:

- `VERIFY_METHOD` must be **`sslv23`** (OpenSSL's "negotiate the highest mutually
  supported version"). `tlsv1` and `tlsv1_1` are guaranteed to fail.
- The SDK's documented `VERIFY_METHOD` list stopping at `tlsv1_1` is very likely
  stale. Director is on OpenSSL 3.x — the OS 4.0.0 notes cite OpenSSL 3.0
  deprecations, and lua-openssl 0.8.5 was trimmed of precisely the modules OpenSSL 3
  removed. Under OpenSSL 3.x, `sslv23` reaches TLS 1.2/1.3.

Note also: without a client cert, TLS 1.2 fails with alert 40 while TLS 1.3 appears to
succeed — under 1.3 the certificate request happens after the server's Finished, so the
client sees a completed handshake. Don't mistake that for a passing test.

### Step 3 — mTLS handshake from Director: **PASS**

| TLS Method | Cert Path Form | Port | Result |
|---|---|---|---|
| sslv23 | `./atv_client.pem` | 6467 | ✅ `ONLINE` |

```
OnConnectionStatusChanged: binding=6001 port=6467 status=ONLINE
OnConnectionStatusChanged: binding=6001 port=6467 status=OFFLINE
```

The `OFFLINE` immediately after is **expected and not a failure**. The pairing service
expects a `PairingRequest` as soon as the socket opens; the spike connects and sends
nothing, so the device closes the connection. Same behaviour was observed from a
desktop `openssl s_client` probe.

`./atv_client.pem` resolves against the `.c4z` directory, and Step 2 had written the
cert there via the `C4Z:/` alias — so runtime-generated certs work with the documented
relative path form. No need for the `SANDBOX:/` spelling.

## Conclusion

**Architecture decision: native Lua driver. No sidecar bridge, no container.**

Everything Option B required is verified on hardware:

| Requirement | Status |
|---|---|
| Generate a client identity in-driver | ✅ lua-openssl 0.8.5 |
| Persist it where the TLS layer can read it | ✅ `C4Z:/`, read back via `./` |
| Reach TLS 1.2+ (device rejects 1.0/1.1) | ✅ via `sslv23` |
| Present a client cert and complete mTLS | ✅ `ONLINE` on 6467 |

**Superseded:** this document originally concluded that pairing was impossible
in-driver, because the peer certificate is never exposed to Lua. That conclusion was
too strong. Director will not *hand over* the peer certificate, but the driver can
fetch it itself: in TLS 1.2 the server's Certificate message is plaintext, so a raw
TCP socket and a hand-rolled ClientHello recover it. Proven by `tools/peek_cert.py`
against the real device — see the pairing section of [CLAUDE.md](../CLAUDE.md).

Pairing therefore stays in the driver, and `tools/pair.py` is kept as a fallback for
the case where the device stops offering TLS 1.2.

Caveat on the strength of the Step 3 evidence: under TLS 1.3 the client sees a completed
handshake before the server validates the client certificate, so `ONLINE` is not by
itself proof the cert was *accepted*. For port 6467 this is moot — the pairing port
accepts any self-signed identity by design. Definitive proof comes when a **paired**
cert holds a connection open on 6466, which is milestone 3.

### Next

1. Desktop pairing tool → produces `client.pem` + `client_key.pem` (milestone 2).
2. Import those into the driver, connect on 6466, send a keycode (milestone 3).
