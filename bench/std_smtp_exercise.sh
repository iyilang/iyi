#!/usr/bin/env bash
# Exercises `std/smtp`.
#
#     bash bench/std_smtp_exercise.sh
#
# The exercise holds the client to servers it scripts itself over
# loopback; this gate runs it plain and --release, then holds the client
# to an SMTP server written here by hand in Python: in plain TCP, under
# STARTTLS and under TLS from the first byte with a certificate made by
# `cryptography`, with AUTH PLAIN, LOGIN and CRAM-MD5 checked by the
# server, the message read back on the server's side after its dots are
# undone and parsed by Python's `email`, and the server refusing a
# recipient, a password, hanging up, saying nothing and presenting a
# certificate the client does not trust. It names what is refused with
# its sentence, and proves on broken copies of the module that the checks
# fail where they say.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_smtp_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/smtp exercise, plain build"
build_and_run "plain" smtp-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/smtp-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every smtp section reported"
for phrase in "== a whole session" "== dot-stuffing" "== reply codes" "== EHLO and HELO" "== extensions in MAIL FROM" "== AUTH" "== servers that misbehave"; do
  if ! grep -q "$phrase" "$WORK/smtp-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" smtp-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/smtp-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# One SMTP session, written by hand: the server says what its scenario
# has it say, checks AUTH's credentials, undoes DATA's dots, and writes
# down what it heard as JSON.
cat >"$WORK/server.py" <<'PY'
import base64, hashlib, hmac, json, os, socket, ssl, sys, time
scenario, portfile, cert, key, log = sys.argv[1:6]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
listener = socket.create_server(("127.0.0.1", 0))
open(portfile + ".tmp", "w").write(str(listener.getsockname()[1]))
os.rename(portfile + ".tmp", portfile)
listener.settimeout(60)
conn, _ = listener.accept()
conn.settimeout(20)
record = {"heard": [], "tls_at_auth": None, "tls": False, "data": None, "raw": None, "mail": None, "rcpt": []}
tls = False
def done():
    record["tls"] = tls
    json.dump(record, open(log, "w"))
    sys.exit(0)
if scenario == "tls":
    try:
        conn = ctx.wrap_socket(conn, server_side=True)
    except (ssl.SSLError, OSError) as e:
        record["handshake"] = str(e); done()
    tls = True
reader = conn.makefile("rb")
def say(text): conn.sendall(text.encode())
def line():
    # A client that ends its session on an error closes without QUIT, and
    # Windows reports that close as a reset rather than an end of file.
    try:
        got = reader.readline(4096)
    except ConnectionResetError:
        got = b""
    if got: record["heard"].append(got.decode("utf-8", "replace").rstrip("\r\n"))
    return got
if scenario == "silent":
    time.sleep(4)
    done()
