#!/usr/bin/env bash
# Run a previously generated static ELF, only on its matching Linux kernel.
set -u

root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
. "$root/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ "$#" -ne 2 ]; then
  echo "usage: $0 IMAGE PROVENANCE.json" >&2
  exit 1
fi
if [ "$HOST_OS" != linux ]; then
  echo "native ELF execution requires a Linux kernel, not $HOST_ID" >&2
  exit 1
fi
if [ -z "$PY" ]; then
  echo 'a functional Python interpreter is required' >&2
  exit 1
fi
head="$(git -C "$root" rev-parse HEAD)" || exit 1
"$PY" - "$(native_path "$1")" "$(native_path "$2")" "$head" "$HOST_ARCH" \
  "$(native_path "$root/bench/fixtures/native_link/elf_hello.expected")" <<'PY'
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

image, provenance, head, host_arch, fixture = sys.argv[1:]
try:
    with open(provenance, encoding="utf-8") as f:
        metadata = json.load(f)
    with open(image, "rb") as f:
        data = f.read()
    with open(fixture, "rb") as f:
        expected = f.read()
    arch = {"x86_64": "x86_64", "arm64": "aarch64"}[host_arch]
    machine = {"x86_64": 62, "aarch64": 183}[arch]
    digest = hashlib.sha256(data).hexdigest()
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head):
        raise ValueError("checkout HEAD is not a full git object ID")
    if metadata != {"architecture": arch, "git_head": head, "sha256": digest}:
        raise ValueError("image provenance does not match its digest, architecture, or checkout HEAD")
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("image is not little-endian ELF64")
    if struct.unpack_from("<HH", data, 16) != (3, machine):
        raise ValueError("image is not a static-PIE ELF for this kernel architecture")
    os.chmod(image, os.stat(image).st_mode | 0o111)
    run = subprocess.run([os.path.abspath(image)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if run.returncode != 7 or run.stdout != expected or run.stderr != b"":
        raise ValueError(f"ELF execution mismatch: status={run.returncode}, stdout={run.stdout!r}, stderr={run.stderr!r}")
    print(f"native Linux {arch}: verified HEAD {head}, sha256 {digest}, exit 7 and exact stdout/stderr")
except (OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
    print(f"native ELF execution failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
