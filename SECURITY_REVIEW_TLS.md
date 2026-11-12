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
| 7 | Low | std/random | The `/dev/urandom` fallback does not check that it opened a character device | fixed since, `c33043e25` |
| 8 | Informational | std/curve25519 | Ed25519 verification takes a public key of small order | open, by design |
| 9 | Informational | std/rsa | CRT recombination, the reductions by p and q and the blinding inverse are variable-time, on blinded values | open, covered by blinding |
| 10 | Informational | std/http | A redirect from `https://` to `http://` is followed | open, policy |
| 11 | Informational | std/http | A kept connection is reused after `HTTP.tls_config=` changes the roots or identity | closed since by `TlsMadeUnder` (`9137b5396`); a `roots` array changed in place is still not seen |
| 12 | Informational | std/http | The HTTPS server has no cap on connections, and a slow request body is bounded per read only | open, outside TLS |
| 13 | Informational | std/x509 | DER laxness in signed data: explicit DEFAULT values, fractional seconds in a GeneralizedTime | open |
| 14 | Informational | std/tls | A host given to `TlsClient` in Unicode or with a final dot goes into server_name as written | open, fails closed |

This table is the first review's, at 0.18.0. A second one, at 0.21.0 and
over everything std/tls stands on and what stands on it, is at the end of
this file: it found what this one did not reach, and that two of the
bounds listed under "Checked and found sound" below did not hold.

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

### 7. The `/dev/urandom` fallback opens a path (Low, fixed since)

Fixed after this review, in `c33043e25`: the descriptor is `fstat`ed and
must be a character device. What follows is the finding as it was.

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

