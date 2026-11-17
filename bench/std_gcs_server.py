#!/usr/bin/env python3
"""Loopback-only metadata, OAuth, IAM and GCS fake used by the exercises."""
import base64
import datetime as dt
import ipaddress
import json
import pathlib
import re
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ROOT = pathlib.Path(sys.argv[1])
ROOT.mkdir(parents=True, exist_ok=True)
NOW = dt.datetime.now(dt.timezone.utc)
EMAIL = "fake@example.iam.gserviceaccount.com"
SCOPE = "https://www.googleapis.com/auth/devstorage.read_write"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PUBLIC = KEY.public_key()
counts = {}
objects = {}
next_generation = 1
lock = threading.Lock()
https_origin = ""


def pem_key(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


def certificate():
    ca_key = ec.generate_private_key(ec.SECP256R1())
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "iyi GCS fake CA")])
    leaf_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(NOW - dt.timedelta(minutes=5)).not_valid_after(NOW + dt.timedelta(days=1))
          .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
          .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                          key_encipherment=False, data_encipherment=False, key_agreement=False,
                          key_cert_sign=True, crl_sign=True, encipher_only=False, decipher_only=False), critical=True)
          .sign(ca_key, hashes.SHA256()))
    leaf = (x509.CertificateBuilder().subject_name(leaf_name).issuer_name(ca_name)
            .public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(NOW - dt.timedelta(minutes=5)).not_valid_after(NOW + dt.timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"),
                           x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    (ROOT / "ca.pem").write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    (ROOT / "tls.pem").write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
    (ROOT / "tls-key.pem").write_bytes(pem_key(leaf_key))


def b64u(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def crc32c(data):
    crc = 0xffffffff
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82f63b78 if crc & 1 else 0)
    return base64.b64encode((crc ^ 0xffffffff).to_bytes(4, "big")).decode()


def encode(value):
    return urllib.parse.quote(value, safe="-_.~")


def canonical_value(value):
    return re.sub(r"[ \t]+", " ", value.strip(" \t"))


def verify_signed(handler, parsed, params):
    try:
        signature = bytes.fromhex(params["X-Goog-Signature"])
        if params["X-Goog-Algorithm"] != "GOOG4-RSA-SHA256":
            return False
        timestamp = params["X-Goog-Date"]
        scope = timestamp[:8] + "/auto/storage/goog4_request"
        if params["X-Goog-Credential"] != EMAIL + "/" + scope:
            return False
        expiry = int(params["X-Goog-Expires"])
        if not 1 <= expiry <= 604800:
            return False
        names = params["X-Goog-SignedHeaders"].split(";")
        if names != sorted(names) or "host" not in names:
            return False
        canonical_headers = "".join(name + ":" + canonical_value(handler.headers[name]) + "\n" for name in names)
        signed_query = sorted((encode(k), encode(v)) for k, v in params.items() if k != "X-Goog-Signature")
        query = "&".join(k + "=" + v for k, v in signed_query)
        payload = handler.headers.get("x-goog-content-sha256", "UNSIGNED-PAYLOAD")
        canonical = "\n".join((handler.command, parsed.path, query, canonical_headers,
                               ";".join(names), payload))
        digest = hashes.Hash(hashes.SHA256())
        digest.update(canonical.encode())
        to_sign = "\n".join(("GOOG4-RSA-SHA256", timestamp, scope, digest.finalize().hex()))
        PUBLIC.verify(signature, to_sign.encode(), padding.PKCS1v15(), hashes.SHA256())
        return True
    except Exception:
        return False


def verify_jwt(assertion):
    try:
        h, p, s = assertion.split(".")
        header = json.loads(b64u(h))
        payload = json.loads(b64u(p))
        PUBLIC.verify(b64u(s), (h + "." + p).encode(), padding.PKCS1v15(), hashes.SHA256())
        return (header == {"alg": "RS256", "typ": "JWT"}
                and payload["iss"] == EMAIL and payload["sub"] == EMAIL
                and payload["aud"] == https_origin + "/token"
                and payload["scope"] == SCOPE and isinstance(payload["iat"], int)
                and payload["iat"] > 0 and payload["exp"] == payload["iat"] + 3600)
    except Exception:
        return False


def object_metadata(name, entry):
    return {"name": name, "generation": str(entry["generation"]),
            "metageneration": str(entry["metageneration"]), "size": str(len(entry["body"])),
            "crc32c": crc32c(entry["body"]), **entry["metadata"]}


def precondition(params, entry):
    gen = params.get("ifGenerationMatch")
    meta = params.get("ifMetagenerationMatch")
    if gen is not None and (gen != "0" or entry is not None):
        if entry is None or str(entry["generation"]) != gen:
            return False
    if meta is not None and (entry is None or str(entry["metageneration"]) != meta):
        return False
    return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def answer(self, status, body=b"", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, separators=(",", ":")).encode()
            headers = {**(headers or {}), "Content-Type": "application/json"}
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def handle_one(self):
        global next_generation
        if not ipaddress.ip_address(self.client_address[0]).is_loopback:
            return self.answer(403, "loopback only")
        parsed = urllib.parse.urlsplit(self.path)
        params = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        path = parsed.path
        if path == "/reset" and self.command == "POST":
            counts.clear()
            objects.clear()
            next_generation = 1
            return self.answer(200)
        if path == "/counts":
            return self.answer(200, dict(counts))
        if path.startswith("/computeMetadata/v1/instance/service-accounts/default/"):
            leaf = path.rsplit("/", 1)[-1]
            counts["metadata_" + leaf] = counts.get("metadata_" + leaf, 0) + 1
            if self.headers.get("Metadata-Flavor") != "Google":
                return self.answer(403, "missing Metadata-Flavor")
            if leaf == "email":
                return self.answer(200, EMAIL)
            if leaf == "token":
                return self.answer(200, {"access_token": "metadata-token", "expires_in": 3600})
            return self.answer(404)
        if path == "/token" and self.command == "POST":
            counts["token"] = counts.get("token", 0) + 1
            form = urllib.parse.parse_qs(body.decode())
            assertion = form.get("assertion", [""])[0]
            if form.get("grant_type") != ["urn:ietf:params:oauth:grant-type:jwt-bearer"] or not verify_jwt(assertion):
                return self.answer(400, "invalid JWT grant")
            return self.answer(200, {"access_token": "service-token", "expires_in": 3600})
        if path.endswith(":signBlob") and self.command == "POST":
            expected_path = "/v1/projects/-/serviceAccounts/" + encode(EMAIL) + ":signBlob"
            if path != expected_path:
                counts["iam_bad_path"] = counts.get("iam_bad_path", 0) + 1
                return self.answer(404, "unknown signing account")
            counts["iam"] = counts.get("iam", 0) + 1
            if self.headers.get("Authorization") != "Bearer metadata-token":
                return self.answer(401)
            try:
                message = base64.b64decode(json.loads(body)["payload"], validate=True)
                signature = KEY.sign(message, padding.PKCS1v15(), hashes.SHA256())
                PUBLIC.verify(signature, message, padding.PKCS1v15(), hashes.SHA256())
                return self.answer(200, {"signedBlob": base64.b64encode(signature).decode()})
            except Exception:
                return self.answer(400)
        if "X-Goog-Signature" in params:
            counts["signed_" + self.command] = counts.get("signed_" + self.command, 0) + 1
            if not verify_signed(self, parsed, params):
                return self.answer(403, "invalid V4 signature")
            parts = path.split("/", 2)
            if len(parts) != 3:
                return self.answer(404)
            name = urllib.parse.unquote(parts[2])
            entry = objects.get(name)
            if self.command == "PUT":
                objects[name] = {"body": body, "generation": next_generation,
                                 "metageneration": 1, "metadata": {}}
                next_generation += 1
                return self.answer(200)
            if entry is None:
                return self.answer(404)
            if self.command == "DELETE":
                del objects[name]
                return self.answer(204)
            return self.answer(200, entry["body"], {"x-goog-hash": "crc32c=" + crc32c(entry["body"]),
                                                   "x-goog-generation": entry["generation"]})
        authorization = self.headers.get("Authorization")
        if authorization is None:
            counts["anonymous"] = counts.get("anonymous", 0) + 1
        elif authorization in ("Bearer metadata-token", "Bearer service-token"):
            counts["authorized"] = counts.get("authorized", 0) + 1
        else:
            return self.answer(401, "invalid bearer")
        match = re.fullmatch(r"/(upload/)?storage/v1/b/([^/]+)/o(?:/(.*))?", path)
        if not match:
            return self.answer(404, "unknown path")
        upload, bucket, encoded_name = match.groups()
        name = urllib.parse.unquote(encoded_name) if encoded_name is not None else params.get("name")
        if urllib.parse.unquote(bucket) != "test-bucket":
            return self.answer(404)
        if upload and self.command == "POST":
            counts["write"] = counts.get("write", 0) + 1
            if params.get("uploadType") != "media" or name is None:
                return self.answer(400, "media name required")
            entry = objects.get(name)
            if not precondition(params, entry):
                return self.answer(412, "precondition failed")
            entry = {"body": body, "generation": next_generation, "metageneration": 1,
                     "metadata": {"contentType": self.headers.get("Content-Type")}}
            next_generation += 1
            objects[name] = entry
            return self.answer(200, object_metadata(name, entry))
        if name is None and self.command == "GET":
            counts["list"] = counts.get("list", 0) + 1
            names = sorted(n for n in objects if n.startswith(params.get("prefix", "")))
            start = int(params.get("pageToken", "0"))
            reply = {"items": [object_metadata(n, objects[n]) for n in names[start:start + 1]]}
            if start + 1 < len(names):
                reply["nextPageToken"] = str(start + 1)
            return self.answer(200, reply)
        entry = objects.get(name)
        if entry is None:
            return self.answer(404)
        if not precondition(params, entry):
            return self.answer(412, "precondition failed")
        if self.command == "GET":
            counts["read" if params.get("alt") == "media" else "stat"] = counts.get("read" if params.get("alt") == "media" else "stat", 0) + 1
            if params.get("alt") == "media":
                checksum = "AAAAAA==" if name == "corrupt-crc" else crc32c(entry["body"])
                return self.answer(200, entry["body"], {"x-goog-hash": "md5=ignored, crc32c=" + checksum,
                                                       "x-goog-generation": entry["generation"],
                                                       "x-goog-metageneration": entry["metageneration"]})
            return self.answer(200, object_metadata(name, entry))
        if self.command == "PATCH":
            counts["patch"] = counts.get("patch", 0) + 1
            entry["metadata"].update(json.loads(body))
            entry["metageneration"] += 1
            return self.answer(200, object_metadata(name, entry))
        if self.command == "DELETE":
            counts["delete"] = counts.get("delete", 0) + 1
            del objects[name]
            return self.answer(204)
        return self.answer(405)

    def run_safely(self):
        try:
            with lock:
                self.handle_one()
        except Exception as exc:
            print("fake error: " + repr(exc), file=sys.stderr, flush=True)
            self.answer(500, "fake exception")

    do_GET = run_safely
    do_POST = run_safely
    do_PUT = run_safely
    do_HEAD = run_safely
    do_DELETE = run_safely
    do_PATCH = run_safely


certificate()
http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
https = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(ROOT / "tls.pem", ROOT / "tls-key.pem")
https.socket = ctx.wrap_socket(https.socket, server_side=True)
https_origin = "https://127.0.0.1:" + str(https.server_port)
credentials = {"type": "service_account", "client_email": EMAIL,
               "private_key": pem_key(KEY).decode(), "token_uri": https_origin + "/token"}
(ROOT / "service-account.json").write_text(json.dumps(credentials))
(ROOT / "config.json").write_text(json.dumps({"metadata_host": "127.0.0.1:" + str(http.server_port),
                                               "https": https_origin, "email": EMAIL}))
threading.Thread(target=http.serve_forever, daemon=True).start()
(ROOT / "ready").write_text("ready")
https.serve_forever()
