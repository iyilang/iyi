# A security review of std/tls

**This is an automated review, not an audit.** It was made by an AI coding
agent working in this repository, reading the code, reproducing what it
suspected and fixing what it reproduced. Nobody independent of the code has
checked it, and nothing here changes what the 0.18.0 notes and
`src/std/tls.iyi` say: std/tls has not been audited and is not to be called
secure until it is. What follows is evidence for whoever does that audit:
what was looked at, what was found and fixed, and what was looked at and
found sound, each with the place in the code and the check that holds it.

## Scope

The code at `b90c9757c` (0.18.0 and the CI change after it), branch
`tls/audit`:

- `src/std/tls.iyi`: the TLS 1.3 client and server, the TLS 1.2 client.
- What it stands on: `src/std/x509.iyi`, `ecdsa.iyi`, `rsa.iyi`,
  `curve25519.iyi`, `p256.iyi`, `aead.iyi`, `big.iyi` (the parts std/rsa
  uses), `crypto.iyi`, `digest.iyi`, `asn1.iyi` (as std/x509 reads with it)
  and `random.iyi` (`Random::Secure`).
- The callers of std/tls: `src/std/http.iyi` (client, proxy tunnel,
  server), `src/std/smtp.iyi` (STARTTLS), and `src/std/websocket.iyi`
  through `HTTP.upgrade`.

Not in scope: the compiler and the runtime under the library, and any
other platform than Linux x86_64, where everything below was run.

## Method

1. `tls.iyi` and `x509.iyi` were read whole, against RFC 8446, RFC 5246,
   RFC 7627, RFC 5746, RFC 5280 and RFC 6125: the handshake state machine
   at both ends, HelloRetryRequest, KeyUpdate, the transcript and the key
   schedule, the record layer, alerts and close_notify, certificate path
   validation and host matching.
2. The primitives were read by four separate read-only passes, one each
   for std/rsa with std/big, the curves (X25519, Ed25519, P-256, ECDSA),
   the AEADs with HMAC/HKDF, the digests and `Random::Secure`, and std/http
   with std/asn1. Each pass reported file and line for every claim; every
   claim used below was then read again at that line.
3. Every suspected flaw was reproduced against the 0.18.0 code with a
   concrete input: a certificate chain Python's `cryptography` 46.0.5
   built, or a record the scripted TLS server (`bench/std_tls_server.py`)
   sends. The verdict of an outside implementation - Python's verifier,
   OpenSSL 3.5.5's `openssl verify`, or its X.509 parser - was taken
   beside it where one exists.
4. Each fix is its own commit, with a check in the module's gate that
   fails on the old code and a broken copy of the module ("mutation") that
   the gate must catch at that check.

## Findings

| # | Severity | Where | Finding | State |
|---|---|---|---|---|
| 1 | Medium | std/x509 | An excluded name constraint did not hold out a name written with a final dot, which the host matcher takes | fixed, `ed1b21b2c` |
| 2 | Medium | std/x509 | An excluded name constraint did not hold out a wildcard standing for an excluded name (the gap Go fixed as CVE-2025-61727) | fixed, `21e5a6223` |
| 3 | Low | std/x509 | RSA keys of 1024 to 2047 bits were taken anywhere in a chain | fixed, `9243cbebf` |
| 4 | Low | std/x509 | A second extensions block in a TBSCertificate was read on top of the first | fixed, `cbe2a0ca2` |
| 5 | Low | std/tls | A TLS 1.3 record's padding could take its inner plaintext past 2^14 + 1 bytes | fixed, `19b9377c1` |
| 6 | Low | std/tls | Application data or close_notify was taken between the pieces of a split handshake message | fixed, `1634cc151` |
| 7 | Low | std/random | The `/dev/urandom` fallback does not check that it opened a character device | open |
| 8 | Informational | std/curve25519 | Ed25519 verification takes a public key of small order | open, by design |
| 9 | Informational | std/rsa | CRT recombination, the reductions by p and q and the blinding inverse are variable-time, on blinded values | open, covered by blinding |
| 10 | Informational | std/http | A redirect from `https://` to `http://` is followed | open, policy |
| 11 | Informational | std/http | A kept connection is reused after `HTTP.tls_config=` changes the roots or identity | open |
| 12 | Informational | std/http | The HTTPS server has no cap on connections, and a slow request body is bounded per read only | open, outside TLS |
| 13 | Informational | std/x509 | DER laxness in signed data: explicit DEFAULT values, fractional seconds in a GeneralizedTime | open |
| 14 | Informational | std/tls | A host given to `TlsClient` in Unicode or with a final dot goes into server_name as written | open, fails closed |

