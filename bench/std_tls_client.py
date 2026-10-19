"""A TLS 1.3 client that breaks the protocol one rule at a time, for the
server section of bench/std_tls_exercise.sh.

    python3 bench/std_tls_client.py PORT ROOTS_PEM [--p256 | --rsa] [--mtls DIR] [SCENARIO ...]

Connects to the exercise's `serve` mode once per scenario (every one in
SCENARIOS when none is named) and says, one line each, whether the server
answered as it must: `<name>: ok ...`, or `FAIL <name>: ...`. `--p256`
says the server's key is P-256, `--rsa` that it is RSA, not Ed25519: what
a client that leaves out one scheme or another is owed turns on that.
`--mtls DIR` says the server asks for a client's certificate: the MTLS
scenarios run instead, presenting the chains and keys in DIR (client,
client-ed, client-rsa, other, server-only: .pem and .key each) or
breaking a rule of the answer. A correct handshake is
checked here, not taken on trust: the server's certificate against the
root, its CertificateVerify with Python's own Ed25519, ECDSA or RSA-PSS
(under the first RSA-PSS scheme this side offered), its
Finished against the transcript as this side has it, and then a request
answered and closed with close_notify. A broken one must end in the alert
RFC 8446 names, in the clear before the server's keys and under them
after.

The key schedule, records and messages are bench/std_tls_server.py's.
Written for this one purpose; not a TLS client for anything else.
"""
import os
import socket
import struct
import sys
import time

sys.dont_write_bytecode = True  # the gate leaves bench/ as it found it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from std_tls_server import Cipher, Schedule, ext, message, plain  # noqa: E402

from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa, x25519  # noqa: E402

HELLO_RETRY = bytes.fromhex("cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c")
SUITE_NAMES = {0x1301: "TLS_AES_128_GCM_SHA256", 0x1302: "TLS_AES_256_GCM_SHA384", 0x1303: "TLS_CHACHA20_POLY1305_SHA256"}
# rsa_pss_rsae_sha256, -384 and -512, by the hash each names.
PSS = {0x0804: hashes.SHA256, 0x0805: hashes.SHA384, 0x0806: hashes.SHA512}
SIGALGS = (0x0807, 0x0403, 0x0804)

