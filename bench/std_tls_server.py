"""A TLS 1.3 server that breaks the protocol one rule at a time, for
bench/std_tls_exercise.sh.

    python3 bench/std_tls_server.py WORKDIR

Writes WORKDIR/roots.pem (the root its certificates chain to),
WORKDIR/client.pem and client.key (an Ed25519 certificate and key for the
client to present when asked) and WORKDIR/port, then answers connections
one after another until killed.
The scenario is the first label of the name the client sends by SNI:
`ok.tls.test` is a correct handshake followed by an echo, `bad-finished`
sends a Finished that does not match, and so on - SCENARIOS below lists
each and what it breaks. A correct handshake ends with the server checking
the client's Finished and echoing `echo:` and what the client sent, so a
client whose Finished is wrong is answered with an alert and no echo.

Written for this one purpose over Python's cryptography: the key schedule,
the record layer and the messages of RFC 8446, no more than the scenarios
use. Not a TLS server for anything else.
"""
import datetime as dt
import os
import socket
import struct
import time
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, hmac, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa, x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
from cryptography.x509.oid import NameOID

SCENARIOS = {
    "ok": "a correct handshake, ECDSA P-256 leaf, AES-128-GCM",
    "rsa": "an RSA leaf signing CertificateVerify with RSASSA-PSS",
    "p384": "a P-384 leaf signing with ecdsa_secp384r1_sha384",
    "ed25519": "an Ed25519 leaf signing CertificateVerify with ed25519",
    "aes256": "TLS_AES_256_GCM_SHA384, the SHA-384 key schedule",
    "chacha": "TLS_CHACHA20_POLY1305_SHA256",
    "ccs": "a ChangeCipherSpec before the encrypted flight",
    "fragmented": "each message in its own record, one split across two",
    "certreq": "a CertificateRequest naming ecdsa_secp256r1_sha256 alone, answered by an empty Certificate",
    "certreq-ed25519": "a CertificateRequest naming ed25519, answered by the client's certificate and CertificateVerify",
    "alpn": "ALPN answered with http/1.1",
    "hrr-cookie": "a HelloRetryRequest with a cookie, then the handshake",
    "keyupdate": "a KeyUpdate asking for one back, answered before the client's next data",
    "big": "40000 bytes back, over three records",
    "ticket": "a NewSessionTicket before the echo",
    "bad-finished": "a Finished one bit off",
    "bad-cv": "a CertificateVerify signature one bit off",
    "bad-cv-ed25519": "an Ed25519 CertificateVerify one bit off",
    "cv-ed25519-p256": "a P-256 key's signature named ed25519",
    "cv-pkcs1": "CertificateVerify under rsa_pkcs1_sha256",
    "cv-wrong-curve": "a P-384 key named ecdsa_secp256r1_sha256",
    "suite-unoffered": "TLS_AES_128_CCM_SHA256, which was not offered",
    "tls12": "a ServerHello with no supported_versions: TLS 1.2, to a client that did not ask for it",
    "tls12-resume": "a TLS 1.2 ServerHello echoing the client's session id: a resumption",
    "tls12-hello": "a TLS 1.2 ServerHello as it should be, after the ClientHello's TLS 1.2 offer is checked, then a hang-up",
    "tls12-downgrade": "a TLS 1.2 ServerHello whose random ends with DOWNGRD 01",
    "tls12-downgrade11": "a TLS 1.2 ServerHello whose random ends with DOWNGRD 00",
    "tls12-no-ems": "a TLS 1.2 ServerHello without extended_master_secret",
    "tls12-reneg": "a TLS 1.2 ServerHello whose renegotiation_info is not empty",
    "tls12-suite13": "a TLS 1.2 ServerHello choosing TLS_AES_128_GCM_SHA256",
    "tls12-version11": "a ServerHello choosing TLS 1.1",
    "tls12-versions": "a ServerHello whose supported_versions names TLS 1.2",
    "tls12-key-share": "a TLS 1.2 ServerHello carrying a key_share",
    "no-echo": "a ServerHello that does not echo the session id",
    "hrr-group": "a HelloRetryRequest for secp384r1, which the client does not offer",
    "hrr-p256": "a HelloRetryRequest for secp256r1, then the handshake in it",
    "sh-wrong-group": "a ServerHello's share in secp256r1, the client's having been X25519's",
    "unsolicited-ext": "an extension in EncryptedExtensions nobody offered",
    "alpn-unoffered": "ALPN answered with a protocol not offered",
    "wrong-host": "a certificate for another name",
    "untrusted": "a certificate from a root the client does not trust",
    "expired": "a certificate past its end",
    "bad-record-mac": "the first protected record's tag one bit off",
    "oversize": "a ServerHello record past 2^14 + 256 bytes",
    "alert": "handshake_failure instead of a ServerHello",
    "cert-empty": "a Certificate with no certificates",
    "app-data-in-handshake": "application data before Finished",
    "trailing-after-finished": "a NewSessionTicket in the Finished's record",
    "zero-share": "an X25519 share of small order",
    "compression": "a ServerHello with a compression method",
    "sh-extension": "an extension in the ServerHello nobody offered",
    "certreq-no-sigalgs": "a CertificateRequest without signature_algorithms",
    "cert-many": "a Certificate of twelve certificates, the chain six times over",
    "slow-server": "a ServerHello a byte every half second, for ten seconds, then a hang-up",
    "sh-and-more": "EncryptedExtensions in the clear, in the ServerHello's record",
    "ku-no-sign": "a leaf whose keyUsage is keyEncipherment alone",
    "keyupdate-bad": "a KeyUpdate whose request is 2",
    "slow-echo": "the echo a second and a half late",
    "client-rekey": "the client's records read across its KeyUpdates, counted",
    "certreq-context": "a CertificateRequest with a request context, in the handshake",
    "cert-entry-ext": "a certificate entry with a status_request extension nobody asked for",
    "sni-ack-data": "a server_name acknowledgement that is not empty",
    "user-canceled": "a user_canceled warning before the echo",
    "padded-max": "the echo padded to 2^14 + 1 bytes of inner plaintext, the most section 5.4 allows",
    "padded-over": "the echo padded to 2^14 + 2 bytes of inner plaintext, one past section 5.4's limit",
    "split-by-data": "half a NewSessionTicket, then the echo inside it, then the rest",
    "split-by-close": "half a NewSessionTicket, then close_notify",
    # Resumption: the first connection to each is an ok handshake that ends
    # with a real NewSessionTicket; the second, offering it, is checked -
    # its binder over the ClientHello, its obfuscated age against the time
    # since the ticket went, psk_dhe_ke its one mode - and then answered.
    "resume": "the ticket taken: pre_shared_key in the ServerHello, then EncryptedExtensions and Finished",
    "resume-declined": "the ticket passed over: a full handshake",
    "resume-identity": "a ServerHello taking identity 1, of the one offered",
    "resume-hash": "a SHA-256 ticket taken under TLS_AES_256_GCM_SHA384",
    "resume-no-share": "the ticket taken with no key_share, which psk_dhe_ke requires",
    "resume-cert": "the ticket taken, then a Certificate",
    "ticket-many": "twenty NewSessionTickets before the echo",
    "ticket-huge": "a NewSessionTicket whose ticket is 16,385 bytes, over two records",
    "ticket-bad": "a NewSessionTicket cut short",
    # Early data: the first connection's ticket allows 1024 bytes (4 for
    # early-small, none for early-unoffered); the second's early data is
    # taken (early: read to EndOfEarlyData under the early keys, echoed as
    # "early:..."), refused and passed over (early-refused, and early-alpn,
    # which chooses h2 where the ticket's protocol was http/1.1), must not
    # come (early-small), or is "taken" though none came (early-unoffered).
    "early": "early data taken",
    "early-refused": "early data refused and passed over",
    "early-small": "a ticket allowing 4 bytes, for 5 of early data",
    "early-alpn": "early data under an http/1.1 ticket, h2 chosen and the early data refused",
    "early-unoffered": "early_data in EncryptedExtensions with no early data sent",
}

