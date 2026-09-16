# Changelog

## Unreleased

### Added

- **A server written in iyi serves HTTP.** `Server.serve(listener) {
  |request| Response }` in `std/http`: a fiber per connection under a
  group, keep-alive across requests (HTTP/1.0 and `Connection: close`
  honoured), chunked request bodies, `HEAD` without the body, a 400 and
  a close for what is not HTTP, the listener's `close` ending `serve`.
  `Request` carries method, path, query, headers and body;
  `Response.new(status, body, headers)` is written with its length and
  the status's own reason. `bench/std_http_exercise.sh` drives it from a
  raw socket, from the module's own client, from Python's `http.client`,
  and under `wrk -c50 -d3s` on a release build: 76,226 requests/s,
  236,296 requests, every one answered 200.

### Changed

- **`IyiSocket` parks instead of blocking.** On the targets that have the
  runtime, every socket is non-blocking and `connect`, `accept`, `read`
  and `write` park the calling fiber on the poller — `wait_writable`
  joined `wait_readable` for the send side — so a slow peer costs one
  fiber, not the thread. Those calls answer `T | Cancelled` now
  (SPEC.md III.4.2): `!` passes a cancelled task through its remaining
  IO, `.or_panic` refuses it at the top level, and a socket closed by
  another fiber under a parked call answers the same, since the kernel
  drops a closed descriptor from the poller silently and `close` now
  wakes the waiter (`wake_closed`). `bench/server_load.sh` no longer
  names the poller by hand, and `bench/socket_exercise.sh` holds the
  contract: a task parked in `read` leaves with `Cancelled` when a
  sibling fails, on one thread. Where there is no runtime the same
  names block on a `poll` and carry the same type, so a program reads
  the same on every target; `Cancelled` moved into the prelude for that,
  and the ceiling stays at 3,734.

### Fixed