# name: (what the scenario sends, what the server must answer)
#   ("held", text)  the handshake holds and the answer holds text
#   ("alert", code) the server ends it with that alert
# or, where the server's key decides, {"ed25519": answer, "p256": answer}.
SCENARIOS = {
    "ok": ("a correct handshake, AES-128-GCM", ("held", "TLS_AES_128_GCM_SHA256")),
    "aes256": ("TLS_AES_256_GCM_SHA384 alone", ("held", "TLS_AES_256_GCM_SHA384")),
    "chacha": ("TLS_CHACHA20_POLY1305_SHA256 alone", ("held", "TLS_CHACHA20_POLY1305_SHA256")),
    "client-order": ("ChaCha20 offered before AES-128: the client's order", ("held", "TLS_CHACHA20_POLY1305_SHA256")),
    "alpn": ("ALPN http/1.1", ("held", "alpn=http/1.1")),
    "alpn-order": ("ALPN http/1.1 then h2: the server's order", ("held", "alpn=h2")),
    "no-sni": ("no server_name", ("held", "name=-")),
    "hrr": ("a P-384 share alone: a HelloRetryRequest for X25519", ("held", "TLS_AES_128_GCM_SHA256")),
    "p256-share": ("secp256r1 alone, a P-256 share", ("held", "TLS_AES_128_GCM_SHA256")),
    "both-shares": ("P-256 and X25519 shares: X25519 taken", ("held", "TLS_AES_128_GCM_SHA256")),
    "hrr-p256": ("P-384 and secp256r1, a P-384 share: a HelloRetryRequest for secp256r1", ("held", "TLS_AES_128_GCM_SHA256")),
    "bad-p256-share": ("a P-256 share off the curve", ("alert", 47)),
    "short-p256-share": ("a P-256 share of 64 bytes", ("alert", 47)),
    "ccs": ("a ChangeCipherSpec before the client's Finished", ("held", "name=localhost")),
    "early-skip": ("early data the server passes over", ("held", "name=localhost")),
    "early-after-hrr": ("early data before the second ClientHello", ("held", "name=localhost")),
    "keyupdate": ("a KeyUpdate asking for one back", ("held", "echo:ping")),
    "bad-finished": ("the client's Finished one bit off", ("alert", 51)),
    "cert-instead-of-finished": ("a Certificate where the client's Finished belongs", ("alert", 10)),
    "data-before-finished": ("application data before the client's Finished", ("alert", 10)),
    "bad-record-mac": ("the client's Finished record one bit off", ("alert", 20)),
    "dup-ext": ("supported_groups twice", ("alert", 47)),
    "psk-not-last": ("pre_shared_key before another extension", ("alert", 47)),
    "compression": ("a compression method beside null", ("alert", 47)),
    "long-session": ("a session id of 33 bytes", ("alert", 47)),
    "zero-share": ("an X25519 share of small order", ("alert", 47)),
    "share-not-in-groups": ("a share for a group not in supported_groups", ("alert", 47)),
    "short-share": ("an X25519 share of 31 bytes", ("alert", 47)),
    "no-key-share": ("supported_groups without key_share", ("alert", 109)),
    "no-groups": ("key_share without supported_groups", ("alert", 109)),
    "no-sigalgs": ("no signature_algorithms", ("alert", 109)),
    "no-ed25519": ("signature_algorithms without ed25519",
                   {"ed25519": ("alert", 40), "p256": ("held", "name=localhost"), "rsa": ("held", "name=localhost")}),
    "no-p256": ("signature_algorithms without ecdsa_secp256r1_sha256",
                {"ed25519": ("held", "name=localhost"), "p256": ("alert", 40), "rsa": ("held", "name=localhost")}),
    # An RSA key signs under the first RSA-PSS scheme the client lists, and
    # never under PKCS #1 v1.5 (RFC 8446 section 4.2.3).
    "pss-sha384": ("rsa_pss_rsae_sha384 listed before rsa_pss_rsae_sha256", ("held", "name=localhost")),
    "pss-sha512": ("rsa_pss_rsae_sha512 listed first", ("held", "name=localhost")),
    "no-rsa-pss": ("PKCS #1 v1.5, ed25519 and ecdsa_secp256r1_sha256, no RSA-PSS",
                   {"ed25519": ("held", "name=localhost"), "p256": ("held", "name=localhost"), "rsa": ("alert", 40)}),
    "no-group": ("groups without X25519 or secp256r1", ("alert", 40)),
    # A ClientHello of 60 KB, a byte to a record: what the server does with
    # it must grow with what was sent, not with its square.
    # 0.05 s here; 3.2 s when each record copied the message so far.
    "byte-records": ("a 60 KB ClientHello a byte to a record, answered within 1.5 s", ("held", "TLS_AES_128_GCM_SHA256")),
    "ccs-flood": ("seventeen ChangeCipherSpec records after the ClientHello", ("alert", 10)),
    "ccs-first": ("a ChangeCipherSpec before the ClientHello", ("alert", 10)),
    "hello-and-more": ("a Finished in the ClientHello's record", ("alert", 10)),
    # A byte every half second: the server, given 5 s for a handshake,
    # hangs up within 8, where a bound on each wait alone held on.
    "slow-hello": ("a ClientHello a byte every half second", ("ended", 8)),
    "tls12": ("supported_versions TLS 1.2 alone", ("alert", 70)),
    "no-versions": ("no supported_versions: TLS 1.2", ("alert", 70)),
    "no-suite": ("TLS_AES_128_CCM_SHA256 alone", ("alert", 40)),
    "alpn-mismatch": ("ALPN spdy/3 alone", ("alert", 120)),
    "alpn-empty-name": ("an ALPN list holding an empty name", ("alert", 50)),
    "hrr-no-share": ("a second ClientHello still without X25519", ("alert", 47)),
    "hrr-other-session": ("a second ClientHello with another session id", ("alert", 47)),
    "hrr-other-suite": ("a second ClientHello without the suite the HelloRetryRequest chose", ("alert", 47)),
    "hrr-early-again": ("a second ClientHello offering early data", ("alert", 47)),
    # Early data is over at the second ClientHello: a record that does not
    # open is refused after it, where it was passed over.
    "junk-after-hrr": ("a record that does not decrypt, after the second ClientHello", ("alert", 20)),
    # Only a record that does not decrypt is passed over as early data: one
    # under the handshake keys with no content type is refused.
    "early-malformed": ("early data offered, then a handshake record with no content type", ("alert", 10)),
    "sni-two": ("a server_name with two host names", ("alert", 47)),
    # Two identities: the one whose certificate names the host asked for,
    # and the default for any other.
    "sni-other": ("a server_name of other.test: its own certificate", ("held", "shown=CN=other.test")),
    "sni-unknown": ("a server_name no certificate names: the default", ("held", "shown=CN=localhost")),
    "sni-bad": ("a server_name that is no host name", ("alert", 50)),
    "oversize": ("a plaintext record past 2^14 bytes", ("alert", 22)),
    "not-hello": ("a ServerHello where the ClientHello belongs", ("alert", 10)),
    "cut-hello": ("a ClientHello whose extensions run past its end", ("alert", 50)),
    # Resumption (RFC 8446 section 2.2): a first connection keeps the two
    # tickets it is sent; a second offers one as the scenario says. The
    # server's answer says whether it resumed, and so does this side, which
    # resumes only on a ServerHello taking an identity it offered and then
    # checks the server's Finished under that PSK's keys.
    "resume": ("a ticket of the first connection, its binder right", ("held", ("resumed=yes scripted-resumed=yes", "shown=CN=localhost"))),
    "resume-hrr": ("a ticket offered again after a HelloRetryRequest, the binder over it", ("held", "resumed=yes scripted-resumed=yes")),
    "resume-second": ("a ticket no server issued, then the first connection's: the second taken", ("held", "resumed=yes scripted-resumed=yes")),
    "resume-alpn": ("a ticket of a connection on http/1.1, offering h2 now: taken, h2 chosen afresh",
                    ("held", ("alpn=h2", "resumed=yes scripted-resumed=yes"))),
    "resume-no-sigalgs": ("a ticket and no signature_algorithms, which a PSK lets a client leave out", ("held", "resumed=yes scripted-resumed=yes")),
    "resume-bad-binder": ("a ticket whose binder is one bit off", ("alert", 51)),
    "resume-expired": ("a ticket whose age the client gives past its lifetime: a full handshake", ("held", "resumed=no scripted-resumed=no")),
    "resume-expired-no-sigalgs": ("that, and no signature_algorithms: nothing left to authenticate by", ("alert", 109)),
    "resume-other-hash": ("a TLS_AES_128_GCM_SHA256 ticket with TLS_AES_256_GCM_SHA384 alone: a full handshake",
                          ("held", ("TLS_AES_256_GCM_SHA384", "resumed=no scripted-resumed=no"))),
    "resume-psk-ke": ("a ticket offered for psk_ke alone: a full handshake", ("held", "resumed=no scripted-resumed=no")),
    "resume-other-sni": ("localhost's ticket offered for other.test: a full handshake, other.test's certificate",
                         ("held", ("shown=CN=other.test", "resumed=no scripted-resumed=no"))),
    "resume-tampered": ("a ticket one bit off: a full handshake", ("held", "resumed=no scripted-resumed=no")),
    "resume-no-modes": ("a ticket and no psk_key_exchange_modes", ("alert", 109)),
    "resume-binders": ("two identities and one binder", ("alert", 47)),
    "resume-not-last": ("a ticket whose pre_shared_key is not the last extension", ("alert", 47)),
    # Early data (0-RTT) under a ticket of the first connection, which
    # allows 16 KiB. Taken: EncryptedExtensions says so, EndOfEarlyData goes
    # under the early keys, and the server's answer names what came early;
    # refused: the handshake goes on, nothing early named.
    "early-ok": ("early data under the ticket", ("held", ('early="early:ping"', "resumed=yes scripted-resumed=yes"))),
    "early-request": ("a request as early data, answered before this side's Finished (0.5-RTT)",
                      ("held", ('early="GET / HTTP/1.0\\r\\n\\r\\n"', "resumed=yes"))),
    "early-replay": ("the ClientHello and early data of a connection whose early data was taken, sent again: refused",
                     ("held", ('early=""', "resumed=yes scripted-resumed=yes"))),
    "early-too-much": ("16,385 bytes early, past the 16,384 the ticket allows", ("alert", 10)),
    "early-bad-record": ("an early record one bit off, after the server took early data", ("alert", 20)),
    "early-finished-early": ("Finished under the early keys where EndOfEarlyData belongs", ("alert", 10)),
    "early-stale": ("early data with a ticket age 20 s off the server's count: refused", ("held", ('early=""', "resumed=yes"))),
    "early-alpn": ("early data under an http/1.1 ticket, h2 chosen now: refused", ("held", ('early=""', "alpn=h2", "resumed=yes"))),
    "early-suite": ("early data under an AES-128-GCM ticket, ChaCha20-Poly1305 chosen now: refused",
                    ("held", ('early=""', "TLS_CHACHA20_POLY1305_SHA256", "resumed=yes"))),
    "early-second": ("early data with the ticket second among the identities: resumed, early data refused", ("held", ('early=""', "resumed=yes"))),
    "early-hrr": ("early data, then a HelloRetryRequest: refused", ("held", ('early=""', "resumed=yes"))),
}