say("220-test.example ESMTP ready\r\n220 written in Python\r\n")
while True:
    got = line()
    if not got: break
    text = got.decode("utf-8", "replace").rstrip("\r\n")
    verb = text.split(" ")[0].upper()
    if verb == "EHLO":
        if scenario == "drop":
            conn.close(); done()
        ext = ["test.example greets " + text[5:], "SIZE 1000000", "8BITMIME", "AUTH PLAIN LOGIN CRAM-MD5", "HELP"]
        if scenario in ("starttls", "wrong-cert") and not tls: ext.append("STARTTLS")
        if scenario == "utf8": ext.append("SMTPUTF8")
        say("".join(f"250-{e}\r\n" for e in ext[:-1]) + f"250 {ext[-1]}\r\n")
    elif verb == "STARTTLS":
        say("220 2.0.0 ready\r\n")
        reader.close()
        try:
            conn = ctx.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError) as e:
            record["handshake"] = str(e); done()
        tls = True
        reader = conn.makefile("rb")
    elif verb == "AUTH":
        record["tls_at_auth"] = tls
        mech = text.split(" ")[1].upper()
        user = pw = None
        if mech == "PLAIN":
            _, user, pw = base64.b64decode(text.split(" ")[2]).decode().split("\0")
        elif mech == "LOGIN":
            say("334 VXNlcm5hbWU6\r\n"); user = base64.b64decode(line().strip()).decode()
            say("334 UGFzc3dvcmQ6\r\n"); pw = base64.b64decode(line().strip()).decode()
        elif mech == "CRAM-MD5":
            challenge = b"<12345.67890@test.example>"
            say("334 " + base64.b64encode(challenge).decode() + "\r\n")
            user, digest = base64.b64decode(line().strip()).decode().split(" ")
            pw = "s3cret pass" if hmac.compare_digest(digest, hmac.new(b"s3cret pass", challenge, hashlib.md5).hexdigest()) else "?"
        record["auth"] = [mech, user, pw]
        if user == "ann@example.com" and pw == "s3cret pass": say("235 2.7.0 accepted\r\n")
        else: say("535 5.7.8 authentication credentials invalid\r\n")
    elif verb == "MAIL":
        record["mail"] = text
        say("250 2.1.0 ok\r\n")
    elif verb == "RCPT":
        record["rcpt"].append(text)
        if scenario == "reject" and "nobody@" in text: say("550 5.1.1 <nobody@example.org>: no such user here\r\n")
        else: say("250 2.1.5 ok\r\n")
    elif verb == "DATA":
        say("354 end with <CRLF>.<CRLF>\r\n")
        raw = b""
        while True:
            chunk = reader.readline(100000)
            if not chunk or chunk == b".\r\n": break
            if not chunk.endswith(b"\r\n"): record["bare_lf"] = True
            raw += chunk
        record["raw"] = raw.hex()
        # Undo the dots (RFC 5321 section 4.5.2): a line that begins with
        # one loses it.
        record["data"] = b"".join(l[1:] if l.startswith(b".") else l for l in raw.splitlines(keepends=True)).hex()
        if scenario == "drop-data":
            conn.close(); done()
        say("250 2.0.0 queued as 1\r\n")
    elif verb == "RSET":
        say("250 2.0.0 reset\r\n")
    elif verb == "QUIT":
        say("221 2.0.0 bye\r\n"); break
    else:
        say("500 5.5.2 what\r\n")
conn.close()
done()
PY

# What each scenario must come to: the client's last line, and what the
# server must have seen, as a Python expression over its record `r` and
# the message `m` the client sent.
cat >"$WORK/judge.py" <<'PY'
import email, email.policy, json, sys
scenario, log, out = sys.argv[1:4]
lines = open(out, encoding="utf-8").read().splitlines()
r = json.load(open(log))
sent = next((bytes.fromhex(l.split(" ")[1]) for l in lines if l.startswith("message ")), None)
said = [l for l in lines if not l.startswith("message ")]
got = bytes.fromhex(r["data"]) if r.get("data") else None
def parsed():
    m = email.message_from_bytes(got, policy=email.policy.default)
    return m
def delivered():
    return got is not None and got == sent + b"\r\n" and not r.get("bare_lf") and b"\r\n..\r\n...two\r\n..three\r\n" in bytes.fromhex(r["raw"])
