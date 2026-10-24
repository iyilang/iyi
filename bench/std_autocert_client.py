#!/usr/bin/env python3
"""The outside half of bench/std_autocert_exercise.sh: Python's ssl and
cryptography against the exercise's HTTPS servers, and Pebble's own log.

    python3 bench/std_autocert_client.py modes CACHE_DIR
    python3 bench/std_autocert_client.py alpn EXERCISE WORK
    python3 bench/std_autocert_client.py pebble EXERCISE SETUP.json PARTS

Each check prints its name, and `FAIL: <name>: ...` when it does not hold;
the gate's broken copies are each caught at the name of the check that
covers them. The exit status is 1 when any check failed.

`pebble`'s PARTS, by commas or `all`, in the order they run: first,
refused, ten, remembered, restart, http01, modes, renewal, unknown. A
part runs the parts it rests on first (restart needs first and ten,
http01 restart's server, modes the cache they wrote).
"""

import hashlib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.x509.oid import ExtensionOID

ACME_IDENTIFIER = x509.ObjectIdentifier("1.3.6.1.5.5.7.1.31")
failed = []


def ok(name, detail=""):
    print(f"  {name}" + (f": {detail}" if detail else ""), flush=True)


def fail(name, detail):
    failed.append(name)
    print(f"  FAIL: {name}: {detail}", flush=True)


def held(cond, name, detail=""):
    (ok if cond else fail)(name, detail)
    return cond


def handshake(port, name, alpn=("http/1.1",), cafile=None, tls12=False, request=False):
    """One handshake with 127.0.0.1:port for *name*: the leaf the server
    showed, the protocol ALPN chose, and with *request* the body of a GET.
    The chain is verified to *cafile* and the leaf for *name* when one is
    given; an ssl.SSLError or OSError is raised when the handshake fails."""
    if cafile:
        ctx = ssl.create_default_context(cafile=cafile)
    else:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(list(alpn))
    if tls12:
        ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    with socket.create_connection(("127.0.0.1", port), timeout=120) as raw:
        with ctx.wrap_socket(raw, server_hostname=name) as tls:
            leaf = x509.load_der_x509_certificate(tls.getpeercert(binary_form=True))
            chosen = tls.selected_alpn_protocol()
            version = tls.version()
            body = ""
            if request:
                tls.sendall(f"GET / HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n".encode())
                data = b""
                while True:
                    chunk = tls.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                body = data.decode(errors="replace").split("\r\n\r\n", 1)[-1].strip()
    return leaf, chosen, version, body


def acme_identifier(leaf):
    try:
        return leaf.extensions.get_extension_for_oid(ACME_IDENTIFIER)
    except x509.ExtensionNotFound:
        return None


# --- the local cache's files, and the challenge certificate ---


def modes(directory, name="cache files are 0600"):
    """Every file in the cache holds a private key: none may be read or
    written by group or others, and the directory is the owner's alone.
    Each key reads back with cryptography, and a certificate's key is its
    leaf's."""
    if os.name == "nt":
        ok(name, "not measured: Windows has no POSIX modes, and the cache's files take the directory's ACL")
    else:
        entries = sorted(os.listdir(directory))
        loose = [f"{e} {oct(os.stat(os.path.join(directory, e)).st_mode & 0o777)}" for e in entries
                 if os.stat(os.path.join(directory, e)).st_mode & 0o077]
        dir_mode = os.stat(directory).st_mode & 0o777
        held(entries and not loose and dir_mode == 0o700, name,
             f"{len(entries)} files, {', '.join(loose) or 'each 0600'}; the directory {oct(dir_mode)}")
    problems = []
    keys = 0
    for entry in sorted(os.listdir(directory)):
        text = open(os.path.join(directory, entry), "rb").read()
        try:
            key = serialization.load_pem_private_key(text, None)
        except ValueError as e:
            problems.append(f"{entry}: {e}")
            continue
        keys += 1
        if entry == "acme_account+key":
            continue
        chain = x509.load_pem_x509_certificates(text)
        pub = lambda k: k.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        if pub(chain[0].public_key()) != pub(key.public_key()) or len(chain) < 2:
            problems.append(f"{entry}: a chain of {len(chain)} whose leaf's key is not the key beside it")
    held(keys > 0 and not problems, "the cache holds keys cryptography reads, each certificate's its leaf's",
         "; ".join(problems) or f"{keys} keys")


