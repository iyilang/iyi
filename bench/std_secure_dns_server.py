"""Scripted encrypted DNS servers for bench/std_secure_dns_exercise.sh.

    python3 bench/std_secure_dns_server.py WORKDIR

Makes a test CA and a server certificate for `dns.test` and 127.0.0.1
(WORKDIR/ca.pem is the root a client trusts), then answers one fixed zone,
`zone.test`, on 127.0.0.1 over:

  * DNS over TLS (RFC 7858): Python's ssl, each message after its two-byte
    length; the port in WORKDIR/dot.port.
  * DNS over HTTPS (RFC 8484) over HTTP/1.1: http.server inside ssl, POST
    and GET at /dns-query; WORKDIR/doh.port.
  * DNS over HTTPS over HTTP/2, when the `h2` package imports: the same
    paths through h2's state machine; WORKDIR/h2.port. Without the package
    the file is not written and WORKDIR/h2.missing says why.
  * plain DNS over UDP, for the resolver's opt-in fallback; WORKDIR/udp.port.

WORKDIR/ready is written last. Runs until killed, a thread per connection.

The zone is ZONE below. A few names misbehave on purpose, the way a broken
or hostile server would, so the client's refusals have something to refuse:
`wrong-id` answers with another ID, `cut` ends the connection halfway into
an answer, `tc` sets TC, `long` sends bytes past the message (over HTTPS,
past 65535 of them). Two more report what the server saw: `stats` the TLS
connections accepted and, on this connection, the queries read and the
most that were read before the first of them was answered (pipelining);
`id` the query's ID. `transport` says which server answered. Over HTTPS,
`/status-500` answers 500 and `/wrong-type` a good answer as text/plain;
a GET whose `dns` parameter has padding is refused 400, as RFC 8484 4.1
says the parameter has none.

EDNS(0), as a real server speaks it: a query with an OPT record is
answered with one (RFC 6891 6.1.1), and that OPT record holds a Padding
option bringing the answer to a multiple of 468 octets when the query's
had one (RFC 7830 4, RFC 8467 4.1). An NXDOMAIN answer carries the zone's
SOA in its authority section. `badvers` answers BADVERS (16): 0 in the
header and 1 in the OPT record's extended RCODE. Every query is judged
against RFC 7830 and RFC 8467 4.1's client policy - one OPT record owned
by the root, version 0, one Padding option of zero bytes, the message a
multiple of 128 octets - and counted per transport; `padding` (TXT) says
the counts since it was last asked, this query included, as
"queries=N edns=E unpadded=U", followed by " first=<why>" for the first
query that was not padded, and starts the counts again.
"""
import base64
import datetime as dt
import http.server
import ipaddress
import os
import select
import socket
import socketserver
import ssl
import struct
import sys
import threading
import urllib.parse

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

A, CNAME, TXT, AAAA, HTTPS = 1, 5, 16, 28, 65
MEDIA = "application/dns-message"

# name -> [(type, data)]: data is the address text, the target, the TXT
# record's strings, or an HTTPS record's data in hex (RFC 9460 2.2).
ZONE = {
    "a.zone.test": [(A, "192.0.2.1")],
    "six.zone.test": [(AAAA, "2001:db8::6")],
    "dual.zone.test": [(A, "192.0.2.2"), (AAAA, "2001:db8::2")],
    "txt.zone.test": [(TXT, ["hello, encrypted world", "and a second string"]), (TXT, ["v=spf1 -all"])],
    "alias.zone.test": [(CNAME, "a.zone.test")],
    # A ServiceMode HTTPS record - alpn h2 and http/1.1, and RFC 9848 3's
    # example ECHConfigList as its ech - and an AliasMode one to it.
    "svc.zone.test": [(A, "127.0.0.1"), (HTTPS, "0001" "00" "0001000c02683208687474702f312e31"
                                                "0005004a0048fe0d004401002000201d77eb1c522d08605b179d4214ee4a3635df7e17c336ea"
                                                "9006655a73fcaad63e00040001000164156563682d73697465732e6578616d706c652e6e65740000")],
    "https.zone.test": [(HTTPS, "0000" "03737663047a6f6e65047465737400")],
    # The names that misbehave answer for themselves; these records are
    # what a well-behaved answer would have held.
    "wrong-id.zone.test": [(A, "192.0.2.66")],
    "cut.zone.test": [(A, "192.0.2.67")],
    "tc.zone.test": [(A, "192.0.2.68")],
    "long.zone.test": [(A, "192.0.2.69")],
}