- **The twenty-two merge modules were probed, the way the other
  fifty-three were.** Nearly 1,200 programs against `bit_array`, `dir`,
  `docs_pseudo_methods`, `fiber`, `file`, `levenshtein`, `named_tuple`,
  `weak_ref`, `capsule`, `hpack`, `udp`, `annotations`, `comparable`,
  `empty`, `env`, `errno`, `iterable`, `kernel`, `nil`,
  `reference_storage`, `steppable`, `symbol`, and `debug`. Local defects
  are held by each module's gate. What is a leftover (`empty`,
  `docs_pseudo_methods`, `p`/`pp`, `NilAssertionError`, `ENV` vs
  `Program.env`, `Errno.value` as a class variable, `Fiber.new` beside
  `group`) stays for the owner.

  - `std/file`: `touch` no longer truncates; `empty?` of a missing path
    is false; `chown` compiles; `match?` and `join("a", "b")` compile;
    `real_path("")` refuses; tempfile names include the pid;
    `readable?`/`writable?`/`executable?` ask `faccessat`;
    `same_content?` of a directory is false; a NUL in a path is refused.
  - `std/dir`: `glob` matches and walks from the segments before `**`;
    `mkdir_p` through a file refuses; a NUL in a path is refused; Linux
    `O_DIRECTORY` on aarch64 is `0x84000`; `to_s` is `#<Dir:path>`.
  - `std/env`: an empty key, a key with `=`, and a NUL in a key or a
    value are refused by name, instead of aliasing a prefix or dropping
    the entry from `each`.
  - `std/errno`: seven Linux numbers were Darwin leftovers (`EPROTO`
    was 71, `EREMOTE`'s sentence).
  - `std/hpack`: integer overflow and a huge index are `HpackError`;
    a size update after a header field is refused; the encoder emits
    RFC 7541 §4.2's minimum then the new size.
  - `std/capsule`: overlong datagram varints name overlong, not
    truncated; a quarter-stream id at `2^62` is refused; a negative
    encode length is refused before `Bytes.new`.
  - `std/udp`: `Datagram[i]` panics unless `i` is 0, 1 or 2. Receive
    still blocks the worker (`MSG_DONTWAIT` is not parking).
  - `std/bit_array`: `hash` mixes the bits; `fill`/`rotate`/`new` past
    `Int32` refuse with the module's sentence.
  - `std/comparable`: inverted `clamp` panics; `==` follows `<=>`;
    exclusive `...nil` is unbounded; the unused `Cmp` import is gone.
  - `std/symbol`: inspect escapes `"`, `\\`, newline; `:sort!` does not
    need quotes.
  - `std/steppable`: a walk that lands on `Int32::MAX` does not overflow
    on the next `next`.
  - `std/named_tuple`: hyphenated keys work on `[]`/`fetch`/`merge`.
  - `std/levenshtein`: distance uses `bytesize == size`; Finder scores
    an adjacent transposition as one.
  - `std/fiber`: enqueue of a dead fiber or one with no stack panics;
    `suspend` leaves the fiber resumable, not running.
  - `std/weak_ref`: `Std::Gc::GC.is_heap_ptr`, no `::GC` shim.
  - `std/debug`: `say` is `__iyi_write`; Darwin `lib LibC` is behind
    `flag?(:darwin)`. The Linux gate proves a copy that binds
    `LibC.write` leaves `write` undefined.
  - `std/reference_storage`: `hash` wraps; `==` is field-wise.
  - `std/nil`: a `not_nil` panic names the program site.
  - `std/kernel`: `sleep` takes `Float64` (narrow widths compiled
    `Number` and died).
  - `std/annotations`: `using` re-exports the compiler's annotations,
    so `@[Deprecated]` warns and `@[Link]` is `-l`.

## 0.13.0 — 2026-09-16

**The standard library is iyi.** `src/std` is seventy-five modules and
36,269 lines written in iyi over the prelude — JSON, YAML, XML, HTML,
path, IO, unicode, big, regex, digest, base64, CSV, random, UUID, a heap,
HTTP with its verbs, DEFLATE with zlib and gzip, an option parser — and
they bind nothing but the platform: `socket`, `time`, `file`, `dir` and
`udp` reach the kernel by raw syscall on Linux and libSystem on darwin,
`debug` reads the program's own DWARF, and everything else is iyi over
the prelude's intrinsics, which `bench/std_exercise.sh` checks by
reading the source. What Crystal's library gets from zlib, PCRE, OpenSSL,
GMP and getaddrinfo is written here or absent on purpose: DEFLATE reads
72 of zlib's streams and zlib reads 18 of iyi's; the regex engine is a
Pike VM, linear and leftmost-first, held against Python's `re` on 2,214
pattern/subject pairs; the digests against hashlib. The Crystal socket
stack that had landed beside `IyiSocket` left, and so did `iyi repl`.

**Then it was probed, and 65 defects were fixed where they lived.** Nearly
a thousand programs against twelve modules found panics wearing the
prelude's sentence (a control character in YAML indexed an empty table,
`pow(-1, Infinity)` overflowed, a Char above U+00FF overflowed a block
`gsub`), wrong answers (`Math.frexp` landed past 1.0 for whole bands of
small magnitudes and every log-based function inherited it; `a|ab`
matched `ab`; `round(TiesAway)` moved an integer; `from_json` could not
read the `UInt64` `to_json` wrote), and silent loss (a dedented YAML
entry dropped, base64 data after a `=` dropped, `+99:99` accepted as an
offset). Each fix is held by the module's own gate, most against
Python's answer. Before that, the verbs were probed the same way:
seventeen of them have a gate now, the language server and the MCP
server answer a client's mistake with the protocol's code, a syntax slip
is a sentence rather than the token the parser wanted, and the stack
running out is a panic the program prints itself.

**Twenty-nine pull requests from jwaldrip landed.** The runtime's symbols
are `__iyi_*` for an iyi program and `__crystal_*` under `--crystal`; a
panic on darwin prints a backtrace that `std/debug` resolves to
`file:line`; twenty-two std modules arrived, eleven of them the ones the
rewrite had dropped, reinstated on the owner's call; a build-tool floor
names every host binary the build runs. Landing them found three things:
the prelude's `__iyi_close` declared no output for its syscall, so under
optimisation a second `close` in a row became a `read`; the ABI is
decided by the prelude that was loaded, not the entry's extension; and
`file` and `dir` had come calling libc on Linux, which the floor refuses,
so their Linux branches are raw syscalls now.

`.iyimod` is v50.

### Added

- **Nine std modules written in iyi, none of them a C binding.** Digest
  (MD5, SHA-1, SHA-256, CRC-32, Adler-32), Base64 (RFC 4648), CSV (RFC
  4180), a PCG-32 `Random` (and `Array#shuffle` / `sample`), UUID v4
  (RFC 4122), a Thompson NFA `Regex` (RE2's contract: linear time, no
  backreferences or lookaround), a min-heap over `Cmp`, HTTP/1.1 GET
  over `IyiSocket` (numeric IPv4 and `localhost`; TLS is not in 0.x),
  and `OptionParser`. Each has a `bench/std_<name>_exercise.sh`. What
  Crystal's library gets from OpenSSL, PCRE, GMP and getaddrinfo is
  still not here, on purpose.

