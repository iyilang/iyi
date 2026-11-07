"""An HPKE (RFC 9180) for bench/std_hpke_exercise.sh to hold std/hpke to.

    python3 bench/std_hpke_oracle.py vectors VECTORS.json   # itself, against RFC 9180's vectors
    python3 bench/std_hpke_oracle.py drive ORACLE [ROUNDS]   # std/hpke's oracle mode, both ways
    python3 bench/std_hpke_oracle.py answers                # the known answers the exercise embeds

Written from the RFC's pseudocode and nothing of std/hpke's, over the
primitives of Python's `cryptography` (OpenSSL underneath): X25519, ECDH on
P-256 and P-384, HMAC with SHA-256, -384 and -512, AES-GCM and
ChaCha20-Poly1305. `cryptography` has no HPKE of its own. The labeled
steps, DeriveKeyPair's rejection sampling, the KEMs, the key schedule, the
nonces and the exports are this file's, so before it is believed it is run
over the same RFC vectors std/hpke is (`vectors`).

`drive` starts the exercise's oracle mode and, for every one of the 144
suites and modes, derives the same key pairs on both sides, seals the same
messages from the same ephemeral randomness (so the encapsulations,
ciphertexts and exports must be byte for byte the same), opens what the
other sealed from randomness of its own, and asks both to refuse a changed
ciphertext, an X25519 encapsulation of small order and a P-256 or P-384
point off its curve. Exits 1 on any difference.
"""

import hashlib
import json
import os
import random
import subprocess
import sys

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, hmac, serialization
from cryptography.hazmat.primitives.asymmetric import ec, x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

KEMS = {
    0x0010: dict(name="P-256", curve=ec.SECP256R1, hash=hashes.SHA256, nsecret=32, npk=65, nsk=32,
                 order=0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551),
    0x0011: dict(name="P-384", curve=ec.SECP384R1, hash=hashes.SHA384, nsecret=48, npk=97, nsk=48,
                 order=0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973),
    0x0020: dict(name="X25519", curve=None, hash=hashes.SHA256, nsecret=32, npk=32, nsk=32, order=None),
}
KDFS = {1: hashes.SHA256, 2: hashes.SHA384, 3: hashes.SHA512}
AEADS = {1: (AESGCM, 16), 2: (AESGCM, 32), 3: (ChaCha20Poly1305, 32), 0xFFFF: (None, 0)}
MODES = ("base", "psk", "auth", "auth_psk")


class Refused(Exception):
    pass


def i2osp(n, size):
    return n.to_bytes(size, "big")


def extract(hash_, salt, ikm):
    mac = hmac.HMAC(salt, hash_())
    mac.update(ikm)
    return mac.finalize()


def expand(hash_, prk, info, length):
    out, block, n = b"", b"", 1
    while len(out) < length:
        mac = hmac.HMAC(prk, hash_())
        mac.update(block + info + bytes([n]))
        block = mac.finalize()
        out += block
        n += 1
    return out[:length]


def labeled_extract(hash_, suite_id, salt, label, ikm):
    return extract(hash_, salt, b"HPKE-v1" + suite_id + label + ikm)


def labeled_expand(hash_, suite_id, prk, label, info, length):
    return expand(hash_, prk, i2osp(length, 2) + b"HPKE-v1" + suite_id + label + info, length)


class Key:
    """A KEM key pair: the serialised private and public keys, and the
    `cryptography` object that does the Diffie-Hellman."""

    def __init__(self, kem, secret):
        self.kem = kem
        k = KEMS[kem]
        if k["curve"] is None:
            clamped = bytearray(secret)
            clamped[0] &= 248
            clamped[31] = (clamped[31] & 127) | 64
            self.sk = bytes(clamped)
            self.obj = x25519.X25519PrivateKey.from_private_bytes(self.sk)
            self.pk = self.obj.public_key().public_bytes_raw()
        else:
            d = int.from_bytes(secret, "big")
            if not 0 < d < k["order"]:
                raise Refused(f"a {k['name']} private key out of range")
            self.sk = bytes(secret)
            self.obj = ec.derive_private_key(d, k["curve"]())
            self.pk = self.obj.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)

    def dh(self, peer):
        k = KEMS[self.kem]
        if len(peer) != k["npk"]:
            raise Refused(f"a {k['name']} public key is {k['npk']} bytes, not {len(peer)}")
        try:
            if k["curve"] is None:
                out = self.obj.exchange(x25519.X25519PublicKey.from_public_bytes(peer))
            else:
                out = self.obj.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(k["curve"](), peer))
        except ValueError as e:
            raise Refused(str(e))
        if out == bytes(len(out)):
            raise Refused("an all-zero shared secret")
        return out