Severity is judged for a TLS client that trusts the system roots: Medium is
a way around a check that a certificate authority's own constraints rely
on; Low is a rule of the RFCs not held, with no known way to turn it into
an attack; Informational is a choice or a hardening gap.

### 1. A final dot taken past an excluded name constraint (Medium)

**What.** `X509Names.dns_matches?` drops one final dot from a dNSName
before it compares it to the host, as RFC 6125 allows. The name constraint
check (`X509.constraint_error`) compared the dNSName as written. An
intermediate whose nameConstraints exclude `evil.example` therefore did not
exclude a leaf naming `evil.example.` or `www.evil.example.`, and the leaf
matched the hosts `evil.example` and `www.evil.example`. A constraint itself
written with a final dot (`evil.example.`) excluded nothing, and a name with
two final dots matched the host written with two.

**Evidence.** A root, an intermediate excluding `evil.example`, and a leaf
naming `evil.example.`, made by Python's cryptography; `X509.verify` for
the host `evil.example` at 0.18.0 answered `true`, and Python's verifier
refuses the chain (it matches a name with a final dot to no host). An
intermediate excluding `evil.example.` over a leaf for `evil.example`:
0.18.0 `true`, Python "malformed DNS name constraint".

**Fix.** A name is judged by a constraint as the matcher reads it, without
its final dot; a name under a DNS constraint, or a DNS constraint, with an
empty label refuses the chain.

**Checks.** `bench/std_x509_exercise.iyi` holds four chains (a name below
the excluded one with a final dot, the excluded name with one, a constraint
with one, a name with two) and a control that still holds; the gate's 200
fresh chains gain the `excluded_dot` defect, each verdict Python's.
Mutations caught: "a name's final dot kept from its constraints", "a name
with an empty label judged by its constraints", "a constraint with an
empty label taken".

### 2. A wildcard taken past an excluded name constraint (Medium)

**What.** A wildcard `*.example.com` was compared to an excluded
`bad.example.com` as one name, and it is neither that name nor below it,
so a leaf for `*.example.com` under an intermediate excluding
`bad.example.com` held for the host `bad.example.com`. This is the gap Go
closed in 1.25.5 and 1.24.11 as CVE-2025-61727 (GO-2025-4175).

**Evidence.** The chain made by Python's cryptography: 0.18.0 `true` for
`bad.example.com` and for `good.example.com`; Python's verifier refuses it
for both ("excluded name constraint matched SAN").

**Fix.** An excluded constraint holds a wildcard out when it names a host
the wildcard stands for - whatever host the chain is checked for, as
Python does.

**Checks.** The exercise refuses the chain for the excluded host and for
another, and the 200 fresh chains gain the `excluded_wildcard` defect.
Mutation caught: "a wildcard judged as one name by an excluded
constraint".

### 3. RSA keys under 2048 bits in a chain (Low)

**What.** std/rsa reads public keys down to 1024 bits, and std/x509 set no
other floor, so a leaf, intermediate or root with a 1024-bit RSA key was
taken; a TLS server's CertificateVerify or ServerKeyExchange is then checked
under that key. 2048 bits is the floor std/rsa signs at and the CA/Browser
Forum's for a certificate's key.

**Evidence.** A 1024-bit RSA leaf under an EC intermediate: 0.18.0 `true`.
`openssl verify -auth_level 2` refuses 1024- and 1536-bit keys at every
depth. Python's verifier refuses a 1024-bit intermediate and takes a
1024-bit leaf. OpenSSL judges by NIST SP 800-56B's estimate and was
measured taking 1990 bits and up, so std/x509 is the stricter between 1990
and 2047 bits.

**Fix.** `X509::MIN_RSA_BITS = 2048`, checked for the leaf and every
issuer, root included.

**Checks.** The exercise refuses a 1024-bit leaf and a 1024-bit
intermediate; the gate holds seven fresh chains (1024 and 1536 bits at the
leaf, the intermediate and the root, and none) to `openssl verify
-auth_level 2`. Mutations caught: "a leaf's RSA key of any size taken", "an
issuer's RSA key of any size taken".

### 4. Two extensions blocks in one certificate (Low)