- **`std/compress`: DEFLATE, zlib and gzip, written in iyi.** SPEC.md
  III.10 said "own it. DEFLATE is a known quantity and arrives with
  HTTP", and it has. `Deflate.decompress` reads every block type the
  format has (stored, fixed, dynamic); `Deflate.compress` writes one
  fixed-Huffman block over a 32 KiB LZ77 window with hash chains, which
  is zlib level 1's shape and comes out smaller than zlib level 1 on
  every corpus the gate tries. `Zlib` and `Gzip` add and check their
  envelopes — the header, a preset dictionary, the Adler-32 or CRC-32,
  the length, a gzip header's optional fields — and refuse by name. No
  zlib is linked. `bench/std_compress_exercise.sh` reads 72 streams
  zlib wrote (six corpora, four levels, three envelopes) and has zlib
  read 18 of iyi's.

- **`std/http` speaks the verbs, and reads what a server actually sends.**
  `HTTP.get`, `head`, `post`, `put`, `delete` and the `request` under
  them carry a caller's headers and a body; `Host` names the port when
  it is not 80; `Content-Length` is written for a `POST` or `PUT` even
  when the body is empty. A response's headers are read by name without
  regard to case (`Response#header`), a chunked body arrives joined, a
  `HEAD`, `204` or `304` carries no body whatever its headers say, and a
  `Content-Length` or a status that is not a number is refused by name
  rather than the prelude's. A method or header that would break the
  request's own lines — a space in the method, a line break in a value,
  a caller's `Content-Length` — is refused before anything is written.
  `bench/std_http_exercise.sh` holds it, five verbs against a server on
  a thread.