def check_public(kem, pk):
    k = KEMS[kem]
    if len(pk) != k["npk"]:
        raise Refused("wrong length")
    if k["curve"] is not None:
        try:
            ec.EllipticCurvePublicKey.from_encoded_point(k["curve"](), pk)
        except ValueError as e:
            raise Refused(str(e))
    return pk


def derive_key_pair(kem, ikm):
    k = KEMS[kem]
    suite_id = b"KEM" + i2osp(kem, 2)
    prk = labeled_extract(k["hash"], suite_id, b"", b"dkp_prk", ikm)
    if k["curve"] is None:
        return Key(kem, labeled_expand(k["hash"], suite_id, prk, b"sk", b"", k["nsk"]))
    for counter in range(256):
        candidate = bytearray(labeled_expand(k["hash"], suite_id, prk, b"candidate", bytes([counter]), k["nsk"]))
        candidate[0] &= 0xFF
        if 0 < int.from_bytes(candidate, "big") < k["order"]:
            return Key(kem, bytes(candidate))
    raise Refused("DeriveKeyPairError")


def extract_and_expand(kem, dh, kem_context):
    k = KEMS[kem]
    suite_id = b"KEM" + i2osp(kem, 2)
    prk = labeled_extract(k["hash"], suite_id, b"", b"eae_prk", dh)
    return labeled_expand(k["hash"], suite_id, prk, b"shared_secret", kem_context, k["nsecret"])


def encap(kem, pk_r, ikm_e, sender=None):
    eph = derive_key_pair(kem, ikm_e)
    dh = eph.dh(pk_r)
    context = eph.pk + pk_r
    if sender is not None:
        dh += sender.dh(pk_r)
        context += sender.pk
    return eph.pk, extract_and_expand(kem, dh, context)


def decap(kem, key, enc, pk_s=None):
    dh = key.dh(enc)
    context = enc + key.pk
    if pk_s is not None:
        dh += key.dh(pk_s)
        context += pk_s
    return extract_and_expand(kem, dh, context)


class Context:
    def __init__(self, kem, kdf, aead, mode, shared, info, psk, psk_id):
        if (psk == b"") != (psk_id == b"") or (psk != b"") != (mode in (1, 3)):
            raise Refused("VerifyPSKInputs")
        h = KDFS[kdf]
        suite_id = b"HPKE" + i2osp(kem, 2) + i2osp(kdf, 2) + i2osp(aead, 2)
        context = bytes([mode]) + labeled_extract(h, suite_id, b"", b"psk_id_hash", psk_id) + labeled_extract(h, suite_id, b"", b"info_hash", info)
        secret = labeled_extract(h, suite_id, shared, b"secret", psk)
        cls, nk = AEADS[aead]
        nn = 0 if cls is None else 12
        self.key = labeled_expand(h, suite_id, secret, b"key", context, nk)
        self.base_nonce = labeled_expand(h, suite_id, secret, b"base_nonce", context, nn)
        self.exporter_secret = labeled_expand(h, suite_id, secret, b"exp", context, h.digest_size)
        self.box = None if cls is None else cls(self.key)
        self.h, self.suite_id, self.seq = h, suite_id, 0

    def nonce(self):
        if self.seq >= (1 << 96) - 1:
            raise Refused("MessageLimitReachedError")
        return bytes(a ^ b for a, b in zip(self.base_nonce, i2osp(self.seq, 12)))

    def seal(self, aad, pt):
        ct = self.box.encrypt(self.nonce(), pt, aad)
        self.seq += 1
        return ct

    def open(self, aad, ct):
        try:
            pt = self.box.decrypt(self.nonce(), ct, aad)
        except InvalidTag:
            raise Refused("OpenError")
        self.seq += 1
        return pt

    def export(self, context, length):
        return labeled_expand(self.h, self.suite_id, self.exporter_secret, b"sec", context, length)


def setup_s(kem, kdf, aead, mode, pk_r, info, ikm_e, psk=b"", psk_id=b"", sender=None):
    enc, shared = encap(kem, pk_r, ikm_e, sender)
    return enc, shared, Context(kem, kdf, aead, mode, shared, info, psk, psk_id)