LOCK = threading.Lock()
TLS_CONNECTIONS = [0]
# transport -> [queries, with an OPT record, not padded, first fault]
PADDING = {}
QUERY_BLOCK = 128
ANSWER_BLOCK = 468


def wire_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def read_question(query):
    """The query's ID, flags, name (lowercase) and type, or None."""
    if len(query) < 12:
        return None
    ident, flags, qd = struct.unpack(">HHH", query[:6])
    if qd != 1:
        return None
    at = 12
    labels = []
    while True:
        if at >= len(query):
            return None
        n = query[at]
        if n == 0:
            at += 1
            break
        if n & 0xC0:
            return None
        labels.append(query[at + 1:at + 1 + n].decode("ascii", "replace"))
        at += 1 + n
    if at + 4 > len(query):
        return None
    qtype = struct.unpack(">H", query[at:at + 2])[0]
    return ident, flags, ".".join(labels).lower(), qtype, query[12:at + 4]


def read_opt(query, question):
    """The query's OPT record, read past *question*: None when it has
    none, else (owner byte, payload size, TTL, data, a fault or None)."""
    an, ns, ar = struct.unpack(">HHH", query[6:12])
    at = 12 + len(question)
    if an or ns or ar == 0:
        return None
    if ar != 1:
        return (0, 0, 0, b"", "%d additional records, not one OPT record" % ar)
    if at + 11 > len(query):
        return (0, 0, 0, b"", "an additional record running past the message")
    owner = query[at]
    rtype, payload, ttl, length = struct.unpack(">HHIH", query[at + 1:at + 11])
    if rtype != 41:
        return None
    data = query[at + 11:]
    if len(data) != length:
        return (owner, payload, ttl, data, "an OPT record of %d data bytes with %d after it" % (length, len(data)))
    return (owner, payload, ttl, data, None)


def options_of(data):
    """The EDNS options in an OPT record's data, [(code, bytes)], or None
    when one runs past it."""
    found = []
    while data:
        if len(data) < 4:
            return None
        code, length = struct.unpack(">HH", data[:4])
        if len(data) < 4 + length:
            return None
        found.append((code, data[4:4 + length]))
        data = data[4 + length:]
    return found


def padding_fault(query, question):
    """Why *query* is not padded as RFC 7830 and RFC 8467 4.1 have a
    client pad it, or None when it is."""
    opt = read_opt(query, question)
    if opt is None:
        return "no OPT record"
    owner, payload, ttl, data, fault = opt
    if fault:
        return fault
    if owner != 0:
        return "an OPT record not owned by the root"
    if ttl >> 16:
        return "extended RCODE or version %d, not 0" % (ttl >> 16)
    # RFC 7830 4: a padded message no longer than the payload size it
    # states, which RFC 6891 6.2.3 reads as 512 when it says less.
    if len(query) > max(payload, 512):
        return "%d bytes, past the payload size of %d" % (len(query), payload)
    options = options_of(data)
    if options is None:
        return "an option running past the OPT record"
    codes = [code for code, _ in options]
    if 12 not in codes:
        return "no Padding option"
    if codes.count(12) > 1:
        return "two Padding options"
    # RFC 8467 3: the last option applied, so it is the one that ends it.
    if codes[-1] != 12:
        return "a Padding option that is not the last"
    if any(options[-1][1]):
        return "padding bytes that are not zero"
    if len(query) % QUERY_BLOCK:
        return "%d bytes, not a multiple of %d" % (len(query), QUERY_BLOCK)
    return None