# The scenarios against a server that asks for a client's certificate.
MTLS = {
    "mtls-ok": ("a P-256 client certificate and its CertificateVerify", ("held", "peer=CN=client")),
    "mtls-ed25519": ("an Ed25519 client certificate", ("held", "peer=CN=client ed")),
    "mtls-rsa": ("an RSA client certificate, its CertificateVerify under rsa_pss_rsae_sha256", ("held", "peer=CN=client rsa")),
    "mtls-none": ("no client certificate", ("alert", 116)),
    "mtls-bad-cv": ("the client's CertificateVerify one bit off", ("alert", 51)),
    "mtls-no-cv": ("a client Certificate with no CertificateVerify", ("alert", 10)),
    "mtls-context": ("a client Certificate with a request context", ("alert", 47)),
    # The rest of the flight sent after the refusal: a server that closes
    # with it unread resets the connection, and this send breaks.
    "mtls-late": ("a refused client Certificate, the rest of the flight after a pause", ("alert", 47)),
    "mtls-wrong-scheme": ("a CertificateVerify under a scheme not the key's", ("alert", 47)),
    "mtls-untrusted": ("a client certificate from another root", ("alert", 42)),
    "mtls-server-only": ("a client certificate for serverAuth only", ("alert", 42)),
    "mtls-long-chain": ("a client Certificate of twelve certificates", ("alert", 42)),
    "mtls-entry-ext": ("a client certificate entry with an extension", ("alert", 110)),
    # Asked of a server told a certificate is not required.
    "mtls-optional-none": ("no client certificate, where one is not required", ("held", "peer=-")),
    # The client's certificate goes with the session: resumed, the server
    # names it as the first handshake checked it.
    "mtls-resume": ("a ticket of a connection that presented a P-256 certificate", ("held", ("peer=CN=client", "resumed=yes scripted-resumed=yes"))),
    # Asked of a server that takes no early data: its tickets allow none.
    "mtls-early-unallowed": ("early data under a ticket that allows none: refused", ("held", ('early=""', "peer=CN=client", "resumed=yes"))),
}
MTLS_DIR = None


class Refused(Exception):
    def __init__(self, code):
        super().__init__(f"alert {code}")
        self.code = code


class Client:
    def __init__(self, port, root):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""
        self.root = root
        self.reader = None
        self.handshake = b""
        # What a resumption takes from this connection: the tickets it was
        # sent - (lifetime, age_add, nonce, ticket) each - when they came,
        # the resumption master secret and the suite.
        self.tickets = []
        self.received = None
        self.res_master = None
        self.suite = None
        self.resumed = False

    # The next record after the handshake, NewSessionTickets kept and
    # passed over: each judged as RFC 8446 section 4.6.1 lays it out, a
    # lifetime of at most seven days, no extension the server was not asked
    # for.
    def after(self):
        while True:
            type_, data = self.content()
            if type_ != 22 or data[:1] != b"\x04":
                return type_, data
            while data:
                assert data[0] == 4 and len(data) >= 4, f"handshake message {data[0]} among the NewSessionTickets"
                size = int.from_bytes(data[1:4], "big")
                body, data = data[4:4 + size], data[4 + size:]
                lifetime, age_add = struct.unpack(">II", body[:8])
                nonce = body[9:9 + body[8]]
                at = 9 + body[8]
                length = int.from_bytes(body[at:at + 2], "big")
                ticket = body[at + 2:at + 2 + length]
                rest = body[at + 2 + length:]
                assert 0 < lifetime <= 604800, f"a ticket lifetime of {lifetime} s"
                # No extension, or early_data alone with its max_early_data_size.
                assert ticket and len(ticket) == length and (rest == b"\x00\x00" or (len(rest) == 10 and rest[:6] == b"\x00\x08\x00\x2a\x00\x04")), \
                    f"a NewSessionTicket laid out wrong: {body.hex()}"
                self.tickets.append((lifetime, age_add, nonce, ticket))
                self.received = time.monotonic()

    def read_exact(self, n):
        while len(self.buf) < n:
            got = self.sock.recv(65536)
            if not got:
                raise EOFError("the server closed the connection")
            self.buf += got
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def record(self):
        header = self.read_exact(5)
        return header, self.read_exact(int.from_bytes(header[3:5], "big"))

    # The next record's type and content: in the clear before the server's
    # keys, opened under them after - where a record in the clear, an
    # alert too, is the server's mistake; a ChangeCipherSpec passed over,
    # an alert raised.
    def content(self):
        while True:
            header, body = self.record()
            if header[0] == 20:
                continue
            if self.reader:
                assert header[0] == 23, f"a record of type {header[0]} in the clear after the server's keys"
                type_, data = self.reader.open(header, body)
            else:
                type_, data = header[0], body
            if type_ == 21:
                raise Refused(data[1])
            return type_, data

    # The next handshake message, whole.
    def message(self):
        while len(self.handshake) < 4 or len(self.handshake) < 4 + int.from_bytes(self.handshake[1:4], "big"):
            type_, data = self.content()
            if type_ != 22:
                raise AssertionError(f"a record of type {type_} where a handshake message belongs")
            self.handshake += data
        size = 4 + int.from_bytes(self.handshake[1:4], "big")
        out, self.handshake = self.handshake[:size], self.handshake[size:]
        return out