- **Twenty-eight pull requests from jwaldrip, merged.** New std modules
  `bit_array`, `dir`, `docs_pseudo_methods`, `fiber`, `file`,
  `levenshtein`, `named_tuple`, `weak_ref`, `capsule`, `hpack` and `udp`
  (#63, #65, #66, #71, #72, #75, #76, #81, #82, #83, #84), and the eleven
  reinstated below. The runtime's ABI symbols are `__iyi_*` for an iyi
  program and `__crystal_*` under `--crystal` (#55); a panic on darwin
  prints a backtrace, and `std/debug` resolves it to `file:line` from the
  program's own DWARF (#56); a build-tool floor gate names every host
  binary the build runs (#58); the C++ shim and libc++ are conditional
  on LLVM < 18 (#59); the toolchain-floor rule is recorded in SPEC.md
  III.9 and the floor's denylist names Crystal's thirteen ancestor
  libraries (#60, #61). `file` and `dir` arrived calling libc on Linux,
  which the floor refuses; their Linux branches are raw syscalls now,
  the shape `socket` has, with `realpath` walked in iyi over
  `readlinkat`, and the darwin floor names each libSystem symbol the
  three platform modules add.

### Removed

- **The Crystal socket stack that landed beside `IyiSocket`.** TCP, UDP,
  UNIX, `getaddrinfo` and a second `Socket` type were 1,699 lines of the
  other language's library, and they broke the dependency floor. The
  module is the blocking `IyiSocket` it was, over raw syscalls on Linux
  and libSystem on darwin. `bench/socket_exercise.sh` holds it.

- **Twelve std modules the prelude already owns — and eleven of them
  came back.** `annotations`, `comparable`, `empty`, `env`, `errno`,
  `exception`, `iterable`, `kernel`, `nil`, `reference_storage`,
  `steppable` and `symbol` were dropped from the rewrite as empty shims,
  exception classes in a language without exceptions, or names the
  compiler has already refused (`p`, `pp`, `ENV`, `try`, `not_nil!`).
  Their author's pull requests (#62, #64, #68, #69, #70, #73, #74, #77,
  #78, #79, #80) reinstate all but `exception`, each with a gate of its
  own, on the owner's call; the sentence above records why they had
  gone, so the second meaning is at least a written one.

- **`iyi repl`.** The session ran on the macro evaluator, which is the
  other language's compile-time library, so it answered iyi code with
  that library's sentences: `"ab" * -3` came back `Negative argument`
  where this compiler says `negative count: -3`, `7 // 0` came back
  `Division by 0` where the compiler panics `division by zero`, and every
  error carried `Showing last frame. Use --error-trace for full trace.` —
  the compiler's own voice, in what is supposed to be a session. One name
  meaning two things depending on whether it was typed at a prompt or
  compiled, which is the thing III.1.7a is about, and a second
  implementation of the semantics, which is what V.11 removed the
  interpreter for. It is gone rather than taught the prelude: the verb,
  its 123 lines, and the line in `DELEGATED`. `iyi repl` answers "unknown
  command" now, and `bench/verbs_exercise.sh` holds it there.

### Changed

- **`src/std` is iyi over the prelude.** JSON, YAML, XML, HTML, path, IO,
  unicode, big and the rest of the library bind nothing: no `lib`, no
  `fun`, no `asm`, no `@[Link]`, except `socket`, `time`, `file`, `dir`
  and `udp` (the platform, on purpose), `debug` (the program's own DWARF)
  and `math`'s LLVM hardware instructions
  (`llvm.sqrt`, `llvm.copysign`). `Math` is a `pub struct`
  with class methods; `Complex` and `Benchmark` import it. `sin(1e22)`
  answers a point on the circle instead of panicking. Every module has a
  `bench/std_<name>_exercise.sh` that builds plain and `--release` and
  proves a broken copy is caught. `bench/std_exercise.sh` holds both
  rules.

- **`find` and `index` answer nil.** They raised, under a rule this
  library stated and generalised one method too far: `?` for the nilable
  one, the plain name for the one that raises, "the convention `max?`/`max`
  and `first?`/`first` already use". Those two are not that rule. The rule
  is that the plain name is the *common* case — `max` raises because an
  empty collection has no largest element, and `find` answers nil because
  not finding is the ordinary outcome of a search, which is why Crystal
  spells the raising ones `find!` and `index!` rather than breaking its own
  convention. Applying the wrong half made one name mean two things inside
  this tree: `Enumerable#index` raised while `Indexable#index` and
  `Array#index` answered nil, and SPEC.md III.1.7a exists to keep exactly
  that out. It also pointed the one-way door the wrong way: `|| raise "no
  element matched"` turns a nil into a panic in one expression — the
  prelude writes that itself in `String#to_i` — while a panic is caught at
  a task boundary and nowhere else (III.4.3), so the raising default put
  the recoverable answer out of reach. `find?` and `index?` are gone; the
  plain names answer nil in `Enumerable`, `Iterator` and the prelude's
  `Array`, where `find?` was the only spelling. `max?`/`max`, `min?`/`min`,
  `first?`/`first` and `minmax?`/`minmax` keep their pairs untouched.

### Fixed

- **A second `close` in a row became a `read`, under optimisation.** The
  prelude's `__iyi_close` issued its syscall from an `asm` that declared
  no output, so LLVM took the number register to still hold 3 afterwards
  and skipped the load for the next call; the kernel had written 0 there,
  and the next close blocked in `read` on the descriptor. Found by
  `std/udp`'s gate, whose lifecycle section closes two sockets back to
  back; the syscall's answer is declared as an output now, on both
  Linux targets.

- **A probe of `src/std` found 58 defects across twelve modules, and
  each is fixed where it lived and held by the module's gate.** The
  shapes: a panic carrying the prelude's sentence (`std/yaml` indexed an
  empty table on a control character; `std/time` overflowed past an
  Int32 year; `std/text` overflowed on a Char above U+00FF in a block
  `gsub`; `std/math` overflowed on `pow(-1, Infinity)`), a wrong answer
  (`Math.frexp` landed past 1.0 for whole bands of small magnitudes and
  every log-based function inherited it; `pow(2, 1023)` was off in the
  fourteenth digit; `log10(1000)` was not 3; `atan(1e155)` was 0;
  `asin(2)` was π/2; `round(TiesAway)` moved an integer; `from_json`
  could not read the `UInt64` `to_json` wrote; `Node#text=` did
  nothing; `tr` had no ranges; `Unicode.upcase("i", Turkic)` was `I`),
  and silent loss (`std/yaml` dropped a dedented entry and made a
  stream empty after a `%YAML` directive; `std/base64` dropped what
  followed a `=`; `parse_rfc3339` took `+99:99` and trailing text;
  `parse_ip` read `010.1.1.1` as ten; `read_char` accepted overlong
  and surrogate sequences; the JSON reader accepted bytes that are not
  UTF-8 inside a string). Also: a billion-laughs YAML is refused at a
  million nodes instead of stalling; CDATA holding `]]>` is written as
  two sections; `divmod` works on floats; a float narrows to infinity
  instead of panicking; `Int64 == Float64` is exact. What is left is
  named in the module headers: the prelude's own `//` and `%`
  truncate (a decision, not a defect), `Float64#round` with no mode is
  the prelude's, `sin(1e22)` still wants Payne-Hanek, and the Bessel
  handover at 5 is a known step.

[Showing lines 1-300 of 7848. Use :301 to continue]