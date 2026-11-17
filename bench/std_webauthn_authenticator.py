#!/usr/bin/env python3
"""Create WebAuthn ceremonies and targeted refusals using cryptography.

Usage: python3 bench/std_webauthn_authenticator.py 100 > cases.jsonl
The output is a JSON line per ceremony. No network or persistent key is used.
"""
import base64
import copy
import datetime
import hashlib
import json
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa
from cryptography.x509.oid import NameOID


def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def cbor_head(major, number):
    if number < 24:
        return bytes([major * 32 + number])
    if number < 256:
        return bytes([major * 32 + 24, number])
    if number < 65536:
        return bytes([major * 32 + 25]) + number.to_bytes(2, "big")
    if number < 2**32:
        return bytes([major * 32 + 26]) + number.to_bytes(4, "big")
    return bytes([major * 32 + 27]) + number.to_bytes(8, "big")


def cbor(value):
    if isinstance(value, int):
        return cbor_head(0, value) if value >= 0 else cbor_head(1, -1 - value)
    if isinstance(value, bytes):
        return cbor_head(2, len(value)) + value
    if isinstance(value, str):
        data = value.encode()
        return cbor_head(3, len(data)) + data
    if isinstance(value, list):
        return cbor_head(4, len(value)) + b"".join(map(cbor, value))
    if isinstance(value, dict):
        return cbor_head(5, len(value)) + b"".join(cbor(k) + cbor(v) for k, v in value.items())
    raise TypeError(type(value))


def key_new(alg):
    if alg == -7:
        return ec.generate_private_key(ec.SECP256R1())
    if alg == -257:
        return rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return ed25519.Ed25519PrivateKey.generate()


def cose_key(key, alg):
    public = key.public_key()
    if alg == -7:
        p = public.public_numbers()
        return {1: 2, 3: alg, -1: 1, -2: p.x.to_bytes(32, "big"), -3: p.y.to_bytes(32, "big")}
    if alg == -257:
        p = public.public_numbers()
        return {1: 3, 3: alg, -1: p.n.to_bytes((p.n.bit_length() + 7) // 8, "big"), -2: p.e.to_bytes((p.e.bit_length() + 7) // 8, "big")}
    return {1: 1, 3: alg, -1: 6, -2: public.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)}


def sign(key, alg, message):
    if alg == -7:
        return key.sign(message, ec.ECDSA(hashes.SHA256()))
    if alg == -257:
        return key.sign(message, padding.PKCS1v15(), hashes.SHA256())
    return key.sign(message)


def certificate(key, alg, ou="Authenticator Attestation", aaguid=None, critical=False):
    name = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Software Authenticator"),
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, ou),
        x509.NameAttribute(NameOID.COMMON_NAME, "Test attestation"),
    ])
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now - datetime.timedelta(days=1))
               .not_valid_after(now + datetime.timedelta(days=1))
               .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True))
    if aaguid is not None:
        oid = x509.ObjectIdentifier("1.3.6.1.4.1.45724.1.1.4")
        builder = builder.add_extension(x509.UnrecognizedExtension(oid, b"\x04\x10" + aaguid), critical=critical)
    return builder.sign(key, None if alg == -8 else hashes.SHA256()).public_bytes(serialization.Encoding.DER)


def client(kind, challenge, origin, **fields):
    return json.dumps({"type": kind, "challenge": challenge, "origin": origin, "crossOrigin": False, **fields}, separators=(",", ":")).encode()


def reg_auth(rp, ident, public_key, flags=0x45, count=0):
    return hashlib.sha256(rp.encode()).digest() + bytes([flags]) + count.to_bytes(4, "big") + bytes(16) + len(ident).to_bytes(2, "big") + ident + cbor(public_key)


def response(ident, payload):
    s = b64(ident)
    return {"id": s, "rawId": s, "type": "public-key", "response": payload}