Since this review the blinding factor's inverse is std/big's constant-time
one (`8f5a117d7`, `be1c9b553`) and the windows are five bits. The second
review adds what this list left out: the blinding factor itself is reduced
and raised by the variable-time steps (its finding 37).

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
- **Closing.** `close` sends close_notify, shuts the socket's sending
  half, and reads past what the peer still sends - to its close_notify or
  the socket's end, while it comes within a second, for at most ten
  seconds and 64 MiB, so a peer cannot hold a close longer - before the
  socket closes; `abort` closes at once.
  Nothing is sent after this side's close_notify, an alert included, and
  in TLS 1.2 nothing is written after the peer's (RFC 5246 section
  7.2.1).

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
  by the mutations in `bench/std_x509_exercise.sh`. (The 100 bounded the
  candidates and not the work: the second review's finding 2.)
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
  verification. (It bounded one verification, at 3 ms for 16384 bits, and
  a chain asks for a hundred: the second review's finding 2, since which
  a chain's keys stop at 8192 bits.)

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

## A second review, at 0.21.0

**This too is an automated review, not an audit**: AI coding agents again,
eleven readers with a part each and one that checked and joined what they
found, and nobody independent of the code. It was made at `140375a3b`
(0.21.0), three releases after the first, and it is wider: std/tls with
what the first review could not reach because it was being written -
resumption, 0-RTT, Encrypted Client Hello, the TLS 1.2 server - every
primitive under it, the modules that use them (std/http, std/cookie,
std/password, std/otp, std/acme, std/autocert, std/smtp, std/secure_dns,
std/websocket), the machine code the compiler makes of the constant-time
paths, and what a release is built from: `install.sh`, the workflows,
`iyi.sum` and the `.iyimod` reader.

### Method

Each reader read its part whole against its RFCs and FIPS documents and
against the first review, then ran what it suspected: a hostile peer written
over Python's sockets, a chain made by OpenSSL or Python's cryptography, a
crafted file, two endpoints in one program. A finding below is marked
*shown* when the program that shows it was run and its output read, and
*read* when it rests on the code alone. The primitives were held to other
implementations rather than read alone:

| What | Against | Cases | Wrong |
|---|---|---|---|
| AES-GCM, ChaCha20-Poly1305, the digests, SHAKE, HMAC, HKDF, PBKDF2 | Wycheproof, Python's hashlib, cryptography 50.0.2; four seeds | about 196,000 | 0 |
| std/big's division, Montgomery products and inverse | Python's integers | 247,891 | 0 |
| RSA verification, the forgeries of Bleichenbacher's 2006 kind among them | an RFC 8017 verifier written for it | 1,657 | 0 |
| ECDSA on P-256, P-384 and P-521, ECDH, X25519, Ed25519 | Wycheproof | 4,971 | 0 |
| Field, scalar and point arithmetic of the curves | Python's integers | 164,746 | 0, but two inputs outside a function's contract |
| RFC 6979 signatures, public keys, ECDH | OpenSSL and pycryptodome, byte for byte | 7,670 | 0 |
| ECDSA verification at Q = G, -G, 2G and small nonces | OpenSSL | 6,804 | 0 |
| ML-KEM-768 | Go's accumulated vector at 1,000,000 rounds; C2SP's 780 bad keys; NIST's ACVP | - | 0 |
| HPKE | RFC 9180's vectors, 12,336 encryptions | 64 suites | 0 |
| The TLS 1.3 client's state machine | 15 flights out of order | 15 | each refused by its alert |
| Record framing | 21 probes | 21 | each as it should be |
| OCSP responses, read and checked | mutation | 3,000,000 | no panic |

The first review said it had not read the machine code of the constant-time
paths. This one did, for `--release` builds on x86-64 and for aarch64 by
cross-compiling: `Subtle.constant_time_compare` at each of std/tls's seven
uses, the AEADs' tag compare, X25519's swap and field, Ed25519's and the
NIST curves' table lookups, the bitsliced AES, GHASH, Poly1305's last
reduction, std/big's `pow_fixed`, `reduce` and `inverse_mod_secret`, and
ML-KEM's compare and `Compress` have no branch on a secret and no `div` of
one; `bench/ct_timing.sh` ran on Windows with every secret path's |t| at 10
or under and its leaking control at 259. Findings 16 to 19 are where the
machine code did not keep what the source says.

### Findings

Severity as the first review's: High is a way past authentication that
needs a condition one can expect to meet; Medium, a way past a check under
narrower ones, or a peer's cheap way to stop a program; Low, a rule not
held with no known way to use it, or hardening; Informational, a choice.
Every High, Medium and Low was fixed on the branch `security-review`, each
with a check that fails on the code before it and, where the module's gate
breaks copies of it, a broken copy the gate must catch. The branch was then
read again, part by part, by six readers who had not written it: what they
found is in the second commit named beside a finding.

| # | Severity | Where | Finding | Shown | State |
|---|---|---|---|---|---|
| 1 | High | std/tls | A server resumed any ticket its keys opened, whatever was asked of a client where the ticket was sealed: one from a listener that asks for no certificate resumed on one whose `client_roots` require one (`dup` and every `frozen` copy share ticket keys), a chain checked under other roots or past its notAfter was the peer's, and `client_roots` set in place did not reach tickets already out. The class of Go's CVE-2025-68121 | shown | fixed, `2b05943b0` |
| 2 | Medium | std/x509 | A chain search was bounded by its candidates (100) and not by their cost: each was held to its name constraints, every name by every constraint, before its signature. One 65 KB Certificate message, signed by the sender's own key, took 9.3 s to refuse - at any client, and at a server that asks for a client's certificate, before either peer is known (`openssl verify`: 64 ms). A chain of 16384-bit RSA keys cost 330 ms | shown | fixed, `860f9aba6` |
| 3 | Medium | std/system_roots | On Windows a root's purposes are a property beside the certificate, which was not read: 8 of one machine's 29 roots were for code signing, time stamping or mail, four of them valid CAs, and all were a TLS client's | shown | fixed, `75540b9f4` |
| 4 | Medium | std/cookie | An `http://` answer replaced a `Secure` cookie of the same name, removed it with `Max-Age=0`, or set a longer path's beside it; the header said it could not | shown | fixed, `36be36443` |
| 5 | Medium | std/http | `HTTP.upgrade`, and so `wss://`, handshook under a configuration of its own without `require_staple` and `ech_configs` | shown | fixed, `fb78ceb85` |
| 6 | Medium | std/password | `Bcrypt` stopped at a NUL in an `Array(UInt8)` too, so a digest given to it is the empty password one time in 256 | shown | fixed, `bcd0c4684` |
| 7 | Medium | `iyi.sum` | The tree hash had no lengths, and a file may hold the zero byte that ended one: a tag moved to a tree whose bytes crossed a file's edge built under the line the first tree wrote. (And it was SHA-1.) | shown | fixed, `b4ebefaf2`, `4e795f909`; `7def2192f`, `5863467e3` and `4d1c3674f` for the cache, an unwritable file and a link |
| 8 | Medium | workflows | The jobs that build a release's archives used actions by tags a publisher can move (89 `uses:`), and Crystal, CMake, LLVM's source and `make` unchecked; SHA256SUMS is made after the build | read | fixed, `5dcab2159`, but for the Crystal that builds the Windows zip and darwin's, which the action and Homebrew fetch unhashed; unrun until CI runs it |
| 9 | Medium | workflows | The VS Code job's registry tokens were in every step's environment, beside an `npx --yes` of whatever the registry answered, on every pull request | read | fixed, `3bee42788`; unrun until CI runs it |
| 10 | Low | std/tls | A socket closed under a connection whose early data was taken was a panic at `read_early` and `read` | shown | fixed, `ad201ebea` |
| 11 | Low | std/tls | Records that carry nothing - empty application data, user_canceled, KeyUpdate, tickets - were passed over without end; 3.3 to 4.3 MB/s of KeyUpdates held a core | shown | fixed, `03e7e3c55`, and `8bf379a91` for early data |
| 12 | Low | std/tls | The client looked for a repeated extension in an array: 44 ms for one 64 KiB NewSessionTicket | shown | fixed, `586c81fa8` |
| 13 | Low | std/tls | Early data a server passed over is sent again and read by `read`, which the header called never a replay; with a copy of the ClientHello taken first the server has it twice and could not tell | shown | fixed, `93940d9cf`: `early_declined?` |
| 14 | Low | std/system_roots, std/x509 | The Windows Disallowed store took roots out and did nothing for an intermediate in it | read; the fix shown | fixed, `82f6f19a3`, `e53db0367`, `c8f8aac94` |
| 15 | Low | std/x509 | An IPv4 name constraint did not judge an IPv4-mapped IPv6 address (nor does OpenSSL's) | shown | fixed, `752402b0c`, `7cedec42b` |
| 16 | Low | std/mlkem | Decapsulation's choice between K and the implicit-rejection key, masks in the source, was a `cmov` of a pointer and a load in the machine code: which buffer is read says whether the ciphertext held. std/tls makes a key for each handshake and is not reached; a kept key is | shown (assembly) | fixed, `aacb73b3e`: std/digest's `ValueBarrier` |
| 17 | Low | std/p256 | The barrier the fixed-base lookup read its selector through was folded away by every `--release` build, and the lookup was free of branches by the optimiser's choice alone | shown (IR) | fixed, `70a2e23a3`, for P-384's and Curve25519's lookups and X25519's swap too |
| 18 | Low | std/big | In a build without `--release` the Montgomery products' carries branch on secret limbs | shown (assembly) | fixed, `6eac7c8e8` |
| 19 | Low | std/base64 | A private key's PEM, read and written, indexed tables by its bytes and branched on them (the Util::Lookup class) | shown (assembly) | fixed, `8a84f9f59`, `ccad03c87`, `48f393c4c` |
| 20 | Low | std/p256, std/curve25519, std/ecdsa, std/digest, std/password | Tables built at first use were published by a plain store; on a machine that reorders stores a second thread may read one half written, and a deterministic signature made with it and its repeat give the key | read | fixed, `c011d3995`, and `3ebe84b83` for bcrypt's table: constants where they can be, an atomic address where not |
| 21 | Low | std/rsa | A signature that failed its check was a panic, and a key whose p is not prime passed every check at reading: the first handshake ended the process | shown | fixed, `b0424223a`, `b71a18c62` |
| 22 | Low | std/smtp | A CRAM-MD5 challenge that is not base64 was a panic | shown | fixed, `c73a11483` |
| 23 | Low | std/password | `Bcrypt` cut a password at 72 bytes | shown | fixed, `87c95c35d` |
| 24 | Low | std/password | `Bcrypt.verify` did the work of whatever cost a stored hash named, to 31 | shown | fixed, `db277ef00` |
| 25 | Low | std/otp | `TOTP.verify` said yes or no, so the caller's "once" (RFC 6238 section 5.2) could not be kept | shown | fixed, `9443b4756` |
| 26 | Low | std/cookie | `__Host-` and `__Secure-` were names like any other to a jar | shown | fixed, `4718ec7a3` |
| 27 | Low | std/cookie | `to_set_cookie` wrote a `Path`, `Domain` or `SameSite` as given, a `;` and what follows it too | shown | fixed, `283241a29` |
| 28 | Low | std/autocert | On Windows the cache's private keys took the access list of the directory above them | shown | fixed, `06ad424fe`, `a7cd2b2fc` |
| 29 | Low | std/otp | A secret of one byte was taken, and a label's control and bidirectional characters read | shown | fixed, `7e0dd407c`, `3ebe84b83` |
| 30 | Low | `.iyimod` reader | Every count in an artifact was allocated as read: 16 bytes asked for 32 GiB. No read past a buffer was found in 430 mutated files | shown | fixed, `ff6bd7832`, and `da744a9cf` for counts that nest |
| 31 | Low | `install.sh` | A SHA256SUMS that could not be fetched was a note and an install | shown | fixed, `28339c03f` |
| 32 | Low | workflows | A release carried no signature or provenance | read | fixed, `9f31d26fe`; unrun until CI runs it |
| 33 | Informational | std/tls | The client takes a server's acceptance of early data without holding ALPN and the suite to the ticket's (the server is held to it) | read | open |
| 34 | Informational | std/tls | After a resumption under `identity_source`, `TlsServer#identity` is the configuration's own | read | open |
| 35 | Informational | std/tls | `fail` writes its alert from the reading task, where a task writing beside it owns the socket's writes | read | open |
| 36 | Informational | std/tls | `export_keying_material` panics for a label of 250 bytes | shown | open |
| 37 | Informational | std/rsa | The blinding factor is itself reduced and raised by variable-time steps | read | open |
| 38 | Informational | std/tls | A ChangeCipherSpec is passed over between a handshake message's pieces; an alert's level is not read | shown | open |
| 39 | Informational | std/tls | With early data taken, the wait for the client's Finished is bounded by the socket's read timeout alone | read | open |
| 40 | Informational | std/ocsp | Any certificate the CA gave OCSPSigning answers for all of the CA's, itself included (RFC 6960 has it so) | shown | open |
| 41 | Informational | std/system_roots | A root Windows has not yet fetched into its store is not there to read - a chain to it is refused, where Windows would fetch it - and std/tls keeps the roots for the process | shown | open, fails closed |
| 42 | Informational | std/p256, std/p384, std/curve25519 | Signing is deterministic and a signature is not checked before it leaves, as RSA's is | read | open |
| 43 | Informational | std/curve25519 | Ed25519 is verified without the cofactor, as OpenSSL verifies it (the first review's finding 8, further) | shown | open |
| 44 | Informational | std/ecdsa | (r, s) and (r, n - s) both verify | shown | open |
| 45 | Informational | std/big | `pow_mod_secret` shows the exponent's length in bits, which its comment said it did not | shown | the comment says so now, `10e3adfcc` |
| 46 | Informational | std/otp | A code's digits were written in as many steps as the number has digits | shown | fixed, `5a32503f4` |
| 47 | Informational | std/mlkem, std/hpke | No secret is wiped | read | open |
| 48 | Informational | std/base64 | `decode` reads `QQ==` and `QR==` alike, and the two alphabets mixed | shown | said in the header, `f99b17ebb`; `decode_secret` is strict |
| 49 | Informational | std/http | A multipart boundary is a hash of the form's content, and goes in a header | read | open |
| 50 | Informational | std/cookie | No public-suffix list | shown | open, as the header says |
| 51 | Informational | `.iyimod` | An artifact is code, and what says it is current is its own word | read | said in SPEC.md IV.2a and SECURITY.md |
| 52 | Informational | `iyi.sum` | The first fetch is trusted; there is no log to hold it to | read | open, as SPEC.md III.7 says |
| 53 | Informational | std/rsa | `verify_pss` overflowed for a salt length near 2^31; no caller reaches it | shown | fixed, `b261cf8ca` |
| 54 | Informational | std/big | `pow_fixed`, `reduce` and `inverse_mod_secret` hide their masks by xoring a zero read through an atomic field, the idiom finding 17 retired in std/p256; in this compiler's `--release` IR the load and the xor are there, and no gate reads that machine code | read (the IR shown) | open |

What each fix holds, and by what check, is in its commit and in the
module's header and gate; the changelog says what a program sees of them.
Findings 16 to 18 and 20 change no answer, so no check of an answer can
fail on the code before them: their checks read the `--release` assembly
and the LLVM IR the gates emit for x86_64 and aarch64 - a value barrier
before each pick, both operands loaded, an ordered load and store of each
table's address - and a broken copy must be refused there.

### What changed for the first review's claims

- Its findings 7 and 11 are closed and 9 is narrower, as marked above; 10
  (a redirect from `https://` to `http://` is followed) and 12 to 14 stand
  as they were.
- "A chain search bounded by 100 signature checks" and "a peer's key bounds
  the work of a verification" were bounds on a count and on one
  verification: finding 2.
- "DNS and IP constraints applied to the leaf's names" left out an
  IPv4-mapped address: finding 15.
- "No bytes that only look random are returned", the constant-time list
  and everything else under "Checked and found sound" were found as
  written, in the machine code too, but for findings 16 to 18.

### What this review did not do

- Run anything on Linux, darwin or an aarch64 machine: their paths were
  read, typechecked and cross-compiled. Finding 20 can only show on a
  machine that reorders stores.
- Show findings 16 and 19 by a cache measurement; the assembly is the
  evidence.
- Fuzz the parsers, beyond std/ocsp and the `.iyimod` reader.
- Hold the HTTP/2 client to a hostile server, or std/acme to a CA other
  than the gate's Pebble.
- Stage a certificate in a machine's Disallowed store for finding 14: the
  fix was shown instead with the store's answer changed in a copy of
  std/system_roots, a live server's intermediate in it.
- Run the workflows: findings 8, 9 and 32 are fixed as read.
- Look at a repository's settings - who may push a tag, what protects a
  branch - which are not in the tree.
- Replace an audit.

### Gates run for the second review

On Windows 11, x86_64 - the one machine there was - with Python 3.12's
cryptography 50.0.2 and OpenSSL 3.5, each whole, on the branch with every
fix in it unless said:

- `bash bench/std_tls_exercise.sh`: "the std/tls exercise holds (344
  breaks caught)", the scripted server's scenarios at "34 handshakes held
  and echoed, 54 refused, each for its reason" and "11 resumptions and
  ticket scenarios".
- `bash bench/std_http_exercise.sh`: "the std/http exercise holds".
- `bash bench/std_x509_exercise.sh`: "holds (51 breaks caught)", and
  `std_rsa_exercise.sh`: "holds (36 breaks caught)" - both before the
  constant-time fixes were joined to the branch, their exercises again
  after.
- `std_acme_exercise.sh`: "holds (18 breaks caught)";
  `std_autocert_exercise.sh`, with Pebble: "holds (17 of 18 breaks
  caught, the rest unmeasured here" - the one that reads POSIX modes;
  `std_smtp_exercise.sh`: "holds".
- `std_p256_exercise.sh`: "holds (27 breaks caught)";
  `std_digest_exercise.sh`: "holds"; `std_big_exercise.sh`: "ALL CHECKS
  PASSED".
- On each fix's own branch before it was joined: std/cookie's gate (32
  breaks caught), std/password's and std/otp's, std/system_roots' (15),
  std/base64's, std/ecdsa's (22), std/p384's (23), std/curve25519's and
  std/mlkem's, and the package gates `packages_resolve.sh` and
  `packages_get.sh` with a compiler built from the branch.
- `bash bench/ct_timing.sh`: its reading of the machine code holds for
  x86_64 and aarch64, and of its ten timings of secret paths nine stay
  under 10 (the largest 6.61) with the leaking control at 257.81. The
  tenth, mlkem-key - one key's decapsulation against 64 others' - did not, at
  15.56, and does not on this machine for the 0.21.0 module either: five
  runs of each in turn gave 7.11, 15.56, 16.33, 14.01 and 16.79 for
  0.21.0's and 19.3, 13.94, 13.2, 14.47 and 19.69 for the branch's. This
  review's own first run of it, before any fix, measured 8.31 there. What it times is
  one key that is always in the cache against 64 that are not; it is
  open, and is not a finding of either review until somebody tells the
  two apart.

## References

- RFC 8446 sections 4.1.4, 4.4, 4.6.3, 5.1, 5.2, 5.4; RFC 5246; RFC 7627;
  RFC 5746; RFC 5280 sections 4.1 and 4.2.1.10; RFC 6125; RFC 8032.
- CVE-2025-61727, GO-2025-4175: <https://nvd.nist.gov/vuln/detail/CVE-2025-61727>,
  fixed in Go 1.25.5 and 1.24.11
  (<https://www.openwall.com/lists/oss-security/2025/12/05/3>).