# The tickets issued, by their bytes: (PSK, suite, age_add, when).
TICKETS = {}
NOW = dt.datetime.now(dt.timezone.utc)
DAY = dt.timedelta(days=1)


def name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def issue(subject, key, issuer, issuer_key, ca, sans=None, start=NOW - DAY, end=NOW + 30 * DAY, extra=()):
    b = (x509.CertificateBuilder().subject_name(name(subject)).issuer_name(issuer)
         .public_key(key.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(start).not_valid_after(end)
         .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if sans:
        b = b.add_extension(x509.SubjectAlternativeName([x509.DNSName(s) for s in sans]), critical=False)
    for extension, critical in extra:
        b = b.add_extension(extension, critical=critical)
    return b.sign(issuer_key, hashes.SHA256())


class Pki:
    def __init__(self):
        self.root_key = ec.generate_private_key(ec.SECP256R1())
        self.root = issue("Scripted Root", self.root_key, name("Scripted Root"), self.root_key, True)
        self.inter_key = ec.generate_private_key(ec.SECP256R1())
        self.inter = issue("Scripted Inter", self.inter_key, self.root.subject, self.root_key, True)
        other_key = ec.generate_private_key(ec.SECP256R1())
        other = issue("Other Root", other_key, name("Other Root"), other_key, True)
        self.keys = {"p256": ec.generate_private_key(ec.SECP256R1()), "p384": ec.generate_private_key(ec.SECP384R1()),
                     "rsa": rsa.generate_private_key(public_exponent=65537, key_size=2048),
                     "ed25519": ed25519.Ed25519PrivateKey.generate()}
        self.leaves = {k: issue("leaf", v, self.inter.subject, self.inter_key, False, ["*.tls.test"]) for k, v in self.keys.items()}
        self.wrong_host = issue("leaf", self.keys["p256"], self.inter.subject, self.inter_key, False, ["other.example"])
        self.expired = issue("leaf", self.keys["p256"], self.inter.subject, self.inter_key, False, ["*.tls.test"],
                             start=NOW - 30 * DAY, end=NOW - DAY)
        self.untrusted = issue("leaf", self.keys["p256"], other.subject, other_key, False, ["*.tls.test"])
        self.client_key = ed25519.Ed25519PrivateKey.generate()
        # Past 16 KiB, with an extension nobody reads: a client's Certificate
        # must come in more than one record.
        bulk = x509.UnrecognizedExtension(x509.ObjectIdentifier("1.3.6.1.4.1.32473.1"), b"\x04\x82\x4e\x20" + bytes(20000))
        self.client = issue("client", self.client_key, self.inter.subject, self.inter_key, False, extra=[(bulk, False)])
        # A leaf whose keyUsage is keyEncipherment alone: it may not sign.
        no_sign = x509.KeyUsage(False, False, True, False, False, False, False, False, False)
        self.no_sign = issue("leaf", self.keys["p256"], self.inter.subject, self.inter_key, False, ["*.tls.test"], extra=[(no_sign, True)])


def der(cert):
    return cert.public_bytes(serialization.Encoding.DER)


class Schedule:
    def __init__(self, suite):
        self.sha384 = suite == 0x1302
        self.hash = hashes.SHA384() if self.sha384 else hashes.SHA256()
        self.size = 48 if self.sha384 else 32
        self.suite = suite

    def digest(self, data):
        h = hashes.Hash(self.hash); h.update(data); return h.finalize()

    def hmac(self, key, data):
        h = hmac.HMAC(key, self.hash); h.update(data); return h.finalize()

    def extract(self, salt, ikm):
        return self.hmac(salt, ikm)

    def expand_label(self, secret, label, context, length):
        full = b"tls13 " + label
        info = struct.pack(">HB", length, len(full)) + full + bytes([len(context)]) + context
        return HKDFExpand(self.hash, length, info).derive(secret)

    def derive(self, secret, label, transcript):
        return self.expand_label(secret, label, self.digest(transcript), self.size)

    def finished(self, secret, transcript):
        return self.hmac(self.expand_label(secret, b"finished", b"", self.size), self.digest(transcript))


class Cipher:
    def __init__(self, schedule, secret):
        size = 16 if schedule.suite == 0x1301 else 32
        key = schedule.expand_label(secret, b"key", b"", size)
        self.iv = schedule.expand_label(secret, b"iv", b"", 12)
        self.aead = ChaCha20Poly1305(key) if schedule.suite == 0x1303 else AESGCM(key)
        self.seq = 0

    def nonce(self):
        n = bytearray(self.iv)
        for i in range(8):
            n[11 - i] ^= (self.seq >> (8 * i)) & 0xFF
        return bytes(n)

    def seal(self, type_, content, corrupt=False, pad=0):
        inner = content + bytes([type_]) + bytes(pad)
        header = bytes([23, 3, 3]) + struct.pack(">H", len(inner) + 16)
        sealed = bytearray(self.aead.encrypt(self.nonce(), inner, header))
        if corrupt:
            sealed[-1] ^= 1
        self.seq += 1
        return header + bytes(sealed)

    def open(self, header, body):
        inner = self.aead.decrypt(self.nonce(), body, header)
        self.seq += 1
        inner = inner.rstrip(b"\x00")
        return inner[-1], inner[:-1]


def message(type_, body):
    return bytes([type_]) + len(body).to_bytes(3, "big") + body


def ext(type_, data):
    return struct.pack(">HH", type_, len(data)) + data


def plain(type_, content):
    return bytes([type_, 3, 3]) + struct.pack(">H", len(content)) + content


class Conn:
    def __init__(self, sock, pki):
        self.sock = sock
        self.pki = pki
        self.buf = b""

    def read_exact(self, n):
        while len(self.buf) < n:
            got = self.sock.recv(65536)
            if not got:
                raise EOFError
            self.buf += got
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def record(self):
        header = self.read_exact(5)
        return header, self.read_exact(int.from_bytes(header[3:5], "big"))

    def client_hello(self):
        header, body = self.record()
        assert header[0] == 22, header
        ch = body
        while len(ch) < 4 or len(ch) < 4 + int.from_bytes(ch[1:4], "big"):
            _, more = self.record()
            ch += more
        assert ch[0] == 1
        b = ch[4:]
        i = 2
        random = b[i:i + 32]; i += 32
        sid = b[i + 1:i + 1 + b[i]]; i += 1 + b[i]
        n = int.from_bytes(b[i:i + 2], "big"); suites = [int.from_bytes(b[i + 2 + k:i + 4 + k], "big") for k in range(0, n, 2)]; i += 2 + n
        i += 1 + b[i]
        exts = {}
        end = i + 2 + int.from_bytes(b[i:i + 2], "big"); i += 2
        while i < end:
            t, l = struct.unpack(">HH", b[i:i + 4]); exts[t] = b[i + 4:i + 4 + l]; i += 4 + l
        sni = exts[0][5:].decode() if 0 in exts else ""
        share = None
        ks = exts.get(51, b"")
        j = 2
        while j < len(ks):
            g, l = struct.unpack(">HH", ks[j:j + 4])
            if g == 0x1d:
                share = ks[j + 4:j + 4 + l]
            j += 4 + l
        alpn = []
        if 16 in exts:
            a = exts[16][2:]
            while a:
                alpn.append(a[1:1 + a[0]].decode()); a = a[1 + a[0]:]
        return ch, sid, suites, sni, share, alpn, exts

    def serve(self):
        ch, sid, suites, sni, share, alpn, exts = self.client_hello()
        s = sni.split(".")[0]
        transcript = ch
        if s == "alert":
            self.sock.sendall(plain(21, bytes([2, 40])))
            return
        if s == "tls12":
            # The client was not asked for TLS 1.2: its ClientHello offers 1.3
            # alone, and nothing of 1.2's.
            assert exts.get(43) == b"\x02\x03\x04", f"supported_versions {exts.get(43)!r}, not TLS 1.3 alone"
            assert not [x for x in suites if x >> 8 != 0x13], f"TLS 1.2 suites offered: {suites}"
            assert 23 not in exts and 0xff01 not in exts, "TLS 1.2's extensions offered"
        if s.startswith("tls12-"):
            # A TLS 1.2 ServerHello, one rule broken, then a hang-up: the
            # client must refuse it before reading on. tls12-hello checks the
            # ClientHello's offer of 1.2 first and breaks nothing.
            if s == "tls12-hello":
                assert exts.get(43) == b"\x04\x03\x04\x03\x03", f"supported_versions {exts.get(43)!r}, not TLS 1.3 then 1.2"
                assert exts.get(23) == b"", "no extended_master_secret offered"
                assert exts.get(0xff01) == b"\x00", "no empty renegotiation_info offered"
                assert exts.get(11) == b"\x01\x00", "ec_point_formats not uncompressed alone"
                offered12 = [x for x in suites if x in (0xc02b, 0xc02f, 0xc02c, 0xc030, 0xcca9, 0xcca8)]
                assert offered12 == [0xc02b, 0xc02f, 0xc02c, 0xc030, 0xcca9, 0xcca8], f"TLS 1.2 suites offered: {offered12}"
            tail = {"tls12-downgrade": b"DOWNGRD\x01", "tls12-downgrade11": b"DOWNGRD\x00"}.get(s, os.urandom(8))
            # tls12-hello's ServerHello is followed by access_denied, which the
            # client reads only if it took the ServerHello.
            e = b"" if s == "tls12-no-ems" else ext(23, b"")
            e += ext(0xff01, b"\x01\x00" if s == "tls12-reneg" else b"\x00")
            if s == "tls12-key-share":
                e += ext(51, b"\x00\x1d" + struct.pack(">H", 32) + os.urandom(32))
            if s == "tls12-versions":
                e = ext(43, b"\x03\x03")
            # tls12-versions is read as TLS 1.3 (it carries supported_versions),
            # so it echoes the session id and names a TLS 1.3 suite.
            own = sid if s in ("tls12-versions", "tls12-resume") else os.urandom(32)
            sh = message(2, (b"\x03\x02" if s == "tls12-version11" else b"\x03\x03") + os.urandom(24) + tail + bytes([len(own)]) + own
                         + struct.pack(">HB", 0x1301 if s in ("tls12-suite13", "tls12-versions") else 0xc02b, 0) + struct.pack(">H", len(e)) + e)
            self.sock.sendall(plain(22, sh) + (plain(21, bytes([2, 49])) if s == "tls12-hello" else b""))
            return
        suite = {"aes256": 0x1302, "chacha": 0x1303, "suite-unoffered": 0x1304}.get(s, 0x1301)
        psk = None
        if s.startswith(("resume", "early")) and 41 in exts:
            judged = self.judge_psk(ch, exts)
            if isinstance(judged, int):
                self.sock.sendall(plain(21, bytes([2, judged])))
                return
            psk = None if s == "resume-declined" else judged
            if s == "resume-hash":
                suite = 0x1302
        schedule = Schedule(0x1301 if suite == 0x1304 else suite)
        groups = exts.get(10, b"")
        if s in ("hrr-cookie", "hrr-group", "hrr-p256"):
            offered = [int.from_bytes(groups[k:k + 2], "big") for k in range(2, len(groups), 2)]
            assert 0x17 in offered, f"secp256r1 not among the client's groups {offered}"
            retry_random = bytes.fromhex("cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c")
            asked = {"hrr-cookie": ext(44, struct.pack(">H", 8) + b"cookie!!"), "hrr-group": ext(51, b"\x00\x18"),
                     "hrr-p256": ext(51, b"\x00\x17")}[s]
            e = ext(43, b"\x03\x04") + asked
            hrr = message(2, b"\x03\x03" + retry_random + bytes([len(sid)]) + sid + struct.pack(">HB", suite, 0) + struct.pack(">H", len(e)) + e)
            self.sock.sendall(plain(22, hrr))
            if s == "hrr-group":
                return
            first = schedule.digest(ch)
            ch2, sid, suites, sni, share, alpn, exts = self.client_hello()
            if s == "hrr-cookie":
                assert exts.get(44) == struct.pack(">H", 8) + b"cookie!!", "no cookie echoed"
            transcript = bytes([254, 0, 0, len(first)]) + first + hrr + ch2
        if s == "hrr-p256":
            # The second ClientHello's one share, in secp256r1.
            ks = exts.get(51, b"")
            g, l = struct.unpack(">HH", ks[2:6])
            assert g == 0x17 and l == 65 and len(ks) == 6 + l, "the second ClientHello's share is not one secp256r1 point"
            peer_point = ks[6:6 + l]
            ec_key = ec.generate_private_key(ec.SECP256R1())
        key = x25519.X25519PrivateKey.generate()
        mine = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        if s == "zero-share":
            mine = bytes(32)
        e = b""
        if s != "tls12":
            e += ext(43, b"\x03\x04")
        if s in ("hrr-p256", "sh-wrong-group"):
            other = ec_key if s == "hrr-p256" else ec.generate_private_key(ec.SECP256R1())
            mine = other.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
            e += ext(51, b"\x00\x17" + struct.pack(">H", 65) + mine)
        elif s != "resume-no-share" or psk is None:
            e += ext(51, b"\x00\x1d" + struct.pack(">H", 32) + mine)
        if psk is not None:
            e += ext(41, struct.pack(">H", 1 if s == "resume-identity" else 0))
        if s == "sh-extension":
            e += ext(0xff00, b"")
        echo = b"\x00" * len(sid) if s == "no-echo" else sid
        sh = message(2, b"\x03\x03" + os.urandom(32) + bytes([len(echo)]) + echo + struct.pack(">HB", suite, 1 if s == "compression" else 0)
                     + struct.pack(">H", len(e)) + e)
        record = plain(22, sh + (message(8, b"\x00\x00") if s == "sh-and-more" else b""))
        if s == "oversize":
            record = bytes([22, 3, 3]) + struct.pack(">H", 16384 + 257) + sh + b"\x00" * (16384 + 257 - len(sh))
        if s == "slow-server":
            started = time.monotonic()
            for b in record:
                if time.monotonic() - started > 10:
                    return
                try:
                    self.sock.sendall(bytes([b]))
                except OSError:
                    return
                time.sleep(0.5)
            return
        self.sock.sendall(record)
        if s in ("tls12", "no-echo", "suite-unoffered", "zero-share", "compression", "sh-extension", "oversize", "sh-wrong-group",
                 "sh-and-more") or (psk is not None and s in ("resume-identity", "resume-hash", "resume-no-share")):
            return
        transcript += sh
        if s == "hrr-p256":
            shared = ec_key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), peer_point))
        else:
            shared = key.exchange(x25519.X25519PublicKey.from_public_bytes(share))
        early = schedule.extract(bytes(schedule.size), psk if psk is not None else bytes(schedule.size))
        hs = schedule.extract(schedule.derive(early, b"derived", b""), shared)
        c_hs = schedule.derive(hs, b"c hs traffic", transcript)
        s_hs = schedule.derive(hs, b"s hs traffic", transcript)
        writer = Cipher(schedule, s_hs)
        reader = Cipher(schedule, c_hs)
        if s == "ccs":
            self.sock.sendall(plain(20, b"\x01"))

        ee_ext = b""
        if s == "alpn" and "http/1.1" in alpn:
            ee_ext += ext(16, struct.pack(">H", 9) + b"\x08http/1.1")
        if s == "alpn-unoffered":
            ee_ext += ext(16, struct.pack(">H", 7) + b"\x06spdy/3")
        if s == "unsolicited-ext":
            ee_ext += ext(0xff01, b"")
        if s == "early-alpn" and alpn:
            # http/1.1 for the ticket, h2 for the connection that resumes.
            ee_ext += ext(16, struct.pack(">H", 9) + b"\x08http/1.1") if psk is None else ext(16, struct.pack(">H", 3) + b"\x02h2")
        if psk is not None and s == "early-small" and 42 in exts:
            self.sock.sendall(plain(21, bytes([2, 47])))
            return
        if psk is not None and s in ("early", "early-unoffered"):
            ee_ext += ext(42, b"")
        if s == "sni-ack-data":
            ee_ext += ext(0, b"\x00")
        messages = [message(8, struct.pack(">H", len(ee_ext)) + ee_ext)]
        if s == "certreq":
            messages.append(message(13, b"\x00" + struct.pack(">H", 8) + ext(13, struct.pack(">H", 2) + b"\x04\x03")))
        if s == "certreq-ed25519":
            messages.append(message(13, b"\x00" + struct.pack(">H", 10) + ext(13, struct.pack(">H", 4) + b"\x04\x03\x08\x07")))
        if s == "certreq-context":
            messages.append(message(13, b"\x02ab" + struct.pack(">H", 8) + ext(13, struct.pack(">H", 2) + b"\x04\x03")))
        if s == "certreq-no-sigalgs":
            messages.append(message(13, b"\x00" + struct.pack(">H", 4) + ext(0xff02, b"")))
        kind = {"rsa": "rsa", "cv-pkcs1": "rsa", "p384": "p384", "cv-wrong-curve": "p384", "ed25519": "ed25519",
                "bad-cv-ed25519": "ed25519"}.get(s, "p256")
        leaf = {"wrong-host": self.pki.wrong_host, "expired": self.pki.expired, "untrusted": self.pki.untrusted,
                "ku-no-sign": self.pki.no_sign}.get(s, self.pki.leaves[kind])
        sent = (leaf, self.pki.inter) * (6 if s == "cert-many" else 1)
        entry_ext = b"\x00\x04" + ext(5, b"") if s == "cert-entry-ext" else b"\x00\x00"
        entries = b"" if s == "cert-empty" else b"".join(len(der(c)).to_bytes(3, "big") + der(c) + entry_ext for c in sent)
        messages.append(message(11, b"\x00" + len(entries).to_bytes(3, "big") + entries))
        if s == "cert-empty":
            messages.append(message(15, b"\x04\x03\x00\x00"))
        else:
            transcript_cv = transcript + b"".join(messages)
            signed = b" " * 64 + b"TLS 1.3, server CertificateVerify\x00" + schedule.digest(transcript_cv)
            k = self.pki.keys[kind]
            if kind == "rsa" and s == "cv-pkcs1":
                scheme, sig = 0x0401, k.sign(signed, padding.PKCS1v15(), hashes.SHA256())
            elif kind == "rsa":
                scheme, sig = 0x0804, k.sign(signed, padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32), hashes.SHA256())
            elif kind == "p384" and s != "cv-wrong-curve":
                scheme, sig = 0x0503, k.sign(signed, ec.ECDSA(hashes.SHA384()))
            elif kind == "p384":
                scheme, sig = 0x0403, k.sign(signed, ec.ECDSA(hashes.SHA256()))
            elif kind == "ed25519":
                scheme, sig = 0x0807, k.sign(signed)
            elif s == "cv-ed25519-p256":
                scheme, sig = 0x0807, k.sign(signed, ec.ECDSA(hashes.SHA256()))
            else:
                scheme, sig = 0x0403, k.sign(signed, ec.ECDSA(hashes.SHA256()))
            if s in ("bad-cv", "bad-cv-ed25519"):
                sig = sig[:-1] + bytes([sig[-1] ^ 1])
            messages.append(message(15, struct.pack(">HH", scheme, len(sig)) + sig))
        if psk is not None and s != "resume-cert":
            # Resumed: EncryptedExtensions alone before Finished.
            messages = messages[:1]
        transcript += b"".join(messages)
        verify = schedule.finished(s_hs, transcript)
        if s == "bad-finished":
            verify = bytes([verify[0] ^ 1]) + verify[1:]
        finished = message(20, verify)
        transcript += finished
        flight = b"".join(messages) + finished
        if s == "app-data-in-handshake":
            self.sock.sendall(writer.seal(22, b"".join(messages)) + writer.seal(23, b"early"))
            return
        if s == "trailing-after-finished":
            self.sock.sendall(writer.seal(22, flight + message(4, b"\x00" * 13)))
            return
        if s == "fragmented":
            out = b""
            for m in messages + [finished]:
                if m[0] == 11:
                    half = len(m) // 2
                    out += writer.seal(22, m[:half]) + writer.seal(22, m[half:])
                else:
                    out += writer.seal(22, m)
            self.sock.sendall(out)
        else:
            self.sock.sendall(writer.seal(22, flight, corrupt=(s == "bad-record-mac")))
        if s in ("bad-finished", "bad-cv", "cv-pkcs1", "cv-wrong-curve", "unsolicited-ext", "alpn-unoffered",
                 "wrong-host", "untrusted", "expired", "bad-record-mac", "cert-empty", "certreq-no-sigalgs", "cert-many", "ku-no-sign",
                 "certreq-context", "cert-entry-ext", "sni-ack-data") or (psk is not None and s in ("resume-cert", "early-unoffered")):
            return

        master = schedule.extract(schedule.derive(hs, b"derived", b""), bytes(schedule.size))
        c_ap = schedule.derive(master, b"c ap traffic", transcript)
        s_ap = schedule.derive(master, b"s ap traffic", transcript)
        # The client's flight: its ChangeCipherSpec, then under c_hs.
        expected_client = transcript
        early_data = b""
        if psk is not None and s == "early":
            # The early data, under the client's early traffic keys over the
            # ClientHello, to EndOfEarlyData, which joins the transcript.
            early_reader = Cipher(schedule, schedule.derive(schedule.extract(bytes(schedule.size), psk), b"c e traffic", ch))
            while True:
                header, body = self.record()
                if header[0] == 20:
                    continue
                type_, data = early_reader.open(header, body)
                if type_ == 23:
                    early_data += data
                    continue
                assert type_ == 22 and data == message(5, b""), "no EndOfEarlyData after the early data"
                break
            expected_client += message(5, b"")
        # Early data refused: what does not open under the handshake keys
        # is passed over (section 4.2.10).
        skipping = psk is not None and 42 in exts and s != "early"
        answered = False
        verified = False
        # Alerts go under the server's application keys: its own Finished
        # switched them (section 7.3), and the client reads so.
        alert = lambda code: self.sock.sendall(Cipher(schedule, s_ap).seal(21, bytes([2, code])))
        pending = b""

        # The client's next handshake message, from as many records as it
        # takes, none past the 2^14 bytes of content section 5.1 allows.
        def next_message():
            nonlocal pending
            while len(pending) < 4 or len(pending) < 4 + int.from_bytes(pending[1:4], "big"):
                header, body = self.record()
                if header[0] == 20:
                    continue
                try:
                    type_, data = reader.open(header, body)
                except Exception:
                    if skipping:
                        continue
                    raise
                assert type_ == 22, f"a record of type {type_} in the client's flight"
                assert len(data) <= 16384, f"a record of {len(data)} bytes of content, past 2^14"
                pending += data
            size = 4 + int.from_bytes(pending[1:4], "big")
            out, pending = pending[:size], pending[size:]
            return out

        while True:
            content = next_message()
            if content[0] == 11 and s == "certreq-ed25519":
                # The identity's chain, its one certificate with no
                # extensions, under the request's empty context.
                own = der(self.pki.client)
                assert content == message(11, b"\x00" + (len(own) + 5).to_bytes(3, "big") + len(own).to_bytes(3, "big") + own + b"\x00\x00"), \
                    "the client's Certificate is not its identity's"
                expected_client += content
                answered = True
                continue
            if content[0] == 11:
                assert s == "certreq" and content[4:] == b"\x00\x00\x00\x00", "unexpected client Certificate"
                expected_client += content
                answered = True
                continue
            if content[0] == 15:
                assert s == "certreq-ed25519" and answered and not verified, "unexpected client CertificateVerify"
                scheme, size = struct.unpack(">HH", content[4:8])
                assert scheme == 0x0807 and size == len(content) - 8, "a client CertificateVerify not under ed25519"
                signed = b" " * 64 + b"TLS 1.3, client CertificateVerify\x00" + schedule.digest(expected_client)
                try:
                    self.pki.client_key.public_key().verify(content[8:], signed)
                except Exception:
                    alert(51)
                    return
                expected_client += content
                verified = True
                continue
            assert content[0] == 20
            # A CertificateRequest must be answered by a Certificate, if an
            # empty one (RFC 8446 section 4.4.2): certificate_required; a
            # certificate sent must be followed by its CertificateVerify.
            if s in ("certreq", "certreq-ed25519") and not answered:
                alert(116)
                return
            if s == "certreq-ed25519" and not verified:
                alert(10)
                return
            if content[4:] != schedule.finished(c_hs, expected_client):
                alert(51)
                return
            break
        writer = Cipher(schedule, s_ap)
        reader = Cipher(schedule, c_ap)
        if s == "ticket":
            self.sock.sendall(writer.seal(22, message(4, struct.pack(">IIB", 3600, 1, 4) + b"tick" + b"\x00\x04abcd\x00\x00")))
        if s == "ticket-bad":
            self.sock.sendall(writer.seal(22, message(4, struct.pack(">IIB", 3600, 1, 4) + b"tick" + b"\x00\x04ab")))
        if early_data:
            self.sock.sendall(writer.seal(23, b"early:" + early_data))
        if (s.startswith(("resume", "early")) and psk is None) or s in ("ticket-many", "ticket-huge"):
            # Real tickets: each PSK from the resumption master secret, over
            # the handshake to the client's Finished, and its nonce.
            res_master = schedule.derive(master, b"res master", expected_client + content)
            out = b""
            for i in range(20 if s == "ticket-many" else 1):
                nonce = struct.pack(">Q", i)
                ticket = os.urandom(16385 if s == "ticket-huge" else 32)
                age_add = int.from_bytes(os.urandom(4), "big")
                TICKETS[ticket] = (schedule.expand_label(res_master, b"resumption", nonce, schedule.size), suite, age_add, time.monotonic())
                allows = {"early-small": 4, "early-unoffered": 0}.get(s, 1024 if s.startswith("early") else 0)
                extensions = ext(42, struct.pack(">I", allows)) if allows else b""
                nst = message(4, struct.pack(">IIB", 3600, age_add, len(nonce)) + nonce + struct.pack(">H", len(ticket)) + ticket +
                              struct.pack(">H", len(extensions)) + extensions)
                for k in range(0, len(nst), 16384):
                    out += writer.seal(22, nst[k:k + 16384])
            self.sock.sendall(out)
        header, body = self.record()
        type_, data = reader.open(header, body)
        assert type_ == 23
        if s == "keyupdate-bad":
            self.sock.sendall(writer.seal(22, message(24, b"\x02")))
            return
        def next_key(secret):
            return schedule.expand_label(secret, b"traffic upd", b"", schedule.size)

        if s == "keyupdate":
            # Asked once the client has written: the server's keys move at
            # once and the echo goes under them. The client's KeyUpdate is
            # owed before its next application data (section 4.6.3), so it
            # comes with the client's second write, not its reads.
            self.sock.sendall(writer.seal(22, message(24, b"\x01")))
            s_ap = next_key(s_ap)
            writer = Cipher(schedule, s_ap)
            self.sock.sendall(writer.seal(23, b"echo:" + data))
            header, body = self.record()
            type_, content = reader.open(header, body)
            assert type_ == 22 and content == message(24, b"\x00"), "no KeyUpdate before the client's next data"
            c_ap = next_key(c_ap)
            reader = Cipher(schedule, c_ap)
            header, body = self.record()
            type_, data = reader.open(header, body)
            assert type_ == 23, "the client's second write is not application data"
            self.sock.sendall(writer.seal(23, b"echo:" + data))
            self.sock.sendall(writer.seal(21, b"\x01\x00"))
            return
        if s == "user-canceled":
            self.sock.sendall(writer.seal(21, b"\x01\x5a"))
        if s == "slow-echo":
            # Past the client's read timeout: its first read times out, and
            # the same connection reads the echo after.
            time.sleep(1.5)
        if s == "client-rekey":
            # Everything the client writes, its KeyUpdates taken as they
            # come - two at its key limit of two records, then one asking
            # for this side's, which is answered - and counted in the echo.
            updates = asked = 0
            while True:
                header, body = self.record()
                type_, content = reader.open(header, body)
                if type_ == 22:
                    assert content[0] == 24 and len(content) == 5, "a handshake message that is not a KeyUpdate"
                    c_ap = next_key(c_ap)
                    reader = Cipher(schedule, c_ap)
                    if content[4] == 1:
                        asked += 1
                        self.sock.sendall(writer.seal(22, message(24, b"\x00")))
                        s_ap = next_key(s_ap)
                        writer = Cipher(schedule, s_ap)
                        break
                    updates += 1
                    continue
                assert type_ == 23
                data += content
            data += f" keyupdates={updates} asked={asked}".encode()
        if s in ("padded-max", "padded-over"):
            echo = b"echo:" + data
            pad = 16384 + 1 - len(echo) - 1 + (1 if s == "padded-over" else 0)
            self.sock.sendall(writer.seal(23, echo, pad=pad))
            self.sock.sendall(writer.seal(21, b"\x01\x00"))
            return
        if s in ("split-by-data", "split-by-close"):
            # Section 5.1: no record of another type between a handshake
            # message's pieces.
            ticket = message(4, struct.pack(">IIB", 3600, 1, 4) + b"tick" + b"\x00\x04abcd\x00\x00")
            self.sock.sendall(writer.seal(22, ticket[:6]))
            if s == "split-by-close":
                self.sock.sendall(writer.seal(21, b"\x01\x00"))
                return
            self.sock.sendall(writer.seal(23, b"echo:" + data))
            self.sock.sendall(writer.seal(22, ticket[6:]))
            self.sock.sendall(writer.seal(21, b"\x01\x00"))
            return
        if s == "big":
            payload = b"echo:" + data + bytes(i % 251 for i in range(40000 - 5 - len(data)))
            for k in range(0, len(payload), 16384):
                self.sock.sendall(writer.seal(23, payload[k:k + 16384]))
        else:
            self.sock.sendall(writer.seal(23, b"echo:" + data))
        self.sock.sendall(writer.seal(21, b"\x01\x00"))

    def judge_psk(self, ch, exts):
        """A resumption's ClientHello, judged: its pre_shared_key last and
        offering one ticket this server issued, psk_dhe_ke its one mode, the
        ticket's age as the client gives it within a second of the time
        since it went, and its binder over the ClientHello to the binders.
        The PSK, or the alert a failure sends."""
        data = exts[41]
        if not ch.endswith(ext(41, data)) or exts.get(45) != b"\x01\x01":
            return 47
        size = int.from_bytes(data[:2], "big")
        identities, binders = data[2:2 + size], data[2 + size:]
        length = int.from_bytes(identities[:2], "big")
        ticket, obfuscated = identities[2:2 + length], int.from_bytes(identities[2 + length:6 + length], "big")
        if len(identities) != 6 + length or ticket not in TICKETS:
            return 47
        secret, suite, age_add, when = TICKETS[ticket]
        age = (obfuscated - age_add) % (1 << 32)
        elapsed = (time.monotonic() - when) * 1000
        if not elapsed - 1000 <= age <= elapsed + 1000:
            return 47
        schedule = Schedule(suite)
        binder_key = schedule.derive(schedule.extract(bytes(schedule.size), secret), b"res binder", b"")
        if binders != struct.pack(">HB", 1 + schedule.size, schedule.size) + schedule.finished(binder_key, ch[:len(ch) - len(binders)]):
            return 51
        return secret


def main():
    work = sys.argv[1]
    pki = Pki()
    with open(os.path.join(work, "roots.pem"), "wb") as f:
        f.write(pki.root.public_bytes(serialization.Encoding.PEM))
    with open(os.path.join(work, "client.pem"), "wb") as f:
        f.write(pki.client.public_bytes(serialization.Encoding.PEM))
    with open(os.path.join(work, "client.key"), "wb") as f:
        f.write(pki.client_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                             serialization.NoEncryption()))
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(16)
    with open(os.path.join(work, "port"), "w") as f:
        f.write(str(server.getsockname()[1]))
    while True:
        sock, _ = server.accept()
        sock.settimeout(10)
        try:
            Conn(sock, pki).serve()
        except Exception as e:
            print(f"server: {type(e).__name__}: {e}", file=sys.stderr)
        finally:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()


if __name__ == "__main__":
    main()