def make_case(key, alg, fmt, serial):
    challenge, assertion_challenge = b64(os.urandom(32)), b64(os.urandom(32))
    origin, rp, ident, handle = "https://example.org", "example.org", os.urandom(32), b"user-17"
    pub = cose_key(key, alg)
    reg_client = client("webauthn.create", challenge, origin)
    auth = reg_auth(rp, ident, pub)
    statement = {}
    if fmt == "packed":
        statement = {"alg": alg, "sig": sign(key, alg, auth + hashlib.sha256(reg_client).digest())}
    elif fmt == "packed-x5c":
        statement = {"alg": alg, "sig": sign(key, alg, auth + hashlib.sha256(reg_client).digest()), "x5c": [certificate(key, alg)]}
    att = {"fmt": "packed" if fmt.startswith("packed") else fmt, "authData": auth, "attStmt": statement}
    assertion_client = client("webauthn.get", assertion_challenge, origin)
    assertion_auth = hashlib.sha256(rp.encode()).digest() + b"\x05" + (1).to_bytes(4, "big")
    assertion_sig = sign(key, alg, assertion_auth + hashlib.sha256(assertion_client).digest())
    record = {"name": f"{serial}/{alg}/{fmt}", "challenge": challenge, "assertion_challenge": assertion_challenge,
              "rp_id": rp, "origin": origin, "policy": "verify", "user_verification": True,
              "registration": response(ident, {"clientDataJSON": b64(reg_client), "attestationObject": b64(cbor(att))}),
              "assertion": response(ident, {"clientDataJSON": b64(assertion_client), "authenticatorData": b64(assertion_auth), "signature": b64(assertion_sig), "userHandle": b64(handle)}),
              "user_handle": b64(handle), "reg_error": "", "assert_error": ""}
    return record, auth, att, pub, reg_client