def setup_r(kem, kdf, aead, mode, key, enc, info, psk=b"", psk_id=b"", pk_s=None):
    k = KEMS[kem]
    if len(enc) != k["npk"]:
        raise Refused("an encapsulation of the wrong length")
    check_public(kem, enc)
    shared = decap(kem, key, enc, pk_s)
    return Context(kem, kdf, aead, mode, shared, info, psk, psk_id)


def h(data):
    return data.hex() if data else "-"


def vectors(path):
    """Itself against the vectors as bench/std_hpke_exercise.sh cuts them."""
    cases = json.load(open(path))
    sealed = exported = 0
    for n, c in enumerate(cases):
        kem, kdf, aead, mode = c["kem_id"], c["kdf_id"], c["aead_id"], c["mode"]
        what = f"vector {n} ({MODES[mode]}, kem {kem:#06x}, kdf {kdf:#06x}, aead {aead:#06x})"
        g = lambda f: bytes.fromhex(c.get(f, ""))
        key_r, key_e = derive_key_pair(kem, g("ikmR")), derive_key_pair(kem, g("ikmE"))
        key_s = derive_key_pair(kem, g("ikmS")) if mode >= 2 else None
        if key_r.pk != g("pkRm") or key_e.pk != g("pkEm") or (key_s and key_s.pk != g("pkSm")):
            raise SystemExit(f"  FAIL the Python HPKE, {what}: the key pairs")
        enc, shared, ctx = setup_s(kem, kdf, aead, mode, key_r.pk, g("info"), g("ikmE"), g("psk"), g("psk_id"), key_s)
        if enc != g("enc") or shared != g("shared_secret") or ctx.key != g("key") or ctx.base_nonce != g("base_nonce"):
            raise SystemExit(f"  FAIL the Python HPKE, {what}: the encapsulation or the key schedule")
        rctx = setup_r(kem, kdf, aead, mode, key_r, enc, g("info"), g("psk"), g("psk_id"), key_s.pk if key_s else None)
        listed = {e["seq"]: e for e in c["encryptions"]}
        digest = hashlib.sha256()
        for i in range(c["count"]):
            pt, aad = bytes.fromhex(c["encryptions"][0]["pt"]), b"Count-%d" % i
            ct = ctx.seal(aad, pt)
            digest.update(ct)
            if (i in listed and ct.hex() != listed[i]["ct"]) or rctx.open(aad, ct) != pt:
                raise SystemExit(f"  FAIL the Python HPKE, {what}: encryption {i}")
        if digest.hexdigest() != c["ciphertexts_sha256"]:
            raise SystemExit(f"  FAIL the Python HPKE, {what}: the ciphertexts' SHA-256")
        for e in c["exports"]:
            context = bytes.fromhex(e["exporter_context"])
            if ctx.export(context, e["L"]).hex() != e["exported_value"] or rctx.export(context, e["L"]).hex() != e["exported_value"]:
                raise SystemExit(f"  FAIL the Python HPKE, {what}: an export")
        sealed += c["count"]
        exported += len(c["exports"])
    print(f"  the Python HPKE passes {len(cases)} vectors itself: {sealed} encryptions, {exported} exports")