def judge(query, question, transport):
    """The query counted against its transport's padding."""
    fault = padding_fault(query, question)
    with LOCK:
        seen = PADDING.setdefault(transport, [0, 0, 0, None])
        seen[0] += 1
        if read_opt(query, question) is not None:
            seen[1] += 1
        if fault:
            seen[2] += 1
            if seen[3] is None:
                seen[3] = fault


def padding_report(transport):
    with LOCK:
        seen = PADDING.pop(transport, [0, 0, 0, None])
    said = "queries=%d edns=%d unpadded=%d" % tuple(seen[:3])
    return said + (" first=" + seen[3] if seen[3] else "")


def rdata(rtype, data):
    if rtype == A:
        return ipaddress.IPv4Address(data).packed
    if rtype == AAAA:
        return ipaddress.IPv6Address(data).packed
    if rtype == CNAME:
        return wire_name(data)
    if rtype == HTTPS:
        return bytes.fromhex(data)
    return b"".join(bytes([len(s.encode())]) + s.encode() for s in data)


def answer(query, transport, stats=None):
    """The answer to *query* from ZONE, the special names answered."""
    read = read_question(query)
    if read is None:
        return struct.pack(">HHHHHH", struct.unpack(">H", query[:2])[0] if len(query) >= 2 else 0, 0x8001, 0, 0, 0, 0)
    ident, flags, name, qtype, question = read
    judge(query, question, transport)
    opt = read_opt(query, question)
    rd = flags & 0x0100
    records = []
    rcode = 0
    extended = 0
    tc = 0
    if name == "transport.zone.test" and qtype == TXT:
        records = [(name, TXT, [transport])]
    elif name == "stats.zone.test" and qtype == TXT:
        records = [(name, TXT, [stats() if stats else "connections=0"])]
    elif name == "id.zone.test" and qtype == TXT:
        records = [(name, TXT, ["id=%d" % ident])]
    elif name == "padding.zone.test" and qtype == TXT:
        records = [(name, TXT, [padding_report(transport)])]
    elif name == "badvers.zone.test" and opt is not None:
        extended = 1
    elif name in ZONE:
        target = name
        for _ in range(8):
            held = ZONE.get(target, [])
            alias = [d for t, d in held if t == CNAME]
            if alias and qtype != CNAME:
                records.append((target, CNAME, alias[0]))
                target = alias[0]
                continue
            records += [(target, t, d) for t, d in held if t == qtype]
            break
        if name == "tc.zone.test":
            tc = 0x0200
    elif name.endswith("zone.test"):
        rcode = 3
    else:
        rcode = 5
    if name == "wrong-id.zone.test":
        ident ^= 0x5555
    body = question
    for owner, rtype, data in records:
        value = rdata(rtype, data)
        body += wire_name(owner) + struct.pack(">HHIH", rtype, 1, 300, len(value)) + value
    authority = b""
    if rcode == 3:
        soa = wire_name("ns.zone.test") + wire_name("hostmaster.zone.test") + struct.pack(">IIIII", 1, 3600, 600, 86400, 300)
        authority = wire_name("zone.test") + struct.pack(">HHIH", 6, 1, 300, len(soa)) + soa
    additional = b""
    if opt is not None:
        options = options_of(opt[3]) or []
        data = b""
        if any(code == 12 for code, _ in options):
            unpadded = 12 + len(body) + len(authority) + 11 + 4
            pad = -unpadded % ANSWER_BLOCK
            data = struct.pack(">HH", 12, pad) + b"\x00" * pad
        additional = b"\x00" + struct.pack(">HHIH", 41, 1232, extended << 24, len(data)) + data
    head = struct.pack(">HHHHHH", ident, 0x8400 | 0x0080 | rd | tc | rcode, 1, len(records),
                       1 if authority else 0, 1 if additional else 0)
    return head + body + authority + additional


