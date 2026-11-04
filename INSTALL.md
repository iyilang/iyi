# Installing iyi

The released version is 0.20.0, and a build from current source reports the
same. [README.md](README.md#install) has the two-line install; this file is
what those lines check, how to do the same by hand, and what a compiler and a
program built by it depend on.

## Linux and macOS

```sh
curl -fsSL https://raw.githubusercontent.com/iyilang/iyi/master/install.sh | sh
~/.local/bin/iyi run ~/.local/share/iyi/samples/hello.iyi
```

[`install.sh`](install.sh) (POSIX sh over `curl` and `tar`) picks the
tarball for your machine, linux-x86_64 or darwin-arm64, and refuses anything
else. It checks the tarball against the release's `SHA256SUMS` and unpacks
nothing on a mismatch. `IYI_PREFIX` moves the destination and
`IYI_VERSION=0.20.0` pins a release. By hand it is the same two lines:

```sh
tar -xzf iyi-0.20.0-linux-x86_64.tar.gz -C ~/.local
~/.local/bin/iyi run ~/.local/share/iyi/samples/hello.iyi
```

The tarball is relocatable and carries every library a program can ask for:
iyi's own 1,097 KB prelude, the 4,936 KB of `src/std` that `import std/...`
resolves to, and Crystal's standard library for `--crystal`. `bin/iyi` finds
all three beside itself, so there is nothing to configure. LLVM is inside the
binary — a static minimal build from `scripts/build-static-llvm.sh` — so `lib/`
holds only libstdc++ on Linux and nothing on darwin. The one thing the tarball
does not bring is a C toolchain, because iyi links through `cc`. CI unpacks it
in a bare Ubuntu 20.04 image with nothing but `gcc` and builds a program there.

**Linux** needs glibc 2.31 or newer (Ubuntu 20.04, Debian 11, RHEL 9 and
later), because the tarball is built on Ubuntu 20.04.

**macOS** 14.4 is the floor for the compiler and for every program it builds:
the collector's helper threads sleep on the public futex API that release
added (GC_DESIGN.md, "darwin's helpers park").

## Windows

```powershell
irm https://raw.githubusercontent.com/iyilang/iyi/master/install.ps1 | iex
& "$env:LOCALAPPDATA\Programs\iyi\bin\iyi.exe" run "$env:LOCALAPPDATA\Programs\iyi\share\iyi\samples\hello.iyi"
```

The release also carries `iyi-0.20.0-windows-x86_64.zip`, and
[`install.ps1`](install.ps1) installs it the way `install.sh` installs the
tarball: checksums first, `IYI_PREFIX` and `IYI_VERSION` honoured, default
prefix `%LOCALAPPDATA%\Programs\iyi`, `<prefix>\bin` added to the user's
`PATH`, no administrator. Saved to disk rather than piped, run it as
`powershell -ExecutionPolicy Bypass -File install.ps1`. By hand:

```powershell
Expand-Archive iyi-0.20.0-windows-x86_64.zip -DestinationPath "$env:LOCALAPPDATA\Programs\iyi"
& "$env:LOCALAPPDATA\Programs\iyi\bin\iyi.exe" run "$env:LOCALAPPDATA\Programs\iyi\share\iyi\samples\hello.iyi"
```

You need the Visual C++ build tools: the MSVC toolset and the Windows SDK, e.g.
Visual Studio Build Tools with "Desktop development with C++". iyi links with
`cl.exe` and finds it, and the SDK's libraries, through the registry, so no
developer prompt and nothing on `PATH` is needed.

The zip carries `bin\iyi.exe`, the `LLVM-C.dll` the compiler loads, iyi's
prelude and `src/std`. It does not carry Crystal's standard library, whose
`.lib` files on Windows only come with Crystal's own package, so `--crystal`
there needs a checkout of this repository on `IYI_PATH` and that package's
`lib` on `CRYSTAL_LIBRARY_PATH`. It does not carry the daemon either, which is
POSIX-only (`poll(2)` and `fork`).

## From source

Building it needs LLVM and a Crystal compiler to bootstrap from. CI bootstraps
with Crystal 1.21, and the Linux and macOS releases link LLVM 20.1;
`src/llvm/ext/llvm-versions.txt` lists every LLVM the build accepts.

```console
$ make                                  # the compiler, and `iyi` itself
$ ./bin/iyi run samples/iyi/hello.iyi   # run it out of the checkout
$ sudo make install_iyi                 # or install it, PREFIX=/usr/local
```

`make` also builds the same compiler under Crystal's name, as `./bin/crystal`,
which compiles `.cr` files and is what the specs and the benches use. On
Windows it is `make -f Makefile.win crystal` then `make -f Makefile.win iyi`,
with Crystal's own Windows package and the Visual C++ build tools.

## Targets

An iyi program produces code for `x86_64-linux-gnu`, `x86_64-linux-musl`,
`aarch64-linux-gnu`, `arm-linux-gnueabihf`, `x86_64-darwin`, `aarch64-darwin`,
`x86_64-w64-mingw32`, `x86_64-windows-msvc` and `wasm32-wasi`, and CI
type-checks the library for all nine every build. Five are *run* every build,
each checked against what the same program printed on the machine that
compiled it: x86-64 glibc natively, x86-64 musl in an Alpine container,
aarch64 under emulation, wasm32-wasi under wasmtime, and aarch64-darwin
natively. CI also audits the emitted object for seven of the nine;
`x86_64-linux-musl` and `arm-linux-gnueabihf` only type-check. Windows x86-64
is not one of the five, but it is built and tested natively: eight CI jobs run
on Windows, and a failure in any of them stops a release.

A wasm32-wasi program is linked by a wasi toolchain's `cc` (CI uses wasi-sdk's
clang), not by a bare linker, and has no concurrency runtime.

## What a program depends on

A plain build with iyi's own prelude links the platform's C library and
nothing else from the thirteen libraries Crystal's published list requires:
no libgc, no libevent, no openssl, no zlib. On Linux the object
itself asks libc for nothing, since the prelude issues its own syscalls; the
linked executable still references the C toolchain's startup objects. On macOS
it links `libSystem`, Apple's only supported interface. The collector is iyi's
own and adds no library; `-Dgc_boehm` swaps in bdw-gc and `-Dgc_none` a bump
allocator that never frees. `bench/dependency_floor.sh` holds all of this, on
own-prelude builds; a `--crystal` build links Crystal's library and whatever
its shards pull.

**On Linux the binary can travel as one file.** `iyi build --static` passes
`-static` to the C toolchain and the result has no dynamic loader at all: copy
it to a bare Linux and run it. macOS has no static libc, so there the default
build links `libSystem` alone and still copies to another Mac. A Windows build
imports `kernel32` (plus `advapi32` and `ws2_32` for entropy or sockets), the
dynamic Visual C++ runtime and five UCRT façades; `--static` changes nothing
there. A wasm32 build is one self-contained module already.

## What the compiler depends on

The compiler links LLVM, the C++ runtime and libc. On the released Linux
binary LLVM is inside it, and the loader is asked for libstdc++ (shipped in
`lib/`), libgcc_s, libm and libc. pcre2 is gone: macro-level regex runs on
iyi's own engine, and `bench/dependency_floor.sh` forbids `libpcre` outright.