**What.** RFC 5280 has issuerUniqueID `[1]`, subjectUniqueID `[2]` and
extensions `[3]` at most once each, in that order. `Certificate.parse` took
any number in any order and read every extensions block into the same
record, the duplicate-extension check starting afresh for each, so a
certificate whose second block said basicConstraints cA where its first
did not was a CA here. The signature covers both blocks, so this needs the
issuer's key; what it breaks is that every other reader sees another
certificate, which is how a certificate passes a linter or a CT monitor as
one thing and is used as another.

**Evidence.** A self-signed certificate with `[3]{cA FALSE}` and then
`[3]{cA TRUE}`, made with Python's cryptography and re-signed: 0.18.0 read
it as a CA. Python's cryptography refuses to read it (`ExtraData` in
`tbs_cert`) and so does `openssl x509`.

**Fix.** A second `[1]`, `[2]` or `[3]`, or one out of order, is refused.

**Checks.** The exercise refuses that certificate for its reason.
Mutation caught: "a second extensions block read over the first".

### 5. Padding past 2^14 + 1 bytes of inner plaintext (Low)

**What.** RFC 8446 section 5.4: "the full encoded TLSInnerPlaintext MUST
NOT exceed 2^14 + 1 octets", padding included. `TlsRecordCipher#open`
checked the content alone, so a peer could pad a full record past the
limit by up to the 239 bytes the ciphertext's own limit leaves. No attack
is known that needs it; it is a rule that both ends are held to.

**Evidence.** The scripted server's `padded-over` sends the echo padded to
16,386 bytes of inner plaintext: the 0.18.0 client read `"echo:hello"`.

**Fix.** The inner plaintext's size is checked before the padding is
scanned: past 2^14 + 1 is `record_overflow`.

**Checks.** `padded-over` must be refused with `record_overflow`, and
`padded-max` - padded to exactly 2^14 + 1 - must still be read. Mutations
caught: "padding past 2^14 + 1 bytes of inner plaintext taken" and "the
inner plaintext's limit one byte short".

### 6. A record between the pieces of a handshake message (Low)

**What.** RFC 8446 section 5.1: when a handshake message is split across
records, no record of another type comes between its pieces. After the
handshake `read` gathered handshake bytes and went on returning application
data, or a close_notify, while half a message was held - at both ends, and
in TLS 1.2 too.

**Evidence.** The scripted server's `split-by-data` sends six bytes of a
NewSessionTicket, the echo, then the rest; `split-by-close` the six bytes
and close_notify. The 0.18.0 client read the echo from the first and ended
cleanly on the second.

**Fix.** Application data, close_notify or user_canceled with handshake
bytes held is `unexpected_message`; another alert still reports the peer's
alert.

**Checks.** Both scenarios must be refused for that reason. Mutations
caught: "application data taken inside a split handshake message",
"close_notify taken inside a split handshake message".

### 7. The `/dev/urandom` fallback opens a path (Low, open)

`Random::Secure.fill` on Linux reads `getrandom(2)` and falls back to
`/dev/urandom` only when the call answers `ENOSYS` - a kernel before 3.17,
or a seccomp filter that hides the call (`src/std/random.iyi`,
`from_device`). The fallback does not check that the file it opened is a
character device, as Crystal's `urandom.cr` does, so in a chroot or
container where both conditions hold and `/dev/urandom` is a file someone
else controls, keys and randoms would come from that file. Not fixed: no
check here can make `getrandom` answer `ENOSYS` on the machines the gates
run on, so a fix could not be held to a failing check, and it is left for
a change that can test it (a seccomp-filtered child process would).

### 8. Ed25519 public keys of small order (Informational)

`Ed25519PublicKey` decodes keys strictly (y < p, x = 0 with the sign bit
refused) and verification enforces S < L (`CurveScalar.canonical?`), but a
public key of small order is taken: with A the identity and the signature
R = identity, S = 0, `[S]B - [k]A` is the identity for every message. RFC
8032's verification does not refuse such keys, and the key must be
certified to matter in TLS. Left as it is.

### 9. Variable-time steps on blinded values in RSA signing (Informational)