def negatives(key, alg, baseline, auth, att, pub, reg_client):
    def emit(name, stage, kind, check, mutate):
        case = copy.deepcopy(baseline)
        case["name"] = name
        mutate(case)
        case[stage + "_error"] = kind + "/" + check
        print(json.dumps(case, separators=(",", ":")))

    def reg_client_set(case, body):
        case["registration"]["response"]["clientDataJSON"] = b64(body)
    def reg_object(case, obj):
        case["registration"]["response"]["attestationObject"] = b64(cbor(obj))
    def reg_auth_set(case, data):
        obj = copy.deepcopy(att)
        obj["authData"] = data
        reg_object(case, obj)
    def auth_set(case, data):
        case["assertion"]["response"]["authenticatorData"] = b64(data)
    def auth_raw(case):
        s = case["assertion"]["response"]["authenticatorData"]
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    def alter_client(case, **changes):
        payload = json.loads(reg_client)
        payload.update(changes)
        reg_client_set(case, json.dumps(payload, separators=(",", ":")).encode())
    def with_auth_flags(case, flags, tail=b""):
        reg_auth_set(case, auth[:32] + bytes([flags]) + auth[33:] + tail)
    def bad_key(case, keymap):
        reg_auth_set(case, auth[:55 + 32] + cbor(keymap))
    def change_credential(case, stage):
        case[stage]["id"] = case[stage]["rawId"] = b64(b"other credential")
    def assertion_flags(case, flags, tail=b""):
        data = auth_raw(case)
        auth_set(case, data[:32] + bytes([flags]) + data[33:] + tail)

    emit("base64url alphabet", "reg", "malformed", "encoding", lambda c: c["registration"]["response"].update(attestationObject="+"))
    emit("base64url padding", "reg", "malformed", "encoding", lambda c: c["registration"]["response"].update(attestationObject="AA=="))
    emit("base64url whitespace", "reg", "malformed", "encoding", lambda c: c["registration"]["response"].update(attestationObject="AA A"))
    emit("base64url length", "reg", "malformed", "encoding", lambda c: c["registration"]["response"].update(attestationObject="A"))
    emit("response shape", "reg", "malformed", "shape", lambda c: c["registration"].update(rawId="other"))
    emit("client UTF-8", "reg", "malformed", "encoding", lambda c: reg_client_set(c, b"\xff"))
    emit("client shape", "reg", "malformed", "shape", lambda c: reg_client_set(c, b"[]"))
    emit("client type", "reg", "verification", "type", lambda c: alter_client(c, type="webauthn.get"))
    emit("client challenge", "reg", "verification", "challenge", lambda c: alter_client(c, challenge="wrong"))
    emit("client origin", "reg", "verification", "origin", lambda c: alter_client(c, origin="https://evil.example"))
    emit("cross origin", "reg", "verification", "cross_origin", lambda c: alter_client(c, crossOrigin=True))
    emit("cbor", "reg", "malformed", "cbor", lambda c: c["registration"]["response"].update(attestationObject=b64(b"\x9f")))
    emit("short auth data", "reg", "malformed", "auth_data", lambda c: reg_auth_set(c, b"\x00"))
    emit("rpId hash", "reg", "verification", "rp_id", lambda c: reg_auth_set(c, bytes(32) + auth[32:]))
    emit("user present", "reg", "verification", "user_present", lambda c: with_auth_flags(c, 0x44))
    emit("user verified", "reg", "verification", "user_verified", lambda c: with_auth_flags(c, 0x41))
    emit("missing AT", "reg", "malformed", "auth_data", lambda c: with_auth_flags(c, 0x05))
    emit("credential length", "reg", "malformed", "auth_data", lambda c: reg_auth_set(c, auth[:53] + b"\x04\x00" + auth[55:]))
    emit("registration ID", "reg", "verification", "credential", lambda c: change_credential(c, "registration"))
    emit("registration trailing byte", "reg", "malformed", "auth_data", lambda c: reg_auth_set(c, auth + b"\x00"))
    emit("extension trailing byte", "reg", "malformed", "auth_data", lambda c: with_auth_flags(c, 0xc5, cbor({}) + b"\x00"))
    emit("extension is not a map", "reg", "malformed", "auth_data", lambda c: with_auth_flags(c, 0xc5, cbor([])))
    emit("unsupported algorithm", "reg", "malformed", "algorithm", lambda c: bad_key(c, {**pub, 3: -999}))
    emit("algorithm not offered", "reg", "malformed", "algorithm", lambda c: c.update(only_rs256=True))
    weak = rsa.generate_private_key(public_exponent=65537, key_size=1024)
    weak_key = cose_key(weak, -257)
    emit("RSA under 2048 bits", "reg", "malformed", "key", lambda c: bad_key(c, weak_key))
    rsa_key = key_new(-257)
    bad_exponent = {**cose_key(rsa_key, -257), -2: b"\x03"}
    emit("RSA exponent other than 65537", "reg", "malformed", "key", lambda c: bad_key(c, bad_exponent))
    emit("assertion ID", "assert", "verification", "credential", lambda c: change_credential(c, "assertion"))
    emit("assertion user handle", "assert", "verification", "user_handle", lambda c: c["assertion"]["response"].update(userHandle=b64(b"somebody else")))
    emit("assertion AT set", "assert", "malformed", "auth_data", lambda c: assertion_flags(c, 0x45))
    emit("assertion trailing byte", "assert", "malformed", "auth_data", lambda c: auth_set(c, auth_raw(c) + b"\x00"))
    emit("assertion UV", "assert", "verification", "user_verified", lambda c: assertion_flags(c, 0x01))
    emit("assertion extension trailing", "assert", "malformed", "auth_data", lambda c: assertion_flags(c, 0x85, cbor({}) + b"\x00"))
    emit("assertion counter", "assert", "verification", "counter", lambda c: c.update(stored_count=1))
    emit("assertion signature", "assert", "verification", "signature", lambda c: c["assertion"]["response"].update(signature=b64(b"bad signature")))
    def packed(case, signature=None, cert=None):
        obj = copy.deepcopy(att)
        obj["fmt"] = "packed"
        obj["attStmt"] = {"alg": alg, "sig": signature if signature is not None else sign(key, alg, auth + hashlib.sha256(reg_client).digest())}
        if cert is not None:
            obj["attStmt"]["x5c"] = [cert]
        reg_object(case, obj)
    emit("packed self signature", "reg", "verification", "attestation", lambda c: packed(c, b"wrong"))
    emit("packed certificate signature", "reg", "verification", "attestation", lambda c: packed(c, b"wrong", certificate(key, alg)))
    emit("packed certificate subject", "reg", "malformed", "attestation", lambda c: packed(c, cert=certificate(key, alg, ou="wrong")))
    emit("packed certificate AAGUID", "reg", "malformed", "attestation", lambda c: packed(c, cert=certificate(key, alg, aaguid=bytes([1]) * 16)))
    emit("packed critical AAGUID", "reg", "malformed", "attestation", lambda c: packed(c, cert=certificate(key, alg, aaguid=bytes(16), critical=True)))
    valid_aaguid = copy.deepcopy(baseline)
    valid_aaguid["name"] = "packed matching AAGUID"
    packed(valid_aaguid, cert=certificate(key, alg, aaguid=bytes(16)))
    print(json.dumps(valid_aaguid, separators=(",", ":")))
    zero = copy.deepcopy(baseline)
    zero["name"] = "both counters zero"
    zero_data = auth_raw(zero)[:33] + bytes(4)
    auth_set(zero, zero_data)
    encoded_client = zero["assertion"]["response"]["clientDataJSON"]
    actual_client = base64.urlsafe_b64decode(encoded_client + "=" * (-len(encoded_client) % 4))
    zero["assertion"]["response"]["signature"] = b64(sign(key, alg, zero_data + hashlib.sha256(actual_client).digest()))
    print(json.dumps(zero, separators=(",", ":")))
    extended = copy.deepcopy(baseline)
    extended["name"] = "extension maps"
    extended["expect_extensions"] = True
    with_auth_flags(extended, 0xc5, cbor({"example": b"output"}))
    extended_auth = auth_raw(extended)[:32] + b"\x85" + auth_raw(extended)[33:] + cbor({"example": b"output"})
    auth_set(extended, extended_auth)
    extended["assertion"]["response"]["signature"] = b64(sign(key, alg, extended_auth + hashlib.sha256(actual_client).digest()))
    print(json.dumps(extended, separators=(",", ":")))
    no_uv = copy.deepcopy(baseline)
    no_uv["name"] = "user verification optional"
    no_uv["user_verification"] = False
    with_auth_flags(no_uv, 0x41)
    no_uv_auth = auth_raw(no_uv)[:32] + b"\x01" + auth_raw(no_uv)[33:]
    auth_set(no_uv, no_uv_auth)
    no_uv["assertion"]["response"]["signature"] = b64(sign(key, alg, no_uv_auth + hashlib.sha256(actual_client).digest()))
    print(json.dumps(no_uv, separators=(",", ":")))
    def u2f(case):
        obj = copy.deepcopy(att)
        obj["fmt"] = "fido-u2f"
        obj["attStmt"] = {"sig": b"not verified"}
        reg_object(case, obj)
    emit("unrecognised attestation", "reg", "malformed", "attestation", u2f)
    ignored = copy.deepcopy(baseline)
    ignored["name"] = "ignored fido-u2f"
    ignored["policy"] = "ignore"
    u2f(ignored)
    print(json.dumps(ignored, separators=(",", ":")))


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    for number in range(count):
        for alg in (-7, -257, -8):
            key = key_new(alg)
            for fmt in ("none", "packed", "packed-x5c"):
                record, auth, att, pub, reg_client = make_case(key, alg, fmt, number)
                print(json.dumps(record, separators=(",", ":")))
                if number == 0 and alg == -7 and fmt == "none":
                    negatives(key, alg, record, auth, att, pub, reg_client)


if __name__ == "__main__":
    main()
