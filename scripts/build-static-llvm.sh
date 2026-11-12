#!/usr/bin/env bash
# Build the LLVM the tarball links: static, minimal, and the same on every
# platform that ships one.
#
# This is Crystal's own recipe (distribution-scripts, omnibus's llvm
# software definition), recorded in 0.6.0's Learned entry and adopted
# once it was measured: `BUILD_SHARED_LIBS=OFF` so the compiler carries
# LLVM inside itself, `MinSizeRel`, only the five targets the compiler
# reaches, and every optional dependency `OFF` — zlib, zstd, libxml2,
# ffi, z3, libedit — so the closure a shared libLLVM drags behind it
# (libedit, libxml2, libicu, libncursesw, libzstd; 179 MB of `lib/` on
# Linux, brew's whole LLVM keg on darwin) never comes into existence
# rather than being bundled well.
#
# One script and not one cmake line per CI job, because two copies of a
# recipe are two recipes the day one is edited. CI keys its cache on this
# file's hash, so editing the recipe *is* invalidating the cache; nothing
# has to remember to bump a version token.
#
# The archive must be built by the toolchain that will link it: a static
# archive is bound to the C++ runtime and libc it was compiled against,
# and one built on a newer machine is a link error or a silent
# binary-for-newer-glibc on this one. So each platform builds its own,
# and the cost — roughly an hour on a CI runner — is paid once per
# recipe change, not per push.
#
# Usage: build-static-llvm.sh <install-prefix>
#
# Needs cmake, a C++ toolchain, curl, sha256sum or shasum, and a tar that
# reads xz; installing those is the caller's business because it differs
# per image.
#
# The source is the one tarball whose SHA-256 is written below, beside the
# version it belongs to: what is compiled here ends up inside the compiler
# every release ships, so an archive that is not that one, or an error
# page saved under its name, is refused before it is unpacked. The hash is
# part of this file, so it is part of the cache key too.
set -euo pipefail

prefix=${1:?usage: build-static-llvm.sh <install-prefix>}
version=20.1.2
sha256=f0a4a240aabc9b056142d14d5478bb6d962aeac549cbd75b809f5499240a8b38

work=$(mktemp -d "${TMPDIR:-/tmp}/llvm-build.XXXXXX")
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/llvm.tar.xz" \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/llvm-project-$version.src.tar.xz"
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$work/llvm.tar.xz")
else
  actual=$(shasum -a 256 "$work/llvm.tar.xz")
fi
actual=${actual%% *}
if [ "$actual" != "$sha256" ]; then
  echo "build-static-llvm: llvm-project-$version.src.tar.xz is not the one pinned here: expected $sha256, got $actual" >&2
  exit 1
fi
tar -xf "$work/llvm.tar.xz" -C "$work"

cmake -S "$work/llvm-project-$version.src/llvm" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DBUILD_SHARED_LIBS=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF \
  -DLLVM_TARGETS_TO_BUILD='X86;AArch64;ARM;AVR;WebAssembly' \
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_Z3_SOLVER=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_BINDINGS=OFF

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
make -C "$work/build" -j"$jobs" install

# The recipe's whole point, asserted rather than assumed: llvm-config
# answers for static archives and no shared libLLVM exists under the
# prefix. A prefix that fails this would link a compiler that ships a
# libLLVM after all, which is the state this script exists to end.
mode=$("$prefix/bin/llvm-config" --shared-mode)
if [ "$mode" != static ]; then
  echo "build-static-llvm: llvm-config --shared-mode says '$mode', not static" >&2
  exit 1
fi
if ls "$prefix/lib" | grep -Eq '^libLLVM.*\.(so|dylib)'; then
  echo "build-static-llvm: $prefix/lib holds a shared libLLVM; the recipe went shared" >&2
  exit 1
fi
echo "static LLVM $version installed under $prefix"