`RsaPrivateKey#rsasp1` runs each CRT half through `pow_mod_secret` (fixed
4-bit windows, every table entry read and the wanted one selected by mask,
`src/std/big.iyi` `pow_fixed`, and a Montgomery reduction whose final
subtraction is masked, `reduce`). The steps around it are std/big's general
arithmetic and variable-time: `c % p` and `c % q` (Knuth's algorithm D), the
recombination `(qi * (s1 - s2)) % p` with its branch on the sign, and the
blinding factor's inverse by Euclid. Each runs on the blinded value
`m * r^e`, so its timing is over a value the attacker does not know; that is
the protection, and the code says so. The blinding factor is derived by
HMAC from the key and the message, so one message always has the same `r`;
in TLS the signed content holds both hellos' randoms and never repeats. A
fault check (`s^e == m` before the signature leaves) guards the CRT.

### 10-12. std/http (Informational)

- A redirect from `https://` to `http://` is followed (`redirected`, `open`
  in `src/std/http.iyi`), as Go's client and curl's `-L` follow one.
  `Authorization`, `Proxy-Authorization` and `Cookie` are not carried to
  another scheme (`same_authority?`), and `Secure` cookies go to `https://`
  alone; any other header a caller set, and a 307/308 body, go out in the
  clear.
- The pool's key is scheme, host and port (and the proxy). After
  `HTTP.tls_config=` changes the roots or the identity, a connection made
  under the old configuration is still reused for the same origin.
- The HTTPS server bounds the handshake by one deadline
  (`TlsServer.over(..., timeout_ms)`, every read cut to what is left of it),
  so a peer that sends a byte at a time is dropped; it has no cap on
  concurrent connections, and once the request head is read the body is
  bounded per read only.

### 13. DER laxness in signed data (Informational)

std/asn1 is strict where it matters to a parser - no trailing bytes, no
indefinite or non-minimal lengths, no lengths past the input, minimal
INTEGERs, BOOLEAN only 0x00 or 0xFF, BIT STRING padding checked, nesting
bounded, UTCTime and GeneralizedTime range-checked - but std/x509 takes
explicit DEFAULT values (`version` v1 written, `critical FALSE`, `cA FALSE`)
and a GeneralizedTime with fractional seconds, which RFC 5280 forbids. All
of it is inside what the issuer signed; none of it changes a verdict.

### 14. server_name as written (Informational)

`TlsClient` writes the host it is given into server_name as it is. A host
in Unicode goes as UTF-8, not as its A-labels, and a host with a final dot
keeps it, where RFC 6066 has neither; a server refuses or answers without
it, and the certificate is still checked for the host's A-labels (std/http
hands the client the URL's ASCII form). It fails closed.

## Checked and found sound

Each with where it holds.

### The handshake (`src/std/tls.iyi`)

- **Message order, client (TLS 1.3).** ServerHello, then under the
  handshake keys EncryptedExtensions, an optional CertificateRequest,
  Certificate, CertificateVerify, Finished, each type checked
  (`server_flight`); a plaintext handshake record after the ServerHello is
  refused (`next_record`); application data during the handshake is
  refused (`handshake_message`); nothing may follow the ServerHello or the
  Finished in its record (scenarios `sh-and-more`,
  `trailing-after-finished`).
- **Message order, server.** ClientHello, then the client's Certificate and
  CertificateVerify when asked, then Finished (`shake`,
  `client_certificate`); a ChangeCipherSpec before the ClientHello and more
  than 16 of them are refused (`pass_over_ccs`).
- **HelloRetryRequest.** Client: the suite must be offered and kept in the
  ServerHello, a second HelloRetryRequest is refused, one asking for the
  group already shared or one not offered is `illegal_parameter`, one that
  changes nothing is refused, the transcript restarts as `message_hash`
  (section 4.4.1), the session id echo is checked, and a TLS 1.2
  ServerHello after one is refused. Server: the second ClientHello must
  carry the share asked for, the same session id, the suite chosen and no
  early_data.
- **ServerHello.** Legacy version, session id echo, offered suite,
  compression, supported_versions naming 1.3 only, a cookie only in a
  HelloRetryRequest, duplicate and unoffered extensions refused; the share
  must be in the group sent and an X25519 share 32 bytes.
- **EncryptedExtensions, CertificateRequest, Certificate.** Unoffered
  extensions refused; server_name acknowledgement empty and only for a name
  sent; ALPN one protocol, offered; a CertificateRequest context empty in
  the handshake, signature_algorithms required; certificate entries with
  extensions refused; an empty server Certificate is `decode_error`; at
  most `X509::MAX_CHAIN` (10) certificates read.
- **CertificateVerify.** The context string by side, the transcript hash
  through Certificate, the scheme bound to the key (ECDSA curve and hash
  both, RSA-PSS rsae only, Ed25519), PKCS #1 v1.5 refused, keyUsage
  digitalSignature required when present.
- **Finished.** Compared with `Subtle.constant_time_compare`
  (`src/std/crypto.iyi`: every byte, one test at the end), before anything
  is written under the application keys.
- **KeyUpdate.** Length 1, request 0 or 1, the read keys moved at once and
  nothing more of the record's handshake bytes allowed after it (section
  5.1); a request answered before this side's next application data; this
  side's keys move at `key_limit` (2^23 records), and a TLS 1.2 connection
  stops writing there.