def alpn(exercise, work):
    os.makedirs(work, exist_ok=True)
    server = subprocess.Popen([exercise, "challenge-serve", work], stdout=open(f"{work}/serve.out", "w"), stderr=subprocess.STDOUT)
    try:
        port_file = f"{work}/port"
        for _ in range(600):
            if os.path.exists(port_file) and open(port_file).read().strip():
                break
            time.sleep(0.05)
        port = int(open(port_file).read())
        domain, authorization = open(f"{work}/alpn.txt").read().split()
        leaf, chosen, _, _ = handshake(port, domain, alpn=("acme-tls/1",))
        ext = acme_identifier(leaf)
        names = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
        held(chosen == "acme-tls/1" and ext is not None and ext.critical
             and ext.value.value == b"\x04\x20" + hashlib.sha256(authorization.encode()).digest() and names == [domain],
             "under acme-tls/1 alone the challenge certificate is shown", f"ALPN chose {chosen}, the certificate names {names}")
        for offered in (["http/1.1"], ["acme-tls/1", "http/1.1"], ["h2"]):
            try:
                leaf, chosen, _, _ = handshake(port, domain, alpn=offered)
                shown = "the challenge certificate" if acme_identifier(leaf) else "another certificate"
            except (ssl.SSLError, OSError) as e:
                shown = f"no certificate ({e.__class__.__name__}: {getattr(e, 'reason', None) or e})"
            held(shown != "the challenge certificate",
                 "a challenge certificate is shown under acme-tls/1 alone", f"offering {', '.join(offered)}: {shown}")
        try:
            handshake(port, "other.autocert.example", alpn=("acme-tls/1",))
            refused = "a certificate"
        except (ssl.SSLError, OSError) as e:
            refused = f"refused ({getattr(e, 'reason', None) or e})"
        held(refused.startswith("refused"), "acme-tls/1 for a name with no challenge up is refused", refused)
    finally:
        server.terminate()
        server.wait(10)


# --- against Pebble ---


class Pebble:
    def __init__(self, setup, which):
        self.directory = setup[which]["directory"]
        self.log = setup[which]["log"]
        self.root = setup[which]["root"]
        if not os.path.exists(self.root):
            ctx = ssl.create_default_context(cafile=setup["minica"])
            pem = urllib.request.urlopen(f"{setup[which]['management']}/roots/0", context=ctx, timeout=10).read()
            open(self.root, "wb").write(pem)

    def text(self):
        return open(self.log, errors="replace").read()

    def orders(self):
        """Orders Pebble made: one `Added order` line each."""
        return self.text().count("Added order")

    def order_requests(self):
        """newOrder requests, made into an order or refused."""
        return len(re.findall(r"POST /order-plz -> calling handler", self.text()))


class Served:
    """One `serve` process of the exercise, and its log."""

    def __init__(self, setup, label, pebble, cache, hosts, challenges, roots=None):
        self.ready = os.path.join(setup["work"], f"{label}.ready")
        if os.path.exists(self.ready):
            os.remove(self.ready)
        self.out = os.path.join(setup["work"], f"{label}.out")
        # ROOTS, which the manager checks each chain to: Pebble's own root
        # unless another is given.
        self.process = subprocess.Popen(
            [setup["exercise"], "serve", pebble.directory, setup["minica"], roots or pebble.root, cache, str(setup["tls_port"]),
             str(setup["http_port"]), ",".join(hosts), ",".join(challenges), self.ready],
            stdout=open(self.out, "w"), stderr=subprocess.STDOUT)
        # The exercise tries a port held after the last server for a minute.
        deadline = time.time() + 90
        while not os.path.exists(self.ready):
            if self.process.poll() is not None or time.time() > deadline:
                raise SystemExit(f"  FAIL: the exercise's server ({label}) did not come up: {open(self.out).read()[-400:]}")
            time.sleep(0.05)
        self.port = setup["tls_port"]

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(10)
        # The ports are drawn again by the next server at once.
        time.sleep(0.2)


def serial(leaf):
    return format(leaf.serial_number, "x")