def make_pki(work):
    now = dt.datetime.now(dt.timezone.utc)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Encrypted DNS Test Root")])
    ca = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    key = ec.generate_private_key(ec.SECP256R1())
    leaf = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "dns.test")]))
        .issuer_name(ca_name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=20))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("dns.test"), x509.IPAddress(ipaddress.IPv4Address("127.0.0.1"))]), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    pem = serialization.Encoding.PEM
    write(work, "ca.pem", ca.public_bytes(pem).decode())
    write(work, "leaf.pem", leaf.public_bytes(pem).decode() + ca.public_bytes(pem).decode())
    write(work, "leaf.key", key.private_bytes(pem, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode())


def write(work, name, text):
    with open(os.path.join(work, name), "w", newline="\n") as handle:
        handle.write(text)


def context(work, alpn):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.path.join(work, "leaf.pem"), os.path.join(work, "leaf.key"))
    if alpn:
        ctx.set_alpn_protocols(alpn)
    return ctx


# --- DNS over TLS ---

def serve_dot(listener, ctx):
    while True:
        raw, _ = listener.accept()
        threading.Thread(target=dot_connection, args=(raw, ctx), daemon=True).start()


def dot_connection(raw, ctx):
    try:
        conn = ctx.wrap_socket(raw, server_side=True)
    except (ssl.SSLError, OSError):
        raw.close()
        return
    with LOCK:
        TLS_CONNECTIONS[0] += 1
    seen = {"queries": 0, "batch": 0}

    def stats():
        with LOCK:
            made = TLS_CONNECTIONS[0]
        return "connections=%d queries=%d batch=%d" % (made, seen["queries"], seen["batch"])

    buf = b""
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            buf += data
            # What else is already on its way: a client that pipelines has
            # written its queries before reading any answer.
            while conn.pending() or select.select([conn], [], [], 0.05)[0]:
                more = conn.recv(65536)
                if not more:
                    break
                buf += more
            frames = []
            while len(buf) >= 2:
                n = struct.unpack(">H", buf[:2])[0]
                if len(buf) < 2 + n:
                    break
                frames.append(buf[2:2 + n])
                buf = buf[2 + n:]
            seen["queries"] += len(frames)
            seen["batch"] = max(seen["batch"], len(frames))
            # Answered last first, so a client that matches by ID is held to it.
            for query in reversed(frames):
                message = answer(query, "tls", stats)
                read = read_question(query)
                name = read[2] if read else ""
                if name == "cut.zone.test":
                    conn.sendall(struct.pack(">H", len(message)) + message[: len(message) // 2])
                    conn.close()
                    return
                if name == "long.zone.test":
                    message += b"\x00" * 40
                conn.sendall(struct.pack(">H", len(message)) + message)
    except (ssl.SSLError, OSError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


# --- DNS over HTTPS ---

def doh_answer(method, path, headers, body, transport):
    """(status, content type, body bytes, declared length or None)."""
    parts = urllib.parse.urlsplit(path)
    if parts.path not in ("/dns-query", "/status-500", "/wrong-type"):
        return 404, "text/plain", b"no such path", None
    if method == "GET":
        values = urllib.parse.parse_qs(parts.query).get("dns", [])
        if len(values) != 1:
            return 400, "text/plain", b"no dns parameter", None
        text = values[0]
        if "=" in text or "+" in text or "/" in text:
            return 400, "text/plain", b"the dns parameter is base64url without padding", None
        try:
            query = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
        except ValueError:
            return 400, "text/plain", b"the dns parameter is not base64url", None
    elif method == "POST":
        if (headers.get("content-type") or "").split(";")[0].strip().lower() != MEDIA:
            return 415, "text/plain", b"not application/dns-message", None
        query = body
    else:
        return 405, "text/plain", b"GET or POST", None
    message = answer(query, transport)
    read = read_question(query)
    name = read[2] if read else ""
    if parts.path == "/status-500":
        return 500, MEDIA, message, None
    if parts.path == "/wrong-type":
        return 200, "text/plain", message, None
    if name == "long.zone.test":
        return 200, MEDIA, message + b"\x00" * (70000 - len(message)), None
    if name == "cut.zone.test":
        return 200, MEDIA, message[: len(message) // 2], len(message)
    return 200, MEDIA, message, None


class DohHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle_one(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        headers = {k.lower(): v for k, v in self.headers.items()}
        status, kind, data, declared = doh_answer(method, self.path, headers, body, "https/1.1")
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(declared if declared is not None else len(data)))
        self.send_header("Cache-Control", "max-age=300")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()
        if declared is not None:
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")


class TlsHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def __init__(self, address, ctx):
        self.ctx = ctx
        super().__init__(address, DohHandler)

    def get_request(self):
        raw, peer = self.socket.accept()
        raw.settimeout(10)
        try:
            return self.ctx.wrap_socket(raw, server_side=True), peer
        except (ssl.SSLError, OSError):
            raw.close()
            raise OSError("handshake refused")

    def handle_error(self, request, client_address):
        pass


def serve_h2(listener, ctx):
    while True:
        raw, _ = listener.accept()
        threading.Thread(target=h2_connection, args=(raw, ctx), daemon=True).start()


def h2_connection(raw, ctx):
    import h2.config
    import h2.connection
    import h2.events

    try:
        conn = ctx.wrap_socket(raw, server_side=True)
    except (ssl.SSLError, OSError):
        raw.close()
        return
    h2c = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False, header_encoding="utf-8"))
    h2c.initiate_connection()
    conn.sendall(h2c.data_to_send())
    streams = {}
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            for event in h2c.receive_data(data):
                if isinstance(event, h2.events.RequestReceived):
                    streams[event.stream_id] = [dict(event.headers), b""]
                elif isinstance(event, h2.events.DataReceived):
                    streams[event.stream_id][1] += event.data
                    h2c.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, h2.events.StreamEnded):
                    head, body = streams.pop(event.stream_id)
                    status, kind, payload, declared = doh_answer(head.get(":method"), head.get(":path", "/"), head, body, "h2")
                    h2c.send_headers(event.stream_id, [(":status", str(status)), ("content-type", kind),
                                                       ("content-length", str(len(payload))), ("cache-control", "max-age=300")])
                    at = 0
                    while True:
                        room = min(h2c.local_flow_control_window(event.stream_id), h2c.max_outbound_frame_size, len(payload) - at)
                        last = at + room >= len(payload)
                        h2c.send_data(event.stream_id, payload[at:at + room], end_stream=last)
                        at += room
                        conn.sendall(h2c.data_to_send())
                        if last:
                            break
                        # Wait for the window to open.
                        more = conn.recv(65536)
                        if not more:
                            return
                        h2c.receive_data(more)
                elif isinstance(event, h2.events.ConnectionTerminated):
                    return
            conn.sendall(h2c.data_to_send())
    except (ssl.SSLError, OSError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


# --- plain UDP ---

class UdpHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(answer(data, "udp"), self.client_address)


def listen_tcp():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(64)
    return listener


def main():
    work = sys.argv[1]
    make_pki(work)

    dot = listen_tcp()
    threading.Thread(target=serve_dot, args=(dot, context(work, None)), daemon=True).start()
    write(work, "dot.port", str(dot.getsockname()[1]))

    doh = TlsHTTPServer(("127.0.0.1", 0), context(work, ["http/1.1"]))
    threading.Thread(target=doh.serve_forever, daemon=True).start()
    write(work, "doh.port", str(doh.server_address[1]))

    try:
        import h2.connection  # noqa: F401
        have_h2 = True
    except ImportError as missing:
        have_h2 = False
        write(work, "h2.missing", "no h2 package for this python (%s), so there is no HTTP/2 server" % missing)
    if have_h2:
        h2_listener = listen_tcp()
        threading.Thread(target=serve_h2, args=(h2_listener, context(work, ["h2"])), daemon=True).start()
        write(work, "h2.port", str(h2_listener.getsockname()[1]))

    udp = socketserver.ThreadingUDPServer(("127.0.0.1", 0), UdpHandler)
    threading.Thread(target=udp.serve_forever, daemon=True).start()
    write(work, "udp.port", str(udp.server_address[1]))

    write(work, "ready", "ready\n")
    threading.Event().wait()


if __name__ == "__main__":
    main()
