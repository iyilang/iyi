#!/usr/bin/env bash
# Exercises `std/ocsp`.
#
#     bash bench/std_ocsp_exercise.sh
#
# The exercise judges responses Python's cryptography built and responses
# written by hand, each verdict held to the one it names; this gate runs
# it plain and --release, has OpenSSL judge the same vectors, then holds
# std/ocsp to OpenSSL's own responder (`openssl ocsp -index`): responses
# from the CA, from delegated responders and from ones that may not
# answer, under P-256, P-384, RSA and RSA-PSS, each verdict the one
# `openssl ocsp -respin -verify` gives, and requests the same bytes
# OpenSSL writes and read by its responder and by Python. Then responses
# Python builds now, mutated one way each, judged as OpenSSL judges them,
# and every response here read field by field as Python's
# `load_der_ocsp_response` reads it. Last, broken copies of the module,
# each caught at the check that names it.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# Windows answers `python3` with a store stub that prints and exits, so
# the interpreter is measured rather than assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
# OpenSSL itself, where Homebrew installed it: macOS's `openssl` is
# LibreSSL, which is not the oracle here (below).
OPENSSL="${OPENSSL:-openssl}"
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  [ -x "$candidate" ] && OPENSSL="$candidate" && break
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's path mapping: a scratch
# directory named `/tmp/tmp.X` is not found on Windows, and a patched copy
# would never be read.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_ocsp_exercise.iyi" \
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

echo "== the std/ocsp exercise, plain build"
build_and_run "plain" ocsp-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/ocsp-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi
X="$WORK/ocsp-plain"

echo
echo "== every ocsp section reported"
for phrase in "== responses judged at 2026-11-01" "== what a response says, read" "== requests, as OpenSSL and Python's cryptography write them" \
  "== the TLS Feature extension and id-pkix-ocsp-nocheck" "== every truncation and flipped byte refused"; do
  if ! grep -q "$phrase" "$WORK/ocsp-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" ocsp-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/ocsp-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# OpenSSL's verdict on a response: malformed (not read, or a responder's
# error), signer (the signature or the responder refused), certid (no
# status for the leaf), time (status times invalid) or the status.
# openssl_verdict <response> <leaf.pem> <issuer.pem> <CAfile> <hash> [more
# args]: the CertID OpenSSL looks for is under <hash> (sha1, sha256, ...).
openssl_verdict() {
  local response="$1" leaf="$2" issuer="$3" cafile="$4" hash="$5" out
  shift 5
  out="$("$OPENSSL" ocsp -no_nonce -respin "$response" -issuer "$issuer" "-$hash" -cert "$leaf" -CAfile "$cafile" "$@" 2>&1)"
  case "$out" in
    *"Responder Error"* | *"Error reading OCSP response"* | *"rror parsing"* | *"unable to load"*) echo malformed ;;
    *"Response Verify Failure"*) echo signer ;;
    *"No Status found"*) echo certid ;;
    *"Status times invalid"*) echo time ;;
    *": good"*) echo good ;;
    *": revoked"*) echo revoked ;;
    *": unknown"*) echo unknown ;;
    *) echo "unread: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)" ;;
  esac
}

# How a verdict of std/ocsp's and one of OpenSSL's compare: `same`;
# `refused`, both refusing for reasons that differ; or `parted`, one taking
# the response and the other not (or OpenSSL's answer unread). The
# decision to take a response or not is held exactly; the reason for a
# refusal is not, because OpenSSL builds differ in which check refuses
# first: a response for another issuer's CertID, signed by the CA, was "No
# Status found" (certid) to OpenSSL 3.5.5, 3.0.15 and 1.1.1w built on
# Linux, and a verify failure (signer) to the OpenSSL on darwin's CI
# runner, which also refused a CertID cut short and a response with no
# SingleResponse at verify. The sections print the version they asked.
compare() { # compare <ours> <theirs>
  if [ "$1" = "$2" ]; then
    echo same
    return
  fi
  case "$1:$2" in
    malformed:malformed | malformed:signer | malformed:certid | malformed:time | signer:malformed | signer:certid | signer:time | \
      certid:malformed | certid:signer | certid:time | time:malformed | time:signer | time:certid) echo refused ;;
    *) echo parted ;;
  esac
}

# OpenSSL's own: LibreSSL's ocsp (macOS's /usr/bin/openssl) words and
# judges otherwise, and is not the oracle here. Each section that asks it
# names the version it asked.
HAVE_OPENSSL=no
if command -v "$OPENSSL" >/dev/null 2>&1 && [ -n "$PY" ] && "$OPENSSL" version 2>/dev/null | grep -q '^OpenSSL'; then
  help="$("$OPENSSL" ocsp -help 2>&1)"
  if printf '%s' "$help" | grep -q -- '-index' && printf '%s' "$help" | grep -q -- '-rsigner' &&
     printf '%s' "$help" | grep -q -- '-attime' && printf '%s' "$help" | grep -q -- '-validity_period'; then
    HAVE_OPENSSL=yes
  fi
fi

echo
echo "== the exercise's vectors, judged by OpenSSL"
# Each response of the exercise OpenSSL can be asked of - a leaf with its
# own issuer - judged by `openssl ocsp -respin -verify` at the exercise's
# time (-attime, for the responder's certificate) with its own skew
# opened wide (-validity_period), since OpenSSL holds a response's times
# to the clock and no flag moves it: OpenSSL's signer, certid and status
# against std/ocsp's, a time refusal of std/ocsp's against whatever status
# OpenSSL reads. Where the two part, the line below names it and why:
# std/ocsp holds to the DER and to RFC 5280's keyUsage where OpenSSL lets
# a response through. Both refusing, for reasons that differ, is agreement
# (`compare`, above), and shown.
if [ "$HAVE_OPENSSL" = no ]; then
  echo "  no OpenSSL with ocsp's -index, -rsigner, -attime and -validity_period here (or no python), so the vectors go unjudged by OpenSSL"