- **NewSessionTicket** from a client, and every other post-handshake
  message but KeyUpdate (and TLS 1.2's HelloRequest), refused.

### Transcript and key schedule

- The schedule (`TlsKeySchedule`) is held byte for byte to RFC 8448's
  simple 1-RTT trace, every secret through the exporter's, and mutations of
  the label prefix, the master secret's salt and the Finished key are
  caught in `bench/std_tls_exercise.sh`.
- Traffic secrets: handshake keys from the transcript through ServerHello;
  application keys and the exporter's from the transcript through the
  server's Finished; the client's Finished over its Certificate and
  CertificateVerify when sent; the server derives the same (`shake`).
- The exporter (section 7.5) and, in TLS 1.2, RFC 5705's over the extended
  master secret, each held to OpenSSL's.

### Records

- **Sequence numbers and nonces.** 64-bit per direction, reset with each
  new key, XORed into the IV's last eight bytes (section 5.3); a nonce
  never repeats under one key. TLS 1.2's AES-GCM explicit nonce is the
  sequence number going out (RFC 5288) and the record's coming in; its
  ChaCha20-Poly1305 nonce is RFC 7905's.
- **Limits.** A record past 2^14 + 256 bytes is `record_overflow` before
  it is read (`read_record`); a plaintext record past 2^14 likewise; the
  inner plaintext past 2^14 + 1 since finding 5.
- **Content type and padding.** The type is the last nonzero byte; all
  zeros is `unexpected_message`; an inner type the state does not allow is
  refused at each step.
- **Alerts.** Any alert but close_notify (and user_canceled after the
  handshake) ends the connection as an error; a plaintext alert is taken
  only during the handshake; an alert not two bytes is `decode_error`.
- **close_notify and truncation.** `read` answers `""` only for a
  close_notify; a TCP close without one is a `TlsError` ("closed the
  connection without close_notify"). std/http keeps that distinction: a
  body delimited by the connection's close is complete only on a clean
  end, and Content-Length and chunked bodies cut short are errors.

### TLS 1.2 client

- The extended master secret is required (RFC 7627), and the master secret
  is over the session hash through ClientKeyExchange.
- renegotiation_info is offered empty and, when answered, must be empty
  (RFC 5746 section 3.4); there is no renegotiation, and a HelloRequest is
  answered with a no_renegotiation warning.
- The downgrade sentinels DOWNGRD 01 and 00 in a TLS 1.2 ServerHello's
  random are refused, since this ClientHello always offers 1.3.
- ECDHE and AEAD suites only; the certificate's key must fit the suite; the
  ServerKeyExchange's signature is checked over both randoms and the
  parameters under an offered scheme; a ChangeCipherSpec before this
  side's Finished, or a second one, is refused (no early-CCS state).

### Certificate path validation (`src/std/x509.iyi`)

- basicConstraints cA required of every issuer, a CA refused as a leaf,
  pathLenConstraint counted over the CA certificates below, keyCertSign
  required when keyUsage is present, extKeyUsage for the purpose at every
  level that carries it, validity at every level, unknown critical
  extensions refused, the inner and outer signature algorithms equal, a
  duplicate extension refused, a chain search bounded by 100 signature
  checks - each held to Python's verifier over 200 fresh random chains and
  by the mutations in `bench/std_x509_exercise.sh`.
- Name constraints: DNS and IP constraints applied to the leaf's names,
  any other kind refusing the chain (fail closed), and since findings 1
  and 2 read as the host matcher reads names.
- Hosts: subjectAltName only, never the common name; a wildcard only as
  the whole leftmost label, for exactly one label, with at least two
  labels after it; IP addresses only against iPAddress entries, IPv4
  without leading zeros; a host in Unicode taken through IDNA to its
  A-labels.
- Signatures: SHA-1 refused; RSA PKCS #1 v1.5 checked by building the
  whole expected block and comparing it, never by parsing the decrypted
  one (`verify_pkcs1v15`); PSS by every step of EMSA-PSS-VERIFY with the
  salt length from its parameters; ECDSA r and s in [1, n - 1], the key's
  point on its curve and not compressed, the hash truncated as SEC 1 says;
  Ed25519 with S < L and the key's y < p.

### Constant time

- **X25519** (`src/std/curve25519.iyi`): clamping, a Montgomery ladder
  whose swap is a mask (`cswap`), field arithmetic with no branch on a
  limb, the all-zero shared secret refused after an OR over every byte.
- **Ed25519 signing**: RFC 8032's deterministic nonce, a fixed 64-window
  scalar multiplication whose table lookup reads all 16 entries, the scalar
  reduction a fixed 512 steps with a masked subtraction.
- **P-256** (`src/std/p256.iyi`): complete Renes-Costello-Batina formulas,
  fixed 4-bit windows with a lookup that reads every entry, Montgomery
  arithmetic with a masked final subtraction, inversion by Fermat (its
  branch on the public exponent only), RFC 6979 nonces taken only in
  [1, n - 1]; ECDH refuses a peer point off the curve, past p, or
  compressed, before the private key is used.
- **AES-GCM** (`src/std/aead.iyi`): bitsliced AES (BearSSL's `aes_ct64`),
  no lookup table; GHASH by masked integer multiplies (`ghash_ctmul64`),
  constant-time where the CPU's 64-bit multiply is; the tag compared over
  all 16 bytes before any plaintext is produced.
- **ChaCha20-Poly1305**: Poly1305's final reduction selected by mask, the
  tag compared as above, before decryption.
- **RSA**: see finding 9.
- What was not checked: that the compiler keeps those masks free of
  branches in the machine code it emits. That needs the emitted assembly
  read, and was not done.

### Parsing and limits

- Handshake messages at most 64 KiB, records read into a fixed inbox of two
  records' room, every TLS field read through `TlsReader`, which marks a
  read past the end rather than reading it; a ClientHello's extensions kept
  in sets, so 16,384 empty ones cost linear time; a handshake deadline that
  every socket wait is cut to (30 s by default); a refused server's linger
  bounded to 64 KiB and one second.
- std/asn1 as listed in finding 13; RSA moduli 1024 to 16384 bits and
  exponents 3 to 2^31 - 1, odd, so a peer's key bounds the work of a
  verification.

### Randomness

`Random::Secure` (`src/std/random.iyi`) is `getrandom(2)` with no flags on
Linux, which blocks only until the pool is first seeded and is retried on
EINTR and on a short read; `arc4random_buf` on macOS; `RtlGenRandom` on
Windows, its answer checked; WASI's `random_get`. Any other answer panics -
no bytes that only look random are returned. Every key, random and session
id in std/tls comes from it. See finding 7 for the one gap.

### std/http and std/smtp over TLS

The host the certificate is checked for, and sent as server_name, is the
URL's - through a CONNECT tunnel too, never the proxy's - and after a
redirect the new URL's; bytes a proxy or an SMTP server sends early after
its CONNECT or STARTTLS answer refuse the connection; HTTP/2 is spoken only
when ALPN chose it; a kept connection is reused only for its own scheme,
host and port.

## What this review did not do

- Read the machine code the compiler emits for the constant-time paths.
- Fuzz the parsers. The gates hold the code to other implementations and
  break it one rule at a time; they do not search for inputs.
- Look at platforms other than Linux x86_64, or at the TLS 1.2 server,
  session resumption and 0-RTT, which are being written on other branches
  as this is.
- Replace an audit: everything above is one automated reader's evidence.

## Gates run for this review

On Linux x86_64, with Python 3's cryptography 46.0.5 and OpenSSL 3.5.5:

- `bash bench/std_x509_exercise.sh`, after the last x509 commit: "the
  std/x509 exercise holds (33 breaks caught)" - 200 fresh chains as
  Python's verifier judges them, 7 as `openssl verify -auth_level 2` does.
- `bash bench/std_tls_exercise.sh`, after the last tls commit: "the
  std/tls exercise holds (127 breaks caught)", the scripted server's
  scenarios at "24 handshakes held and echoed, 43 refused, each for its
  reason".
- Before each fix, the input that shows it was run against the 0.18.0
  module, with the results quoted under each finding.

## References

- RFC 8446 sections 4.1.4, 4.4, 4.6.3, 5.1, 5.2, 5.4; RFC 5246; RFC 7627;
  RFC 5746; RFC 5280 sections 4.1 and 4.2.1.10; RFC 6125; RFC 8032.
- CVE-2025-61727, GO-2025-4175: <https://nvd.nist.gov/vuln/detail/CVE-2025-61727>,
  fixed in Go 1.25.5 and 1.24.11
  (<https://www.openwall.com/lists/oss-security/2025/12/05/3>).