def client_hello(session, share, suites=(0x1301, 0x1302, 0x1303), groups=(0x1d,), shares=None, sigalgs=SIGALGS,
                 versions=(0x0304,), alpn=None, sni="localhost", compression=b"\x00", order=None, early=False,
                 psk=None, modes=b"\x01", prefix=b"", schedule=None, binders=None, corrupt_binder=False):
    """The ClientHello. With `psk`, a list of (ticket, obfuscated age, PSK
    or None), it offers them in a pre_shared_key whose binders - over
    `prefix` and the message to its binders, under `schedule`'s hash - are
    right for each PSK given and random for None; `binders` sets how many
    go, `corrupt_binder` puts the first one bit off, and `modes` (None for
    none) is psk_key_exchange_modes."""
    shares = {0x1d: share} if shares is None else shares
    body = b"\x03\x03" + os.urandom(32) + bytes([len(session)]) + session
    body += struct.pack(">H", 2 * len(suites)) + b"".join(struct.pack(">H", s) for s in suites)
    body += bytes([len(compression)]) + compression
    exts = {}
    if sni is not None:
        name = sni.encode()
        entry = b"\x00" + struct.pack(">H", len(name)) + name
        exts["sni"] = ext(0, struct.pack(">H", len(entry)) + entry)
    if groups is not None:
        exts["groups"] = ext(10, struct.pack(">H", 2 * len(groups)) + b"".join(struct.pack(">H", g) for g in groups))
    if sigalgs is not None:
        exts["sigalgs"] = ext(13, struct.pack(">H", 2 * len(sigalgs)) + b"".join(struct.pack(">H", s) for s in sigalgs))
    if versions is not None:
        exts["versions"] = ext(43, bytes([2 * len(versions)]) + b"".join(struct.pack(">H", v) for v in versions))
    if shares is not False:
        entries = b"".join(struct.pack(">HH", g, len(k)) + k for g, k in shares.items())
        exts["shares"] = ext(51, struct.pack(">H", len(entries)) + entries)
    if alpn is not None:
        names = b"".join(bytes([len(a)]) + a.encode() for a in alpn)
        exts["alpn"] = ext(16, struct.pack(">H", len(names)) + names)
    size = schedule.size if schedule else 32
    if early:
        exts["early"] = ext(42, b"")
        if psk is None:
            # A ticket no server issued: early data offered that cannot be
            # taken, with a well-formed pre_shared_key around it.
            psk = [(b"ticket", 0, None)]
    if psk is not None:
        if modes is not None:
            exts["modes"] = ext(45, bytes([len(modes)]) + modes)
        identities = b"".join(struct.pack(">H", len(t)) + t + struct.pack(">I", age) for t, age, _ in psk)
        count = len(psk) if binders is None else binders
        listed = b"".join(bytes([size]) + bytes(size) for _ in range(count))
        exts["psk"] = ext(41, struct.pack(">H", len(identities)) + identities + struct.pack(">H", len(listed)) + listed)
    names = order or [k for k in ("sni", "groups", "sigalgs", "versions", "shares", "alpn", "early", "modes", "psk") if k in exts]
    extensions = b"".join(exts[k] if k in exts else k for k in names)
    hello = message(1, body + struct.pack(">H", len(extensions)) + extensions)
    if psk is None:
        return hello
    # The binders: in place, over the transcript to them - the ClientHello
    # without its binders list, the list's length gone too (RFC 8446
    # section 4.2.11.2) - wherever the pre_shared_key falls.
    at = hello.index(exts["psk"]) + len(exts["psk"]) - len(listed)
    truncated = hello[:at - 2]
    out = b""
    for i in range(count):
        key = psk[i][2] if i < len(psk) else None
        if key is None or schedule is None:
            binder = os.urandom(size)
        else:
            early_secret = schedule.extract(bytes(schedule.size), key)
            binder = schedule.finished(schedule.derive(early_secret, b"res binder", b""), prefix + truncated)
        if i == 0 and corrupt_binder:
            binder = bytes([binder[0] ^ 1]) + binder[1:]
        out += bytes([size]) + binder
    return hello[:at] + out + hello[at + len(out):]


def parse_server_hello(sh):
    b = sh[4:]
    random = b[2:34]
    i = 34
    sid = b[i + 1:i + 1 + b[i]]
    i += 1 + b[i]
    suite = int.from_bytes(b[i:i + 2], "big")
    i += 3
    end = i + 2 + int.from_bytes(b[i:i + 2], "big")
    i += 2
    exts = {}
    while i < end:
        t, n = struct.unpack(">HH", b[i:i + 4])
        exts[t] = b[i + 4:i + 4 + n]
        i += 4 + n
    return random, sid, suite, exts


def run(name, port, root):
    if name.startswith("resume") or name in ("mtls-resume", "mtls-early-unallowed") or \
            (name.startswith("early-") and name not in ("early-skip", "early-after-hrr", "early-malformed")):
        return resume(name, port, root)
    c = Client(port, root)
    try:
        return scenario(c, name)
    finally:
        c.sock.close()


def resume(name, port, root):
    """A first connection, its tickets kept, then a second of `name` that
    offers one; the second's outcome, and whether this side resumed. For
    early-replay, a third sends the second's first flight again."""
    first = Client(port, root)
    extra = {"suites": (0x1301,)} if name in ("resume-other-hash", "early-suite") else {}
    if name in ("resume-alpn", "early-alpn"):
        extra["alpn"] = ["http/1.1"]
    try:
        outcome = scenario(first, "mtls-ok" if name.startswith("mtls-") else "first", extra=extra)
    finally:
        first.sock.close()
    assert outcome[0] == "held" and len(first.tickets) == 2, f"the first connection: {outcome!r}, {len(first.tickets)} tickets"
    offer = {"tickets": first.tickets, "res_master": first.res_master, "suite": first.suite, "received": first.received}
    second = Client(port, root)
    try:
        outcome = scenario(second, name, offer=offer)
    finally:
        second.sock.close()
    if name == "early-replay" and outcome[0] == "held":
        third = Client(port, root)
        try:
            outcome = scenario(third, name, offer=offer, replay=second.first_flight)
        finally:
            third.sock.close()
        second = third
    if outcome[0] != "held":
        return outcome
    return "held", outcome[1].rstrip() + f" scripted-resumed={'yes' if second.resumed else 'no'}", outcome[2]