else
  echo "  $("$OPENSSL" version) ($OPENSSL)"
  V="$WORK/vectors"
  mkdir -p "$V"
  "$X" vectors "$V"
  tr -d '\r' <"$V/list" >"$V/list.lf" && mv "$V/list.lf" "$V/list"
  for der in "$V"/*.der; do
    "$OPENSSL" x509 -inform DER -in "$der" -out "${der%.der}.pem"
  done
  NOW_2026_11_01=1793491200
  # name -> std/ocsp's verdict, OpenSSL's, and why they part.
  "$PY" - "$V/divergences" <<'PY'
import sys
rows = [
    ("a delegated responder not allowed digitalSignature", "signer", "good",
     "RFC 5280 section 4.2.1.3: a keyUsage without digitalSignature allows no signature; OpenSSL checks only the responder's extKeyUsage"),
    ("a response signed under SHA-1", "signer", "good", "SHA-1 is refused in a response as std/x509 refuses it in a certificate"),
    ("a response with a critical extension it does not understand", "malformed", "good", "RFC 5280 section 4.2: a critical extension not understood is not passed over"),
    ("a critical extension in a SingleResponse", "malformed", "good", "the same, in singleExtensions"),
    ("a ResponseData whose version is written out", "malformed", "good", "DER leaves a DEFAULT out (X.690 section 11.5), as Python's reader holds"),
    ("a ResponseData of version 2", "malformed", "good", "RFC 6960 has v1 alone"),
    ("a revocation reason of 7", "malformed", "revoked", "CRLReason has no 7"),
    ("an extension twice", "malformed", "good", "RFC 5280 section 4.2: an extension appears once"),
    ("a nonce that is not an OCTET STRING", "malformed", "good", "RFC 8954: the nonce is an OCTET STRING; OpenSSL reads it only against a request"),
    ("a byte after the response", "malformed", "good", "DER is one value with nothing after it"),
]
with open(sys.argv[1], "w", newline="\n") as f:
    for name, ours, theirs, why in rows:
        f.write(f"{name}|{ours}|{theirs}|{why}\n")
PY
  agreed=0
  refused=0
  parted=0
  while IFS='|' read -r name resp leaf issuer ours hash; do
    [ -n "$name" ] || continue
    # OpenSSL's CertID is under the hash the response's is, which it is
    # told: SHA-1 unless another.
    theirs="$(openssl_verdict "$V/$resp" "$V/$leaf.pem" "$V/$issuer.pem" "$V/$issuer.pem" "$hash" -attime "$NOW_2026_11_01" -validity_period 1000000000)"
    same="$(compare "$ours" "$theirs")"
    # A time std/ocsp refuses is one OpenSSL, with its skew opened, reads
    # past to the status.
    [ "$ours" = time ] && case "$theirs" in good | revoked | unknown) same=same ;; esac
    if [ "$same" = refused ] && ! grep -qF "$name|" "$V/divergences"; then
      echo "  $name: refused by both, std/ocsp for $ours, OpenSSL for $theirs"
      refused=$((refused + 1))
    elif [ "$same" != parted ]; then
      # Another OpenSSL may hold to what this one lets through.
      grep -qF "$name|" "$V/divergences" && echo "  $name: written down as parting, and this OpenSSL agrees ($theirs)"
      agreed=$((agreed + 1))
    elif grep -qF "$name|$ours|$theirs|" "$V/divergences"; then
      echo "  $name: std/ocsp $ours, OpenSSL $theirs - $(grep -F "$name|" "$V/divergences" | cut -d'|' -f4)"
      parted=$((parted + 1))
    else
      echo "  FAIL $name: std/ocsp $ours, OpenSSL $theirs"
      status=1
    fi
  done <"$V/list"
  echo "  $agreed vectors judged alike, $refused refused by both for reasons that differ, $parted parting where written down"
fi

echo
echo "== OpenSSL's responder"
# A CA on P-256 and leaves under it - good, revoked (keyCompromise), one
# its index does not hold (unknown) - and responses `openssl ocsp -index`
# makes: from the CA by name and by key id (-resp_key_id), from delegated
# responders (id-kp-OCSPSigning with nocheck and without, serverAuth
# alone, one issued by another CA, one left out of the response with
# -resp_no_certs), for two certificates at once, for a SHA-256 CertID,
# from an RSA CA under PKCS #1 v1.5 and under PSS (-rsigopt), from a P-384
# CA under SHA-384 (-rmd), and to std/ocsp's own request. Each judged for
# its leaf and for another one, std/ocsp's verdict held to `openssl ocsp
# -respin -verify`'s, now. Then the requests: std/ocsp's the same bytes as
# OpenSSL's -reqout under SHA-1 and SHA-256, its nonce as `-req_text`
# reads it, and the whole of it as Python's OCSPRequestBuilder writes it.
L="$WORK/live"
if [ "$HAVE_OPENSSL" = no ]; then
  echo "  no OpenSSL with ocsp's -index, -rsigner, -attime and -validity_period here (or no python), so its responder goes unasked"
else
  echo "  $("$OPENSSL" version)"
  mkdir -p "$L"
  (
    cd "$L" || exit 1
    ca() { # ca <name> <CN> <key args...>
      local name="$1" cn="$2"
      shift 2
      printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' "$cn" >"$name.cnf"
      "$OPENSSL" req -x509 -new "$@" -nodes -keyout "$name.key" -out "$name.pem" -days 30 -config "$name.cnf" -extensions v3 2>/dev/null
    }
    issue() { # issue <name> <CN> <ca> <extensions> <key args...>
      local name="$1" cn="$2" issuer="$3" ext="$4"
      shift 4
      printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n' "$cn" >"$name.cnf"
      printf '%b' "$ext" >"$name.ext"
      "$OPENSSL" req -new -config "$name.cnf" "$@" -nodes -keyout "$name.key" -out "$name.csr" 2>/dev/null &&
        "$OPENSSL" x509 -req -in "$name.csr" -CA "$issuer.pem" -CAkey "$issuer.key" -CAcreateserial -out "$name.pem" -days 20 -extfile "$name.ext" 2>/dev/null
    }
    P256="-newkey ec -pkeyopt ec_paramgen_curve:P-256"
    LEAF='basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n'
    SIGNER='basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=OCSPSigning\n'
    # shellcheck disable=SC2086
    ca root "OCSP Live Root" $P256 && ca other "Other Live Root" $P256 && ca rsa "OCSP RSA Root" -newkey rsa:2048 &&
      ca p384 "OCSP P-384 Root" -newkey ec -pkeyopt ec_paramgen_curve:P-384 &&
      issue good good.live.test root "$LEAF" $P256 && issue revoked revoked.live.test root "$LEAF" $P256 &&
      issue unknown unknown.live.test root "$LEAF" $P256 && issue rsaleaf rsa.live.test rsa "$LEAF" $P256 &&
      issue p384leaf p384.live.test p384 "$LEAF" $P256 &&
      issue signer "OCSP Live Responder" root "${SIGNER}noCheck=ignored\n" $P256 &&
      issue plain "OCSP Live Responder Plain" root "$SIGNER" $P256 &&
      issue noeku "OCSP Live Responder No EKU" root 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' $P256 &&
      issue foreign "OCSP Live Responder Foreign" other "$SIGNER" $P256 || exit 1
    entry() { # entry <V|R> <cert> [revocation]: an index line for <cert>
      local serial end
      serial="$("$OPENSSL" x509 -in "$2.pem" -noout -serial | cut -d= -f2)"
      end="$("$OPENSSL" x509 -in "$2.pem" -noout -enddate | cut -d= -f2)"
      end="$("$PY" -c 'import sys, datetime as d; print(d.datetime.strptime(sys.argv[1], "%b %d %H:%M:%S %Y %Z").strftime("%y%m%d%H%M%SZ"))' "$end")"
      printf '%s\t%s\t%s\t%s\tunknown\t/CN=%s\n' "$1" "$end" "${3:-}" "$serial" "$2"
    }
    yesterday="$("$PY" -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=1)).strftime("%y%m%d%H%M%SZ"))')"
    { entry V good; entry R revoked "$yesterday,keyCompromise"; } >index.txt
    { entry V rsaleaf; } >rsa-index.txt
    { entry V p384leaf; } >p384-index.txt
    request() { # request <out> <issuer> [digest] <cert>...: OpenSSL's request
      local out="$1" issuer="$2"
      shift 2
      local args=() digest=""
      case "$1" in -sha*) digest="$1"; shift ;; esac
      for c in "$@"; do args+=(${digest:+"$digest"} -cert "$c.pem"); done
      "$OPENSSL" ocsp -issuer "$issuer.pem" "${args[@]}" -no_nonce -reqout "$out" 2>/dev/null
    }
    respond() { # respond <out> <request> <index> <ca> <signer> [more]: OpenSSL's response
      local out="$1" req="$2" index="$3" issuer="$4" signer="$5"
      shift 5
      "$OPENSSL" ocsp -index "$index" -CA "$issuer.pem" -rsigner "$signer.pem" -rkey "$signer.key" -reqin "$req" -respout "$out" -ndays 1 "$@" >/dev/null 2>&1
    }
    for c in good revoked unknown; do request "$c.req" root "$c"; done
    request two.req root good revoked
    request good256.req root -sha256 good
    request rsaleaf.req rsa rsaleaf
    request p384leaf.req p384 p384leaf
    "$X" request good.pem root.pem sha1 - iyi.req
    : >judge.txt
    pair() { # pair <response> <leaf> <issuer> [hash]: one judgment to make
      printf '%s|%s|%s|%s|%s|-|%s\n' "$1 for $2" "$L/$1.resp" "$L/$2.pem" "$L/$3.pem" "${4:-sha1}" >>judge.txt
    }
    for c in good revoked unknown; do respond "direct-$c.resp" "$c.req" index.txt root root && pair "direct-$c" "$c" root; done
    pair direct-good revoked root
    respond bykey.resp good.req index.txt root root -resp_key_id && pair bykey good root
    respond delegated.resp good.req index.txt root signer && pair delegated good root && pair delegated revoked root
    respond delegated-revoked.resp revoked.req index.txt root signer && pair delegated-revoked revoked root
    respond plain.resp good.req index.txt root plain && pair plain good root
    respond noeku.resp good.req index.txt root noeku && pair noeku good root
    respond foreign.resp good.req index.txt root foreign && pair foreign good root
    respond nocerts.resp good.req index.txt root signer -resp_no_certs && pair nocerts good root
    respond two.resp two.req index.txt root root && pair two good root && pair two revoked root && pair two unknown root
    respond good256.resp good256.req index.txt root root && pair good256 good root sha256
    respond rsa.resp rsaleaf.req rsa-index.txt rsa rsa && pair rsa rsaleaf rsa
    if "$OPENSSL" ocsp -help 2>&1 | grep -q -- '-rsigopt'; then
      respond rsapss.resp rsaleaf.req rsa-index.txt rsa rsa -rsigopt rsa_padding_mode:pss && pair rsapss rsaleaf rsa
    fi
    respond p384.resp p384leaf.req p384-index.txt p384 p384 -rmd sha384 && pair p384 p384leaf p384
    respond iyi.resp iyi.req index.txt root root && pair iyi good root
    exit 0
  ) || { echo "  FAIL the live PKI or its responses were not made"; status=1; }
  if [ -s "$L/judge.txt" ]; then
    cut -d'|' -f1-4,6 "$L/judge.txt" | awk -F'|' '{print $1"|"$2"|"$3"|"$4"|-"}' >"$L/ours.in"
    "$X" judge "$L/ours.in" 2>&1 | tr -d '\r' >"$L/ours.out"
    agreed=0
    while IFS='|' read -r name resp leaf issuer hash _; do
      ours="$(grep -F "$name|" "$L/ours.out" | head -1 | cut -d'|' -f2)"
      theirs="$(openssl_verdict "$resp" "$leaf" "$issuer" "$issuer" "$hash")"
      if [ -n "$ours" ] && [ "$ours" = "$theirs" ]; then
        agreed=$((agreed + 1))
        echo "  $name: $ours"
      elif [ -n "$ours" ] && [ "$(compare "$ours" "$theirs")" = refused ]; then
        agreed=$((agreed + 1))
        echo "  $name: refused by both, std/ocsp for $ours, OpenSSL for $theirs"
      else
        echo "  FAIL $name: std/ocsp ${ours:-nothing}, OpenSSL $theirs"
        status=1
      fi
    done <"$L/judge.txt"
    echo "  $agreed judgments of OpenSSL's responses, each taken or refused as OpenSSL's own"
  fi
  # The requests.
  (
    cd "$L" || exit 1
    failed=0
    "$X" request good.pem root.pem sha1 - ours1.req && "$OPENSSL" ocsp -issuer root.pem -cert good.pem -no_nonce -reqout theirs1.req 2>/dev/null
    if cmp -s ours1.req theirs1.req; then echo "  a request under SHA-1: the bytes of OpenSSL's -reqout"; else echo "  FAIL a request under SHA-1 is not OpenSSL's"; failed=1; fi
    "$X" request good.pem root.pem sha256 - ours256.req && "$OPENSSL" ocsp -issuer root.pem -sha256 -cert good.pem -no_nonce -reqout theirs256.req 2>/dev/null
    if cmp -s ours256.req theirs256.req; then echo "  a request under SHA-256: the bytes of OpenSSL's -reqout"; else echo "  FAIL a request under SHA-256 is not OpenSSL's"; failed=1; fi
    nonce=00112233445566778899aabbccddeeff
    "$X" request good.pem root.pem sha1 "$nonce" nonce.req
    upper="$(printf '%s' "$nonce" | tr 'a-f' 'A-F')"
    if "$OPENSSL" ocsp -reqin nonce.req -req_text 2>/dev/null | tr -d ' \r\n:' | grep -q "OCSPNonce0410$upper"; then
      echo "  a request with a nonce: OpenSSL's -req_text reads it"
    else
      echo "  FAIL a request's nonce, as OpenSSL reads it: $("$OPENSSL" ocsp -reqin nonce.req -req_text 2>&1 | grep -A1 Nonce | tr '\n' ' ')"
      failed=1
    fi
    if "$PY" -c 'from cryptography.x509 import ocsp' >/dev/null 2>&1; then
      if "$PY" - "$nonce" <<'PY'; then
import sys
from cryptography import x509
from cryptography.x509 import ocsp
from cryptography.hazmat.primitives import hashes, serialization
good = x509.load_pem_x509_certificate(open("good.pem", "rb").read())
root = x509.load_pem_x509_certificate(open("root.pem", "rb").read())
nonce = bytes.fromhex(sys.argv[1])
ours = open("nonce.req", "rb").read()
theirs = (ocsp.OCSPRequestBuilder().add_certificate(good, root, hashes.SHA1())
          .add_extension(x509.OCSPNonce(nonce), critical=False).build().public_bytes(serialization.Encoding.DER))
read = ocsp.load_der_ocsp_request(ours)
ok = (ours == theirs and read.serial_number == good.serial_number and read.hash_algorithm.name == "sha1"
      and read.extensions.get_extension_for_class(x509.OCSPNonce).value.nonce == nonce)
print("  a request with a nonce: the bytes of Python's OCSPRequestBuilder, and read by its loader" if ok else "  FAIL a request with a nonce, as Python writes and reads it")
sys.exit(0 if ok else 1)
PY
        :
      else
        failed=1
      fi
    else
      echo "  no python cryptography here, so the request goes unread by Python"
    fi
    exit "$failed"
  ) || status=1
fi

HAVE_PY_OCSP=no
[ -n "$PY" ] && "$PY" -c 'from cryptography.x509 import ocsp; from cryptography.x509 import OCSPNonce' >/dev/null 2>&1 && HAVE_PY_OCSP=yes

echo
echo "== responses Python builds now, judged as OpenSSL judges them"
# Python's OCSPResponseBuilder over the CA above, now: good; revoked with
# each CRLReason and with none; unknown; by key hash; from the delegated
# responders; signed by a key of the CA's name that is not the CA's; for
# another certificate; out of their time by a day and inside the skew by
# two minutes either way; without nextUpdate an hour old and three days
# old; SHA-256, SHA-384 and SHA-512 CertIDs; a nonce. Each verdict held to
# OpenSSL's, but one: a response without nextUpdate three days old, which
# OpenSSL takes and std/ocsp holds to a day (see its header).
F="$WORK/fresh"
if [ "$HAVE_OPENSSL" = no ] || [ "$HAVE_PY_OCSP" = no ] || ! [ -s "$L/root.pem" ]; then
  echo "  no OpenSSL or no python cryptography with x509.ocsp here, so Python's responses go unjudged"
else
  mkdir -p "$F"
  if "$PY" - "$L" "$F" <<'PY'; then
import datetime as dt, sys
from cryptography import x509
from cryptography.x509 import ocsp
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
L, F = sys.argv[1], sys.argv[2]
load = lambda n: x509.load_pem_x509_certificate(open(f"{L}/{n}.pem", "rb").read())
key = lambda n: serialization.load_pem_private_key(open(f"{L}/{n}.key", "rb").read(), None)
root, good, revoked = load("root"), load("good"), load("revoked")
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
H, D, M = dt.timedelta(hours=1), dt.timedelta(days=1), dt.timedelta(minutes=1)
impostor_key = ec.generate_private_key(ec.SECP256R1())
impostor = (x509.CertificateBuilder().subject_name(root.subject).issuer_name(root.subject).public_key(impostor_key.public_key())
            .serial_number(9).not_valid_before(now - D).not_valid_after(now + 10 * D)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(impostor_key, hashes.SHA256()))
S = ocsp.OCSPCertStatus
lines = []
def build(name, leaf="good", status=S.GOOD, signer="root", certs=False, by=ocsp.OCSPResponderEncoding.NAME, this=None, nxt="day",
          rtime=None, reason=None, hash=hashes.SHA1(), nonce=None, signer_cert=None, signer_key=None, asked=None):
    this = now - H if this is None else this
    nxt = now + D if nxt == "day" else nxt
    cert = load(leaf)
    s_cert = signer_cert or load(signer)
    b = (ocsp.OCSPResponseBuilder().add_response(cert=cert, issuer=root, algorithm=hash, cert_status=status, this_update=this,
         next_update=nxt, revocation_time=rtime, revocation_reason=reason).responder_id(by, s_cert))
    if certs: b = b.certificates([s_cert])
    if nonce: b = b.add_extension(x509.OCSPNonce(nonce), critical=False)
    open(f"{F}/{name}.resp", "wb").write(b.sign(signer_key or key(signer), hashes.SHA256()).public_bytes(serialization.Encoding.DER))
    lines.append(f"{name}|{F}/{name}.resp|{L}/{asked or leaf}.pem|{L}/root.pem|{hash.name}")
build("good")
for reason in x509.ReasonFlags:
    if reason in (x509.ReasonFlags.unspecified,):
        continue
    build(f"revoked-{reason.name}", "revoked", S.REVOKED, rtime=now - D, reason=reason)
build("revoked-no-reason", "revoked", S.REVOKED, rtime=now - D)
build("unknown", status=S.UNKNOWN)
build("by-key", by=ocsp.OCSPResponderEncoding.HASH)
build("delegated", signer="signer", certs=True)
build("delegated-by-key", signer="signer", certs=True, by=ocsp.OCSPResponderEncoding.HASH)
build("delegated-plain", signer="plain", certs=True)
build("delegated-no-eku", signer="noeku", certs=True)
build("delegated-foreign", signer="foreign", certs=True)
build("impostor", signer_cert=impostor, signer_key=impostor_key)
build("another-certificate", "revoked", asked="good")
build("expired", this=now - 10 * D, nxt=now - 3 * D)
build("ahead", this=now + D, nxt=now + 3 * D)
build("ahead-inside-the-skew", this=now + 2 * M)
build("past-inside-the-skew", this=now - 3 * D, nxt=now - 2 * M)
build("no-next-update-fresh", nxt=None)
build("no-next-update-old", this=now - 3 * D, nxt=None)
build("sha256", hash=hashes.SHA256())
build("sha384", hash=hashes.SHA384())
build("sha512", hash=hashes.SHA512())
build("nonce", nonce=bytes(range(32)))
open(f"{F}/list", "w", newline="\n").write("\n".join(lines) + "\n")
PY
    awk -F'|' '{print $1"|"$2"|"$3"|"$4"|-"}' "$F/list" >"$F/ours.in"
    "$X" judge "$F/ours.in" 2>&1 | tr -d '\r' >"$F/ours.out"
    agreed=0
    while IFS='|' read -r name resp leaf issuer hash; do
      ours="$(grep -F "$name|" "$F/ours.out" | head -1 | cut -d'|' -f2)"
      theirs="$(openssl_verdict "$resp" "$leaf" "$issuer" "$issuer" "$hash")"
      if [ -n "$ours" ] && [ "$ours" = "$theirs" ]; then
        agreed=$((agreed + 1))
      elif [ -n "$ours" ] && [ "$(compare "$ours" "$theirs")" = refused ]; then
        agreed=$((agreed + 1))
        echo "  $name: refused by both, std/ocsp for $ours, OpenSSL for $theirs"
      elif [ "$name" = no-next-update-old ] && [ "$ours" = time ] && [ "$theirs" = good ]; then
        echo "  $name: std/ocsp time, OpenSSL good - a response without nextUpdate is taken for a day after its thisUpdate here"
      else
        echo "  FAIL $name: std/ocsp ${ours:-nothing}, OpenSSL $theirs"
        status=1
      fi
    done <"$F/list"
    echo "  $agreed of Python's responses taken or refused as OpenSSL does: $(cut -d'|' -f2 "$F/ours.out" | sort | uniq -c | awk '{printf "%s%s %s", sep, $1, $2; sep=", "}')"
  else
    echo "  FAIL Python did not build its responses"
    status=1
  fi
fi

echo
echo "== every response here, read as Python's cryptography reads it"
# The exercise's vectors, OpenSSL's responses and Python's: std/ocsp's
# reading of each - status, responder, producedAt, signature algorithm,
# certificates, nonce, and each SingleResponse's CertID, status,
# revocation, thisUpdate and nextUpdate - against `load_der_ocsp_response`.
# A response std/ocsp refuses and Python reads must be one of those
# written down here, for the reason given.
if [ "$HAVE_PY_OCSP" = no ] || ! [ -d "$WORK/vectors" ]; then
  echo "  no python cryptography with x509.ocsp here (or no vectors written), so nothing is read twice"
else
  : >"$WORK/all.in"
  for f in "$WORK"/vectors/*.resp "$L"/*.resp "$F"/*.resp; do
    [ -f "$f" ] || continue
    printf '%s|%s\n' "$f" "$f" >>"$WORK/all.in"
  done
  "$X" dump "$WORK/all.in" 2>&1 | tr -d '\r' >"$WORK/ours.dump"
  "$PY" - "$WORK/all.in" "$WORK/theirs.dump" <<'PY'
import sys
from cryptography import x509
from cryptography.x509 import ocsp
HASH = {"sha1": "1.3.14.3.2.26", "sha256": "2.16.840.1.101.3.4.2.1", "sha384": "2.16.840.1.101.3.4.2.2", "sha512": "2.16.840.1.101.3.4.2.3"}
REASON = {x509.ReasonFlags.unspecified: 0, x509.ReasonFlags.key_compromise: 1, x509.ReasonFlags.ca_compromise: 2,
          x509.ReasonFlags.affiliation_changed: 3, x509.ReasonFlags.superseded: 4, x509.ReasonFlags.cessation_of_operation: 5,
          x509.ReasonFlags.certificate_hold: 6, x509.ReasonFlags.remove_from_crl: 8, x509.ReasonFlags.privilege_withdrawn: 9,
          x509.ReasonFlags.aa_compromise: 10}
ts = lambda t: "-" if t is None else str(int(t.timestamp()))
def dump(der):
    try:
        r = ocsp.load_der_ocsp_response(der)
        if r.response_status != ocsp.OCSPResponseStatus.SUCCESSFUL:
            return f"status={r.response_status.value}"
        parts = ["status=0"]
        name = r.responder_name
        parts.append("responder=" + ("name:" + name.public_bytes().hex() if name is not None else "key:" + r.responder_key_hash.hex()))
        parts += [f"produced={ts(r.produced_at_utc)}", f"sigalg={r.signature_algorithm_oid.dotted_string}", f"certs={len(r.certificates)}"]
        try:
            nonce = r.extensions.get_extension_for_class(x509.OCSPNonce).value.nonce.hex()
        except x509.ExtensionNotFound:
            nonce = "-"
        parts.append(f"nonce={nonce}")
        for s in r.responses:
            reason = s.revocation_reason
            parts.append("single=" + ",".join([HASH[s.hash_algorithm.name], s.issuer_name_hash.hex(), s.issuer_key_hash.hex(),
                         format(s.serial_number, "x"), s.certificate_status.name.lower(), ts(s.revocation_time_utc),
                         "-" if reason is None else str(REASON[reason]), ts(s.this_update_utc), ts(s.next_update_utc)]))
        return ";".join(parts)
    except Exception:
        return "refused"
with open(sys.argv[2], "w", newline="\n") as out:
    for line in open(sys.argv[1]):
        name, path = line.rstrip("\n").split("|")
        out.write(f"{name}|{dump(open(path, 'rb').read())}\n")
PY
  # The vectors std/ocsp refuses and Python reads, by the exercise's
  # case: a critical extension not understood, in the response or in a
  # SingleResponse; a nonce that is not an OCTET STRING; a CertID whose
  # hash is cut short; a responder key hash of 19 bytes; version 2; no
  # SingleResponse, which Python reads and refuses only when asked for
  # one; and tryLater carrying responseBytes, which RFC 6960 gives a
  # successful response alone.
  "$PY" - "$WORK/ours.dump" "$WORK/theirs.dump" "$WORK/vectors/list" <<'PY' || status=1
import sys
ours = dict(l.rstrip("\n").split("|", 1) for l in open(sys.argv[1]) if "|" in l)
theirs = dict(l.rstrip("\n").split("|", 1) for l in open(sys.argv[2]) if "|" in l)
names = {}
for l in open(sys.argv[3]):
    f = l.rstrip("\n").split("|")
    if len(f) > 1: names[f[1]] = f[0]
allowed = {
    "a response with a critical extension it does not understand", "a critical extension in a SingleResponse",
    "a nonce that is not an OCTET STRING", "a CertID with a hash cut short", "a responder key hash of 19 bytes",
    "a ResponseData of version 2", "a ResponseData with no SingleResponse", "tryLater with responseBytes",
}
same = 0
parted = set()
failed = False
for path, mine in ours.items():
    other = theirs.get(path, "missing")
    case = names.get(path.replace("\\", "/").rsplit("/", 1)[-1], path)
    if mine == other:
        same += 1
    elif mine == "refused" and other != "refused" and case in allowed:
        parted.add(case)
    else:
        print(f"  FAIL {case}: std/ocsp reads {mine}, Python {other}")
        failed = True
for case in sorted(parted):
    print(f"  {case}: refused by std/ocsp, read by Python")
print(f"  {same} responses read alike, field by field; {len(parted)} refused here that Python reads")
sys.exit(1 if failed else 0)
PY
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [module]: the exercise must
# fail on a copy of the module (std/ocsp unless named) with <old>
# replaced, at the check that names <phrase>. Each copy is built and run
# in a subshell of its own, MUT_JOBS at a time, with a compiler cache of
# its own, as std/tls's are; the answers are printed in order at the end.
MUT_JOBS="${MUT_JOBS:-4}"
mutations=0
mutation_pids=""
mkdir -p "$WORK/mutres"
prove_copy() { # prove_copy <n> <dir> <label> <phrase>
  local n="$1" W="$2" label="$3" phrase="$4"
  export IYI_CACHE_DIR="$W/cache"
  if ! IYI_PATH="$W/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$W/x" \
       "$REPO/bench/std_ocsp_exercise.iyi" >"$W/build.log" 2>&1; then
    printf '  the %s copy did not build:\n%s\n' "$label" "$(tail -3 "$W/build.log" | sed 's/^/    /')" >"$WORK/mutres/$n"
    touch "$WORK/mutres/failed"
    return
  fi
  if "$W/x" >"$W/mut.out" 2>&1; then
    echo "  the exercise PASSED on $label" >"$WORK/mutres/$n"
    touch "$WORK/mutres/failed"
  elif grep -qF -e "$phrase" "$W/mut.out"; then
    echo "  $label is caught" >"$WORK/mutres/$n"
    rm -rf "$W"
  else
    printf '  %s failed, but not where it should have:\n%s\n' "$label" "$({ grep -m1 -F 'ASSERTION' "$W/mut.out" || tail -2 "$W/mut.out"; } | sed 's/^/    /')" >"$WORK/mutres/$n"
    touch "$WORK/mutres/failed"
  fi
}
prove_broken() {
  mutations=$((mutations + 1))
  local n="$mutations" W="$WORK/mut-$mutations"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured" >"$WORK/mutres/$n"
    return
  fi
  mkdir -p "$W/patched/std"
  if ! OLD="$3" NEW="$4" MODULE="${5:-ocsp}" "$PY" - <<PY
import os
from pathlib import Path
module = os.environ["MODULE"]
src = Path("$REPO/src/std/" + module + ".iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$W/patched/std/" + module + ".iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8", newline="\n")
PY
  then
    echo "  the $1 patch did not apply" >"$WORK/mutres/$n"
    touch "$WORK/mutres/failed"
    return
  fi
  prove_copy "$n" "$W" "$1" "$2" &
  mutation_pids="$mutation_pids $!"
  # `wait -n` where the shell has it (bash 4.3); darwin's 3.2 polls.
  local pid running
  while :; do
    running=""
    for pid in $mutation_pids; do
      kill -0 "$pid" 2>/dev/null && running="$running $pid"
    done
    mutation_pids="$running"
    [ "$(echo $mutation_pids | wc -w)" -lt "$MUT_JOBS" ] && break
    wait -n 2>/dev/null || sleep 0.2
  done
}
prove_broken "the response's signature unchecked" "a response signed by another key under the issuer's name: expected" \
  '      problem = X509.signature_error(candidate.public_key, @signature_algorithm, @signature_parameters, @tbs, @signature, "the OCSP response", candidate.subject_name) unless problem' \
  '      problem = nil unless problem'
prove_broken "the CertID's serial number not compared" "a response for another certificate: expected" \
  '    return false unless @serial == leaf.serial' ''
prove_broken "the CertID's issuer key hash not compared" "a response for another issuer's key under the same name: expected" \
  '    @issuer_name_hash == @hash.digest(leaf.issuer) && @issuer_key_hash == @hash.digest(issuer.public_key_bits)' '    @issuer_name_hash == @hash.digest(leaf.issuer)'
prove_broken "the CertID's issuer name hash not compared" "a response for another issuer's name: expected" \
  '    @issuer_name_hash == @hash.digest(leaf.issuer) && @issuer_key_hash == @hash.digest(issuer.public_key_bits)' '    @issuer_key_hash == @hash.digest(issuer.public_key_bits)'
prove_broken "a delegated responder's id-kp-OCSPSigning unchecked" "a delegated responder without id-kp-OCSPSigning: expected" \
  '    return "the responder #{name} is not allowed id-kp-OCSPSigning" unless usages && usages.includes?(Ocsp::SIGNING)' ''
prove_broken "anyExtendedKeyUsage taken for id-kp-OCSPSigning" "a delegated responder allowed only anyExtendedKeyUsage: expected" \
  'unless usages && usages.includes?(Ocsp::SIGNING)' 'unless usages && (usages.includes?(Ocsp::SIGNING) || usages.includes?("2.5.29.37.0"))'
prove_broken "a delegated responder's issuer unchecked" "a delegated responder issued by another CA: expected" \
  '    return "the responder #{name} was not issued by #{issuer.subject_name}, the CA it answers for" unless responder.issuer == issuer.subject' ''
prove_broken "a delegated responder's own signature unchecked" "a delegated responder whose certificate the issuer did not sign: expected" \
  '    problem = responder.signature_error(issuer)' '    problem = nil.as(String?)'
prove_broken "a delegated responder's time unchecked" "a delegated responder out of its time: expected" \
  '    return "the responder #{name} is not valid at #{now}: from #{responder.not_before} to #{responder.not_after}" unless responder.valid_at?(now)' ''
prove_broken "a delegated responder's keyUsage unchecked" "a delegated responder not allowed digitalSignature: expected" \
  '    return "the responder #{name} is not allowed digitalSignature" if usage && (usage >> Certificate::KEY_DIGITAL_SIGNATURE) & 1 == 0' ''
prove_broken "the responder matched by any name" "a delegated responder without id-kp-OCSPSigning: expected" \
  '  private def names?(candidate : Certificate) : Bool' '  private def names?(candidate : Certificate) : Bool
    return true'
prove_broken "the responder's key hash under another hash" "a good response from the issuer, by key hash: expected" \
  '      return SHA1.hash_bytes(candidate.public_key_bits) == hash' '      return SHA256.hash_bytes(candidate.public_key_bits)[0, 20] == hash'
prove_broken "nextUpdate ignored" "a response past its nextUpdate: expected" \
  '      return OcspError.new("a response past its nextUpdate, #{next_update}, at #{now}") if next_update < early' ''
prove_broken "a thisUpdate ahead of now taken" "a response whose thisUpdate is a day ahead: expected" \
  '    if single.this_update > late' '    if false'
prove_broken "no clock skew allowed" "a response whose thisUpdate is two minutes ahead, inside the skew: expected" \
  '  SKEW_SECONDS = 300' '  SKEW_SECONDS = 0'
prove_broken "a response without nextUpdate taken forever" "a response without nextUpdate from three days ago: expected" \
  '    elsif single.this_update.shift(seconds: Ocsp::NO_NEXT_UPDATE_SECONDS.to_i64) < early' '    elsif false'
prove_broken "a nextUpdate before its thisUpdate taken" "a nextUpdate before its thisUpdate: expected" \
  '      return OcspError.new("a response whose nextUpdate, #{next_update}, is before its thisUpdate, #{single.this_update}") if next_update < single.this_update' ''
prove_broken "revoked read as good" "a revoked response with its reason: expected" \
  '      status = OcspCertStatus::Revoked' '      status = OcspCertStatus::Good'
prove_broken "unknown read as good" "an unknown response: expected" \
  '      status = OcspCertStatus::Unknown' '      status = OcspCertStatus::Good'
prove_broken "a revocation reason not read" "a revoked response with its reason: expected" \
  '        reason = code.to_i32' ''
prove_broken "a critical extension passed over" "a response with a critical extension it does not understand: expected" \
  '      elsif critical
        return OcspError.new("a critical extension #{oid} in #{where}, which this does not understand")' ''
prove_broken "an extension twice taken" "an extension twice: expected" \
  '      return OcspError.new("extension #{oid} twice in #{where}") if seen.includes?(oid)' ''
prove_broken "a version written out taken" "a ResponseData whose version is written out: expected" \
  '      return OcspError.new("a ResponseData whose version v1 is written out, which DER leaves out as the default")' '      data = data[1, data.size - 1]'
prove_broken "a UTCTime taken" "a thisUpdate in UTCTime: expected" \
  '    return OcspError.new("a #{what} that is #{value.describe}, where RFC 6960 writes a GeneralizedTime") unless value.universal?(DerTag::GENERALIZED_TIME)' ''
prove_broken "CRLReason 7 taken" "a revocation reason of 7: expected" \
  'if code < 0 || code > 10 || code == 7' 'if code < 0 || code > 10'
prove_broken "tryLater with responseBytes taken" "tryLater with responseBytes: expected" \
  '      return OcspError.new("a responseStatus of #{Ocsp.status_name(status)} with responseBytes, which only a successful one carries") if top.size == 2' ''
prove_broken "a CertID's hash size unchecked" "a CertID with a hash cut short: expected" \
  '    unless name_hash.size == hash.size && key_hash.size == hash.size' '    if false'
prove_broken "a leaf asked of a CA that did not issue it" "the leaf asked of another CA as its issuer: expected" \
  '    unless leaf.issuer == issuer.subject
      return OcspError.new' '    if false
      return OcspError.new'
prove_broken "a request's CertID without NULL parameters" "as \`openssl ocsp -no_nonce\` writes it" \
  '    algorithm = OcspDer.sequence(OcspDer.oid(@hash.oid) + [0x05_u8, 0x00_u8])' '    algorithm = OcspDer.sequence(OcspDer.oid(@hash.oid))'
prove_broken "the nonce read as the extension's whole value" "a nonce that is not an OCTET STRING: expected" \
  '        nonce = bytes(inner.octet_string)!' '        nonce = body'
prove_broken "the TLS Feature extension passed over" "must.ocsp.test's TLS Feature" \
  '        @tls_features = features' '' x509
prove_broken "id-pkix-ocsp-nocheck passed over" "which carries id-pkix-ocsp-nocheck" \
  '        @ocsp_nocheck = true' '' x509
for pid in $mutation_pids; do
  wait "$pid"
done
n=1
while [ "$n" -le "$mutations" ]; do
  cat "$WORK/mutres/$n"
  n=$((n + 1))
done
[ -e "$WORK/mutres/failed" ] && status=1

echo
if [ "$status" -eq 0 ]; then
  echo "the std/ocsp exercise holds ($mutations breaks caught)"
else
  echo "the std/ocsp exercise did not hold"
fi
exit $status
