# Reporting a Vulnerability

This is a pre-release fork of [Crystal](https://github.com/crystal-lang/crystal)
and it has no users to protect yet. It is not built for production and the
README says so.

**If the issue is in Crystal**, which is most of this code, report it to
Crystal: <security@manas.tech>. That is their mailbox and their process, and it
reaches everybody the bug actually affects.

**If the issue is in what this fork added** — the `.iyimod` artifact reader, the
import path and `iyi.sum`, the rules in [SPEC.md](SPEC.md), and the standard
library written in iyi under `src/std`, which holds its own TLS (`std/tls`),
certificate checking (`std/x509`, `std/ocsp`, `std/system_roots`) and every
primitive under them (`std/aead`, `std/digest`, `std/crypto`, `std/big`,
`std/rsa`, `std/ecdsa`, `std/p256`, `std/p384`, `std/curve25519`,
`std/mlkem`, `std/hpke`, `std/asn1`, `std/random`), with no OpenSSL beneath — open a private security
advisory on this repository, or an ordinary issue if it is not sensitive.

None of that cryptography has been audited, and it is not to be called secure
until it is. What has been done is two automated reviews by AI coding agents,
each reproducing what it suspected and fixing what it reproduced:
[SECURITY_REVIEW_TLS.md](SECURITY_REVIEW_TLS.md) holds what they looked at,
what they found and what they left open, as evidence for whoever audits it.

Two places parse what a program did not write itself and are the interesting
cases: the `.iyimod` reader, which is handed a file — and an artifact is code,
linked and compiled as source is, so a hostile one is to be trusted no more
than hostile source — and `std/tls` with `std/x509`, which are handed a peer's
bytes.