want = {
    "plain": lambda: said[-3:] == ["auth: ok", "send: ok", "quit: ok"] and r["auth"] == ["PLAIN", "ann@example.com", "s3cret pass"] and delivered()
        and r["rcpt"] == ["RCPT TO:<bob@example.org>", "RCPT TO:<eve@example.net>"] and parsed()["Bcc"] is None
        # The message ends without a line break, and DATA gives it one.
        and parsed().get_body(("plain",)).get_content().replace("\r\n", "\n") == ".\n..two\n.three\nplain\n. space\n\nend\n.\n",
    "starttls": lambda: said[0] == "tls true" and r["tls"] and r["tls_at_auth"] and r["auth"][0] == "LOGIN" and delivered()
        and r["heard"][:3] == ["EHLO client.example", "STARTTLS", "EHLO client.example"],
    "tls": lambda: said[0] == "tls true" and r["tls"] and r["tls_at_auth"] and r["auth"][0] == "PLAIN" and delivered(),
    "cram": lambda: r["auth"] == ["CRAM-MD5", "ann@example.com", "s3cret pass"] and said[-1] == "quit: ok" and delivered(),
    "bad-password": lambda: said[-1] == "auth: 535 SMTP: AUTH PLAIN was refused: 535 5.7.8 authentication credentials invalid" and r["mail"] is None,
    "reject": lambda: said[-1] == "send: 550 SMTP: RCPT TO:<nobody@example.org> was refused: 550 5.1.1 <nobody@example.org>: no such user here"
        and r["heard"][-1] == "RSET" and got is None,
    "drop": lambda: said[-1] == "connect: 0 SMTP: the server closed the connection",
    "drop-data": lambda: said[-1] == "send: 0 SMTP: the server closed the connection" and delivered(),
    "silent": lambda: said[-1].startswith("connect: 0 SMTP: reading from 127.0.0.1 failed") and said[-1].endswith("(timed out)"),
    "wrong-cert": lambda: said[-1].startswith("connect: 0 SMTP: the TLS handshake with localhost failed: tls: the server's certificate is not trusted")
        and r["heard"] == ["EHLO client.example", "STARTTLS"],
    "utf8": lambda: r["mail"].endswith(" SMTPUTF8 BODY=8BITMIME") and "RCPT TO:<jörg@bücher.example>" in r["rcpt"] and delivered()
        and said[-1] == "quit: ok",
}[scenario]
ok = False
try:
    ok = want()
except Exception as e:
    print(f"    ({type(e).__name__}: {e})")
print(f"  {scenario}: {said[-1] if said else 'nothing said'}" + ("" if ok else "  <- NOT what it should be"))
if not ok:
    print("    the server heard: " + " | ".join(r["heard"][:12]))
sys.exit(0 if ok else 1)
PY

# session <binary> <scenario> <roots>: the Python server for one
# scenario, the client against it, and the judgement.
session() {
  rm -f "$WORK/port" "$WORK/log.json"
  "$PY" "$WORK/server.py" "$2" "$WORK/port" "$WORK/certs/chain.pem" "$WORK/certs/key.pem" "$WORK/log.json" 2>"$WORK/server.err" &
  local pid=$! waited=0
  while [ ! -s "$WORK/port" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ ! -s "$WORK/port" ]; then
    echo "  $2: the server did not start: $(tail -1 "$WORK/server.err")"
    kill "$pid" 2>/dev/null
    return 1
  fi
  timeout 60 "$1" client "$(cat "$WORK/port")" "$2" "$3" >"$WORK/client.out" 2>&1
  wait "$pid"
  if [ ! -s "$WORK/log.json" ]; then
    echo "  $2: the server wrote no record: $(tail -1 "$WORK/server.err")"
    return 1
  fi
  "$PY" "$WORK/judge.py" "$2" "$WORK/log.json" "$WORK/client.out"
}

SCENARIOS="plain starttls tls cram bad-password reject drop drop-data silent wrong-cert utf8"

echo
echo "== the client against an SMTP server written in python"
# A root and a localhost leaf it signs, made by `cryptography`, for the
# server; another root, which signs nothing the server shows, for
# wrong-cert. std/x509 takes no self-signed leaf for its own anchor, as
# browsers take none, so the certificate the server presents is a root's.
if [ -z "$PY" ] || ! "$PY" -c 'import ssl; from cryptography import x509' >/dev/null 2>&1; then
  echo "  skipped: no python3 with ssl and cryptography to serve SMTP with"
  SCENARIOS=""
else
  mkdir -p "$WORK/certs"
  "$PY" - "$WORK/certs" <<'PY'