def scenario(c, name, offer=None, extra=None, replay=None):
    """One connection of `name`. With `offer`, what a first connection of
    the same scenario kept (its tickets, resumption master secret, suite
    and when the tickets came), a ticket of it is offered as `name` says;
    `extra` adds ClientHello arguments."""
    key = x25519.X25519PrivateKey.generate()
    share = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    ec_key = ec.generate_private_key(ec.SECP256R1())
    ec_share = ec_key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    p384_share = b"\x04" + os.urandom(96)
    hrr_names = ("hrr", "early-after-hrr", "hrr-no-share", "hrr-other-session", "hrr-p256", "hrr-other-suite", "hrr-early-again",
                 "junk-after-hrr", "resume-hrr", "early-hrr")
    p256_names = ("p256-share", "hrr-p256")
    session = os.urandom(32)
    kw = {}
    if name == "aes256": kw["suites"] = (0x1302,)
    if name == "chacha": kw["suites"] = (0x1303,)
    if name == "client-order": kw["suites"] = (0x1303, 0x1301)
    if name == "alpn": kw["alpn"] = ["http/1.1"]
    if name == "alpn-order": kw["alpn"] = ["http/1.1", "h2"]
    if name == "no-sni": kw["sni"] = None
    if name in hrr_names:
        kw["groups"] = (0x18, 0x17) if name == "hrr-p256" else (0x18, 0x1d)
        kw["shares"] = {0x18: p384_share}
    if name == "p256-share":
        kw["groups"] = (0x17,)
        kw["shares"] = {0x17: ec_share}
    early_data = None
    if name == "both-shares":
        kw["groups"] = (0x17, 0x1d)
        kw["shares"] = {0x17: ec_share, 0x1d: share}
    if name in ("bad-p256-share", "short-p256-share"):
        kw["groups"] = (0x17,)
        kw["shares"] = {0x17: ec_share[:-1] + bytes([ec_share[-1] ^ 1]) if name == "bad-p256-share" else ec_share[:64]}
    if name in ("early-skip", "early-after-hrr", "junk-after-hrr", "early-malformed"): kw["early"] = True
    if name == "sni-two":
        names = b"".join(b"\x00" + struct.pack(">H", len(n)) + n for n in (b"localhost", b"other.test"))
        kw["sni"] = None
        kw["order"] = ["groups", "sigalgs", "versions", "shares", ext(0, struct.pack(">H", len(names)) + names)]
    if name == "sni-bad": kw["sni"] = "bad host"
    if name == "sni-other": kw["sni"] = "other.test"
    if name == "sni-unknown": kw["sni"] = "unknown.test"
    if name == "dup-ext": kw["order"] = ["sni", "groups", "sigalgs", "groups", "versions", "shares"]
    if name == "psk-not-last":
        kw["early"] = True
        kw["order"] = ["sni", "groups", "sigalgs", "versions", "shares", "modes", "psk", ext(0xff01, b"\x00")]
    if name == "compression": kw["compression"] = b"\x01\x00"
    if name == "long-session": session = os.urandom(33)
    if name == "zero-share": kw["shares"] = {0x1d: bytes(32)}
    if name == "share-not-in-groups": kw["shares"] = {0x1d: share, 0x17: b"\x04" + os.urandom(64)}
    if name == "short-share": kw["shares"] = {0x1d: share[:31]}
    if name == "no-key-share": kw["shares"] = False
    if name == "no-groups": kw["groups"] = None
    if name == "no-sigalgs": kw["sigalgs"] = None
    if name == "no-ed25519": kw["sigalgs"] = (0x0403, 0x0804)
    if name == "no-p256": kw["sigalgs"] = (0x0807, 0x0804)
    if name == "pss-sha384": kw["sigalgs"] = (0x0805, 0x0804, 0x0807, 0x0403)
    if name == "pss-sha512": kw["sigalgs"] = (0x0806, 0x0807, 0x0403, 0x0804)
    if name == "no-rsa-pss": kw["sigalgs"] = (0x0401, 0x0501, 0x0601, 0x0807, 0x0403)
    if name == "no-group":
        kw["groups"] = (0x18,)
        kw["shares"] = {0x18: p384_share}
    if name == "byte-records":
        kw["order"] = ["sni", "groups", "sigalgs", "versions", "shares", ext(21, bytes(60000))]
    if name == "tls12": kw["versions"] = (0x0303,)
    if name == "no-versions": kw["versions"] = None
    if name == "no-suite": kw["suites"] = (0x1304,)
    if name == "alpn-mismatch": kw["alpn"] = ["spdy/3"]
    if name == "alpn-empty-name": kw["alpn"] = ["h2", ""]
    if extra:
        kw.update(extra)
    if offer is not None:
        # The first ticket the first connection was sent: its PSK from its
        # nonce (RFC 8446 section 4.6.1), its age as this side counts it.
        lifetime, age_add, nonce, ticket = offer["tickets"][0]
        held = Schedule(offer["suite"])
        secret = held.expand_label(offer["res_master"], b"resumption", nonce, held.size)
        age = int((time.monotonic() - offer["received"]) * 1000)
        if name in ("resume-expired", "resume-expired-no-sigalgs"):
            age = lifetime * 1000 + 1000
        if name == "resume-tampered":
            ticket = ticket[:-1] + bytes([ticket[-1] ^ 1])
        entries = [(ticket, (age + age_add) & 0xFFFFFFFF, secret)]
        if name == "early-stale":
            entries = [(ticket, (age + 20000 + age_add) & 0xFFFFFFFF, secret)]
        if name == "resume-second":
            entries = [(os.urandom(len(ticket)), 0, None)] + entries
        if name == "resume-binders":
            entries = entries + [(os.urandom(len(ticket)), 0, None)]
            kw["binders"] = 1
        kw["psk"] = entries
        kw["schedule"] = held
        if name == "resume-bad-binder": kw["corrupt_binder"] = True
        if name == "resume-psk-ke": kw["modes"] = b"\x00"
        if name == "resume-no-modes": kw["modes"] = None
        if name == "resume-not-last":
            kw["order"] = ["sni", "groups", "sigalgs", "versions", "shares", "modes", "psk", ext(0xff01, b"\x00")]
        if name == "resume-other-hash": kw["suites"] = (0x1302,)
        if name == "resume-other-sni": kw["sni"] = "other.test"
        if name == "resume-alpn": kw["alpn"] = ["h2"]
        if name in ("resume-no-sigalgs", "resume-expired-no-sigalgs"): kw["sigalgs"] = None
        if name.startswith("early") or name == "mtls-early-unallowed":
            kw["early"] = True
            if name == "early-alpn": kw["alpn"] = ["h2"]
            if name == "early-suite": kw["suites"] = (0x1303, 0x1301)
            if name == "early-second": kw["psk"] = [(os.urandom(len(ticket)), 0, None)] + kw["psk"]
            early_data = {"early-request": b"GET / HTTP/1.0\r\n\r\n", "early-too-much": bytes(16385)}.get(name, b"early:ping")
    if replay is not None:
        # The same ClientHello, and its key share's key, for the replay.
        ch, key, sent = replay
        session = ch[39:39 + ch[38]]
    else:
        ch = client_hello(session, share, **kw)
    if name == "slow-hello":
        record = bytes([22, 3, 1]) + struct.pack(">H", len(ch)) + ch
        started = time.monotonic()
        c.sock.settimeout(0.5)
        for b in record:
            if time.monotonic() - started > 12:
                break
            try:
                c.sock.sendall(bytes([b]))
                if c.sock.recv(1) == b"":
                    return ("ended", time.monotonic() - started)
            except socket.timeout:
                continue
            except OSError:
                return ("ended", time.monotonic() - started)
        return ("held on", time.monotonic() - started)
    if name == "cut-hello":
        ch = ch[:4] + ch[4:-1]
        ch = bytes([1]) + (len(ch) - 4).to_bytes(3, "big") + ch[4:]
    if name == "not-hello":
        ch = bytes([2]) + ch[1:]
    if name == "ccs-first":
        c.sock.sendall(plain(20, b"\x01"))
    if name == "oversize":
        c.sock.sendall(bytes([22, 3, 1]) + struct.pack(">H", 16385) + ch + bytes(16385 - len(ch)))
    elif name == "byte-records":
        started = time.monotonic()
        c.sock.sendall(b"".join(bytes([22, 3, 1, 0, 1, b]) for b in ch))
    elif name == "hello-and-more":
        more = ch + message(20, bytes(32))
        c.sock.sendall(bytes([22, 3, 1]) + struct.pack(">H", len(more)) + more)
    elif replay is not None:
        c.sock.sendall(sent)
    else:
        sent = bytes([22, 3, 1]) + struct.pack(">H", len(ch)) + ch
        c.sock.sendall(sent)
    early_writer = None
    if early_data is not None:
        # The early data (RFC 8446 section 4.2.10): a ChangeCipherSpec, then
        # records under the client's early traffic keys - the ticket's suite,
        # from its PSK, over this ClientHello alone.
        held = Schedule(offer["suite"])
        early_writer = Cipher(held, held.derive(held.extract(bytes(held.size), kw["psk"][0][2] or bytes(held.size)), b"c e traffic", ch))
        if replay is None:
            early = plain(20, b"\x01")
            for k in range(0, len(early_data), 16384):
                early += early_writer.seal(23, early_data[k:k + 16384], corrupt=(name == "early-bad-record"))
            c.sock.sendall(early)
            c.first_flight = (ch, key, sent + early)
        else:
            for _ in range(len(early_data) // 16384 + 1):
                early_writer.seq += 1
    if name == "ccs-flood":
        c.sock.sendall(plain(20, b"\x01") * 17)
    if kw.get("early") and early_data is None:
        # Early data under keys the server does not have: it must pass over
        # these records.
        for _ in range(3):
            junk = os.urandom(200)
            c.sock.sendall(bytes([23, 3, 3]) + struct.pack(">H", len(junk)) + junk)
    transcript = ch
    sh = c.message()
    if name == "byte-records":
        took = time.monotonic() - started
        assert took < 1.5, f"the ServerHello came {took:.1f} s after a ClientHello a byte to a record"
    assert sh[0] == 2, f"message {sh[0]} where the ServerHello belongs"
    random, sid, suite, exts = parse_server_hello(sh)
    assert sid == session, "the session id not echoed"
    assert exts.get(43) == b"\x03\x04", "no TLS 1.3 in the ServerHello"
    schedule = Schedule(suite)
    if random == HELLO_RETRY:
        wanted = b"\x00\x17" if name == "hrr-p256" else b"\x00\x1d"
        assert exts.get(51) == wanted, f"a HelloRetryRequest asking for {exts.get(51)!r}"
        assert name in hrr_names, "a HelloRetryRequest nobody needed"
        digest = schedule.digest(ch)
        transcript = bytes([254, 0, 0, len(digest)]) + digest + sh
        if name == "early-after-hrr":
            for _ in range(2):
                junk = os.urandom(300)
                c.sock.sendall(bytes([23, 3, 3]) + struct.pack(">H", len(junk)) + junk)
        c.sock.sendall(plain(20, b"\x01"))
        again = dict(kw)
        if name == "hrr-early-again":
            again["early"] = True
        else:
            again.pop("early", None)
        if name == "hrr-other-suite":
            again["suites"] = tuple(x for x in (0x1301, 0x1302, 0x1303) if x != suite)
        if name == "hrr-p256":
            again["shares"] = {0x17: ec_share}
        elif name != "hrr-no-share":
            again["shares"] = {0x1d: share}
        if name == "hrr-other-session":
            session = os.urandom(32)
        if "psk" in again:
            again["prefix"] = transcript
        ch = client_hello(session, share, **again)
        c.sock.sendall(plain(22, ch))
        transcript += ch
        sh = c.message()
        random, sid, suite, exts = parse_server_hello(sh)
        assert random != HELLO_RETRY, "a second HelloRetryRequest"
    assert suite in SUITE_NAMES, f"suite {suite:#x}"
    group, length = struct.unpack(">HH", exts[51][:4])
    transcript += sh
    if name in p256_names:
        assert group == 0x17 and length == 65, "the server's share is not secp256r1"
        shared = ec_key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), exts[51][4:]))
    else:
        assert group == 0x1d and length == 32, "the server's share is not X25519"
        shared = key.exchange(x25519.X25519PublicKey.from_public_bytes(exts[51][4:]))
    # A resumption (RFC 8446 section 2.2): the ServerHello names the
    # identity taken, whose PSK the early secret is made of.
    resumed = 41 in exts
    psk_secret = bytes(schedule.size)
    if resumed:
        assert "psk" in kw, "a pre_shared_key in a ServerHello to a ClientHello offering none"
        chosen = int.from_bytes(exts[41], "big")
        assert len(exts[41]) == 2 and chosen < len(kw["psk"]) and kw["psk"][chosen][2] is not None, f"a ServerHello taking identity {exts[41].hex()}"
        psk_secret = kw["psk"][chosen][2]
    c.resumed = resumed
    early_secret = schedule.extract(bytes(schedule.size), psk_secret)
    hs = schedule.extract(schedule.derive(early_secret, b"derived", b""), shared)
    c_hs = schedule.derive(hs, b"c hs traffic", transcript)
    s_hs = schedule.derive(hs, b"s hs traffic", transcript)
    c.reader = Cipher(schedule, s_hs)

    ee = c.message()
    mtls = name in MTLS
    assert ee[0] == 8, f"message {ee[0]} where EncryptedExtensions belongs"
    listed, i, types = ee[6:], 0, []
    while i < len(listed):
        t, n = struct.unpack(">HH", listed[i:i + 4])
        types.append(t)
        i += 4 + n
    taken = 42 in types
    wanted = early_data is not None and replay is None and name in ("early-ok", "early-request", "early-too-much", "early-bad-record",
                                                                    "early-finished-early", "early-replay")
    assert taken == wanted, f"early data {'taken' if taken else 'refused'} where it should {'' if wanted else 'not '}be"
    assert (16 in types) == (kw.get("alpn") is not None), f"EncryptedExtensions {types} for ALPN {kw.get('alpn')}"
    transcript += ee
    cert = c.message()
    requested = cert[0] == 13 and not resumed
    if resumed:
        # The PSK is the authentication: no CertificateRequest, Certificate
        # or CertificateVerify (RFC 8446 sections 2.2 and 4.3.2).
        assert cert[0] == 20, f"message {cert[0]} where a resumption's Finished belongs"
        finished = cert
    else:
        if requested:
            assert mtls, "a CertificateRequest from a server that was not told to ask"
            body = cert[4:]
            assert body[0] == 0, "a CertificateRequest with a context"
            listed, i, offered = body[3:], 0, []
            while i < len(listed):
                t, n = struct.unpack(">HH", listed[i:i + 4])
                if t == 13:
                    schemes = listed[i + 6:i + 4 + n]
                    offered = [int.from_bytes(schemes[k:k + 2], "big") for k in range(0, len(schemes), 2)]
                i += 4 + n
            assert 0x0807 in offered and 0x0403 in offered, f"a CertificateRequest offering {offered}"
            transcript += cert
            cert = c.message()
        else:
            assert not mtls, "no CertificateRequest from a server told to ask"
        assert cert[0] == 11, f"message {cert[0]} where Certificate belongs"
        transcript += cert
        body = cert[4:]
        assert body[0] == 0, "a request context"
        first = int.from_bytes(body[4:7], "big")
        leaf = x509.load_der_x509_certificate(body[7:7 + first])
        leaf.verify_directly_issued_by(c.root)
        verify = c.message()
        signed = b" " * 64 + b"TLS 1.3, server CertificateVerify\x00" + schedule.digest(transcript)
        public = leaf.public_key()
        if isinstance(public, ed25519.Ed25519PublicKey):
            assert verify[4:6] == b"\x08\x07", f"an Ed25519 key's CertificateVerify under {verify[4:6].hex()}"
            public.verify(verify[8:], signed)
        elif isinstance(public, rsa.RSAPublicKey):
            wanted = next(s for s in kw.get("sigalgs", SIGALGS) if s in PSS)
            scheme = int.from_bytes(verify[4:6], "big")
            assert scheme == wanted, f"an RSA key's CertificateVerify under {scheme:#06x}, the first RSA-PSS scheme offered being {wanted:#06x}"
            h = PSS[scheme]()
            public.verify(verify[8:], signed, padding.PSS(mgf=padding.MGF1(h), salt_length=h.digest_size), h)
        else:
            assert isinstance(public, ec.EllipticCurvePublicKey) and public.curve.name == "secp256r1", "the leaf's key is neither Ed25519, P-256 nor RSA"
            assert verify[4:6] == b"\x04\x03", f"a P-256 key's CertificateVerify under {verify[4:6].hex()}"
            public.verify(verify[8:], signed, ec.ECDSA(hashes.SHA256()))
        assert verify[0] == 15, f"message {verify[0]} where CertificateVerify belongs"
        transcript += verify
        finished = c.message()
    assert finished[0] == 20 and finished[4:] == schedule.finished(s_hs, transcript), "the server's Finished"
    transcript += finished
    assert not c.handshake, "handshake bytes after the server's Finished"
    master = schedule.extract(schedule.derive(hs, b"derived", b""), bytes(schedule.size))
    c_ap = schedule.derive(master, b"c ap traffic", transcript)
    s_ap = schedule.derive(master, b"s ap traffic", transcript)
    # What the server writes from here is under its application keys.
    c.reader = Cipher(schedule, s_ap)

    writer = Cipher(schedule, c_hs)
    if requested:
        # The client's certificate, or one rule of its answer broken.
        who = {"mtls-ed25519": "client-ed", "mtls-rsa": "client-rsa", "mtls-untrusted": "other", "mtls-server-only": "server-only"}.get(name, "client")
        ders = [x509c.public_bytes(serialization.Encoding.DER)
                for x509c in x509.load_pem_x509_certificates(open(os.path.join(MTLS_DIR, who + ".pem"), "rb").read())]
        own = serialization.load_pem_private_key(open(os.path.join(MTLS_DIR, who + ".key"), "rb").read(), None)
        if name in ("mtls-none", "mtls-optional-none"):
            presented = message(11, b"\x00" + bytes(3))
        else:
            context = b"\x01\x07" if name in ("mtls-context", "mtls-late") else b"\x00"
            extension = b"\x00\x04" + ext(5, b"") if name == "mtls-entry-ext" else b"\x00\x00"
            entries = b"".join(len(d).to_bytes(3, "big") + d + extension for d in ders * (6 if name == "mtls-long-chain" else 1))
            presented = message(11, context + len(entries).to_bytes(3, "big") + entries)
        c.sock.sendall(writer.seal(22, presented))
        transcript += presented
        if name == "mtls-late":
            time.sleep(0.3)
        if name not in ("mtls-none", "mtls-optional-none", "mtls-no-cv"):
            signed = b" " * 64 + b"TLS 1.3, client CertificateVerify\x00" + schedule.digest(transcript)
            if isinstance(own, ed25519.Ed25519PrivateKey):
                scheme, sig = 0x0807, own.sign(signed)
            elif isinstance(own, rsa.RSAPrivateKey):
                scheme, sig = 0x0804, own.sign(signed, padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32), hashes.SHA256())
            else:
                scheme, sig = 0x0403, own.sign(signed, ec.ECDSA(hashes.SHA256()))
            if name == "mtls-wrong-scheme":
                scheme = 0x0807 if scheme == 0x0403 else 0x0403
            if name == "mtls-bad-cv":
                sig = sig[:-1] + bytes([sig[-1] ^ 1])
            client_verify = message(15, struct.pack(">HH", scheme, len(sig)) + sig)
            c.sock.sendall(writer.seal(22, client_verify))
            transcript += client_verify
            if name == "mtls-late":
                time.sleep(0.2)
    if taken and name == "early-request":
        # The answer comes before this side's Finished (0.5-RTT): read it,
        # under the server's application keys, first.
        c.reader = Cipher(schedule, s_ap)
        type_, data = c.after()
        assert type_ == 23 and b"HTTP/1.0 200 ok" in data, f"no answer before the client's Finished: {type_} {data[:40]!r}"
        early_answer = data
    if taken and name == "early-finished-early":
        c.sock.sendall(early_writer.seal(22, message(20, schedule.finished(c_hs, transcript))))
    elif taken:
        ended = message(5, b"")
        c.sock.sendall(early_writer.seal(22, ended))
        transcript += ended
    if name == "ccs":
        c.sock.sendall(plain(20, b"\x01"))
    if name == "cert-instead-of-finished":
        c.sock.sendall(writer.seal(22, message(11, b"\x00\x00\x00\x00")))
    elif name == "data-before-finished":
        c.sock.sendall(writer.seal(23, b"too soon"))
    elif name in ("junk-after-hrr", "early-malformed"):
        if name == "junk-after-hrr":
            junk = os.urandom(100)
            c.sock.sendall(bytes([23, 3, 3]) + struct.pack(">H", len(junk)) + junk)
        else:
            c.sock.sendall(writer.seal(0, bytes(5)))
        c.sock.sendall(writer.seal(22, message(20, schedule.finished(c_hs, transcript))))
    else:
        verify_data = schedule.finished(c_hs, transcript)
        if name == "bad-finished":
            verify_data = bytes([verify_data[0] ^ 1]) + verify_data[1:]
        c.sock.sendall(writer.seal(22, message(20, verify_data), corrupt=(name == "bad-record-mac")))
    writer = Cipher(schedule, c_ap)
    # The resumption master secret, over the handshake to this side's
    # Finished: the tickets' PSKs are made of it.
    c.res_master = schedule.derive(master, b"res master", transcript + message(20, schedule.finished(c_hs, transcript)))
    c.suite = suite
    got = b""
    if name == "keyupdate":
        c.sock.sendall(writer.seal(22, message(24, b"\x01")))
        writer = Cipher(schedule, schedule.expand_label(c_ap, b"traffic upd", b"", schedule.size))
        c.sock.sendall(writer.seal(23, b"ping"))
        type_, data = c.after()
        assert type_ == 22 and data == message(24, b"\x00"), "no KeyUpdate back"
        c.reader = Cipher(schedule, schedule.expand_label(s_ap, b"traffic upd", b"", schedule.size))
        type_, data = c.after()
        assert type_ == 23, f"a record of type {type_} where the echo belongs"
        got += data
    if taken and name == "early-request":
        got = early_answer
    else:
        c.sock.sendall(writer.seal(23, b"GET / HTTP/1.0\r\n\r\n"))
    while True:
        try:
            type_, data = c.after()
        except Refused as r:
            if r.code == 0:
                break
            raise
        assert type_ == 23, f"a record of type {type_} after the handshake"
        got += data
    return "held", got.decode(errors="replace"), SUITE_NAMES[suite]