class Scenario:
    HOSTS = ["a.autocert.example", "b.autocert.example", "c.autocert.example", "blocked.example"]

    def __init__(self, setup):
        self.setup = setup
        self.a = Pebble(setup, "a")
        self.cache = os.path.join(setup["work"], "cache")
        self.server = None
        self.serials = {}
        self.done = set()

    def serve(self, label, challenges):
        if self.server:
            self.server.stop()
        self.server = Served(self.setup, label, self.a, self.cache, self.HOSTS, challenges)

    def need(self, part):
        if part not in self.done:
            self.done.add(part)
            getattr(self, part)()

    def first(self):
        print("\n== an allowed name, its first handshake", flush=True)
        self.serve("first", ["tls-alpn-01", "http-01"])
        before, start = self.a.orders(), len(self.a.text())
        try:
            leaf, chosen, version, body = handshake(self.server.port, "a.autocert.example", cafile=self.a.root, request=True)
        except (ssl.SSLError, OSError) as e:
            fail("an allowed name gets a Pebble-issued chain that verifies", f"{e}; the server said: {open(self.server.out).read()[-300:]}")
            return
        self.serials["a"] = serial(leaf)
        names = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
        held(True, "an allowed name gets a Pebble-issued chain that verifies",
             f"{names} from {leaf.issuer.rfc4514_string()}, serial {serial(leaf)}, {version}, ALPN {chosen}; server: {body}")
        held(self.a.orders() == before + 1, "one order made it", f"Pebble's orders went from {before} to {self.a.orders()}")
        # Pebble's log names the identifier a validation is for and not the
        # challenge's type, and it logs an http-01 fetch by its URL: a
        # validation with no fetch was tls-alpn-01's, the manager offering
        # no dns-01.
        text = self.a.text()[start:]
        validations = sum(1 for line in text.splitlines() if "Pulled a task" in line and '"a.autocert.example"' in line)
        fetched = "http://a.autocert.example:" in text
        held(validations == 1 and not fetched, "tls-alpn-01 answered on the HTTPS listener itself",
             f"{validations} validation of a.autocert.example in Pebble's log, {'an' if fetched else 'no'} http-01 fetch")
        try:
            leaf12, _, version12, _ = handshake(self.server.port, "a.autocert.example", cafile=self.a.root, tls12=True)
            held(serial(leaf12) == self.serials["a"] and version12 == "TLSv1.2", "a TLS 1.2 client is shown the same certificate",
                 f"{version12}, serial {serial(leaf12)}")
        except (ssl.SSLError, OSError) as e:
            fail("a TLS 1.2 client is shown the same certificate", str(e))

    def refused(self):
        self.need("first")
        print("\n== a name the policy does not allow", flush=True)
        before, text_before = self.a.order_requests(), len(self.a.text())
        try:
            leaf, _, _, _ = handshake(self.server.port, "evil.autocert.example")
            outcome = f"a certificate for {leaf.subject.rfc4514_string()}"
        except (ssl.SSLError, OSError) as e:
            outcome = f"refused ({getattr(e, 'reason', None) or e})"
        time.sleep(0.5)
        after = self.a.order_requests()
        mentioned = "evil.autocert.example" in self.a.text()[text_before:]
        held(outcome.startswith("refused") and after == before and not mentioned, "a disallowed name is refused without any order",
             f"{outcome}; Pebble's newOrder requests {before} then {after}, the name {'in' if mentioned else 'not in'} its log")

    def ten(self):
        self.need("first")
        print("\n== ten first handshakes at once", flush=True)
        before = self.a.orders()
        results = [None] * 10
        start = threading.Barrier(10)

        def one(i):
            start.wait()
            try:
                leaf, _, _, _ = handshake(self.server.port, "b.autocert.example", cafile=self.a.root)
                results[i] = serial(leaf)
            except (ssl.SSLError, OSError) as e:
                results[i] = f"error: {e}"

        threads = [threading.Thread(target=one, args=(i,)) for i in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        made = self.a.orders() - before
        verified = [r for r in results if r and not r.startswith("error")]
        self.serials["b"] = verified[0] if verified else ""
        held(len(verified) == 10 and len(set(verified)) == 1, "ten concurrent first connections verify, one certificate",
             f"{len(verified)} verified, serials {sorted(set(verified))}; {[r for r in results if r and r.startswith('error')][:1]}")
        held(made == 1, "ten concurrent first connections create one order", f"Pebble made {made}")

    def remembered(self):
        self.need("first")
        print("\n== a name the CA refuses, remembered", flush=True)
        before = self.a.order_requests()
        outcomes = []
        for _ in range(3):
            try:
                handshake(self.server.port, "blocked.example")
                outcomes.append("a certificate")
            except (ssl.SSLError, OSError) as e:
                outcomes.append(f"refused ({getattr(e, 'reason', None) or e})")
        asked = self.a.order_requests() - before
        held(all(o.startswith("refused") for o in outcomes) and asked == 1, "a failed name is remembered: one order for three handshakes",
             f"{asked} newOrder requests; {outcomes[0]}")

    def restart(self):
        self.need("first")
        self.need("ten")
        print("\n== the cache, across a restart", flush=True)
        before = self.a.orders()
        self.serve("restart", ["http-01", "tls-alpn-01"])
        seen = {}
        for host in ("a", "b"):
            try:
                leaf, _, _, _ = handshake(self.server.port, f"{host}.autocert.example", cafile=self.a.root)
                seen[host] = serial(leaf)
            except (ssl.SSLError, OSError) as e:
                seen[host] = f"error: {e}"
        held(seen == {h: self.serials.get(h) for h in ("a", "b")} and self.a.orders() == before,
             "the cache survives a restart: no new order",
             f"serials {seen} against {self.serials}; Pebble's orders {before} then {self.a.orders()}")

    def http01(self):
        self.need("restart")
        print("\n== http-01, on port 80", flush=True)
        before, start = self.a.orders(), len(self.a.text())
        try:
            leaf, _, _, body = handshake(self.server.port, "c.autocert.example", cafile=self.a.root, request=True)
            outcome = f"serial {serial(leaf)}; server: {body}"
            verified = True
        except (ssl.SSLError, OSError) as e:
            outcome, verified = str(e), False
        url = f"http://c.autocert.example:{self.setup['http_port']}/.well-known/acme-challenge/"
        asked = url in self.a.text()[start:]
        held(verified and asked and self.a.orders() == before + 1, "http-01 answered on port 80",
             f"{outcome}; Pebble {'fetched' if asked else 'never fetched'} {url}...")

    def modes(self):
        self.need("http01")
        print("\n== the cache's files", flush=True)
        self.server.stop()
        self.server = None
        modes(self.cache)

    def renewal(self):
        print("\n== renewal, of a certificate Pebble issued for 24 seconds", flush=True)
        if self.server:
            self.server.stop()
            self.server = None
        b = Pebble(self.setup, "b")
        cache = os.path.join(self.setup["work"], "renew-cache")
        server = Served(self.setup, "renewal", b, cache, ["r.autocert.example"], ["tls-alpn-01"])
        try:
            before = b.orders()
            leaf, _, _, _ = handshake(server.port, "r.autocert.example", cafile=b.root)
            first, ends = serial(leaf), leaf.not_valid_after_utc.timestamp()
            life = ends - leaf.not_valid_before_utc.timestamp()
            ok("the first certificate", f"serial {first}, {life:.0f} s of life")
            # Each poll starts at least a second before the first one ends
            # and is counted only if it ends before then too: past its end
            # a handshake orders anew by itself, which is not renewal.
            renewed, at = None, None
            while True:
                time.sleep(1)
                if time.time() >= ends - 1:
                    break
                try:
                    now_leaf, _, _, body = handshake(server.port, "r.autocert.example", cafile=b.root, request=True)
                except (ssl.SSLError, OSError) as e:
                    continue
                if serial(now_leaf) != first:
                    renewed, at = now_leaf, time.time()
                    break
            if renewed is None or at >= ends:
                fail("a renewal before expiry: new handshakes see a new serial",
                     f"still {first} {ends - time.time():.1f} s before it ends; Pebble's orders {before} then {b.orders()}")
                return
            cached = x509.load_pem_x509_certificates(open(os.path.join(cache, "r.autocert.example"), "rb").read())[0]
            held(b.orders() >= before + 2 and serial(cached) == serial(renewed),
                 "a renewal before expiry: new handshakes see a new serial",
                 f"{serial(renewed)} seen {ends - at:.1f} s before {first} ended; Pebble's orders {before} then {b.orders()}; "
                 f"the cache holds {serial(cached)}; server: {body}")
        finally:
            server.stop()

    def unknown(self):
        print("\n== a chain from a CA the manager does not trust", flush=True)
        if self.server:
            self.server.stop()
            self.server = None
        # The manager trusts Pebble's minica alone, which signs Pebble's
        # HTTPS and no certificate Pebble issues.
        cache = os.path.join(self.setup["work"], "unknown-cache")
        server = Served(self.setup, "unknown", self.a, cache, ["u.autocert.example"], ["tls-alpn-01"], roots=self.setup["minica"])
        try:
            before = self.a.orders()
            try:
                leaf, _, _, _ = handshake(server.port, "u.autocert.example")
                outcome = f"a certificate, serial {serial(leaf)}"
            except (ssl.SSLError, OSError) as e:
                outcome = f"refused ({getattr(e, 'reason', None) or e})"
            made = self.a.orders() - before
            cached = os.path.exists(os.path.join(cache, "u.autocert.example"))
            held(outcome.startswith("refused") and made == 1 and not cached,
                 "a chain from a CA the manager does not trust is refused, not cached",
                 f"{outcome}; Pebble made {made} orders; the cache {'holds' if cached else 'does not hold'} it")
        finally:
            server.stop()

    def close(self):
        if self.server:
            self.server.stop()


PARTS = ["first", "refused", "ten", "remembered", "restart", "http01", "modes", "renewal", "unknown"]


def pebble(exercise, setup_path, parts):
    setup = json.load(open(setup_path))
    setup["exercise"] = exercise
    scenario = Scenario(setup)
    try:
        for part in (PARTS if parts == "all" else parts.split(",")):
            scenario.need(part)
    finally:
        scenario.close()


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "modes":
        modes(sys.argv[2])
    elif mode == "alpn":
        alpn(sys.argv[2], sys.argv[3])
    elif mode == "pebble":
        pebble(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise SystemExit(f"no mode {mode}")
    sys.exit(1 if failed else 0)