import datetime as dt, os, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
out = sys.argv[1]
now = dt.datetime.now(dt.timezone.utc)
def name(cn): return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
pem = lambda c: c.public_bytes(serialization.Encoding.PEM)
for label in ["", "other-"]:
    root_key, key = ec.generate_private_key(ec.SECP256R1()), ec.generate_private_key(ec.SECP256R1())
    root = (x509.CertificateBuilder().subject_name(name("smtp test root")).issuer_name(name("smtp test root"))
            .public_key(root_key.public_key()).serial_number(1).not_valid_before(now - dt.timedelta(days=1))
            .not_valid_after(now + dt.timedelta(days=2))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()), critical=False)
            .sign(root_key, hashes.SHA256()))
    leaf = (x509.CertificateBuilder().subject_name(name("localhost")).issuer_name(root.subject)
            .public_key(key.public_key()).serial_number(2).not_valid_before(now - dt.timedelta(days=1))
            .not_valid_after(now + dt.timedelta(days=2))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), critical=False)
            .sign(root_key, hashes.SHA256()))
    open(os.path.join(out, label + "roots.pem"), "wb").write(pem(root))
    open(os.path.join(out, label + "chain.pem"), "wb").write(pem(leaf) + pem(root))
    open(os.path.join(out, label + "key.pem"), "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
PY
  for scenario in $SCENARIOS; do
    roots="$WORK/certs/roots.pem"
    [ "$scenario" = wrong-cert ] && roots="$WORK/certs/other-roots.pem"
    session "$WORK/smtp-plain" "$scenario" "$roots" || status=1
  done
fi

echo
echo "== what smtp refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/smtp::{SmtpClient, SmtpError, SmtpSecurity}
import std/socket::{IyiSocket}
import std/tls::{TlsConfig}
import std/mail::{Mail}

# A session to a listener that never answers, which these never reach.
listener = IyiSocket.listen("127.0.0.1", 0)
client = SmtpClient.new(IyiSocket.connect("127.0.0.1", listener.local_port).or_panic, "localhost", "client.example", 1000)
case Program.args[0]
when "timeout"
  SmtpClient.connect("127.0.0.1", 25, SmtpSecurity::Cleartext, TlsConfig.new, nil, 0)
when "helo"
  SmtpClient.connect("127.0.0.1", 25, SmtpSecurity::Cleartext, TlsConfig.new, "two words")
when "no-recipients"
  client.send("a@x.test", [] of String, "x")
when "angle"
  client.send("a@x.test", ["b@x.test>"], "x")
when "command-break"
  client.command("NOOP\r\nRSET")
when "password-break"
  client.auth("ann", "pass\r\nQUIT")
when "no-from"
  m = Mail::Message.new
  m.to << Mail::Address.new("b@x.test")
  client.send(m)
when "or-panic"
  SmtpClient.connect("127.0.0.1", listener.local_port, SmtpSecurity::Cleartext, TlsConfig.new, nil, 300).or_panic
end
puts "accepted"
IYI
refuse() { # refuse <case> <phrase>
  if "$IYI" run "$WORK/refuse.iyi" -- "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qF -e "$2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  else
    echo "  $1: $(tr -d '\r' <"$WORK/refuse.out" | grep -oF -e "$2" | head -1)"
  fi
}
refuse timeout "SMTP: a timeout is a count of milliseconds, at least 1, not 0"
refuse helo "SMTP: the EHLO name \"two words\" is not a name"
refuse no-recipients "SMTP: a message with no recipients"
refuse angle "SMTP: \"b@x.test>\" is not an address to put in angle brackets"
refuse command-break "SMTP: a command holds a line break"
refuse password-break "SMTP: a user name or password holds a line break"
refuse no-from "SMTP: a message has no From"
# An error value is not a panic until it is asked to be one.
refuse or-panic "SMTP: reading from 127.0.0.1 failed: cannot read from socket: timed out"

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [scenario]: on a copy of the
# module with <old> replaced, the exercise must fail at the check that
# names <phrase> - or, given a scenario, the client against the Python
# server must, saying <phrase>.
prove_broken() {
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$3" NEW="$4" "$PY" - "$REPO/src/std/smtp.iyi" "$WORK/patched/std/smtp.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
    return
  fi
  if [ -n "${5:-}" ]; then
    if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/smtp-broken" "$REPO/bench/std_smtp_exercise.iyi" >"$WORK/mut.log" 2>&1; then
      echo "  the $1 copy did not compile"
      status=1
      return
    fi
    session "$WORK/smtp-broken" "$5" "$WORK/certs/roots.pem" >"$WORK/mut.out" 2>&1
  else
    IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 300 "$IYI" run "$REPO/bench/std_smtp_exercise.iyi" >"$WORK/mut.out" 2>&1
  fi
  if [ $? -eq 0 ]; then
    echo "  the check PASSED on $1"
    status=1
  elif grep -qF -e "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "a dot at a line's start sent once" "a lone dot" \
  'io.write_byte(46_u8) if start && b == 46_u8' 'io.write_byte(46_u8) if false && b == 46_u8'
prove_broken "a bare LF sent bare" "LF and CR become CRLF" \
  '        io << "\r\n"
        i = i + 1 if b == 13_u8' '        io.write_byte(b)
        i = i + 1 if b == 13_u8'
prove_broken "a reply's continuation taken for its end" "EHLO was refused: 220 second line" \
  'return SmtpReply.new(code, lines) unless line.bytesize > 3 && p[3] == 45_u8' 'return SmtpReply.new(code, lines)'
prove_broken "codes that disagree taken" "a reply whose codes disagree" \
  'if code != 0 && this != code' 'if false'
prove_broken "EHLO's first line taken for an extension" "the greeting line of EHLO is not an extension" \
  '      if i > 0
        space = line.index' '      if i >= 0
        space = line.index'
prove_broken "a refused recipient passed over" "a refused recipient is its 550" \
  'unless answer.code == 250 || answer.code == 251' 'unless true'
prove_broken "no RSET after a refused recipient" "the server waited for \"RSET\"" \
  '        reset = command("RSET")
        return reset if reset.is_a?(SmtpError)' '        reset = nil'
prove_broken "HELO never tried" "EHLO was refused: 502" \
  'if answer.code == 500 || answer.code == 502 || answer.code == 504' 'if false'
prove_broken "SIZE not asked of the server" "the server waited for \"MAIL FROM:<ANN@EXAMPLE.COM> SIZE=\"" \
  'params = " SIZE=#{wire.bytesize}" + params' 'params = "" + params'
prove_broken "8-bit data sent without 8BITMIME" "8-bit data is not sent to a server without 8BITMIME" \
  '      elsif !wide
        return SmtpError.new("the message has bytes past ASCII' '      elsif false
        return SmtpError.new("the message has bytes past ASCII'
prove_broken "SMTPUTF8 not asked for" "MAIL FROM asks for SMTPUTF8" \
  'params = params + " SMTPUTF8"' 'params = params + ""'
prove_broken "a password sent in the clear" "AUTH over cleartext is refused" \
  'unless tls? || @cleartext_auth' 'unless true'
prove_broken "PLAIN without its first NUL" "PLAIN's message is NUL, user, NUL, password" \
  'Base64.encode("\u0000" + user + "\u0000" + password)' 'Base64.encode(user + "\u0000" + password)'
prove_broken "CRAM-MD5 keyed with the challenge" "RFC 2195's response to its challenge" \
  'HMAC.hexdigest(MD5, password, challenge)' 'HMAC.hexdigest(MD5, challenge, password)'
prove_broken "a reply line unbounded" "a line too long" \
  'if (nl || @held.bytesize) > MAX_LINE + 1' 'if false'
prove_broken "a reply unbounded in lines" "a reply too long" \
  'if lines.size >= MAX_LINES' 'if false'
prove_broken "bytes after STARTTLS's 220 taken" "bytes after STARTTLS's 220" \
  'unless @held.empty?' 'if false'
prove_broken "STARTTLS not required" "and heard \"STARTTLS" \
  'unless @extensions.has_key?("STARTTLS")' 'if false'
prove_broken "no timeout on a read" "a server that says nothing times out" \
  'socket.read_timeout_ms = timeout_ms' 'socket.read_timeout_ms = nil'
if [ -n "$SCENARIOS" ]; then
  prove_broken "no EHLO after STARTTLS" "starttls:" \
    '      problem = secure(config)
      return problem if problem
      problem = hello' '      problem = secure(config)
      return problem if problem
      problem = nil' starttls
  prove_broken "the handshake skipped after STARTTLS" "starttls:" \
    '      problem = secure(config)
      return problem if problem
      problem = hello' '      problem = nil
      return problem if problem
      problem = hello' starttls
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/smtp exercise holds"
else
  echo "the std/smtp exercise did not hold"
fi
exit $status