def main():
    port = int(sys.argv[1])
    root = x509.load_pem_x509_certificate(open(sys.argv[2], "rb").read())
    rest = sys.argv[3:]
    key_kind = "ed25519"
    global MTLS_DIR
    while rest and rest[0].startswith("--"):
        if rest[0] in ("--p256", "--rsa"):
            key_kind = rest[0][2:]
            rest = rest[1:]
        elif rest[0] == "--mtls":
            MTLS_DIR = rest[1]
            rest = rest[2:]
        else:
            raise SystemExit(f"no option {rest[0]}")
    names = rest or ([n for n in MTLS if n != "mtls-optional-none"] if MTLS_DIR else list(SCENARIOS))
    failures = 0
    for name in names:
        what, answer = MTLS[name] if name in MTLS else SCENARIOS[name]
        kind, want = answer[key_kind] if isinstance(answer, dict) else answer
        try:
            outcome = run(name, port, root)
        except Refused as r:
            outcome = ("alert", r.code)
        except Exception as e:
            outcome = ("broke", f"{type(e).__name__}: {e}")
        wants = want if isinstance(want, tuple) else (want,)
        if kind == "held" and outcome[0] == "held" and all(w in outcome[1] for w in wants) and "HTTP/1.0 200 ok" in outcome[1]:
            print(f"{name}: ok, {outcome[1].splitlines()[-1]}")
        elif kind == "alert" and outcome == ("alert", want):
            print(f"{name}: ok, alert {want}")
        elif kind == "ended" and outcome[0] == "ended" and outcome[1] < want:
            print(f"{name}: ok, hung up after {outcome[1]:.1f} s")
        else:
            failures += 1
            print(f"FAIL {name} ({what}): expected {kind} {want!r}, got {outcome!r}")
    print(f"{len(names) - failures} of {len(names)} scenarios answered as they must")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