def drive(oracle_bin, rounds):
    oracle_bin += ".exe" if not os.path.exists(oracle_bin) and os.path.exists(oracle_bin + ".exe") else ""
    oracle = subprocess.Popen([oracle_bin, "oracle"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

    def ask(*words):
        oracle.stdin.write(" ".join(str(w) for w in words) + "\n")
        oracle.stdin.flush()
        return oracle.stdout.readline().strip()

    failed = 0

    def fail(what):
        nonlocal failed
        failed += 1
        if failed <= 10:
            print("  FAIL " + what)

    rnd = random.SystemRandom()
    count = messages = refusals = 0
    for kem in KEMS:
        nsk = KEMS[kem]["nsk"]
        for kdf in KDFS:
            for aead in AEADS:
                for mode in range(4):
                    for r in range(rounds):
                        what = f"kem {kem:#06x}, kdf {kdf}, aead {aead:#06x}, {MODES[mode]}, round {r}"
                        ikm = {x: os.urandom(nsk + rnd.choice((0, 0, 1, 16))) for x in "RSE"}
                        keys = {x: derive_key_pair(kem, ikm[x]) for x in "RS"}
                        for x in "RS":
                            if ask("k", kem, ikm[x].hex()) != f"{keys[x].sk.hex()} {keys[x].pk.hex()}":
                                fail(f"{what}: DeriveKeyPair of ikm{x}")
                        info = os.urandom(rnd.choice((0, 1, 20, 77)))
                        psk, psk_id = (os.urandom(rnd.choice((32, 48))), os.urandom(rnd.choice((1, 16)))) if mode in (1, 3) else (b"", b"")
                        sender = keys["S"] if mode >= 2 else None
                        context, length = os.urandom(rnd.choice((0, 3, 40))), rnd.choice((1, 32, 64, 255 * KDFS[kdf].digest_size))
                        plain = [] if aead == 0xFFFF else [(os.urandom(rnd.choice((0, 5, 30))), os.urandom(rnd.choice((0, 1, 16, 17, 1024, rnd.randrange(3000)))))
                                                          for _ in range(rnd.randrange(1, 5))]
                        msgs = ",".join(f"{a.hex()}.{p.hex()}" for a, p in plain) or "-"
                        # The same ephemeral randomness at both ends: every byte the same.
                        enc, _, ctx = setup_s(kem, kdf, aead, mode, keys["R"].pk, info, ikm["E"], psk, psk_id, sender)
                        mine = f"{enc.hex()} {ctx.export(context, length).hex()} " + (",".join(ctx.seal(a, p).hex() for a, p in plain) or "-")
                        sks = sender.sk.hex() if sender else "-"
                        got = ask("s", kem, kdf, aead, keys["R"].pk.hex(), h(info), ikm["E"].hex(), h(psk), h(psk_id), sks, h(context), length, msgs)
                        if got != mine:
                            fail(f"{what}: iyi sealed {got[:40]!r}..., Python {mine[:40]!r}...")
                        # iyi seals from randomness of its own; Python opens.
                        ikm2 = os.urandom(nsk)
                        got = ask("s", kem, kdf, aead, keys["R"].pk.hex(), h(info), ikm2.hex(), h(psk), h(psk_id), sks, h(context), length, msgs).split()
                        try:
                            rctx = setup_r(kem, kdf, aead, mode, keys["R"], bytes.fromhex(got[0]), info, psk, psk_id, sender.pk if sender else None)
                            cts = [] if got[2] == "-" else [bytes.fromhex(x) for x in got[2].split(",")]
                            if [rctx.open(a, ct) for (a, _), ct in zip(plain, cts)] != [p for _, p in plain] or rctx.export(context, length).hex() != got[1]:
                                fail(f"{what}: Python opened iyi's messages to other plaintexts or exported another secret")
                        except (Refused, IndexError, ValueError) as e:
                            fail(f"{what}: Python could not open what iyi sealed: {e} ({' '.join(got)[:60]})")
                            continue
                        # Python seals from randomness of its own; iyi opens.
                        enc3, _, ctx3 = setup_s(kem, kdf, aead, mode, keys["R"].pk, info, os.urandom(nsk), psk, psk_id, sender)
                        cts3 = [ctx3.seal(a, p) for a, p in plain]
                        sealed = ",".join(f"{a.hex()}.{ct.hex()}" for (a, _), ct in zip(plain, cts3)) or "-"
                        pks = sender.pk.hex() if sender else "-"
                        want = f"{ctx3.export(context, length).hex()} " + (",".join(h(p) for _, p in plain) or "-")
                        got = ask("o", kem, kdf, aead, keys["R"].sk.hex(), enc3.hex(), h(info), h(psk), h(psk_id), pks, h(context), length, sealed)
                        if got != want:
                            fail(f"{what}: iyi opened Python's messages as {got[:40]!r}..., not {want[:40]!r}...")
                        # A changed byte in the last message: refused by both.
                        if cts3:
                            bad = bytearray(cts3[-1])
                            bad[rnd.randrange(len(bad))] ^= 1 << rnd.randrange(8)
                            changed = sealed.rsplit(".", 1)[0] + "." + bytes(bad).hex()
                            mine = ask("o", kem, kdf, aead, keys["R"].sk.hex(), enc3.hex(), h(info), h(psk), h(psk_id), pks, h(context), length, changed)
                            rctx = setup_r(kem, kdf, aead, mode, keys["R"], enc3, info, psk, psk_id, sender.pk if sender else None)
                            try:
                                for (a, _), ct in zip(plain[:-1], cts3[:-1]):
                                    rctx.open(a, ct)
                                rctx.open(plain[-1][0], bytes(bad))
                                theirs = "took it"
                            except Refused:
                                theirs = "refused"
                            if not mine.startswith(f"refused: message {len(cts3) - 1}:") or theirs != "refused":
                                fail(f"{what}: a changed ciphertext: iyi {mine[:50]!r}, Python {theirs}")
                            refusals += 1
                        count += 1
                        messages += len(plain)
    # Encapsulations both refuse: X25519 of small order, P-256 and P-384
    # points off their curves.
    for kem, enc in [(0x20, bytes(32)), (0x20, b"\x01" + bytes(31)),
                     (0x10, b"\x04" + bytes(64)), (0x11, b"\x04" + bytes(96))]:
        key = derive_key_pair(kem, os.urandom(KEMS[kem]["nsk"]))
        mine = ask("o", kem, 1, 1, key.sk.hex(), enc.hex(), "-", "-", "-", "-", "-", 16, "-")
        try:
            setup_r(kem, 1, 1, 0, key, enc, b"")
            theirs = "took it"
        except Refused:
            theirs = "refused"
        if not mine.startswith("refused:") or theirs != "refused":
            fail(f"kem {kem:#06x}: the encapsulation {enc.hex()[:16]}...: iyi {mine[:50]!r}, Python {theirs}")
        if kem != 0x20 and not ask("p", kem, enc.hex()).startswith("refused:"):
            fail(f"kem {kem:#06x}: a public key off the curve taken")
        refusals += 1
    oracle.stdin.close()
    oracle.wait()
    import cryptography
    print(f"  cryptography {cryptography.__version__}: {count} round trips over 36 suites in 4 modes, {messages} messages,"
          f" the same bytes from the same randomness, each side opening the other's; {refusals} refusals alike")
    return 1 if failed else 0


def answers():
    """Known answers for what RFC 9180 has no vectors for: DHKEM(P-384) and
    HKDF-SHA384. Deterministic, from SHA-256 of labels, in the shape the
    gate cuts the RFC's vectors to."""
    out = []
    for mode, kem, kdf, aead in [(3, 0x11, 2, 2), (2, 0x20, 2, 3), (1, 0x11, 3, 0xFFFF)]:
        nsk = KEMS[kem]["nsk"]
        tag = f"std/hpke {mode} {kem} {kdf} {aead}"
        draw = lambda what, size: hashlib.shake_256(f"{tag} {what}".encode()).digest(size)
        ikm = {x: draw("ikm" + x, nsk) for x in "RES"}
        keys = {x: derive_key_pair(kem, ikm[x]) for x in "RES"}
        info = b"Ode on a Grecian Urn"
        psk, psk_id = (draw("psk", 32), b"Ennyn Durin aran Moria") if mode in (1, 3) else (b"", b"")
        sender = keys["S"] if mode >= 2 else None
        enc, shared, ctx = setup_s(kem, kdf, aead, mode, keys["R"].pk, info, ikm["E"], psk, psk_id, sender)
        case = dict(mode=mode, kem_id=kem, kdf_id=kdf, aead_id=aead, info=info.hex(), ikmR=ikm["R"].hex(), ikmE=ikm["E"].hex())
        if sender:
            case["ikmS"] = ikm["S"].hex()
        for x in "RES":
            if x != "S" or sender:
                case[f"sk{x}m"], case[f"pk{x}m"] = keys[x].sk.hex(), keys[x].pk.hex()
        if psk:
            case["psk"], case["psk_id"] = psk.hex(), psk_id.hex()
        case.update(enc=enc.hex(), shared_secret=shared.hex(), key=ctx.key.hex(), base_nonce=ctx.base_nonce.hex())
        pt = b"Beauty is truth, truth beauty"
        sealed = [] if aead == 0xFFFF else [(b"Count-%d" % i, ctx.seal(b"Count-%d" % i, pt)) for i in range(257)]
        case["count"] = len(sealed)
        case["ciphertexts_sha256"] = hashlib.sha256(b"".join(ct for _, ct in sealed)).hexdigest()
        case["encryptions"] = [dict(aad=a.hex(), ct=ct.hex(), nonce=bytes(x ^ y for x, y in zip(ctx.base_nonce, i2osp(i, 12))).hex(), pt=pt.hex(), seq=i)
                               for i, (a, ct) in enumerate(sealed) if i in (0, 1, 2, 255, 256)]
        case["exports"] = [dict(L=32, exported_value=ctx.export(c, 32).hex(), exporter_context=c.hex()) for c in (b"", b"\x00", b"TestContext")]
        out.append(case)
    print("[\n" + ",\n".join(json.dumps(c, separators=(",", ":")) for c in out) + "\n]")


if __name__ == "__main__":
    if sys.argv[1] == "vectors":
        vectors(sys.argv[2])
    elif sys.argv[1] == "drive":
        sys.exit(drive(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 2))
    elif sys.argv[1] == "answers":
        answers()
