#!/usr/bin/env python3
"""Compute the build-input digest (IYI_CONFIG_BUILD_INPUTS) for iyi compiler builds.

Covers:
  - sorted `path NUL sha256(content)` lines of `src/**/*.cr` and `Makefile*`
  - llvm-config --version
  - bootstrap crystal --version
  - build FLAGS
"""

import argparse
import hashlib
import os
import subprocess
import sys


def find_files(root_dir: str):
    # Try git ls-files first
    try:
        cmd = [
            "/usr/bin/git",
            "-C",
            root_dir,
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "src/*.cr",
            "src/**/*.cr",
            "Makefile*",
        ]
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode("utf-8")
        lines = [line.strip() for line in out.splitlines() if line.strip()]
        if lines:
            return sorted(set(lines))
    except Exception:
        pass

    # Fallback to filesystem search
    matched = []
    src_dir = os.path.join(root_dir, "src")
    if os.path.isdir(src_dir):
        for dirpath, _, filenames in os.walk(src_dir):
            for f in filenames:
                if f.endswith(".cr"):
                    rel = os.path.relpath(os.path.join(dirpath, f), root_dir)
                    matched.append(rel.replace("\\", "/"))
    for f in os.listdir(root_dir):
        if f.startswith("Makefile") and os.path.isfile(os.path.join(root_dir, f)):
            matched.append(f)
    return sorted(set(matched))


def file_sha256(filepath: str) -> str:
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def compute_digest(root_dir: str, llvm_version: str, crystal_version: str, flags: str) -> str:
    files = find_files(root_dir)
    hasher = hashlib.sha256()

    for rel_path in files:
        full_path = os.path.join(root_dir, rel_path)
        if not os.path.isfile(full_path):
            continue
        content_hash = file_sha256(full_path)
        # Format: path NUL sha256(content) \n
        line = rel_path.encode("utf-8") + b"\0" + content_hash.encode("ascii") + b"\n"
        hasher.update(line)

    # Extra inputs
    hasher.update(b"llvm-config --version\0" + llvm_version.strip().encode("utf-8") + b"\n")
    hasher.update(b"crystal --version\0" + crystal_version.strip().encode("utf-8") + b"\n")
    hasher.update(b"FLAGS\0" + flags.strip().encode("utf-8") + b"\n")

    return hasher.hexdigest()


def main():
    root = "."
    llvm_version = ""
    crystal_version = ""
    flags = ""

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--root" and i + 1 < len(args):
            root = args[i + 1]
            i += 2
        elif arg.startswith("--root="):
            root = arg.split("=", 1)[1]
            i += 1
        elif arg == "--llvm-version" and i + 1 < len(args):
            llvm_version = args[i + 1]
            i += 2
        elif arg.startswith("--llvm-version="):
            llvm_version = arg.split("=", 1)[1]
            i += 1
        elif arg == "--crystal-version" and i + 1 < len(args):
            crystal_version = args[i + 1]
            i += 2
        elif arg.startswith("--crystal-version="):
            crystal_version = arg.split("=", 1)[1]
            i += 1
        elif arg == "--flags" and i + 1 < len(args):
            flags = args[i + 1]
            i += 2
        elif arg.startswith("--flags="):
            flags = arg.split("=", 1)[1]
            i += 1
        else:
            i += 1

    digest = compute_digest(root, llvm_version, crystal_version, flags)
    print(digest)


if __name__ == "__main__":
    main()
