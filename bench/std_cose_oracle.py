#!/usr/bin/env python3
"""Produce independent COSE keys and signatures for the iyi exercise.

The encoder below is intentionally independent of std/cbor. Generated keys
and messages exist only in the local exercise's temporary directory.
"""
import hashlib
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa, utils


def head(major, value):
    if value < 24:
        return bytes([(major << 5) | value])
    for additional, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if value < 1 << (size * 8):
            return bytes([(major << 5) | additional]) + value.to_bytes(size, 'big')
    raise ValueError('too large')


def cbor(value):
    if isinstance(value, int):
        return head(0, value) if value >= 0 else head(1, -1 - value)
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    if isinstance(value, dict):
        entries = sorted((cbor(k), cbor(v)) for k, v in value.items())
        return head(5, len(entries)) + b''.join(k + v for k, v in entries)
    raise TypeError(value)


def bignum(number):
    return number.to_bytes((number.bit_length() + 7) // 8, 'big')


def case(name, index):
    message = hashlib.sha256(f'{name}:{index}'.encode()).digest()
    if name in ('ES256', 'ES384'):
        width = 32 if name == 'ES256' else 48
        algorithm = -7 if width == 32 else -35
        curve = ec.SECP256R1() if width == 32 else ec.SECP384R1()
        digest = hashes.SHA256() if width == 32 else hashes.SHA384()
        private = ec.generate_private_key(curve)
        public = private.public_key().public_numbers()
        key = {1: 2, 3: algorithm, -1: 1 if width == 32 else 2,
               -2: public.x.to_bytes(width, 'big'), -3: public.y.to_bytes(width, 'big')}
        der = private.sign(message, ec.ECDSA(digest))
        r, s = utils.decode_dss_signature(der)
        raw = r.to_bytes(width, 'big') + s.to_bytes(width, 'big')
    elif name == 'EdDSA':
        private = ed25519.Ed25519PrivateKey.generate()
        public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        key = {1: 1, 3: -8, -1: 6, -2: public}
        raw = der = private.sign(message)
    else:
        private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        public = private.public_key().public_numbers()
        key = {1: 3, 3: -257 if name == 'RS256' else -37,
               -1: bignum(public.n), -2: bignum(public.e)}
        pad = padding.PKCS1v15() if name == 'RS256' else padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32)
        raw = der = private.sign(message, pad, hashes.SHA256())
    return key, message, raw, der


def main(path):
    names = ('ES256', 'ES384', 'EdDSA', 'RS256', 'PS256')
    first = {}
    with open(path, 'w', encoding='ascii', newline='\n') as output:
        for name in names:
            for index in range(200):
                key, message, raw, der = case(name, index)
                first.setdefault(name, key)
                output.write('|'.join(('V', name, cbor(key).hex(), message.hex(), raw.hex(), der.hex())) + '\n')
        p256 = first['ES256']
        tests = [
            ({3: -7, -1: 1, -2: p256[-2], -3: p256[-3]}, 'missing kty'),
            ({1: 9, 3: -7}, 'unsupported kty'),
            ({1: 2, 3: -999}, 'unsupported alg'),
            ({1: 2, 3: -8, -1: 1, -2: p256[-2], -3: p256[-3]}, 'incompatible'),
            ({1: 2, 3: -7, -1: 2, -2: p256[-2], -3: p256[-3]}, 'crv'),
            ({1: 2, 3: -7, -1: 1, -3: p256[-3]}, 'missing x'),
            ({1: 2, 3: -7, -1: 1, -2: b'bad', -3: p256[-3]}, 'coordinate lengths'),
            ({1: 2, 3: -7, -1: 1, -2: bytes(32), -3: bytes(32)}, 'not on'),
            ({1: 2, 3: -7, -1: 1, -2: p256[-2], -3: p256[-3], -4: b'private'}, 'private'),
            ({1: 1, 3: -8, -1: 6, -2: b'x'}, 'length'),
            ({1: 1, 3: -8, -1: 5, -2: bytes(32)}, 'crv'),
            ({1: 3, 3: -257, -1: first['RS256'][-1]}, 'missing e'),
            ({1: 3, 3: -257, -1: b'\x01', -2: b'\x03'}, 'modulus'),
        ]
        for key, reason in tests:
            output.write('|'.join(('R', cbor(key).hex(), reason)) + '\n')
    print('200 independent keys and signatures each: ES256 ES384 EdDSA RS256 PS256; 13 malformed keys')


if __name__ == '__main__':
    main(sys.argv[1])
