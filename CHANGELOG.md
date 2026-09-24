# Changelog

## Unreleased

### Added

- **A short name for a requirement.** `require
  github.com/sdogruyol/iyi-web v0.1.0 as web` in `iyi.mod` - or `iyi get
  PATH --as web` - makes `web/dsl` mean `github.com/sdogruyol/iyi-web/dsl`
  in this project's files, so the path is written once, in the manifest,
  and a file writes `using web/dsl`. The name is spelled out before anything
  resolves, so a module is one module however it was reached; a package's
  own short names are its files', from its own manifest; `get -u` keeps a
  name and `tidy` counts what it imports. A short name that is also this
  project's directory, `std`, a name that is not one lower-case word and a
  name given twice are refused by name.
- **A `using` imports what it names.** `import app/dep` followed by `using
  app/dep` wrote one path twice; `using app/dep` is now the one line, and the
  parser makes the import - after the file's own imports, so the edge is the
  file's and the import wall holds: a qualified name the file wrote no line
  for is still refused. Writing both still works and loads the module once.
  The formatter and `to_s` print what the source says, and `mod context` and
  the language server's auto-import write the one `using` line.
- **`iyi get`: a requirement without writing the line by hand.** `iyi get
  example.com/someone/lib` requires the latest release - the highest `vX.Y.Z`
  tag, a pre-release only when there is no release - `PATH@v1.2.0` requires
  that version, up or down, and `iyi get -u` brings every requirement to its
  latest. The graph is resolved by minimal version selection, every selection
  is fetched and checked against `iyi.sum`, and only then is `iyi.mod`
  written: its one line rewritten in place or appended, comments and CRLF
  kept, so a `get` that fails leaves the manifest byte for byte. A version
  that is not a tag is refused beside the versions that are, and a module
  MVS builds at another version than its line names is named.
  `bench/packages_get.sh` drives it against a mirror.
- **`iyi get --check`: which requirements are behind.** `iyi get -u --check`
  lists every requirement behind its latest release, and the same flag on
  any `get` says what it would change - from the repositories' tags alone,
  nothing cloned and nothing written - exiting 1 when something would, so a
  CI step can ask whether the manifest is current.
- **`replace` in `iyi.mod`: a required module built from a directory.**
  `replace example.com/someone/lib => ../lib` makes every verb - a build,
  `get`, `check`, the language server - read the module from that directory
  instead of its tag, wherever the graph reaches it; its edits build without
  `iyi.sum` refusing them, since the sum records only what was fetched, and
  the language server's results move when a file there does. The directory
  must hold the module under the same path, a target is spelled `./`, `../`
  or absolute, and a `replace` in a dependency's manifest is ignored, so a
  library cannot redirect its consumers. iyi-web was copied into `lib/`
  for want of this.
- **`iyi mod tidy`: the manifest says what the source imports.** A package
  imported without a `require` gets one - at the version the graph already
  builds when another requirement pulls it in, so tidying never moves what
  builds, otherwise at the latest release of the import's longest prefix that
  is a repository. A `require` nothing imports is removed, unless removing it
  would lower a version another module pulls in: that line is kept and the
  reason said, decided by the resolver rather than by a second kind of line.
  `iyi.sum` keeps an entry per module that builds and drops the rest, and
  `--check` writes nothing and exits 1 when a change is due. The source is
  every `.iyi` file under the manifest, tests included; a directory with its
  own `iyi.mod`, `lib/` and hidden directories are not.

### Changed

- **`root_exercise` measures on Windows what it only said it could not.**
  Two of its checks reported themselves unmeasured there. What root
  discovery asks the machine for had "no floor on record": it is read from
  the import table now, with the toolchain's `dumpbin`, the way
  `dependency_floor` and `thread_exercise` read theirs - kernel32 and the
  C runtime's DLLs, plain and release, and a DLL beyond them fails it (a
  narrowed list flags `vcruntime140.dll`). And the Linux objects it
  cross-compiles had no `nm` to read them: LLVM's `llvm-nm` reads them
  where there is no `nm`, and they leave exactly `__data_start`,
  `__ehdr_start` and `_end` undefined, as they do read on darwin.

- **The SQLite driver gate runs on Windows.** `sqlite3_queries.sh` binds
  `db` and `sqlite3` as boundaries and runs a query from source and from
  artifacts, and the Windows image has no SQLite to link. The Windows
  gates job makes one: sqlite.org's x64 DLL, pinned by hash, and its
  import library made from the `.def` beside it with MSVC's `lib`, put on
  `LIB` and `PATH`. Run that way on a Windows machine, the two arms
  answered the same four rows. What Windows still does not run: the
  daemon's gates (`iyi-daemon.exe` does not build there),
  `sandbox_story.sh` (wasi-sdk), `gc_race.py` (Go), and `parallel_mark`
  and `concurrent_mark`, which have no mark helpers there to measure.

### Fixed

- **A mark's helpers could find the mark over before it began.** The
  collector turned the generation that wakes the helpers and only then,
  in its own drain, counted itself as a worker with work. A helper that
  reached the pool in between saw no worker active and an empty pool -
  the drain's sign that the mark is done - and left with nothing, and the
  collector marked alone while every helper had taken a permit. With
  Windows' helpers (Added, above), eleven of them took permits and blackened
  nothing in 7 of 20 of `parallel_mark`'s marks of a million-node tree,
  and the exercise failed 6 runs in 10. The collector counts itself in
  before it turns the generation now: in 20 marks printed one by one the
  helpers blackened 82 to 94% of the nodes each time, and the exercise
  held 10 runs of 10.

## 0.14.1 — 2026-09-24

**A server can stop, and be reached more ways.** `std/signal` parks a
fiber until INT or TERM arrives, so a graceful stop is a sibling that
closes the listener and a group that joins what is in flight. `std/socket`
listens and connects over IPv6 and at a unix socket's path, bounds a
read's and a write's wait with `read_timeout_ms` and `write_timeout_ms`,
answers what the peer does as a `SocketError` rather than a panic, and
lets one fiber read a socket while another writes it. A file seeks, a
package imports the standard library, and each of these ran on Linux,
darwin and Windows before it was called done: the socket gate runs on
all three now, and so do twenty-eight more of the language's gates.

**The library is faster where a program ported from Crystal spends its
time.** `Float64#to_s` is Grisu3 and `String#to_f` Eisel-Lemire, `Math.exp`
is fdlibm's, `Base64` is twice as fast, a pattern of byte classes is
searched without the machine and `gsub` takes a table, `BigInt` runs its
limbs through pointers, and a `Hash` allocates nothing until its first
entry. crystal-metric's suite, ported, ran in 24.87 s where Crystal 1.21
took 26.11 s, on the machine the work was measured on.

**Thirty-nine fixes, and one that changes what an artifact is.** A symbol
in a module's object code carried the producing build's number for it, so
a consumer that met its symbols in another order compared them wrong; a
unit now reads the linking program's number, and **`.iyimod` is v54: an
artifact written by 0.14.0 is refused, and `--emit-iyimod` rewrites it.**
The rest include a temporary file that a planted symlink could redirect,
a query whose malformed `%` panicked, a darwin write that made a 0600 file
world-readable, a Windows fiber switch that lost the vector registers a
call keeps, and a collector that handed a live object's chunk to a second
one. `std` is 68 modules and 40,690 lines.

### Added

- `std/socket` read and write timeouts: `read_timeout_ms` and
  `write_timeout_ms` bound how long a read or a write waits for the peer, and
  a wait that runs out answers a `SocketError` whose `timed_out?` (now public)
  is true, with the connection still open. Underneath, the scheduler has an
  io wait with a deadline - `wait_readable(fd, ms)` and `wait_writable(fd, ms)`
  answer `true` when ready and `false` when the time ran out: the fiber is in
  the sleep list beside the io list, whichever wakes it takes it off the
  other, and on Windows the deadline cancels the posted operation and its
  completion is what wakes the fiber, so no packet is left to arrive at the
  fiber's next operation. The socket gate proves a timeout that is not kept
  and a deadline left in the sleep list are both caught, and fails on a panic
  the program outlives.

- `std/socket` unix sockets: `IyiSocket.listen_unix(path)` and
  `IyiSocket.connect_unix(path)`, parking like TCP's. The listener's
  `local_address` is its path, `local_port` refuses by name, and `close`
  removes the socket file; a path that is already taken is refused with
  "the address is in use" rather than taken over, and a path past the
  platform's room (103 bytes on darwin, 107 elsewhere) is refused rather than
  cut. On Windows the accept is `AcceptEx` as for TCP, and the connect a plain
  `connect`, `ConnectEx` being TCP's alone.

- `std/socket` speaks IPv6: `IyiSocket.listen("::1", port)`,
  `IyiSocket.connect("[::1]", port)` (bare or bracketed, as a URL writes it),
  `local_address` written the RFC 5952 way, and `IyiSocket.parse_ipv6` with
  `IPv6Address` for the text forms, including a dotted IPv4 tail. A listener
  on `::` takes IPv6 alone on every platform (`IPV6_V6ONLY`), where Linux's
  default was both families and Windows' IPv6 alone. `std/udp` uses the same
  parser and printer; its own read no dotted tail and printed every address
  but `::` and `::1` uncompressed. The socket gate now runs on darwin and
  Windows as well.

- `std/signal`: `Signal.wait(Signal::INT, Signal::TERM)` parks a fiber until
  one of the signals it names arrives and answers which, or `Cancelled`. From
  the first wait that names a signal, its default action is off and every
  arrival is kept until a wait takes it, so a server stops gracefully with
  ordinary structured concurrency: a sibling waits, closes the listener, and
  the group joins the requests in flight. On Linux and darwin the handler
  writes to a pipe the poller watches; on Windows the console control handler
  posts to the parked fiber's completion port, Ctrl-C and Ctrl-Break being
  `INT` and closing the console, logging off and shutting down `TERM`. Gate:
  `bench/std_signal_exercise.sh`, which sends TERM from outside and proves a
  wait that takes nothing and a handler never installed are both caught.

- **`IO#seek`, `#pos` and `#pos=` on a file (`import std/file`).**
  `seek(offset, IyiIO::Seek::Set | Current | End)` moves where the next
  read or write happens and answers the new position, as Crystal's does:
  a large file, or a byte range of one, is sent from where it lies rather
  than read whole into memory first (iyi-web's `send_file` wanted it).
  Buffered writes are flushed before the move, the read-ahead it skips is
  dropped, and `pos` counts what the program read, not what was read
  ahead.

- **`OptionParser#invalid_option` and `#missing_option`
  (`import std/option_parser`).** A mistyped flag, a value for a flag
  that takes none, and a flag whose value is missing panicked, which is
  a bug report where a usage line was wanted; a program reading its own
  command line had to write its own parser (iyi-web did). The handlers
  are Crystal's: each is handed the flag and parsing goes on after it.
  With none set, the panics are the ones they were.

- **`String#gsub(pattern, table)` (`import std/regex`).** Each match
  replaced by its entry in a `Hash(String, String)` and dropped when the
  table has none, as Crystal 1.21's `gsub(Regex, Hash)` answers:
  `seq.gsub(Regex.compile("B|D"), {"B" => "(c|g|t)", "D" => "(a|g|t)"})`.

- **`Array#zip(other) { |a, b| ... }` and `each_cartesian(other) { |a,
  b| ... }` (`import std/indexable`).** Pairs handed to a block without
  building the array of tuples first: `zip` stops at the shorter of the
  two, `each_cartesian` walks every pair, this collection's order
  outermost — as Crystal 1.21 yields them.

- **`String#gsub(pattern, replacement)`, `String#gsub(pattern) { ... }`
  and `String#matches?(pattern)` (`import std/regex`).** The other
  library's spellings on the text side, over `Regex#replace` and a search
  — `matches?` asks whether the pattern occurs anywhere, which
  `Regex#match?` (the whole text) does not. There are no capture groups
  yet, so a replacement is taken as written; `scan` stays off `String`,
  because Crystal's answers match data and one name meaning two things is
  worse than a missing one.

- **`strict_encode`, `strict_decode` and `decode_string` name what
  `std/base64` calls them.** `Base64.encode` already writes no line breaks
  and `decode` already answers a String; a port that reached for the other
  library's names was told the prelude is small by rule. The error says
  which method it is now.

- **`String#to_u64` (and `to_u64?`, with a base) and `String#[](range)`
  (`import std/text`).** A checksum kept in `UInt64` read back from text,
  nil past 18446744073709551615 or for a sign; and `s[1..3]`,
  `s[-3..-1]`, `s[0...n]` — the bytes a range names, as `[](start,
  count)` counts them. Both answer what Crystal 1.21 answers for the same
  calls.

- **`Int32#step`, `Int64#step` and `Float64#step` (`import
  std/steppable`).** `0.step(to: n, by: 60) { ... }` and
  `n.step(to: -n, by: -0.05) { ... }`: the trait and its iterator were
  there and no number implemented it, so a port wrote Crystal's
  accumulate-and-compare bounds by hand to keep the iteration counts. A
  double steps by adding, and reaches the same count and the same last
  value Crystal 1.21 does; `bench/std_steppable_exercise.iyi` checks both.

- **`Array.new(size, value)`, `Array#+`, `Hash.new(default)`,
  `Hash.new { |table, key| ... }` and `Hash#to_a`.** The forms a Crystal
  port writes first: a filled row, two arrays joined, a counter that
  starts at zero (`counts[k] = counts[k] + 1` on a missing key), a memo
  table whose block stores what it answers, and a table's pairs as an
  array to sort by value. `bench/collections_exercise.sh` checks each and
  fails with the default or the fill taken out.

- **`String.build { |io| ... }` and `String::Builder`.** Text a piece at a
  time — `io << "a" << 1 << 'é'`, `io.write_byte` — into one buffer that
  doubles and is copied once, the other library's spelling. And
  `Regex#replace(text) { |match| ... }`, the per-match substitution a
  fixed replacement cannot say.

- **`iyi init MODULE [DIR]`.** A project, from nothing: `iyi.mod` naming
  the module, an entry `main.iyi`, a module `greet.iyi` the entry imports
  and `main_test.iyi` — the four files that show `module`, `import`,
  `using`, `pub` and what a test is here, in a tree that runs and passes
  the moment it is written. Between `go mod init`, which writes the
  manifest and stops, and `cargo init`, which writes a program. The
  module path is checked by the manifest's own grammar and refused with
  its own sentence; nothing that is already there is written over, so a
  second `init` is one project and not a damaged one.

  It was refused for as long as this fork has had a binary: `init` sat
  in the list of verbs that belong to Crystal, because Crystal's writes a
  shard, and the refusal told the reader to run it "with the `crystal`
  binary in this checkout" — a person who installed the zip has neither.
  `bench/init_project.sh` holds the four files on Linux and on Windows:
  the entry runs, the test passes, `mod context` grounds the import, and
  a second `init` changes not one byte.

### Changed

- **Twenty-eight more gates run on Windows, in a job of their own.** The
  runtime's exercises (`format`, `io`, `number`, `value`, `enum`,
  `float_text`, `collections`, `runtime`, `server_load`, `defer_cost`,
  `windows_exercise`), the boundaries and floors (`bind_roundtrip`,
  `bind_regex_identity`, `open_dispatch`, `yaml_reads`,
  `std_dependency_floor`, `build_tool_floor`), what the editor and the
  numbers say (`debug_info`, `measured_numbers`, `lsp_latency`,
  `lsp_soak`, `context_pack`, `generic_boundary`, `rebuild_speed`) and
  the shards bound as boundaries (`jwt_signs`, `bind_chain`,
  `kemal_serves`, `shard_serves`) ran on Linux and darwin only. Each
  passed on Windows first - the shards on a runner, because `shards
  install` needs symbolic links and a machine without Developer Mode
  refuses them. Two could not start there: `context_pack.py` ran
  `bin/iyi`, a shell script, and takes `IYI` now as the others do, and
  `generic_boundary.py` named a module by its Windows path, `calc\lexer`,
  and looked for `calc/lexer`. `windows-gates` builds and runs them
  beside the other two Windows jobs, each of which is well into its
  ninety minutes. Still not on Windows: `sqlite3_queries.sh` (the image
  has no `sqlite3.lib`), the daemon's (`iyi-daemon.exe` does not build
  there), `sandbox_story.sh` (wasi-sdk) and `gc_race.py` (Go).

- **One fiber may read a socket while another writes it.** The poller
  kept one waiter per descriptor and refused a second with "two fibers
  waiting on one fd", so a WebSocket - a fiber reading frames, another
  writing them - could not be written (found in iyi-web). A descriptor
  now has at most one reader and one writer: epoll's registration is the
  union of what they wait for, widened with `EPOLL_CTL_MOD` and narrowed
  back as each leaves, kqueue keeps a filter per direction, and the
  event's own bits say which half to wake, both on an error or a hangup.
  Two readers or two writers are still refused, by name. A cancelled
  waiter is taken off by identity, not as whoever waits on its fd.

- **What the other end of a socket does is a value, not a panic
  (`SocketError`, `import std/socket`).** A client that disconnected
  mid-response panicked the server with "cannot write to socket", or -
  where the kernel raised SIGPIPE on the broken pipe - killed it without
  a word. `read`, `write`, `recv`, `send`, `accept` and `connect` answer
  `SocketError` beside `Cancelled` now: which operation, the platform's
  error number, a reason (reset by the peer, the peer closed it, refused,
  timed out, no route), and `disconnected?` for "the peer is gone". A
  write never raises SIGPIPE (`MSG_NOSIGNAL` on Linux, `SO_NOSIGPIPE` on
  darwin), an accept whose client left first takes the next one, and
  `std/http`'s server ends that connection and serves on, waiting out a
  listener's own errors from 5 ms doubling to a second; `HTTP.get` and
  its siblings answer `SocketError` for a refused or reset connection.
  What a program does wrong itself - a socket it closed, a negative
  count - still panics (found in iyi-web).

- **A language-server worker replaced on its memory bound is warmed at
  the next quiet, not at once.** Retiring a worker between two requests
  sent its successor the focused file's compile ahead of whatever the
  client asked next, so that request waited for a compile it did not
  need: an unchanged workspace pull took 160 ms behind it and takes
  15 ms now. The idle retirement still warms in its own quiet.

- **A `Hash` takes no storage until its first entry.** Every table made
  its keys, values and index at eight entries, sixteen slots cleared,
  whether or not anything was ever put in it - a trie's leaves, each
  with a children table it never fills, paid for all of it. The metric's
  primes trie went from 1.04 s to 0.88 s (Crystal 1.21: 0.75 s).

- **A parked channel send is one allocation, and finding the running
  fiber is one load.** The sender's value sat in a one-element array, so
  every send that waited for its receiver made a node, an array and the
  array's buffer; it is a field of the node now. `IyiScheduler.state`
  carried its first-touch allocation inline, which made it too large to
  inline and gave every call a large function's prologue ahead of its
  one thread-local load; the first touch is a method of its own. A ring
  of 503 fibers passing a token fifteen million times - which parks on
  every send - went from 1.08 s to 0.72 s (Crystal 1.21: 0.54 s).

- **`BigInt` adds, subtracts, multiplies, shifts and divides through the
  limbs' pointers, and multiplies by a machine integer in one pass.**
  Every limb went through a bounds-checked `Array#[]` and a growth-checked
  `<<`, `x * 10` made a `BigInt` of the ten and ran the general product,
  and `a - b` copied `b` to negate it. The arrays are now built at their
  size and written in place, `* Int32` and `* Int64` under 2^32 are one
  pass, and subtraction compares magnitudes directly. The metric's
  pidigits went from 2.0 s to 0.97 s (Crystal 1.21 with GMP: 1.06 s);
  27,000 random sums, differences, products, quotients, remainders and
  shifts of up to 300 digits print what Crystal's `BigInt` prints.

- **`Float64#to_s` is Grisu3 and `String#to_f` is Eisel-Lemire, each
  with the exact bignum behind it.** Printing multiplies the value and
  its boundaries by a cached power of ten in 64-bit arithmetic and keeps
  the digits only when their proof holds; about one double in 250 is
  left to the bignum, which answered all of them before. Parsing reads
  up to nineteen significant digits into a word and rounds that times a
  128-bit power of five (fast_float's table); past nineteen, the word and
  the word above it are both rounded, and only when they disagree does
  the bignum read the text. Every one of 2,311,905 doubles prints the
  bytes Crystal 1.21 prints, 367,920 hard decimal strings parse to
  Crystal's bits, and the two directions ran 14.2 s and 9.0 s on them
  and now run 1.2 s and 1.6 s. In the metric: JSON generation 3.8 s to
  0.76 s, the three JSON parsers 2.3-3.1 s to 0.45-0.50 s (Crystal:
  0.74 s, 0.30-0.40 s). The tables are strings of little-endian words,
  because an array constant in the prelude is built before the heap it
  lives in has started.

- **`Base64.encode` and `Base64.decode` are twice as fast.** Encoding
  runs whole three-byte groups without asking how many bytes are left,
  and the last group alone takes the padding path. Decoding reads a
  256-entry table instead of five range tests, turns four data characters
  into three bytes in one step between groups, and writes straight into
  the answer, whose size is known from the text when only closing padding
  is there; whitespace or padding elsewhere takes the byte-at-a-time path
  it always took, and every refusal is the one it was. In the metric's
  run, 8,192 times over 300 KB: 2.9 s to 1.2 s encoding, 3.6 s to 1.2 s
  decoding (Crystal 1.21: 0.8 s each). A text that opens with whole groups
  - most of them - runs those in a loop of their own before the one that
  watches for whitespace and padding: another fifth off decoding.

- **A string the prelude builds is counted when `size` asks, not when it
  is made.** `String.new(bytesize) { ... }` scanned every byte it had
  just been handed to store the character count, and almost none of those
  strings - an encoding, a join, a line read - is ever asked for it. The
  count is left at zero, the "not counted yet" `size` already honoured
  for strings from the other library, and scanned once on the first
  `size`. `Base64.encode` of 300 KB, 8,192 times: 2.0 s to 1.4 s.

- **A pattern of byte classes and alternatives is searched without the
  machine.** `agggtaaa|tttaccct`, `[cgt]gggtaaa|tttaccc[acg]`, `a.c`,
  `[^x]y` — runs of fixed length, no quantifier, group or anchor — are
  kept as a table per byte; when the runs are the same length and fit in
  64 bytes together, they run as one Shift-And word, a load, a shift and
  two masks per byte for all the alternatives at once. The nine variant
  patterns of the regex-dna benchmark over 50 MB went from 3.4 s to
  0.54 s (Crystal's PCRE2: 2.0 s). Matches, their order and leftmost-first
  choice are the machine's; everything else still goes to it.

- **`Math.exp` is the fdlibm routine, about three times faster.** The
  argument is reduced by ln 2 split in two parts only past |x| > 0.35, a
  fifth-degree polynomial carries the rest, and 2^k is written into the
  exponent bits rather than multiplied out. Over 350,016 arguments it
  stays within one unit in the last place of Crystal's answer (321,224
  identical); a network that spends its time in a sigmoid ran 4.1 s and
  now runs 1.34 s. `Float64` bits are read through a local pointer rather
  than a heap cell, so printing a float allocates one object fewer.

- **`iyi run` names the status of a death it cannot explain.** "Process
  terminated abnormally, the cause is unknown" left out the one fact
  there was: it now ends `(status 0xc0000409)`, so a stack cookie, a heap
  corruption and a fast-fail read differently. It was written for an
  intermittent Windows crash at `bench/thread_exercise.iyi`'s exit, which
  said only that.

- **A regex with no operator in it is searched as text.** `B`, `ggt`,
  `tHa`: the pattern is its own bytes, found the way a string is searched
  rather than by stepping the matching machine a byte at a time. Eleven
  one-letter replacements over 60 MB — regexdna's substitution pass — went
  from 8.5 s to 1.4 s; find, scan, split and replace still agree with
  Python's `re` on every case of `bench/std_regex_exercise.sh`'s fixture.

- **`Random.new(seed)` is the other library's stream, draw for draw.** The
  stream was taken from the seed where Crystal takes it from a separate
  sequence (zero unless asked), `rand` was 32 bits over 2^32, and
  `rand(n)` a plain modulo, so a seeded benchmark ported from Crystal
  printed different numbers — the port carried seventy lines of its own
  PCG32 to match. `Random.new(seed, sequence = 0)`, `next_u` (was
  `next_u32`), `next_float` (53 bits from two draws), `rand(n)` with the
  rejection that keeps every value equally likely, and
  `shuffle(random)`, `sample(random)` and `sample(n, random)` make
  Crystal 1.21's choices in its order; `bench/std_random_exercise.iyi`
  checks each against the value Crystal prints.

- **`Float64#to_s` is three and a half times faster.** The shortest
  round-trip printer made every one of its bignums eighty limbs wide —
  3.8 KB of garbage per double printed, most of what `to_s` cost — and
  boxed the double on the heap to read its bits. Each bignum is sized to
  the value in hand now and doubles past the estimate instead of writing
  beyond it, the digit loop's sums share one scratch number, and a million
  doubles print in 0.43 s where they took 1.55 s. The text is the same:
  2.3 million bit patterns across the whole range, subnormals and every
  power of two included, print byte for byte what Crystal 1.21 prints. The
  number exercise pins the range's ends and the powers of two whose nearer
  neighbour is below, and fails with the power-of-two rule taken out.

  `String#to_f` and the other two printers (`Float32`, `sprintf`'s `%g`)
  start their bignums at eight limbs rather than eighty and grow on
  demand, so parsing a million doubles takes 0.38 s instead of 0.68 s; the
  2.3 million texts above read back to the bits they were printed from.

- **`Float64#round` sends a tie to the even integer, as Crystal's does.**
  `2.5.round` is 2.0 and `3.5.round` is 4.0; `round(digits)` the same at
  its place. It went away from zero, so the same name compiled under both
  libraries and answered differently — the shape SPEC.md III.1.7a exists
  to keep out — and a program rounding a million doubles to ten places
  printed its first different digit a few hundred thousand values in.
  `std/number`'s `round(mode)` still names every mode, and
  `round(digits, mode)` joins it: `25.0.round(-1, RoundingMode::TiesAway)`
  is 30.0.

- **An install over an install is gated on Windows too.**
  `bench/install_upgrade.sh` holds it for the tarball: a file an older
  release shipped and this one does not used to survive the upgrade and
  was still *required* by a glob in the library. `install.ps1` takes a
  different route — it replaces `share\iyi` whole — and nothing had
  asked whether that route arrives. The Windows job now plants a stale
  file and a poisoned prelude in an installed prefix, proves `check`
  breaks, installs over it, and requires the stale file gone and the
  prelude whole.

- **The language-server gates stop, and say where, when the server does
  not answer.** A Windows run sat in `bench/lsp_session.py` for most of an
  hour — it takes 37 seconds there — and printed nothing, because the
  client blocks on a read and the output was still in a pipe's buffer.
  Both LSP gates now print each step as it finishes and, 180 seconds
  without one, name the step that never did, kill the servers, and exit 1.

- **The Windows job sweeps cursor positions at stride 600.** At Linux's
  200 `bench/lsp_positions.py` took 36 of the job's 90 minutes, which left
  22 to spare; every module is still asked, over the Windows transport and
  paths, which is what that job is there for. The step's output is
  unbuffered, so a gate that stops says where.

### Fixed

- **A module path's `/v2` named a repository nobody publishes.** SPEC.md III.7
  says a major version past 1 is its own module under a path suffix, in the
  same repository; the fetcher took `example.com/lib/v2` as the repository
  `example.com/lib/v2.git`, and the import of its root module looked for
  `v2.iyi`. The suffix is read now: the repository is `example.com/lib`, the
  tag `v2.x.y`, the root module `lib.iyi`. A `require` pairing a path with
  another major's version is refused naming the path it belongs to, and
  `iyi get example.com/lib` never picks the repository's v2 tags.
  `bench/packages_get.sh` publishes a v2 in the same repository and builds
  against it.

- **A Windows program whose threads failed while collections ran could
  never end.** `__iyi_exit` was `ExitProcess`, which stops the other
  threads and then runs every DLL's detach and the C runtime's
  teardown, none of it iyi's. In 3 runs of 70 of `thread_exercise` with its
  thread-root walk taken out, the process printed its failure and then
  sat in `NtTerminateProcess` under `RtlExitUserProcess` for good; the
  dumps show that one thread and nothing else, and neither `timeout -k`
  nor `Stop-Process` could end it. On a runner the gate that runs that
  program hung until `windows-std` was cancelled at 81 minutes. It is
  `TerminateProcess` on itself now, the way Linux's is `exit_group`: 0
  hangs in 1,150 runs. `bench/thread_exercise.sh` runs the program 200
  more times on Windows and wants every run to end with exit 1, and each
  of its deadlines is `timeout -k`, since Git Bash can lose the TERM to
  a native program.

- `bench/socket_exercise.sh` holds on Windows, where its first run found every
  section passing and one proof unable to fail: a stale io deadline there
  cancels an operation rather than waking a fiber, so the exercise cannot see
  it. That proof is epoll's and kqueue's, and runs where they are.

- `bench/debug_info.py` on Windows no longer asks gdb to read an MSVC-linked
  program: gdb reads DWARF, the program's debug information is CodeView in a
  PDB, and the mingw gdb on the runner's PATH found the program and read none
  of its variables. The step says it is unmeasured there, as it does where
  there is no gdb.

- On darwin, `File.write` to a file that already existed set its mode to
  0644: the prelude's open-for-write followed the `open` with a `chmod`, a
  workaround from when `open` was not bound as variadic and a created file's
  mode came out as garbage. The binding is variadic now, so the mode reaches
  `open` on arm64's stack, and the `chmod` only changed files the call did not
  create - `File.tempfile`'s 0600 file became world-readable at its first
  write. `bench/std_file_exercise.sh`'s check that a temporary file is its
  owner's alone, made after a write, is what the darwin runner failed.

- `Dir.tempdir` and `File.tempfile` drop a trailing separator from TMPDIR,
  as Crystal's `Dir.tempdir` does. darwin sets TMPDIR to `/var/folders/.../T/`,
  so every path joined onto it had two separators and `File.dirname` of a
  file made there was not the directory it was made in; the darwin runner's
  std sweep found it. `bench/std_file_exercise.sh` runs the exercise in
  `Dir.tempdir` with a TMPDIR written that way.

- `bench/std_regex_exercise.sh` holds on Windows: its probe for a class past
  ASCII was written with Python's default encoding, which there is the ANSI
  code page, so `[é]` became the byte 0xE9 and the compiler refused the file
  as malformed UTF-8 before the regex could refuse the class. The probe, and
  `bench/std_signal_exercise.sh`'s patched copy, are read and written as
  UTF-8 by name.

- On Windows, `IyiSocket.connect_unix` to a path whose listener had closed
  answered a socket rather than a `SocketError`: the `connect` ran on a socket
  already non-blocking, and the shared `connect` read SO_ERROR before any
  outcome existed. Waiting for it with `select` was tried next and refused a
  listener that was there. A unix socket now connects while still blocking and
  is made non-blocking after, which is Go's `connect` on that platform; the
  listener is on the same machine, and its kernel queues the connection or
  refuses it at once. The socket exercise also parks a unix accept before
  anybody connects, which is `AcceptEx` on a unix socket there.

- **The language server died on Windows when the binary it runs was
  moved away: "Stack overflow".** With `iyi.exe` renamed under a live
  session, the proxy's next worker could not be started, and the
  exception that said so was the first the proxy had built. On Windows
  building one loads the debug information first, and the load asked for
  the executable's path, whose `realpath` raised because the path was gone;
  that exception loaded again, `Crystal.once` raised on the re-entry, and
  that raise loaded again, 3,961 times until the stack ran out (read from
  a dump of the proxy). The loader answers a call from inside itself with
  what it has so far now, and the proxy says "could not be started" as it
  does on Linux. `bench/lsp_memory.py` asks that on Windows: it lists a
  session's workers from the process snapshot where there is no `ps`,
  finds which binary one runs from its image name where there is no
  `/proc`, and runs in the Windows job; before the fix it ended "server
  closed the pipe".

- **No `-Dgc_none` or `-Dgc_boehm` program compiled: "undefined
  constant IyiThread".** The once-guard a constant read before its line
  goes through waits on other threads with `IyiThread.spin_pause`, and
  `thread.iyi` is left out of both of those builds; the guard is a `fun`,
  typed in every program, so every one of them failed, `hello.iyi`
  included. The lock is compiled where threads are and nowhere else.
  `compiler_spec`'s `-Dgc_none` examples and `bench/arena_exercise.sh`'s
  bump-pointer arm are what failed, on every platform.

- `bench/dependency_floor.sh` on darwin names `lseek` and `arc4random_buf`,
  with their reasons: `IO#seek` and `File.tempfile`'s random name brought them,
  both libSystem's, and the floor stopped the darwin job on "THE FLOOR MOVED"
  until it said so.

- A symbol read in a module's object code means what it means in the program
  that links it. Symbols are numbered per build, in the order each build meets
  them, and an artifact's units had the producer's numbers baked in: a consumer
  whose numbering differed compared `:before` against another symbol's number,
  so `samples/webapp.iyi` built from its artifacts counted no before-filter,
  and a symbol the unit returned printed as another's name. A unit now reads a
  symbol's value from a global the linking program defines, as it reads a type
  id, and the artifact carries the names (`SymbolLiterals`, format v54) so the
  consumer numbers even one only the unit spells. `bench/samples_roundtrip.sh`
  now builds a consumer that meets its symbols in another order than the
  producer, and checks `case`, an autocast to an enum, `to_s`, and a symbol
  only the module writes.

- **A package could not import the standard library: "package '...'
  has no module 'std/file'".** A short import written inside a package
  resolves against the package's own checkout and nothing else, so it
  cannot reach the consuming project's modules by a name they share; and
  `std/file` is not in any package's checkout. iyi's standard library is
  nobody's module: a package's `std/...` import that its checkout does
  not have resolves on `IYI_PATH`, as a program's does, and never
  against the consuming project, whose own `std/file.iyi` the package
  still does not see (found in iyi-web, which was copied into `lib/`
  instead of required). `bench/packages_resolve.sh`'s fixture package
  imports `std/file` beside an app that has a `std/file` of its own.

- **A block that names a constant written further down the file did not
  compile: "BUG: __iyi_once is not defined".** A constant read before its
  line is initialised by that first read, through a once-guard codegen
  calls by name, and the prelude never defined one - any `extra_options`
  block over an array declared below it (found in iyi-web). The prelude
  has it now: the first read runs the initialiser and sets the flag, two
  fibers reading the same constant first wait on one another rather than
  build it twice, and an initialiser that reads another constant not yet
  initialised re-enters.

- **`thread_exercise` died now and then on Windows with nothing said.**
  `iyi run` named the status once it could: `0x80000001`, a guard-page
  violation, once in sixty runs on a Windows runner. A fault handler
  that printed every thread's line and every registered fiber before it
  decided showed where: the collector had stopped a thread that had not
  run its first instruction, bounded its stack by the top of a *finished*
  thread's main fiber - a thread's main fiber went on the registry the
  first time it ran a fiber and never came off, and the system had given
  its stack's addresses to the new thread - and scanned up from the new
  thread's first rsp, which is on the stack's guard page. No handler
  claims that page, so the process died of it. A thread takes its main
  fiber off the registry as it finishes now. `thread_exercise` counts the
  registry before its threads and after they are joined, and fails with
  the retirement taken out ("8 fibers of 8 finished threads are still
  registered"); its driver runs the plain build ten more times and turns
  any death into a red step. The crash was not the per-thread stack
  guarantee it had been blamed on: it happened with that taken out.

- **The collector's own exercises had never run on Windows, and the
  Windows loop counted them as passing.** `collect_trigger`,
  `sweep_exercise`, `mark_exercise` and `root_exercise` refused every
  platform but Linux and darwin and printed "nothing to exercise here",
  which exits 0; their drivers, and `thread_exercise.sh`'s, did the
  same. Asked on Windows, sweep, mark and root held as they stood, and
  the trigger did not: every pause swept the whole heap, because
  Windows had kept an eager sweep since a string loop failed under the
  lazy one. The loop and all four exercises pass lazily now, and
  Windows sweeps the way Linux and darwin do. Three drivers read a
  death by signal as the break they prove, and Windows dies of an
  access violation its handler names and exits 1 on; they read that too.
  `collect_trigger`'s scavenge check read the spike's root back in the
  frame that then collected, and on Windows the head stayed in a
  register the scan is conservative about; it is read in a frame that
  returns. `collector_free_floor.sh`, which rebuilds the compiler with
  POSIX `make` and began by deleting `.build/iyi`, says why it does not
  run on Windows: the compiler there is built without a collector by
  default. A second Windows job, `windows-std`, runs these drivers and
  `bench/std_exercise.sh`. The lazy sweep took one proof out of
  Windows' reach: `reuse_integrity.sh`'s straddler proof, the line that
  keeps a cold run's lowest chunk off the released page taken out,
  failed 10 runs of 10 under the pause sweep and passed 20 of 20 under
  the lazy one, which has no helper threads there. Linux, whose sweep
  has them, still runs it; Windows says so and runs the other.

- **Seven standard-library gates failed on Windows, and none for the
  library's sake.** `bench/std_exercise.sh` had never run there. The
  python oracles of `std_deque`, `std_set` and `std_io` wrote CRLF, so
  every line differed from iyi's by an invisible `\r`; they write `\n`
  now. `std_errno`'s and `std_file`'s failure proofs edited the darwin
  arm, which Windows does not compile, so the proof "passed" on an
  unchanged program: errno proves the arm every non-darwin host builds,
  and the touch proof edits Windows' own `SetFileTime` ticks. `std_udp`'s
  blocking-receive proof removed a `MSG_DONTWAIT` that is 0 on Windows,
  where the socket is non-blocking by `FIONBIO`; it turns that off there,
  and kills the stuck copy with `timeout -k`, because Git Bash can lose a
  TERM sent while a native program is still starting. `std_io`'s
  dependency floor read nothing and said nothing new was linked; it reads
  the import table with `dumpbin` now. `std_http` gave its server fifty
  tenths of a second to print a port, and Defender holds an exe it has
  never seen for up to ten seconds on its first launch — measured, 12.8
  s once; the wait is a minute that a dying server ends at once. And the
  file exercise wrote under `/tmp` unless told otherwise; it defaults to
  `Dir.tempdir`. The library needed no change.

- **`Params.parse` panicked on a malformed `%` in a query.** A query is
  what a client sent, and `?q=100%` is what a browser sends for "100%";
  a server reading it died. It reads the way the WHATWG URL standard
  reads `application/x-www-form-urlencoded` now, as Crystal's does: `+`
  is a space, `%XX` is the byte, and a `%` that does not start two hex
  digits is itself. `URI.decode`, asked of text a program made, stays
  strict (found in iyi-web).

- **An unseeded `Random.new` did not compile in a program that imports
  `std/file`.** The entropy read opened `/dev/urandom` through `File`,
  and inside the library's namespace that name is `std/file`'s module
  once the module is loaded: `undefined method 'open' for
  Std::File:Module`. It names the class, `::File`, now.

- **`File.tempfile` could be made to write through a planted symlink.**
  It named the file after the process id and a counter, asked whether
  the path existed, and wrote to it if not; a symlink placed at the next
  name in a shared `/tmp` between the question and the write sent the
  data wherever the link pointed - an upload server's uploads into a file
  of the attacker's choosing (found in iyi-web, and reproduced). The file
  is made with an exclusive create now - `O_CREAT | O_EXCL`, `CREATE_NEW`
  on Windows - which refuses anything at the path, a symlink included,
  with mode 0600; and its name is sixteen hex digits of the kernel's
  randomness (`getrandom`, `arc4random_buf`), so it cannot be planted in
  advance. Windows' `%TEMP%` belongs to its user, and there the create's
  refusal is the guarantee.

- **A bound library whose code read a file-private class variable did
  not link.** An artifact names the class variables its object code
  reads as `Owner::@@name`, and the consumer emits each global by
  looking the owner up from the program's top; a type private to a file
  prints without its file, so it was never found and its global never
  emitted. On Windows `JSON`, `INI` and `XML` bound from Crystal's
  library each read `ConsoleUtils::@@remaining_unit` — `ConsoleUtils` is
  private to Windows' `file_descriptor.cr` — and every artifact arm of
  `bench/library_boundaries.sh` failed on `LNK2019` there. The owner is
  looked for in every file's private namespace when the program's own
  has no such name; the gate runs in the Windows job now.

- **A workspace pull after the language server replaced its worker
  compiled every file again.** The `resultId` of each file folded
  `String#hash` and `Time#hash`, which are seeded per process, and the
  proxy retires its worker mid-session (on its memory bound, or after
  two quiet seconds) and hands the client's ids to the successor: none
  matched, and the pull VS Code sends two seconds after any answer
  recompiled the workspace - 0.9 s for six files where the same pull to
  the same worker is a millisecond. The ids are an FNV-1a fold of the
  paths and text and the files' sizes and modification times now, the
  same in every process. `bench/lsp_session.py` step 31b' pulls with the
  old ids after a replacement; CI's step 31b had been failing on the
  replacement a larger prelude moved in front of it.

- **On Windows a fiber switch lost the vector registers a call keeps.**
  The Windows x64 convention keeps xmm6-xmm15 across a call along with
  the eight integer registers, and a switch is a call — but the switch
  saved and restored the integer ones only. Whatever the compiler kept
  in those registers over a `send` or a `receive` came back as the other
  fiber's: two fibers holding ten doubles each across a channel handoff,
  in a `--release` build, read the other's in 4,000 checks of 4,000. The
  switch carries all ten now, and a fresh fiber's first frame has room
  for them. `bench/concurrency_exercise.iyi` holds the doubles across
  2,000 switches, and `bench/concurrency_exercise.sh` fails on Windows
  with the restores taken out of the switch; the Windows job runs it now,
  with its import floor read off the table with `dumpbin`.

- **On Windows a new object could start with an old object's bytes.**
  The sweep hands a run of dead pages back to the kernel, and the carve
  takes the run up again as fresh memory: an object with a pointer in it
  is not cleared there, because a released page reads zero — Linux's
  `MADV_DONTNEED` makes it so. Windows' release was `MEM_RESET`, which
  only says the bytes may be dropped, and until memory is short they are
  not. A program with no `Pointer` in it built 24,000,000 objects whose
  nilable field the constructor never set, and 14,474,737 of them read it
  as a stale word instead of nil; in a threaded program whose lists'
  tails were such fields, five runs of five failed — a memory fault, a
  list that looped into itself and never finished, a checksum off. The
  release decommits and commits again now: the pages go back at once and
  read zero, and the next touch is legal. `bench/reuse_integrity.sh`
  builds the objects on released pages, plain and optimised, and fails
  with the release made advice again (`MEM_RESET` on Windows,
  `MADV_FREE` on Linux). darwin's `MADV_FREE_REUSABLE` is the same kind
  of advice and the same defect, open: the check does not run there.
  The objects that die to make the released pages were filled in a task
  on the main thread, and on Linux 6 runs in 400 kept them through the
  first collection and ended "the carve took up no released page"; they
  are filled on a thread of its own, joined first, and 0 runs in 400
  did.

- **`bench/doc_numbers.py` counted the compiler's `!` names on
  Windows.** The count README quotes leaves `src/compiler/` out, and it
  asked whether `"/compiler/"` was in the path's text — which on Windows
  is spelled with `\`, so nothing was left out and the gate measured 60
  where Linux measures 50, failing a tree whose sentence was right. It
  asks the path's parts now.

- **`String#to_f` rounded a decimal with more than nineteen significant
  digits as if the rest were zero.** `"6915724680296.729980553".to_f` was
  one unit in the last place under the nearest double, and so were
  85,234 of 367,920 long or halfway-straddling decimals measured against
  Crystal's parser. Every digit up to 800 is read now, past that only
  whether the rest is zero, which is all a double's rounding can depend
  on.

- **A method the integer tower has in `std/int` was reported as missing
  from the language.** `5_u32 + 1_u32`, `x << 3` on a `UInt64` and
  `x.to_u32` answered that the prelude is small by rule — or "did you mean
  `to_i32`?" — and a port concluded `UInt32` had no methods at all. It has
  every operator, shift, conversion and `<=>`, one import away; the error
  says so now: "`+` on UInt32 is in `std/int` ... `import std/int`" — and
  `iyi doc UInt32`, an empty struct before, ends by naming the same import.

- **`Array#join`, `String#tr`, `gsub` with a block, `delete`, `squeeze`
  and `Regex#replace` were quadratic.** Each built its answer with
  `result = result + piece`, which copies everything so far on every
  piece: a 130 MB `tr` ran fourteen minutes of CPU without finishing, and
  eleven `Regex#replace` calls over 60 MB ran thirty. They write into a
  `String::Builder` now, and `tr` over ASCII sets is one 256-entry byte
  table and one pass. `reverse` finds each character from the back instead
  of decoding the string into an array of `Char`s first (520 MB to reverse
  130 MB), and `each_line` scans instead of building every line first.
  `bench/std_text_scale_exercise.sh` puts eight megabytes through all of
  them under a clock, and the clock stops a builder that grows by a fixed
  step instead of doubling.

- **`iyi check` passed a type's methods when nothing built the type.**
  R-2c types a fully written def at its definition, caller or no caller,
  and two kinds of def were still caller-typed: those of a type the module
  never marked `pub`, whose name the probe could not write from outside,
  and those an `impl` block gives a type. With nothing constructing `X`,
  `def helper : Int32` returning `"nope"` and an `impl` method calling a
  method that exists nowhere both checked clean — a 3,000-line port had to
  grow a driver that called everything before `check` would read any of
  it. The probe names such a type the way the module's own code does, and
  an `impl`'s method is probed on the type like any other.

- **`iyi check` named the first def that did not type, and stopped.** Each
  definition-site probe is typed on its own now and every error is
  reported, one per def, in the order written — in text, in `-f json`, and
  as one editor diagnostic apiece. And an error at a probe's call pointed
  at a line and column of the probe's own text inside the def's file
  (`3:37`); it points at the def. `bench/agent_loop.py` checks both errors
  of one file, and fails on the tree before.

- **`record` dropped a block without a word.** `record Vec, x : Float64
  do def norm ... end end` compiled, and the methods were nowhere: the
  first call said `undefined method 'norm'`, at the call rather than at
  the `record`. The block is the struct's own body now, as in Crystal —
  a port that copies `record ... do ... end` keeps its methods.
  `bench/value_exercise.sh` calls one and is refused at compile time with
  the body dropped again.

- **`Float64#round` moved the double just under a half, and
  `round(digits)` ignored a place count under one.**
  `0.49999999999999994.round` was 1.0 — `(x + 0.5).floor` rounds the sum
  before the floor sees it — and `25.0.round(-1)` was 25.0, because a
  non-positive count went to `round` unscaled. The nearest integer is read
  off the fraction now, and a negative count rounds to tens and hundreds
  (`1234.0.round(-2)` is 1200.0). `bench/number_exercise.sh` fails on each
  of the three with the old line put back.

- **The collector handed a live object's chunk to a second object.** A
  run of dead chunks whose pages go back to the kernel keeps its lowest
  chunk on the free list, and when that chunk's head sat in the last
  sixteen bytes below the released page, the release zeroed the slot word
  the list reads when it hands the chunk out. The pop then stamped the
  arena's slot 0 as the new object and left the chunk free, and the next
  sweep listed it again under its owner. A table of fresh strings built
  and dropped sixty times came back with keys spelling other keys, in every
  `--release` build and at random; slot 0 is an arena's oldest chunk, so
  the other face of it was a constant built at startup losing its
  elements: a ported n-body's `BODIES` read a planet's `x` as
  `6.2e-310`, a free-list link, after a k-nucleotide run. That page now
  stays the list's and the cold run starts one page up.
  `bench/reuse_integrity.sh` checks both by content, default and
  optimised, on Linux, darwin and Windows, and on Linux and Windows fails
  on its first run with the release put back. darwin releases a page
  lazily (`MADV_FREE_REUSABLE`) and keeps its bytes until the kernel
  needs them, so there the same bug waits for memory pressure, and the
  put-back cannot be shown on demand.

- **`iyi check --affected` names a missing file the way it was typed.**
  It expanded the path, then chopped the working directory back off, so on
  Windows a caller who wrote `calc/add.iyi` read `calc\add.iyi is not
  there` — and so did `affected_not_found`, which a tool matches against
  what it sent. It keeps what was typed now, as `iyi test --affected`
  already did. `bench/agent_loop.py` step 39 failed on it on Windows.

- **An artifact did not name the `lib` its own object code calls.**
  `Libs` is how a consumer that links a module's units — and compiles
  none of them — learns which C libraries to pass the linker. It was
  recorded where a `lib` fun is *declared*, and a `lib`'s funs are
  declared in the main module and copied into the calling unit past that
  line, so the list was empty for every module whose `lib` is its own. On
  Windows every program built from `std/socket`'s artifact failed to link
  on sixteen Winsock symbols, where the same program from source linked
  `ws2_32.lib` — `bench/samples_roundtrip.sh` said so the first time it
  ran there; on Linux a `lib` whose library is linked anyway hid it. The
  call site records it now, in the unit that makes the call.
  `bench/mod_context.sh` asks a class-nested `lib`'s artifact for it, on
  Linux and Windows, and fails with the recording taken out.

- **`iyi doc Int32` on Windows had no `+`.** The prelude's number
  operators are written by a macro, so a def's file is the expansion's
  real one — spelled with `\` on Windows — and the test that keeps the
  compiler's own methods out asked for `/src/iyi/` in the string. There,
  `doc Int32` listed `%`, `**` and `-`, the three written by hand, and
  none of `+`, `<` or `to_i64`; and the size-rule sentence for a method a
  prelude type lacks asked the same question the same way. Both ask of
  the posix reading now; `bench/packages_resolve.sh` found it the first
  time it ran on Windows.

- **`iyi migrate --out` named a path nobody had typed.** Refusing an
  `--out` that is a file, or a directory it cannot write, it printed the
  path after `File.expand_path` — on Windows that also expands an 8.3
  short name and swaps every separator, so `--out C:/Users/RUNNER~1/x`
  was refused about `C:\Users\runneradmin\x`. It names `--out` as it
  was written now, the way `bind --lib` and `--mods` already did, and
  `bench/verbs_exercise.sh` — which pinned the expanded spelling — runs
  on Windows, where the difference shows.

- **A stack overflow on Windows sometimes said two things.** The fault
  handler wrote the stack-overflow sentence and called `ExitProcess`,
  which runs every loaded DLL's detach callback on the calling thread —
  the thread whose stack had just run out. A second overflow past a
  guard page already consumed is an access violation, and the same
  handler then wrote "the program died of a memory fault" under the
  sentence it had just written. Whether the 16 KB guarantee covered the
  detaches depended on where the first fault landed, so
  `bench/panics.sh` saw it once in three runs of the same binary. The
  handler ends the process with `TerminateProcess` now — nothing unwinds
  on that stack, the exit code is the same 1 — and the gate runs the
  overflow a dozen times from one binary, which makes a flake a failure.

  The gate repeats the overflow on the main, fiber and thread stacks. A
  thread's could, now and then on the runners, still say "a memory
  fault": `SetThreadStackGuarantee` is per thread and was made on the
  main thread alone, so a thread's handler came in with 6.7 to 9.5 KB
  committed under it rather than 14.9 to 17.8. Every `IyiThread` makes
  its own now. The exit crash that had it taken back out was not its
  doing (the fiber registry's, above). Because the shortfall shows only
  on some CPUs, `bench/panics.sh` also has a thread ask for its guarantee
  and wants 16384, and fails with the thread's call taken out.

- **The language server could not read a Windows file URI.** An editor
  sends `file:///c%3A/Users/x/a.iyi`, and the server chopped the scheme
  off and read `/c:/Users/x/a.iyi` — a path with a root it does not have
  — so every buffer opened on Windows was a file it could not find, and
  the URIs it built itself, `file://C:\Users\x\a.iyi`, were ones no
  editor would match. Nothing had asked: `bench/lsp_session.py` ran on
  Linux and darwin, and its own URIs were `"file://" + path`, the right
  spelling on POSIX by luck. The server drops the drive's slash and keeps
  the separators posix, the way the rest of it already spells a Windows
  path — the platform's own separators, because that path is the key an
  unsaved buffer's override is filed under and the compiler spells the
  joint of a resolved `import` with `\`: kept posix, the key matched
  nothing and the sibling the editor had just edited was read off the
  disk (step 9, the first time the session ran on Windows). And an open
  buffer is found by the path the compiler names rather than by a URI
  rebuilt from it: VS Code writes the drive's colon as `%3A` and a space
  as `%20`, so `@documents[uri_of(path)]` matched nothing an editor had
  opened, on any platform. The gate builds URIs the way an editor does,
  and the Windows job runs the whole session.

- **`iyi spec` and `iyi eval` sent the reader to a checkout.** Both are
  Crystal's and stay refused, and the refusal ended with "run it with the
  `crystal` binary in this checkout" — true of a developer's tree, false
  of the tarball and the zip. Each names what stands in for it now: a
  test is a `*_test.iyi` program and `iyi test` runs them; a line to
  evaluate goes in a file and `iyi run` runs it. `bench/verbs_exercise.sh`
  holds both sentences.

## 0.14.0 — 2026-09-22

**Windows is a platform the tree measures.** A panic names its callers
there — the stack from `RtlCaptureStackBackTrace`, the names from a PDB
reader written in iyi over kernel32 and nothing else, checked frame by
frame against `llvm-symbolizer` — and the dependency floor, the socket
that parks, `UdpSocket`, the console's code page, `Dir.tempdir`, a
`sleep` that was fifteen times what was asked and a fiber stack that
died of a bare access violation were each measured on the platform and
fixed where they lived. Every Windows job can now stop a release; the
one that builds the compiler there is on the list too.

**What travels, travels.** Sixty std module exercises round-trip through
`.iyimod`, and the family of "did not travel" defects that stood in the
way is closed: a class hierarchy, a generic's splat, an alias, an enum's
methods, a class variable, a `lib`, a constant in a type body, a
`@[Primitive]`, a method with no unit of its own. `iyi mod diff` reads
what a module was compiled against, `--affected` reaches every consumer
of a bumped requirement, and the build daemon serves a build with the
environment it was sent from — and not, since this release, with the
socket that would have sent the child back to it. The language server
is two processes, so the one that never frees can be replaced.

**And the answers were probed.** Ninety-four fixes, most of them in what
a verb, a tool or the language server *says*: `tool dependencies` saw no
`import`, `tool types` and the editor's completion list were mostly the
compiler's own probe variables, the caller's view of a module dropped
what an `impl` adds and what a facade hands on, `iyi doc` took no module
path, the formatter rewrote every line of a CRLF file, and `for`, `pub
fn`, `const`, `None`, `List`, `new`, `throw` and `length` each got the
sentence this language uses. Two seams are checked rather than
remembered: every gate under `bench/` is reached by something that runs
it, and every parse in the compiler names the language it reads. `std`
is 67 modules and 39,066 lines; `.iyimod` is v53.

### Added

- **A Windows panic names its callers.** `raise` captures the stack with
  `RtlCaptureStackBackTrace` — x86-64 Windows has no frame pointer to
  chase, a frame is described by the unwind data in `.pdata`, so the
  kernel's own unwinder is what walks it — and `std/debug` resolves each
  address by reading the program's own debug information. There is no
  DWARF in a Windows build to read: `dumpbin -headers` shows `.text
  .rdata .data .pdata .reloc` and a Debug Directory, and the line numbers
  are CodeView in the PDB the linker wrote beside the exe. So the reader
  is a PDB reader, in iyi, kernel32 and nothing else: the PE headers the
  loader mapped, the CodeView record's PDB path, the MSF container, the
  DBI stream's module infos and section contributions, the C13
  `DEBUG_S_LINES` and `DEBUG_S_FILECHKSMS` subsections, the `/names`
  string table, and `S_GPROC32`/`S_LPROC32` for the function name.

      iyi: panic: deliberate
        at ...\p_bt.iyi:6
      0   inner at C:\Users\dogru\playground\iyi\.winprobe\p_bt.iyi:7
      1   inner at C:\Users\dogru\playground\iyi\.winprobe\p_bt.iyi:7
      2   inner at C:\Users\dogru\playground\iyi\.winprobe\p_bt.iyi:7
      3   __iyi_main at C:\Users\dogru\playground\iyi\.winprobe\p_bt.iyi:10
      4   main at C:\Users\dogru\playground\iyi\src\iyi\prelude.iyi:8360
      5   __scrt_common_main_seh at ...\exe_common.inl:288
      6   [0x7ffc911ccd87]
      7   [0x7ffc9188caec]

  Every answer was checked against two oracles on the same addresses:
  `llvm-symbolizer --adjust-vma` and `llvm-pdbutil dump -l`'s raw
  `section:offset` blocks, four of four agreeing, plus the stream count,
  block size and owning module compared against `dump --summary`,
  `--streams` and `--section-contribs`. A panic inside a spawned fiber
  names every frame on the fiber stack down to `__iyi_fiber_main`, where
  the kernel unwinder stops because a fiber's bottom frame has no unwind
  data tying it to the stack that switched in. The last two frames of any
  trace are ntdll's and kernel32's, whose symbols are on Microsoft's
  symbol server and not in this program's PDB.

  It refuses rather than guesses: no PDB (a released zip ships none), the
  *wrong* PDB (rejected by the GUID in the image's CodeView record — the
  dangerous case, because a wrong PDB parses perfectly and answers
  confidently), a truncated one, and a block count claiming blocks the
  file does not have all print the panic and the addresses and exit 1.
  `bench/panics.sh` gates it now, on darwin and on Windows: a program that
  imports `std/debug` must name its own function and line, in at least
  two frames of a recursion.

- **`bench/lsp_positions.py`: every cursor question, everywhere in the
  library.** `lsp_session.py` asks the protocol's questions once each on a
  file written for them and `lsp_soak.py` abuses the transport; neither
  asked a question *from a position nobody chose*, which is where the
  answers were wrong. 23,553 questions over the 67 modules of `src/std` -
  hover, definition, completion, type definition, implementation,
  highlights, signature help, prepare rename, call hierarchy, selection
  ranges, the whole-file questions and a few `references` - at a strided
  sweep plus the two shapes the eighteen internal errors were found on: a
  macro directive line and a local assignment, where a variable an arm
  this target does not take never got a type. Six minutes on Linux, a
  coarser stride on darwin. Teeth, measured: against the commit before
  the fix it reports seventeen `-32603`s over `std/dir` and `std/path`
  alone.

  One server per module, and the memory is the server's own problem now:
  this sweep against one long-lived *single-process* server was killed by
  the kernel at 19 GB, which is what sent `iyi lsp` to the two-process
  shape under Changed below. The sweep no longer restarts anything on a
  counter it had to tune - it holds the whole session's resident
  megabytes under a bound instead, measured at 560 MB against 1,024.

- **Windows x86-64 is a platform the tree measures, not one it hopes
  about.** Of the 87 programs under `bench/`, 84 pass unattended on a
  Windows 11 machine, and the tree's own gates run there: every
  `bench/*.sh` honours the platform's path-list delimiter (`;`, because a
  drive letter already owns the colon), converts the shell's own path
  mapping before a native compiler reads it, honours `$IYI` and `$CRYSTAL`
  from the environment, and names what it could not measure instead of
  passing on an empty pipeline — a gate that counted symbols out of a
  missing `nm` used to report "every step held". What is new underneath
  them:
  - **Sockets.** `std/socket` and `std/udp` have Winsock arms, so TCP,
    UDP and HTTP work: `accept` posts `AcceptEx`, `connect` posts
    `ConnectEx`, a blocked `write` posts `WSASend` and a datagram
    receive posts `WSARecvFrom`, all on the completion port the poller
    already runs. The extension pointers come from `WSAIoctl`, so
    `mswsock` is not a second DLL; `ws2_32` is, and SPEC.md III.10 says
    why.
  - **A path is UTF-16 end to end.** The narrow entry points read a path
    in the process's code page, so a name iyi was handed as UTF-8 named
    a different file: `File.write("ünïcode-çğış-日本.txt")` created
    `Ã¼nÃ¯code-...` on disk and now creates the name it was given. The
    conversion is one prelude helper, which also puts on the `\\?\`
    prefix past 248 characters — a 364-character path writes, reads and
    deletes.
  - **The console writes what the program printed.** `WriteConsoleW`
    with UTF-16, VT asked for once per handle, and a UTF-8 tail carried
    across writes, so Turkish and Japanese render under code page 437
    and colour works; a redirected stream stays raw UTF-8, because
    `std/colorize` now asks whether the handle is a console before it
    writes an escape.
  - **A crash says what it was.** A vectored handler names a stack
    overflow and an access violation, `SetErrorMode` keeps the
    Windows-error dialog off a runner, and `bench/panics.sh` runs on
    Windows for the first time. The defect that hid this was a DWORD
    read as `UInt32` where the file's own rule says `Int32`: the
    comparison never matched, so the handler ran and printed nothing.
  - **A collection inside a fiber no longer walks off the stack.** The
    fiber switch rewrites the TEB's `StackBase`, and the collector
    memoized that word as "the main thread's stack base", so a
    collection that happened inside a spawned fiber scanned the parked
    main fiber from its real stack pointer to *that fiber's* top — two
    mappings, gigabytes apart — and died of a memory fault. Eleven lines
    with no IO in them reproduced it, and it predates this release.
  - **The 128-bit divide.** LLVM emits a call to `__divti3`,
    `__modti3`, `__udivti3` and `__umodti3`; every other platform has
    compiler-rt and Windows-MSVC has nothing, so any program dividing an
    `Int128` failed to *link*. The four are written in iyi now, in the
    win32 arm, on a shift-subtract kernel that uses 64-bit words only,
    and a divisor of zero faults exactly where a 64-bit one does.
  - **`File.readlink` and `File.real_path` answer.** They returned the
    empty string and the caller's own argument: a program that followed
    a link on Windows followed nothing and was told it had succeeded.
    The reparse point is read with `FSCTL_GET_REPARSE_POINT` and the
    resolved path with `GetFinalPathNameByHandleW`; `File::SEPARATOR` is
    the platform's, which is what `File.join` had been writing all
    along.
  - **A failure says why.** Every Windows call in `std/file` that fails
    now carries `FormatMessageW`'s own sentence with the code beside it,
    so a refused link reads `Windows error 183: Cannot create a file
    when that file already exists` instead of naming only what was
    attempted.
  - **The dependency floor is measured on Windows.**
    `bench/dependency_floor.sh` reads a PE import table with `dumpbin`,
    located through `vswhere` the way the linker is, and audits every
    program against an allowlist with a reason per DLL. Measured: 114
    binaries import `kernel32`, `vcruntime140` and five UCRT façades,
    four of them `ws2_32`, two `advapi32`, and nothing else. The same
    change guards, on every platform, a branch that used to invite
    deleting a floor it had not read.
  - **A release for Windows.** `make -f Makefile.win iyi-zip` writes the
    zip with its `SHA256SUMS`, `install.ps1` installs it the way
    `install.sh` installs the tarball (checksum refused before anything
    is unpacked, `IYI_PREFIX` and `IYI_VERSION` honoured, user `PATH`
    extended in place), `bin\iyi.ps1` and `bin\iyi.bat` are the
    checkout's launchers, and CI's `windows-native` job builds the zip,
    runs the package gate and installs it twice. The daemon is not in
    it: `iyi daemon`'s loop is `poll(2)` and its worker is `fork`.

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

- **`iyi lsp` is two processes, because a compiler that never frees must
  not be a server that never exits.** `iyi` carries no collector (III.9):
  a front end allocates for one program, answers, and hands the memory
  back by exiting. A server does not exit. Measured here: forty edits and
  hovers on a 327-line module took one server from 87 MB to **1,636 MB**,
  and a sweep of cursor questions over the library reached **19 GB**,
  where the kernel killed it mid-session. Neither a collector on the
  compiler's binary (the ancestor library III.9 spent a release shedding,
  and 29% more peak memory on every one-shot build) nor a second binary
  with one (an exception to the floor) was needed: the build daemon
  already had the shape - analyse, work, exit, let the next process do
  the forgetting.

  So `iyi lsp` is now a proxy that speaks the protocol and keeps the open
  buffers, and a worker (`iyi lsp --worker`, today's server unchanged)
  that compiles and is retired - at half a gigabyte, which it measures
  and reports itself (`getrusage`, one call per request), or after two
  seconds of quiet, so its replacement's first compile is paid out of the
  silence rather than out of the next keystroke. A worker with a request
  in flight is never retired, which is what keeps the code lens running
  the person's program from being killed to save memory; a fresh one is
  handed the buffers with `iyi/adopt` and warmed on the focused file.
  The same forty edits now peak at **518 MB** and rest at **95-112 MB**.

  Two properties came with it. A front-end crash is one bad answer
  instead of a dead session: whoever was waiting is told `-32603` naming
  how the compile died, and the next question is answered by a new
  worker. And a typing burst is still one compile - the coalescing moved
  to the proxy, which is where the client's stream arrives, and the
  worker keeps its own for whoever points an editor at `--worker`.
  The proxy parses four notifications and two requests and relays
  everything else as bytes, malformed frames included, so the protocol's
  refusals still come from the one place that implements them.

  `bench/lsp_memory.py` is the gate: the same client traffic, the whole
  process tree's resident megabytes read from the kernel, the hover
  compared either side of a retirement, and the worker killed outright
  mid-run. `--direct` drives the single process so the numbers the bounds
  rule out stay reproducible: 1,638 MB peak, 1,637 MB at rest, and a
  session that dies with its compile.

- **The ceiling stops counting every platform's floor, and it is a check
  now.** Windows' arrival put the library 508 lines over the 3,734 it is
  held to (SPEC.md I.4), and the section recorded the breach and handed
  the owner a choice: a rule or a rewrite. The rule, decided: the figure
  excludes the arms behind `flag?(:win32)`, `flag?(:linux)`,
  `flag?(:darwin)` and `flag?(:wasm32)` - symmetrically, every arm of such
  a conditional, `else` included - which is **1,489 lines**, and the
  library is **3,295** of 3,734 with 449 to spare. `4,784` is what opening
  `src/iyi/` still counts and is stated beside it everywhere.

  What makes it the honest reading rather than the convenient one is what
  3,734 is measured against: that core did not carry its own floor either
  - libgc, libc's `printf`, libevent, libc's platform calls, none of them
  in its 8,161 lines - and the three largest pieces of iyi's own floor
  (the collector, the scheduler, the float printer) were already excluded
  for exactly this reason. The platform arms are the fourth piece of the
  same kind. What the rule does not forgive: a `pub def` a program calls
  is API and counts wherever it is written.

  And the number has teeth it did not have. The ceiling was prose and a
  habit: 508 lines walked over it and nothing failed.
  `bench/doc_numbers.py` fails now when the library is over it, with what
  it is over by and what to do about it - proven by six hundred lines of
  ballast, which it reports as 33 over.

- **`UdpSocket` parks the way `IyiSocket` does.** Every receive is
  `MSG_DONTWAIT`, and when nothing is queued the task waits on the
  descriptor - the poller under the runtime, a `poll` without one - so
  `receive_from`, `receive` and `receive_datagram` answer `T | Cancelled`
  (SPEC.md III.4.2) and a sibling on the same thread keeps running; a
  `close` under a parked receive wakes it with `Cancelled`. Before, a
  receive was a blocking `recvfrom` that pinned the worker, and the
  module carried `non_blocking=`, `read_timeout=` and `write_timeout=`
  to work around it. Those are gone: the `?` variants answer nil when
  nothing is queued and never park, and `poll_read(ms)` bounds a wait.
  Four receive bodies are two. `bench/std_udp_exercise.sh` runs the two
  tasks on one thread and proves a blocking copy hangs.

- **One comparison trait, and it is `Comparable`.** `std/traits` had
  `Cmp` with `cmp(other) : Int32`, nine modules and `Enumerable`'s bounds
  leaned on it, and `std/comparable` carried a second, generic
  `Comparable(T)` with `<=>` that nothing implemented - so a type written
  against the Crystal-shaped one got `<`, `clamp` and `between?` and could
  not be sorted, `max`ed or put in a `Heap`. The trait is `Comparable`
  now, in `std/traits` beside `Num` and `Hashable`, its one requirement
  `<=>(other : self) : Int32`, and `<`, `<=`, `>`, `>=`, `==`, `clamp`
  and `between?` come with it; `lt`/`gt` are gone, `(a <=> b) < 0` is
  what they said. Every `impl` and every `where Elem : Comparable` in std,
  the samples and the gates follows. SPEC II.6 had written `Comparable`
  all along.

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

- **A release is gated on every job that runs something, and no job can
  hang for a working day.** `release.needs` named eleven jobs and left out
  four: the three that *execute* on Windows — the only jobs that run a
  Windows binary at all — and the one that runs the collector on
  wasm32-wasi, under a README that claims a program is run on those
  targets. A `v*` tag published regardless. It names all sixteen now,
  `cross-objects` included. And every one of the eighteen jobs carries a
  `timeout-minutes`: the default is six hours, these jobs start daemons,
  serve HTTP, soak an LSP and run aarch64 under qemu, and one that hangs
  held a runner for a working day and reported nothing.

- **The floor every program carries has one home.** `bench/floor_base.sh`
  names what a darwin program leaves undefined by being an iyi program at
  all — the prelude's, the poller's, the collector's, the thread layer's
  and the panic path's libSystem symbols — and what a Linux program
  carries from the C runtime, and the gates that audit a program's floor
  source it and add what their own program asks for on top:
  `bench/dependency_floor.sh`, whose list is this plus the platform
  modules' and which keeps the reason for every name, and the root, eiy,
  io and time exercises. It was copied into eleven gates before, and when
  panics learned to print a backtrace two of them were not told; a floor
  written in eleven places is eleven floors, and the one nobody updates is
  the one that fails. The lists whose point is being *exact* — the
  runtime's own twelve in the thread exercise, the thread floor's
  variants, the collector's — stay written out, because "nothing else" is
  what they assert. No list changed by a name: the five rebuilt from the
  base are set-identical to what they replaced.

- **The stack guard's Linux-only code says Linux.** Three guards in
  `concurrency.iyi` read `flag?(:x86_64)` inside `unless flag?(:win32)`
  and meant Linux: the constants under them are Linux syscall numbers, the
  `SA_RESTORER` flag and the `rt_sigreturn` trampoline are Linux's signal
  ABI, and an x86_64 darwin — excluded today only by the prelude's require
  line — would have been handed all three without a word. They read
  `flag?(:linux) && flag?(:x86_64)` now, and the darwin fault handler's
  offsets say which structs they are arm64's. No program is built
  differently: every target this file is required on takes the same
  branch it did.

- **The darwin job runs the standard library's gates.** The std job ran
  all seventy-odd on Linux and nothing ran them on the platform the darwin
  tarball is shipped for — the gap the collector's five gates had once,
  with the same cost: run on a darwin machine, six of them were red, one
  for the module's own defect (`File.touch`) and five for the gates', and
  every one had been green on Linux for a release. `bench/std_exercise.sh`
  runs in the darwin job now, and its timeout is sixty minutes for it.

### Removed

- **`std/fiber`.** It handed the runtime's `IyiFiber` out as `Fiber.new {
  }`, `resume`, `yield` and `suspend` - a second way to start concurrent
  work beside `group`, with no boundary: a panic in one climbed to
  nothing, a cancel reached it never, and `resume` was an enqueue rather
  than a switch. SPEC.md III.4 had already said `Fiber` does not carry
  over as a user-facing primitive, because a raw spawn puts III.4.1's
  leak straight back. Sixty-seven modules, 36,743 lines.

- **`std/iterable`, `std/nil`, `udp`'s own `IPv4Address`, and
  `Errno.value`.** Four more things with two names or none. `Iterable`
  was Crystal's mixin beside `Enumerable`, which nothing implemented and
  whose two methods `Enumerable` already has. `std/nil` reopened `Nil`
  with `not_nil`, `try` and `presence` - `not_nil` on `Nil` alone, so
  `x.not_nil` on an `Int32?` did not compile for the half that matters -
  and a `NilAssertionError` class that existed to carry one sentence;
  `!` and `or_panic` are how a nil is refused here. `std/udp` declared a
  second `IPv4Address`, a second address parser and a second
  `sockaddr_in` writer, all three drifted from `std/socket`'s (no port
  bound, no `inspect` in the sentence); it imports `std/socket` and uses
  its now. `Errno.value`/`value=` was a class variable no syscall ever
  set - the raw calls answer the negative number - and its exercise set
  it by hand and read it back. The enum stays.

- **`std/comparable` and `std/cmp`.** The second trait above, and a
  module of four free functions (`min`, `max`, `clamp`) over the first,
  which `Enumerable` and the trait itself already answer.

- **`std/kernel`'s `sleep`, which took seconds and busy-waited.** The
  prelude has a `sleep` and it takes **milliseconds** as an `Int32`, parking
  the fiber on the scheduler; this module declared a second one taking
  `Float64` seconds, so the unit was decided by whether the argument was
  written `2` or `2.0` — a thousandfold apart, one name meaning two things
  (III.1.7a). Measured: `sleep 2` returned in 0.36 s and `sleep 2.0` in
  2.36 s, of which 1.96 s was CPU, because the body spun on
  `__iyi_monotonic_ns` and starved every other fiber on the thread while it
  did (III.4). The prelude's is the `sleep` there is, and it says so itself:
  `sleep 2.0` is refused with "`sleep` takes milliseconds, an `Int32`".
  `bench/std_kernel_exercise.sh` holds all three — the module declares no
  `sleep`, `using std/kernel::{sleep}` is refused by name, and a `Float64`
  argument is refused with the unit in the sentence.

- **`std/weak_ref`.** Thirty-one lines that kept the target as a bare
  `UInt64` and validated it with `GC.is_heap_ptr`, which answers for any
  address inside the heap. Nothing registered the reference and no sweep
  nulled it, so `value` handed back a slot the collector had freed — and
  after the allocator gave that address to something else, handed it back
  as `T`, which is type confusion rather than a stale read. The doc had it
  right and the module contradicted it: GC_DESIGN.md says weak references
  are registration-based and that there is no table here to walk. There is
  not. What would bring it back is that table — a list the sweep nulls,
  which the `HAS_FINALIZER` bit in the object header already reserves room
  for — and not an address test.

- **`std/empty` and `std/docs_pseudo_methods`, two stubs.** The first was
  four lines of comment binding a vacant `Std::Empty`, named after
  Crystal's `empty.cr` - which is a *prelude*, selected with
  `--prelude=empty`, and still is; `"".empty?` is the prelude's and never
  came from here. The second was Crystal's documentation costume: seven
  private `__crystal_pseudo_*` defs no module could reach, six on `Object`
  whose empty bodies answered `Nil` for `as` and did not compile for the
  rest, and `CRYSTAL_PSEUDO__NoReturn`/`__Void` - two structs that were not
  `NoReturn` and `Void`, could be allocated where the real ones cannot,
  and were refused in a `lib`. `iyi doc` never loaded it, and nothing in
  the tree imported either. `import std/empty` is "can't find module"
  now, which is what it is. Seventy-two modules, 37,127 lines.

### Fixed

- **The context pack did not carry what a facade hands on.** `pub import`
  is a promise to the consumer: a file that imports a facade may `using`
  the module the facade re-exported, with no import of its own (R-2b).
  `iyi mod context` listed the file's own import lines and stopped, so a
  program that compiles — `import facade`, `using deep/core::{core_value}`
  — was grounded with a pack that never mentioned `deep/core`. A model
  reading it sees a name it cannot find declared anywhere and "fixes"
  working code.

  Every module the consumer may name is in the pack now, breadth-first
  through the `pub import` edges the artifacts already carried, each
  marked with the facade that hands it on:

      ── import facade → deep/core (re-exported) ──
      # A file that uses this writes, after its own `module` line:
      #   import facade
      #   using deep/core::{core_value}

  The import line is the facade's, because that is the edge the language
  needs — telling the reader to import the module directly would be
  telling them to add one it does not. `--json` carries `via`, the budget
  ladder cuts these blocks like any other, and `bench/mod_context.sh`
  fails when the re-exported surface or the line that reaches it is
  missing.

- **Importing iyi's std from a `--crystal` build died on an internal
  name.** `--crystal` gives a program Crystal's standard library (item
  12d) and `src/std` is written in iyi, against iyi's prelude — so `iyi
  check --crystal` on a file whose first line is `import std/json`
  answered `undefined constant IyiFloatText`, an internal name of a
  prelude that build does not have, pointed at a line in a file the
  author never opened. An *artifact* of the same module has been refused
  by name since IV.5 — "a program cannot hold one module of each" — and
  the source it is built from was not.

  The import says it now: `"std/json" is iyi's standard library, and this
  program is built against Crystal's`. Only for iyi's own std, found by
  where it resolved — a project with its own `std/` on `IYI_PATH` names
  its own modules and hears nothing about preludes — and
  `bench/verbs_exercise.sh` holds all three cases: the refusal, the same
  import without `--crystal`, and an author's own module with it.

- **`iyi doc app/greeter` was a usage error.** A module's path *is* its
  file's path (R-1, IV.6) — it is what `import` takes, what `mod context`
  prints as a header, and what every error about a module names — and the
  doc verb took a file path or a prelude type and nothing else. So `iyi
  doc std/set`, a module this same binary will ground an edit against,
  answered "expected a .iyi module, a .iyimod artifact, or a type of the
  prelude", where the thing it was handed *was* a module.

  A module path resolves now the way `import` resolves it: the project
  root, then every `IYI_PATH` entry, `.iyi` before `.cr`. The refusal for
  a path that is not there names the form, and `doc --help` says MODULE |
  FILE | TYPE. `bench/packages_resolve.sh` asks for the same module both
  ways and fails unless the two answers are byte-identical.

- **The formatter rewrote every line of a CRLF file.** `iyi tool format`
  emits `\n`, and it wrote that back over whatever it read: a file with
  CRLF endings came back with all of its lines changed, from a command
  asked to fix an indent — on the platform this fork builds, ships and
  tests a binary for. `--check` said the same thing in the least useful
  way available: ``formatting './x.iyi' produced changes`` about a file
  whose code was already formatted, naming neither the line endings nor
  the reason, so a Windows developer's branch failed on a difference the
  message never mentioned.

  `iyi fix` has always kept them — it splices an edit into the bytes it
  read — so two verbs over the same file disagreed about what a line ends
  with, and the one that disagreed was the one rewriting the whole file.
  The formatter writes back the endings the file had, decided by the
  first one in it, which is `rustfmt`'s `newline_style = Auto`. Specced in
  `spec/compiler/iyi/tools/format_spec.cr`: a CRLF file is formatted and
  stays CRLF, and a formatted CRLF file passes `--check` in silence.

- **`iyi mod context --help` answered "unknown flag --help".** Every verb
  in this binary prints its own usage for `--help` — `check`, `fix`,
  `test`, `run`, `build`, `doc`, `bind`, and `mod` itself — and the three
  subcommands under `mod` did not. The answer they gave is the one that
  is certainly wrong: it says the flag does not exist, where what does
  not exist is the help, and a `--help` is how a harness finds a verb's
  switches. AI_FIRST.md §2b hands `iyi mod context --budget N` to agents
  as one of the loop's seven verbs, and nothing on the command line said
  `--budget` was there.

  `mod context`, `mod diff` and `mod dump` each print their own usage
  now, naming the switches they read — including what a budget is counted
  in (a token is four bytes) and that every import is named at every
  budget. `bench/verbs_exercise.sh` checks all three, and that each usage
  names its own switches.

- **The words people arrive with.** This fork answers a spelling from
  another language with the spelling it uses — `elif`, `let`, `println`,
  `null` and a dozen more have been met that way — and the list had holes
  where the most common arrivals are. Each of these was `undefined
  constant X`, `undefined method X`, or worse:

  * `for i in 0..3` answered **"unexpected 'in': no `case` is open for
    it"**, naming a construct the file does not contain, because `in` is
    a keyword `case` owns. It names the loop now: `(0..3).each do |i| ...
    end`, and `xs.each` for a collection.
  * `pub fn greet() -> String` answered ``can't apply `pub` to fn``. A
    bare `fn` has been met since the verbs gate was written; the `pub`
    form is the one Rust actually writes.
  * `None`, `True`, `False`, `List`, `Vec`, `Dict`, `Map` and `Set` — the
    values and containers Python, Rust, Java and JavaScript name — each
    answer with this language's: `nil`, `true`, `Array(T)`, `Hash(K, V)`,
    and `Set(T)` with the import that brings it.
  * `new Array(Int32)`, `throw`, `catch`, `range` and `echo` answer with
    `Array(Int32).new`, `raise "why"`, III.1's "an error is a value",
    `(0...3)` and `puts`.
  * `length`, `filter`, `append`, `push`, `toString` and `parseInt` on a
    receiver answered with the prelude's size rule — true, and silent
    about the name three characters away. They answer `size`, `select`,
    `<<`, `to_s` and `to_i`.

  Specced beside the arrivals that were already there, in
  `spec/compiler/parser/parser_spec.cr` and
  `spec/compiler/semantic/iyi_spec.cr`.

- **A `using` for a name a module declares at the root was refused as a
  typo.** `src/std/set.iyi` is `module std/set` with `class ::Set(T)`
  inside it: the `::` puts the class beside `Array` and `String`, so
  `import std/set` alone is what brings it. Written the way every other
  module in the language is reached — `using std/set::{Set}` — the answer
  was ``Std::Set has no `Set`: nothing by that name is declared in
  `std/set`, `pub` or not``, which is true of the module and wrong about
  the program, where `Set` is right there. Twenty-five modules under
  `src/std` declare a root type this way, and `iyi mod context` prints
  them as `class ::Set(T)` with no `using` line — the grounding answer was
  right and the refusal was not.

  It names the root declaration now and the spelling that works: ``\`Set\`
  is declared at the root by `std/set`, not as a name of it: `import
  std/set` is enough to write `Set```. A name the module really lacks
  still gets the old sentence and its nearest match. Specced in
  `spec/compiler/semantic/iyi_spec.cr` beside the other two mistakes
  behind "does not export".

- **A module that does not compile was answered with the wrapper around
  the reason.** `iyi mod context` prints one line in place of a module's
  surface when the module cannot be compiled alone, so that line is the
  whole diagnosis — and it was `while importing "kit/all"`, the wrapper
  `SemanticVisitor#import_file` puts around an error, which names the file
  the reader had just typed. `iyi check` on the same file said ``can't
  apply `pub` to const`` with the line and the column. `iyi doc` had
  unwrapped this since the verbs gate was written; `mod context` carried
  its own copy of that rescue without the unwrapping, so the one answer
  written for grounding was the one without the diagnosis in it. Both go
  through `Iyi.deepest_error` now, and `bench/mod_context.sh` fails when
  the answer is a wrapper rather than a reason.

- **`const LIMIT = 10` was answered with a sentence about dynamism.** The
  word introduces a constant in Rust, Go, JavaScript, Swift and C++, and
  here it parsed as a call whose argument is an assignment to a constant
  — so the answer came from the shape, `can't declare constant
  dynamically`, about a line at the top level of a file. `pub const LIMIT
  = 10` answered ``can't apply `pub` to const``, which reads as though
  `const` were a construct this language has and `pub` happened not to
  take. The parser meets the word now, in both places, with what to write
  instead: a constant is `LIMIT = ...`, uppercase is what makes it one,
  and `pub LIMIT = ...` is how a module exports it (R-2). `val`, `final`,
  `let` and `var` are met the same way when what follows them is a
  constant. A call to something actually named `const` is still a call —
  the shape is checked, not just the word. Specced beside `fn`, `func`,
  `and` and `or` in `spec/compiler/parser/parser_spec.cr`.

- **The caller's view of a module dropped the methods an `impl` adds.**
  `IyiMod.surface` is AI_FIRST.md §2's text form — what `iyi mod context`
  and `iyi doc` print, and what a model is grounded on — and it rendered
  an impl as one bare line. So for a module whose `Box` implements
  `Shape`, the type's block carried `initialize` and `side`, the trait's
  block carried `abstract def area`, and `box.area`, the call a consumer
  actually writes, was named in neither. The artifact carried those
  methods the whole time: `mod dump` prints them, and this view had its
  own poorer line for the same record.

  It renders like the types above it now — header, the impl's own
  methods, their docs, `end` — through `render_impl_header`, so trait
  arguments and `forall` are part of the line rather than dropped. And in
  this module's own names: the line read `impl Geo::Shape::Shape for
  Geo::Shape::Box`, the other language's spelling, in an answer whose
  first line is `module geo/shape` and which tells the reader to write
  `using geo/shape::{Box}`. Only this module's prefix is stripped, because
  that is the mapping that is certain — a camelcased path segment does not
  invert.

  `bench/mod_context.sh` asks a consumer's view for the impl and fails
  unless the line is `impl Shape for Box` with `def area : Int32` under
  it; it falls back to the old sentence when the methods are dropped.

- **The compiler's own variables were offered to an editor.** Definition
  typing checks a def against its declaration by writing a probe — an
  `uninitialized` receiver, one per argument and one for the return value,
  inside an `if false` — and those probes live in the scope a file's top
  level lives in. Every surface that answers "what is in scope here" read
  them out as the author's. `iyi tool types` on `samples/iyi/calc.iyi`
  answered with twenty-three `__iyi_dt_*` names and one variable somebody
  had written; on `samples/iyi/modules.iyi` it was nine out of nine, an
  answer with nothing real in it. `tool context` printed them in its
  table. The language server returned `__iyi_dt_1_r` and `__iyi_dt_1_v` as
  the *first two* items of a completion with nothing typed yet — kind 6,
  "Variable", ahead of the author's own name.

  Two filters were already there and neither knew this fork's names: the
  types visitor dropped Crystal's `#`-prefixed internals, the context
  visitor dropped `__temp_`. They are one predicate now,
  `Iyi.compiler_variable?`, and both surfaces ask it — which is also why
  the language server is fixed by fixing `tool context`: its completion
  scope is that visitor's.

  Gated on both paths, because they are two. Step 12b of
  `bench/lsp_session.py` asks for completion with an empty prefix and
  fails by naming what was invented; `bench/mod_context.sh` asserts `tool
  types` names the variable the file writes and none of the compiler's.
  Both fall when the predicate is taken back out.

- **`iyi tool dependencies` answered nothing for a file with imports.** The
  tool draws the tree of files a program depends on, and it is fed from
  `require`'s path, `Program#run_requires`. iyi's dependency edge is
  `import`, which resolves in the semantic visitor and never goes through
  there — so the command exited 0 and printed an empty tree. Not a wrong
  answer: an answer that reads as "this file depends on nothing", for
  every `.iyi` file in this repository, in a fork whose module system is
  the `import`.

  The walk records the edge now, wrapped around the recursion rather than
  around the resolution, so the tree nests the way the other language's
  does, a module reached twice is entered twice and printed once, and a
  module that arrived as an artifact is named as that artifact —
  `mods/app/base.iyimod` — because that is the file the build read. What
  the search path finds is still filtered as library code, which is
  Crystal's rule for `CRYSTAL_PATH`, and `-i` opts a directory back in.

  `bench/mod_context.sh` is the gate for the commands that read an import
  without building, and it now compares each sample's own `import` lines
  against the tree the tool draws: nine local edges across `samples/iyi`.
  Taking the recording back out fails it by naming every one of them.

- **`mod diff` never read what a module was compiled against.** Its three
  lines are the module's own — interface, implementation, source — and an
  artifact records a fourth thing: the hashes of every module it imported
  (IV.3, which is how a build asks whether the far end still hashes the
  same). So a module whose file did not change, whose surface did not
  change and whose travelling bodies did not change read

      interface       unchanged
      implementation  unchanged
      source          unchanged
      Consumers do not have to be rebuilt: what they compile against is the same.

  after its dependency moved under it — a bumped requirement, or a
  sibling module whose block-taking body travels. The compiler itself
  refuses that pair (an artifact is read only while it still describes
  its module), so the verdict was advice its own compiler will not take.

  There is a `dependencies` line now, naming each edge that moved and in
  which half, and a verdict of its own: this module has to be rebuilt,
  its own surface is the same, and what it was compiled against moved.
  `bench/mod_diff.sh` has a fifth kind of edit — a module underneath —
  and asserts the refusal that makes the verdict true; it fails when the
  new branch is taken out.


- **Bumping a dependency selected no tests.** `--affected` narrows by
  import closure, and a manifest is not a module: no closure holds
  `iyi.mod`, so the largest change a workspace can make — every `import
  example.test/user/liba` resolves through the requirement it names —
  came back

      0 to run, 1 skipped: no test's imports reach the change

  and `check --affected iyi.mod` answered "0 consumer(s) checked, all
  compile", which is a clean verdict about nothing. An agent that bumps a
  version and asks what to re-run was told: nothing.

  A change to `iyi.mod` or `iyi.sum` turns the discount off now — every
  test runs, every module is a consumer — and both verbs say why, in
  prose and as `affected_manifest` in their JSON, because the caller that
  passes `--affected` is usually a program. An ordinary changed file
  still narrows to what imports it. `bench/packages_resolve.sh` holds
  both halves and fails when the rule is taken back out.


- **A daemon built with its own environment, not the one the build was
  sent from.** The request carried `cwd`, `args` and a version; the child
  it forks inherited the *daemon's* variables. So a build sent from a
  terminal with `IYI_CACHE_DIR` or `IYI_MOD_MIRROR` set was resolved
  without them — a package went to the network instead of to the mirror
  beside it, and the object cache filled somewhere nobody chose. It is
  louder than it sounds only because packages fail loudly; `PATH` decides
  which linker a build finds, and that one is silent.

  The environment travels with the request now, whole, and the child runs
  with it — a variable the daemon carries that the client does not is not
  this build's either. `IYI_PATH` is the one exception: the prelude a
  daemon holds came from its own, so a request asking for another library
  is refused with both resolutions printed rather than served from the
  wrong one. The comparison is by the prelude files a path finds, not by
  the spelling, because an unset `IYI_PATH` and one naming the directory
  it resolves to are the same library.

  A daemon that cannot serve *this* build is the same as no daemon, for a
  build that never asked for one: a refusal is its own frame now, and
  `IYI_DAEMON_SOCKET` — an optimisation somebody set once, in a shell —
  falls back to an ordinary build with the reason printed. `iyi daemon
  build` asked for that daemon and still fails.

  One variable does not travel: the one that names a daemon. A client that
  got here by `IYI_DAEMON_SOCKET` sent it along with the rest, so the
  forked child found a daemon too — this same server — and was served by a
  fork that found it again. No build in that recursion ever finishes:
  `cli_spec`'s implicit-socket example aborted after forty seconds with the
  machine out of memory, and CI's job spent its whole thirty-minute budget
  inside that one example, twice, reported as a cancellation rather than a
  failure. A served build is the daemon's build and does not go looking for
  a daemon.

  `bench/daemon_agrees.py` grew the shape that found it — a dependency
  that is a package rather than a file beside the entry — and the refusal,
  the fallback, and the re-entry; all four are proven to fail — by taking
  the environment back out of the request, by dropping the comparison, by
  making the refusal exit instead of building, and by putting the socket
  variable back into the child. The re-entry check names a socket that is
  not there, so it observes the child's environment for the price of one
  small build instead of the recursion it is about; the second library the
  refusal needs is two files rather than a copy of `src`, because a
  refusal is decided before anything is compiled and the copy was buying
  two cold prelude builds in a job that has thirty minutes.


- **The seam that produced four of this release's defects is checked
  rather than remembered.** Which language a source is written in is the
  one thing the lexer cannot read out of its text, so it comes off the
  file's name — and a `Parser` or `Lexer` built without one reads by the
  other language's rules. That was stdin, the LSP's semantic-token
  scanner, every macro expansion, and a macro body's formatter, each
  found separately. `bench/language_is_named.py` walks the compiler's
  parses: thirteen name their file, four are exempt with what they read
  instead — the regex engine's parser, the factory every caller names,
  the formatter's own lexer, and a keyword scan both languages spell the
  same — and a fifth nameless one fails the check by name. Its list of
  reasons is keyed on the line as written, so changing the code
  re-asks the question.


- **`mod context` and `mod diff` run on Windows.** Both are path-shaped
  work — imports resolved through `IYI_PATH`, a workspace's `mods`, and a
  hash of what a consumer compiles — and both carry the code that platform
  needs: `cygpath` for the checkout and `;` for the search path. Neither
  had ever run there, so that code was a claim rather than a measurement.


- **The dependency floor read one machine's libc as a floor that moved.**
  glibc exports `environ` as a weak alias of `__environ`, and which of the
  two a binary names is the libc's choice: a newer one links the alias, so
  the gate — whose `^_` strip is darwin's — read `_environ` here and
  `environ` on the machine its allowlist was written on. Both complaints
  fired at once, "gained `_environ`" and "`environ` no longer needed",
  about a program whose dependencies had not changed. One datum, one name
  now, and the floor holds on both.

- **The dependency floor runs on Windows, and the first run found a claim
  it cannot make there.** The libgc opt-in is read off the library list —
  `-Dgc_boehm` must link a collector — and a PE's list is its import
  table, which a collector linked from a static `gc.lib` leaves no entry
  in. So the opt-in is read there off something an import table cannot
  hide: two different allocators cannot compile to the same binary, so
  `-Dgc_boehm` and `-Dgc_none` producing the same bytes is the flag doing
  nothing. Getting there took two wrong readings, both kept in the
  script's comment: a plain build is not the thing to compare against —
  it carries the owned collector, which `-Dgc_boehm` drops, which read as
  46 KB against 124 KB — and neither is a size *ordering* against
  `-Dgc_none`, because on Linux, where libgc is a shared object, the
  boehm binary is the smaller of the two. The three sizes are printed
  either way, because the next question about that platform will start
  from them. What the
  import table measures on Windows is the DLL floor itself, which is the
  claim SPEC.md III.10 makes about a Windows program.

- **The dependency floor runs on Windows.** The script has read a PE's
  import table since Windows became a target — `dumpbin -imports`, located
  through the installer the linker is found with — and the two jobs that
  ran it were Linux and darwin, so what a Windows program asks of the
  machine was a claim nothing measured. It is a step in the Windows job
  now. Two ways it could have passed without measuring anything are
  closed: a missing `dumpbin` is a failure rather than a sentence and exit
  0, the way `readelf` already is on Linux, and a run where no binary
  reported a single imported DLL says so — no PE imports nothing, so an
  empty read is a reader that did not read.


- **`iyi bind` now says which of a shard's methods iyi cannot name.** A
  Crystal library's `sort!` crosses the boundary — the declaration has to,
  because a travelling body that calls it must typecheck — and no call
  written in a `.iyi` file can spell it (III.1.7). That crossed in
  silence, so the first anyone heard of it was "undefined method 'sort'"
  at a call site. The bind's report carries the count and the log names
  each one, with the sentence a reader needs: reach it through a
  Crystal-side method with a name this language can write.
  `bench/bind_roundtrip.sh` binds a shard with one and fails when the
  section is taken back out.


- **The compiler offered an edit that makes a file stop parsing.** `!` is
  not part of a name in iyi (III.1.7), and the nearest name to `not_nil`
  in Crystal's library is `not_nil!` — so "Did you mean 'not_nil!'?" was
  the answer, and it did not stop at prose: the edit travels in
  `check -f json` as `suggested_edit`, which is what `iyi fix` applies and
  what an editor or an agent applies. Two lines reproduce it in the mode
  the README recommends for Crystal's ecosystem:

      x = [3, 1, 2]
      puts x.not_nil.to_s

  A bound shard is the same story with its own names — `Box#sort!` is
  carried by the boundary and spellable by nobody. The message now says
  what the library calls it and why no call written here can reach it, and
  carries no edit; `bench/agent_loop.py` gates that an unspellable name is
  explained rather than suggested, and fails with the branch removed.


- **The check that `std/debug` does not bind libc's `write` could not see
  a versioned symbol.** `nm -u` prints `write@GLIBC_2.2.5` for a binary
  linked against a glibc that versions it, and the pattern was anchored on
  the bare name — so on such a machine the check matched nothing at all and
  passed by seeing nothing. The gate's own proof is what said so out loud:
  the step that binds `LibC.write` on purpose failed there, reporting that
  a module which *does* bind it passed the check. Both patterns take an
  optional `@…` now, which is what every other symbol gate here already
  did with `sed 's/@.*$//'`; that sweep found no second instance.


- **A macro whose body used `!` was the one macro the formatter left
  alone.** A macro body is formatted by a second formatter over its text,
  and the text was handed over with no name — so it was read by the other
  language's rules, where `v = read()!` does not parse, and
  `format_macro_literal_only`'s rescue put the body back exactly as it was
  typed. The same body without the operator was reindented, which is what
  made it look like a rule rather than an accident.

  The subformat is in the file's language now, both in the parse that
  decides whether the body is code and in the formatter that writes it.
  `spec/compiler/formatter/iyi_formatter_spec.cr` holds the pair — a body
  with `!` and one without, each ruined on the way in and canonical on the
  way out — and the first fails with the name taken back out.

  This is the fourth surface of one question: the language a buffer is in
  is the only thing the lexer cannot read out of its text. Stdin, the
  semantic-token scanner and macro expansions were the others.


- **An editor's link on an import of a package went nowhere.** The server
  resolved a document link by guessing a filename — `<root>/<path>.iyi`,
  with the path taken as the run of `[A-Za-z0-9_/]` after the keyword — and
  a package's path is dotted, so the run stopped at the first `.` and
  looked for `example.iyi`. The file it names is not under the workspace in
  any case: it is a checkout in the cache, which `iyi.mod`, `iyi.sum` and
  the fetcher decide between them (III.7). So ctrl-clicking a dependency's
  import did nothing, in an editor where the same click on a sibling module
  opens the file.

  The compile already answered the question, so the server reverses its own
  `iyi_module_paths` — filename to module path for everything the build
  read — rather than guessing again, and the path is taken the way the
  parser takes it, with `.` and `-` attached on both sides. A package's
  import now opens its checkout, a sibling's opens the file beside it, and
  `pub import` is a link too. `bench/lsp_session.py` gates all four,
  proven to fail with the resolution removed: two links where there should
  be four, both of them the local module.


- **`--emit-iyimod`'s one line promised an artifact per imported module,
  and a package's is not one of them.** It never was: an artifact carries
  what the consuming build reached, and the one this loop would write for
  a package is hollow — the exports collector keys on the in-package type
  name, which a canonical dotted path does not reach — so the writer skips
  a dotted module on purpose and leaves packages to `iyi.sum` and the
  cache. The sentence now says that, and `bench/packages_resolve.sh` holds
  the contract rather than the prose: the workspace's own module is
  written, no dotted artifact appears beside it, and a build against those
  artifacts still answers, with the package coming from the cache the sum
  pins. Proven to fail by removing the skip, which writes
  `example.test/user/liba.iyimod` for a build that cannot fill it.


- **A macro could not generate `!`, and the rule that `!` is not a name did
  not hold in what a macro wrote.** Which language a file is written in is
  the one thing the lexer cannot read out of the source, so it comes off the
  name — and a macro expansion's name is a `VirtualFile`, which ends in no
  extension at all. Every expansion was therefore reparsed by the other
  language's rules, where `foo!` is a single identifier. Two consequences,
  both measured:

      # v = risky!    from a macro
      Error: undefined local variable or method 'risky!' for top-level
      Did you mean 'risky'?

      # v = risky(1)! from a macro
      Error: unexpected token: "!"

  So the language's central operator (SPEC.md III.1) was unavailable to
  every macro — a macro could generate a call, but not the propagation the
  caller's signature is written for. And in the other direction the rule
  that `!` is not part of a name (III.1.7) went unenforced, which is how
  iyi's own prelude came to declare `to_i!`, `to_f!`, `to_i32!`, `to_i64!`,
  `to_u8!`, `to_u64!` and `to_f64!` on five structs, and `IyiMark.gray!`:
  thirty-six names the language refuses in source, accepted because they
  were written by a macro.

  An expansion is in the language of the file it expands in, which is where
  its chain of locations ends, and `Lexer.iyi_source?` follows a
  `VirtualFile` there. What that exposed is the second half of this entry.

- **The prelude's unchecked conversions had no name any iyi source could
  call.** `to_u8!` was reachable only from macro-expanded code — which is
  where the prelude's own callers sat, and is why they worked: `memset`'s
  `value.to_u8!` is C's "converted to `unsigned char`", `IyiHeap.write8`
  takes a word's low byte, and Winsock's `__sys_handle` needs `-1` to
  become `INVALID_SOCKET` rather than an overflow panic. Written in plain
  iyi source, all of those read as `value.to_u8` with its error propagated,
  which the compiler refuses: "`!` has no error to propagate: no member of
  `UInt8` implements `Error`".

  The unchecked form is spelled `unsafe_to_u8` now, with the prefix
  `unsafe_chr` beside it already used, and the fifteen callers in the
  prelude, `std/socket` and `std/udp` say which conversion they mean.
  `std/int` skips the five the prelude declares, as it already did for the
  checked forms, so R-3 sees no duplicate. Measured: `300.unsafe_to_u8` is
  44 where `300.to_u8` panics, `memset(p, 0x1ff, 4)` writes `0xff` as C
  says it must — it did before too, by the accident above — and a macro
  that writes `to_number(text)!` now propagates through its caller's
  union.


- **Every file that imports a package was unformattable, and the answer was
  a request to report a bug.** A package path's host segment —
  `example.test/user/lib` — is one segment to the parser, which reads its
  dots off the characters, and three tokens to the lexer: `example`, `.`,
  `test`. The formatter consumed one token per segment, so it fell a token
  behind the source it was writing, the next `write_token` found `.` where
  it wanted `/`, and it raised. `iyi tool format` turned that into

      there's a bug formatting 'app.iyi', to show more information, please run:
        $ iyi tool format --show-backtrace 'app.iyi'

  about valid iyi source, and the LSP's `textDocument/formatting` — which
  rescues `CodeError` and not a plain exception — answered an editor with
  `expecting /, not '.', at app.iyi:1:15`. So formatting was unavailable
  for the ordinary shape of III.7. The tree-wide `--check` never saw it
  because this repository's own `.iyi` files import local modules.

  The formatter consumes the run the parser consumed. `iyi tool format` on
  a file that imports packages tidies the spacing and leaves the path
  alone, twice over; `bench/verbs_exercise.sh` gates that and
  `bench/lsp_session.py` gates the editor's request, both proven to fail
  with the consumption reverted.

- **`iyi tool format -` read iyi source as Crystal.** Which language a
  file is written in comes off its extension everywhere in the compiler —
  `!` is one token in a `.iyi` file and another in a `.cr` one — and the
  name stdin was given was `"STDIN"`, which ends in neither. So the pipe
  the command's own banner documents was read by the rules of the one
  language this binary is not for: `sleep(1)!` came back a syntax error,
  `pub trait` came back "expecting identifier 'end'", and an `import` line
  came back as the bug report above, because Crystal's rules made the
  imported path a division.

  Stdin is iyi now, and `--stdin-filename PATH` says where the bytes came
  from — what an editor formatting a buffer knows, and what prettier, ruff
  and rustfmt call the same flag. Its extension picks the language and its
  name appears in the errors. Passing it without `-` is refused rather
  than ignored, because an editor that passed it would otherwise go on
  believing the language was settled. `bench/verbs_exercise.sh` gates the
  pipe against the same bytes in a `.iyi` file, and the flag by the
  refusal it earns on `!` when it names a `.cr` path.


- **A gate nothing runs passes on the machine that wrote it, and that has
  happened four times.** Three existed, held and were named in the
  workflow by nothing — `format_exercise`, `io_exercise` and
  `socket_exercise`, nine seconds between them — and `bench/panics.sh`
  was a fourth in a narrower form: it ran on Linux and darwin, and the
  sentence it asserts is Windows' own, so the one platform it is about
  was the one platform nothing checked it on.

  `bench/gates_reachable.py` is that lesson as a check. A script under
  `bench/` counts as reached when a workflow step names it, when another
  bench script runs or sources it — including `std_exercise.sh`'s
  discovery glob, which is how the sixty `std_*_exercise.sh` siblings
  run — or when a `Makefile`, a `scripts/` file or a spec names it. What
  is left is either a gate nobody runs or a *tool*, and a tool is a file
  that takes an argument and prints a measurement rather than passing or
  failing: there is one, `migrate_count.py`, whose numbers SPEC.md III.6
  reads, and it is on a list that says so.

  Measured on this tree: 143 scripts, 142 reached, one tool. Two failure
  modes, both proven: an unwired gate is named (exit 1), and so is an
  allowlist entry that something *does* run — because an entry that is
  run would hide the next unrun gate behind it. It caught its own first
  draft, which counted this script's prose as a run and therefore
  reported the tool as reached.


- **A package whose tree contains a symbolic link ended the build with
  the walker's accident.** `iyi.sum` hashes a checkout's files, and the
  walk asked `File.directory?` — which follows a link, so a directory
  link was walked *through*: into the package's own parent, or around a
  cycle. A package carrying `inner/loop -> ..` answered

      Error: …/linked@v1.0.0/inner/loop/inner/loop/inner/loop/… : Too many
      levels of symbolic links

  forty levels deep, which is the kernel stopping a walk that would not
  have stopped — and it is not a sentence about a dependency.

  A link is hashed as the link now, which is git's own model: what a
  repository stores for one is the target *text*, so that is the content.
  Two things follow. The cycle is an entry rather than a descent, so the
  package builds. And retargeting a link inside a checkout is a change
  the sum notices, which following it could never have said: reading
  through a link hashes something the package does not contain.

  `bench/packages_resolve.sh` gates both, each proven to fail on its own:
  without the fix the first step dies on the ELOOP path above, and with
  the link's target left out of the digest the second reports that a
  retargeted link went unnoticed.


- **"Dependencies are hashed" was gated in the direction that is a typo,
  not in the direction that is the threat.** `iyi.sum` is fact written by
  the tool, and its whole job is to notice that what arrived is not what
  arrived last time (III.7). `bench/packages_resolve.sh` proved the
  comparison happens — it edits a hash *in the sum file* and the build
  refuses — which says nothing about what the comparison is *against*.
  The case that matters is the other one: the sum file honest and the
  **checkout** mutated, which is what a compromised module cache, a moved
  tag or a backup restored from the wrong day looks like.

  Measured: it is refused, naming both hashes, so nothing needed fixing —
  and the assertion was still missing. It is there now, and it has teeth.
  With `Sum.tree_hash` no longer reading file contents, the tampered-sum
  step still passes and the new one fails with the evidence printed: the
  program runs and answers `hello from somebody else`, which is a
  dependency that changed under a program that was told nothing.

  The step's own first draft assumed a directory order. The fixture's
  cache holds two versions of the same package, `find | head -1` returned
  v1.1.0 on Linux and v1.0.0 on darwin, and mutating a checkout no entry
  pins is a build that succeeds — so darwin failed with the program
  printing its ordinary answer. The checkout is read out of `iyi.sum` now:
  the tree the step mutates is the tree the entry it expects the refusal
  about pins, whatever MVS chose.


- **The stack-overflow sentence was gated everywhere except on the
  platform it is about.** POSIX prints it from `IyiStackGuard` on an
  alternate signal stack; that arm is compiled out on Windows, where the
  line comes from the vectored handler in `src/iyi/prelude.iyi` and from
  the room it prints in — `SetThreadStackGuarantee` on a thread's own
  stack, and the 16,384 committed bytes of `GUARD_SLACK` under the armed
  PAGE_GUARD page of a fiber's. `bench/panics.sh` asserts all of it and
  ran in the Linux and darwin jobs only.

  Measured on Windows 11 x86-64 before the step was added, and nothing
  needed fixing. Each of the three stacks:

      iyi: panic: stack overflow: the stack ran out, which is infinite or very deep recursion
      exit 1

  and a wild `Pointer(Int32).new(16_u64)` is called what it is instead —
  "the program died of a memory fault", exit 1. The whole script:
  eleven steps, `panics gate: every step held`.

  The falsification, because a gate nobody can fail is not a gate: with
  `GUARD_SLACK = 0_u64` and the compiler rebuilt, the fiber stack prints
  the sentence and then dies on the way out —

      iyi: panic: stack overflow: the stack ran out, which is infinite or very deep recursion
      iyi: the program died of a memory fault. Outside `Pointer`, ...

  which is the handler walking off the bottom of the guard page into the
  page nobody committed, and `bench/panics.sh` reports
  `panics FAIL: stack overflow on the fiber stack said:`. Restored to
  16,384 the same program prints the one line and exits 1.

  The `windows-native` job runs `bench/panics.sh` now, after the
  exercises.

- **A read-only file, directory or destination could not be removed or
  replaced on Windows.** POSIX asks the *directory* for permission to
  unlink a name, rename onto one or remove one; Windows asks the thing
  itself, and anything carrying FILE_ATTRIBUTE_READONLY refuses with
  ERROR_ACCESS_DENIED. That attribute is what `File.chmod(path, 0o444)`
  sets here, so the ordinary shapes died on one platform only, measured:

      File.chmod(f, 0o444); File.delete(f)   iyi: panic: cannot delete ...
      File.chmod(d, 0o444); Dir.delete(d)    iyi: panic: Cannot remove directory: ...
      File.chmod(b, 0o444); File.rename(a, b)  ... Windows error 5: Access is denied

  All three take the attribute off, try once more, and put it back when
  the retry still refuses — a file this could not remove is not a file
  this may leave writable. A read-only *directory* handed to
  `File.delete` is still refused, and keeps its attribute: measured,
  `attrib` still reads `R` on it afterwards.

  The bit is cleared with `attributes - 1` rather than `& ~1`: the
  prelude carries no `~` for Int32, and `bench/io_exercise.iyi` — a
  program that imports nothing but the prelude — is what said so.

  `bench/std_file_exercise.iyi` deletes a read-only file and renames
  onto a read-only name; `bench/std_dir_exercise.iyi` removes a
  read-only directory. All three pass on every platform and panic on
  Windows without the retry.
- **Nothing asked whether the daemon builds the same program.** It
  analyses the prelude once and forks a child per build, so the child
  starts from a program this build's command line never configured —
  every switch that matters has to be re-applied to it
  (`Compiler::APPLIED_ON_ADOPT`). The compiler refuses to build when a
  new switch is in none of the three lists, which is a good rail and a
  narrow one: it makes somebody *name* a list and cannot tell them they
  named the right one. Put a switch in the wrong place and the daemon
  quietly builds something else — no error, no warning, a binary that
  runs.

  `bench/daemon_agrees.py` builds four shapes both ways and compares
  what the two binaries *print*: a sample with imports, a workspace
  whose dependency is only an artifact, the mixed shape, and that
  artifact workspace under `--crystal` — twice through the daemon each,
  because the first request warms a prelude and the second adopts one.
  Delete the line that re-applies `use_iyimod` to an adopted program and
  the plain builds answer while all three artifact arms fail, which is
  the divergence this was written to catch. `bench/daemon_protocol.py`
  asks what a daemon does when a client is not a client; this asks what
  it hands back when the client is a client.

  And the shape a developer is in most of the time, now that a build
  reads a workspace's artifacts: a `mods` left over from an earlier
  `--emit-iyimod` run, beside a source they have since edited. The
  source wins — `bench/mod_context.sh` runs the program and asks for the
  edited answer, which is what the artifact-after-source order is for.
  Read the other way round the artifact no longer describes its module
  and a plain build refuses (IV.3) about a file the developer is looking
  at.

- **The editor could not open the workspace R-1 exists for.** A library
  arrives as `.iyimod` files and no source (III.7), and a program built
  with `--use-iyimod` compiles against them — the claim
  `bench/samples_roundtrip.sh` has gated for the build since the
  boundary existed. The language server was never asked. It resolved
  imports from source alone, so that same workspace opened with `can't
  find module 'app/base'` on the import line, hover and definition
  empty, and `iyi/contextPack` reporting that the import does not
  resolve — about a module the build compiles fine against. SPEC.md IV
  says the server's inner loop *is* what `--use-iyimod` already does;
  now it is.

  The order is the server's own, and it is the reverse of a build's. A
  build prefers the artifact and does not open the source; an editor
  answers questions about code somebody is looking at, so where a file
  exists go-to-definition has to land in *it* rather than in a rendered
  declaration. `Program#iyi_prefers_source` is that one caller's
  inversion: the artifact is read for a module whose source is not
  there, which is exactly the case that was broken and leaves every
  workspace with its sources compiled as it was before.

  Every other verb had the same hole, which is the whole agent loop:
  `iyi check` answered `can't find module` about a module `build
  --use-iyimod mods` compiles fine against, `iyi doc` said the file does
  not compile alone, and `iyi run` and `iyi test` could not build it at
  all. They read the artifacts the same way now — a verb has no flag to
  be told with, and a person typing `iyi test` is not telling anybody
  how their dependency arrived.

  A build told `--use-iyimod DIR` is untouched: that flag means "read
  these first and do not open a source", which is its contract. Told
  nothing, a build now reads the workspace's artifacts *after* its
  sources, so a workspace with its sources present compiles exactly as
  it did and the one whose library is only an artifact stops being an
  error.

  Where the artifacts are is one name — `mods` beside the project root,
  which is what the README, the SPEC and every bench in the tree
  already write. Not a setting, because the alternative to one name is
  a setting every editor has to be told and no agent knows; and a
  directory under some other name leaves the server saying what it said
  before. `iyi mod context` reads one the same way, since an artifact
  *is* the surface it was about to compile a module to produce.

  `bench/lsp_artifacts.py` asks the same program the same questions
  twice — dependency as source, dependency as artifact — and both
  answer with the same interface hash. Diagnostics, hover, definition,
  completion after a dot on a type the artifact declares, and the
  context pack: five answers, and five of them were empty or wrong on
  the artifact side before this. `bench/mod_context.sh` asks `check` and
  `doc` the same thing, and `iyi test` in that workspace now passes the
  test it could not build. The mixed shape a project actually has — its
  own modules source, its library an artifact — is asked there too:
  `mod context` compiles an import alone to read its surface, and that
  compile has the module's own imports in it.

- **`iyi mod context` answered that the standard library is not there.**
  It resolves each import the way a build does — the requirement table
  by longest prefix, then the entry file's directory — except that a
  build then looks at `IYI_PATH`, and this did not look there at all.
  So `import std/text` came back as `(does not resolve: no file and no
  requirement covers it)` about a module the same file compiles
  against: nine imports across `samples/iyi`, every one of them the
  library.

  The way it failed is the quiet way. `mod context` is the grounding
  AI_FIRST.md §2 offers a model, and an import it cannot resolve is one
  line saying so inside an answer that otherwise looks complete — a
  model reading it concludes the module does not exist and writes
  around it.

  The same resolution feeds two other commands, and both fail the same
  way for a script rather than for a model. `iyi check --affected
  src/std/text.iyi` answered `{"checked":[],"failed":[]}` — nothing
  affected, all compile — with a file importing `std/text` sitting
  beside it. And `iyi test --affected` on the same change answered `0 to
  run, 2 skipped: no test's imports reach the change`, which is a CI job
  running no tests at all for a library edit. `bench/mod_context.sh`
  sweeps every sample for a hole where a surface belongs and asks both
  verbs for the consumer they used not to find.

- **`iyi mod diff` said "consumers do not have to be rebuilt" about a
  body consumers compile.** The verdict — and the `--exit-code` a build
  system branches on — read the interface hash alone. But the line
  above it in the command's own output names the other half: *the
  bodies a consumer compiles: macros, generics, the initialiser*. A
  block-taking `def` is instantiated at the call site, so its body is
  the consumer's to compile, and moving one moved the consumer's
  machine code while `mod diff` answered that nobody had to rebuild. A
  script trusting that keeps a binary running code its source no longer
  says — the one way a boundary can be wrong quietly rather than
  loudly.

  The verdict is over both hashes now, with its own sentence for the
  case where no name moved. The rebuild-nobody answer the loop is named
  for is untouched and still the common one: a doc comment is in
  neither hash, and an ordinary body is in neither either — it stays
  behind as machine code, and a consumer that is *not* rebuilt links
  the new artifact and answers the new number. `bench/mod_diff.sh`
  checks all four kinds of edit against what the program actually
  prints, which is the comparison that was missing: the verdict was
  never measured against a rebuild.

- **An impl method written wider than its body did not ship one, and six
  of the twelve samples that import a module were not being asked.** An
  impl defines methods on its target, so when the target is a type the
  module declares their machine code is in the module's own unit and the
  header is all that has to travel. That holds while the symbol on both
  sides is the same name, and a union is where it is not: a consumer
  keys the call on the declaration and codegen keys the symbol on the
  type the body inferred. `calc`'s `impl Node for Number` answers
  `Int32` under a `def evaluate(scope) : Int32 | UnknownName |
  DividedByZero`, so the producer emitted `…#evaluate<Hash(String,
  Int32)>:Int32` and the consumer's link ended on the union.

  `bench/samples_roundtrip.sh` named six samples — "the six that import
  a module" — and there are twelve. It names all twelve now, which is
  how `calc` was found: `format`, `socket`, `std_iterator`, `std_text`
  and `std_time` were already crossing and only `calc` was not.

- **A datagram larger than the buffer killed the program on Windows.**
  POSIX fills the buffer, drops the rest and answers what fit; Winsock
  refuses the same call with WSAEMSGSIZE (10040) and fills the buffer
  anyway. Measured: a ten-byte datagram read with a four-byte buffer
  panicked with `cannot receive from UDP socket` where every other
  platform answered four bytes — and on the parked path, where Windows
  completes a posted `WSARecvFrom` instead, the same datagram came back
  as `Cancelled`, which says no datagram arrived when one had.

  `__is_msgsize` is the refusal by name, false on every other platform,
  and both receive paths answer the capacity the caller offered. The
  `std/udp` exercise reads a ten-byte datagram with a four-byte buffer
  twice, immediately and parked: four bytes each, on every platform, and
  the panic above without the arm.

- **A killed `iyi run` left the program it started running.** On POSIX
  the runner traps SIGTERM and SIGHUP and passes them on; Windows
  delivers neither, and `TerminateProcess` — what an editor's run lens,
  a CI step and `taskkill /F` all use — runs no code in the runner at
  all. Measured: `iyi run` on a program that listens, then
  `taskkill /PID <runner> /F`, left the child alive with its port still
  LISTENING. The bill came later, as `LNK1104: cannot open file
  iyi-run-....exe`, because the orphan holds its own executable open and
  the next build of that program cannot write it — which is what the
  `std_http_server` failure in a local run had been all along.

  The runner puts the program in a job object with
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE now: the kernel ends everything in
  the job when the last handle to it closes, and a process closes its
  handles however it died. The calls are the ones
  `src/lib_c/x86_64-windows-msvc/c/jobapi2.cr` already binds. A Windows
  that refuses the assignment (nested jobs before Windows 8) leaves the
  old behaviour exactly as it was rather than failing the run.
  `bench/windows_exercise.sh` kills a runner and asks the OS for the
  port: it comes back now, and reads LISTENING with the job taken out.

- **Expanding a relative path panicked on Windows.** `Path#expand` takes
  its base from `Program.env("PWD")` when none is given, and `PWD` is a
  POSIX shell's bookkeeping: cmd and PowerShell keep none. Measured from
  cmd, `Path["x.txt"].expand` died with `cannot expand "x.txt": no base
  given and PWD is not set` — every program on that platform that
  expanded a path it was handed, and the same in a service, a scheduled
  task or anything else started without a shell.

  The prelude answers it now. `Program.cwd` is the process's own
  directory beside `Program.args` and `Program.env`, which are its other
  facts: `getcwd` (79 on x86_64, 17 on aarch64) on Linux, libSystem's on
  darwin, `GetCurrentDirectoryW` on Windows, and nil on wasm32-wasi,
  which resolves a path against a preopened directory and names none.
  `expand` reads `PWD` first — a shell that keeps it keeps the path the
  person walked, symlinks and all — and asks the process when nothing
  set it. From cmd the same call now answers
  `C:\Users\dogru\playground\iyi\x.txt`.

  `Dir.current` was the other copy of that walk and is one line now, so
  the platform arms exist once. `std/path` could not have called it: a
  cycle, since `std/dir` imports `std/path`, which is why the header
  there said the prelude had no way to ask the kernel for the working
  directory. It has one.

- **`Dir.tempdir` named `C:\Windows\Temp`.** With `TMPDIR`, `TEMP` and
  `TMP` all unset — which is a service, or any program not started from
  a shell — the last resort was that literal, a directory a standard
  user may not write to. Windows keeps the question itself:
  `GetTempPathW` answers `TMP`, then `TEMP`, then the profile directory,
  measured with both variables cleared as `C:\Users\dogru\`. The
  trailing separator the call always writes is dropped, since no other
  branch of `tempdir` carries one.

  `bench/windows_exercise.sh` runs a program with `PWD`, `TMPDIR`,
  `TEMP` and `TMP` all removed: it must expand a relative name and write
  a file under `Dir.tempdir`. Before the fix that step reads the panic
  above.

- **A short sleep on Windows was fifteen times what the program asked
  for.** The poller waits on its completion port with a millisecond
  timeout, and Windows rounds that up to the system timer tick, which is
  15.6 ms on a machine where nothing raised it. Measured here, before:

      asked 1 ms, slept 15,441 us      asked 10 ms, slept 15,932 us
      asked 2 ms, slept 15,701 us      asked 16 ms, slept 26,903 us
      asked 5 ms, slept 15,770 us      asked 50 ms, slept 63,080 us

  A hundred `sleep 1` calls took 1,577 ms. It is the platform's floor and
  not the port's: `Sleep(1)` takes 15,609 us and the port's own
  `GetQueuedCompletionStatus(1)` takes 15,707 on this machine.

  The deadline is a waitable timer now, created with
  CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, which keeps the millisecond
  (1,513 us measured, and 10,393 for ten); the same object without the
  flag takes 15,879, so the flag is the whole reason to ask. The wake is
  a wait on the port *and* the timer rather than the timer's completion
  routine, because a high-resolution timer refuses one —
  `SetWaitableTimer` with a routine answers 0 and ERROR_INVALID_PARAMETER
  on this timer and 1 on a plain one — and a completion port is a
  waitable object: a packet posted to an idle port signals its handle in
  1 us. The millisecond timeout stays on the wait as the backstop, so a
  port that did not signal costs the deadline the program asked for and
  never a hung poller, and a Windows too old for the flag (it arrived in
  10 1803) keeps exactly the wait it had. After:

      asked 1 ms, slept 1,538 us       asked 10 ms, slept 10,141 us
      asked 2 ms, slept 2,402 us       asked 16 ms, slept 16,177 us
      asked 5 ms, slept 5,071 us       asked 50 ms, slept 50,469 us

  A hundred `sleep 1` calls take 156 ms. `bench/windows_exercise.sh`
  gates it at 800 ms — under the tick-rounded floor, five times over the
  measurement — and the gate reads 1,568 ms with the timer taken out. The
  other half of the wait is gated beside it: a fiber parks on a read with
  no data, another writes fifty milliseconds later, a third holds a
  one-second deadline open, and the read comes back after 52 ms. With the
  port taken out of the wait pair it comes back after 150 — at whichever
  deadline lands next, which is what a poller that hears only its timer
  does.
- **A `lib` the module declares did not travel, and the gate now asks
  four other platforms whether one does.** A `fun` is not a symbol this
  artifact answers for — the system linker resolves `opendir` against
  libc — so nothing carried one and nothing missed it. A body that
  *travels* changes that: the consumer compiles it and makes the call
  itself, so it needs the declaration to make it with. `std/dir` calls
  `LibC.opendir` from a body it ships and `std/file` types a field
  `LibC::Stat`, and both were dropped whole: a `LibType` is a
  `ModuleType` and not a `ClassType`, so it fell through every branch
  the emitter had.

  Found on darwin and nowhere else, the day after the section above was
  written, because the `lib` those two declare is inside `{% if
  flag?(:darwin) %}`. So the gate reads its own artifacts for four
  targets' front ends — darwin, windows, aarch64 and musl — which is
  where a platform differs and costs half a second per exercise.

  Three things about a `lib` had to be written the way C spells them:
  a nested struct's fields have no `@` and no accessors, because inside
  a `lib` those are the compiler's, and a `fun` whose C name is not an
  identifier is quoted — `std/math` binds `llvm.copysign.f32`, and
  written bare the parser stopped on the first dot.
- **All sixty std module exercises now round-trip through `.iyimod`, and
  the gate that says so is new.** `bench/std_exercise.sh` asked whether
  every module under `src/std` *writes* an artifact, which is the
  producer's half. Nothing asked the consumer's: build each exercise
  with `--emit-iyimod`, build the same program again with
  `--use-iyimod`, and compare what the two binaries print. Twenty-one of
  the sixty did that when it was first asked. The thirty-nine that did
  not each named a different thing a module never carried, and every one
  of them was a defect a consumer meets that no other gate here could
  see, because every other gate compiles its module from source.

  The output is compared and not merely the exit status, and writing
  that down caught the worst of them straight away:
  `std_reference_storage` built, linked, ran, and answered wrongly.
  `@[Primitive]` decides two different things and neither travelled:

  - **On a type it chooses what the compiler creates.**
    `@[Primitive(:ReferenceStorageType)] struct ReferenceStorage(T) <
    Value` is the type whose size is the instance size of its
    parameter. Arriving without the annotation the consumer built the
    ordinary struct the declaration looks like. It also needs the `<
    Value` other structs imply, and none of the state: the `@type_id` is
    the compiler's, and a compiler handed one back refuses it.
  - **On a def it is the body.** A def read from an artifact is a
    header, so codegen keys it on the type that declared it — right for
    a method whose machine code is elsewhere, wrong for an instruction,
    which has no elsewhere and is compiled per receiver. `std/
    reference_storage` writes `@[Primitive(:pre_initialize)]` on `class
    ::Reference`, so every `Point.unsafe_construct` in the consumer
    called one symbol compiled for `Reference` and got back a pointer
    into nothing.

  Two more, each the last thing between a module and its consumer:

  - **An impl the producer wrote inside the type it targets.** R-3 asks
    that an impl live in the module that defines the trait or the one
    that defines the type, and a declaration's module is the type
    enclosing it — so `impl Comparable for Prerelease` inside `struct
    SemanticVersion` satisfies it, and the same impl rendered at the
    module's own level does not. The rule is about who may *write* an
    impl; what arrives from an artifact is the record of a check the
    producer passed, so it is not asked again.
  - **A `run` inside a macro that travelled.** `run` compiles and
    executes a program at the consumer's compile time, and a module
    names that program the way the file that wrote the macro could:
    `std/eiy` writes `run("./eiy/process", …)`, beside
    `src/std/eiy.iyi`. Resolved against the artifact it was `can't find
    "./eiy/process" relative to "mods/std"`. No artifact can carry the
    program — it is a program — so what travels is where the module was.

  Two exercises are compared by exit status alone, named in the gate
  with the reason: `std_gc_exercise` prints how many bytes a collection
  freed, which is a property of what the build allocated, and
  `std_time_exercise` prints the clock.

- **A type a module declares under a name outside its own namespace
  arrived as its methods and nothing else.** The reopened section was
  written for what a module *adds* to somebody else's type — `12.gcd` on
  `::Int32` — and the methods are all an addition is. A module may also
  *declare* a type there: `struct ::BitArray` is the whole of
  `std/bit_array`, and `class ::File` holds the `enum Type`, the
  `@@temp_counter` and the second `using` that `std/file` wrote. Then
  the methods are not the whole of it, and each missing piece was the
  next error on the same module:

  - **The fields.** `can't infer the type of instance variable '@size'
    of BitArray`. The ones written *in this file*, which is narrower
    than the type's: `StaticArray`'s `@buffer` is its own compiler's and
    is refused when written back.
  - **The class variable.** `@@temp_counter = 1000_u64` on a reopened
    `::File` — carried whoever declared the type, because a class
    variable is a global and the methods that read it travel as machine
    code naming it.
  - **The `enum`, with its members and its bodies.** `enum ::File::Type
    must have at least one member`, and then `undefined reference to
    File::Type#file?` — `std/file` writes those eight question methods
    by hand, and a unit named after `::File::Type` is not under this
    module's namespace and so is not this module's to ship.
  - **The `using` written inside the type.** A reopened name is not
    lexically inside the module unit, so the unit's `using` does not
    reach it and the file writes a second one there. Carried now on
    `TypeDecl#usings`, and only for a module this file imports: a
    foreign type is reopened by whoever likes, and they share one list.
    Without it the consumer read `def self.size(path : String | Path)`
    and answered "undefined constant Path... this file has not written
    `using`", about a directive eleven lines above it.

  And the edges in that section are written absolutely. A bare `Float`
  on `struct ::Float32 < Float` is read as the module `Std::Float` the
  file itself declares — "Std::Float is not a class, it's a module".

  56 of the 60 `bench/std_*_exercise.iyi` round-tripped before this, 58
  do now: `std/bit_array` and `std/file`. The module set `std/dir` pulls
  in went from 870,472 bytes of `.iyimod` to 870,628, up 0.02%.

- **A method with no unit of its own did not travel, in the two shapes a
  method gets that way.** Codegen files an instance method under the type
  that *includes* the module it is written in, and files a generic's
  method under the instantiation. Neither is a symbol the producer can be
  relied on to have emitted, which is the rule a trait's defaults already
  travel under — and two ways in, nothing asked.

  - **A module included into a type this module does not own.** Include
    it into a type declared here and the result is in this module's
    object code; include it into `::Object` and the result is in the
    prelude's, which is not this module's to ship.
  - **A generic nested inside another type.** The exported path knew a
    generic's bodies travel; the carried path, which is where a nested
    type goes whether or not the author exported its container, did not
    ask.

  And the `include` line itself. A module that reopens a foreign type to
  add methods was carried, and one that reopens it to *include* something
  had nothing to carry, so it was dropped entirely — `TypeDecl#includes`
  existed and the emitter never filled it, on a reopened type or on the
  module's own.

  `std/colorize` is all three at once and nothing else: `class ::Object;
  include ObjectExtensions; end` over a `Colorize::Object(T)`. A consumer
  reading it from its artifact was told `undefined method 'colorize' for
  String`, then `undefined reference to
  Object(String)@Object(T)#to_s`. 55 of the 60
  `bench/std_*_exercise.iyi` round-tripped before this, 56 do now, and
  the module set `std/dir` pulls in is the same 870,472 bytes it was.

- **The rest of the signature can be wider than its callers too, and a
  symbol carries all of it.** A consumer types a call from the
  declaration and asks the linker for what the declaration says; the
  producer's codegen is demand-driven and wrote what its own program
  needed. A parameter was the half of this already fixed; the other two
  places a symbol carries a type went on missing.

  - **The receiver.** A method on a class something inherits from is
    reached through the virtual type wherever a declaration names the
    base — `@sink : Sink` holds a `Sink+` — and codegen puts those
    calls in a unit of their own, `Sink+@Sink#take`. The producer emits
    the ones its own program dispatched virtually: `std/io`'s `Reader`
    has two subclasses and the link ended on
    `Reader+@Std::Io::Reader#read_all`.
  - **The return.** `def self.new_element(name : String) : Node` was
    asked for as `new_element<String>:Std::Xml::Node+`, because a
    consumer holds the answer as its virtual type, where the producer —
    whose body returns exactly a `Node` — wrote the answer it had.

  And the other half of why the rule looked ineffective: a nested
  type's travelling body was recorded under its bare name while the
  renderer looks it up under the path it is nested in, so a body inside
  `ByteFormat::BigEndian` was carried and never written out. It is
  keyed on the path now, which is what a nested type's body has always
  needed and what nothing had asked of it.

  Only the *virtual* half of the question applies to a return. A union
  is written into the symbol on both sides — the producer's body types
  to the annotation it was written under — so `def scan(source :
  String) : Array(Token) | BadCharacter` has nothing to disagree
  about, and reading one as a widening shipped the body of every
  module that returns a union: `bench/generic_boundary.py` caught it
  on `calc/lexer`, which has no generic and should ship object code
  and no body.

  The price, measured on the module set `std/dir` pulls in: 870,472
  bytes of `.iyimod`, which is what it was before — a signature this
  rule fires on is rare enough in that set to cost nothing. 53 of the
  60 `bench/std_*_exercise.iyi` round-tripped through `--emit-iyimod`
  and `--use-iyimod` before this, 55 do now: `std/io` and `std/xml`.

- **A class hierarchy did not cross the boundary: not the `<`, not the
  `abstract`, and not the field types the hierarchy makes virtual.**
  Three things the artifact dropped, each enough on its own to stop a
  consumer, and all three were the compiler's own emit path missing
  what `iyi tool bind` already wrote for a Crystal shard.

  - **The edge.** A subclass's `fields` are its own — the inherited
    ones come with the superclass — so `pub class Memory < IyiIO` came
    back as `pub class Memory` and the consumer said `undefined method
    'puts' for Std::Io::Memory`. Worse than the method: a type id is
    assigned by walking that tree, so a consumer with a missing edge
    numbers it differently, and a match against a virtual type answers
    wrongly and links cleanly. It is written relative to the namespace
    it is declared in, which is what lets the renderer's inheritance
    ordering place it — that walk matches names against *siblings*, and
    a full path matched none of them, so a subclass was rendered above
    the class it names.
  - **The word.** An `abstract def` is only allowed on an abstract
    type, so a class that lost `abstract` arrived carrying a
    requirement it could not hold: `can't define abstract def on
    non-abstract class`, where `std/log` stopped.
  - **The field's type.** `IyiIO+` is how a virtual type prints and not
    a name anybody can write. The parser read `IyiIO`, then `+` as an
    operator, and the line after it as its operand: `can't declare def
    dynamically`, pointing at a `def` that was fine. Declaring the base
    is not a narrowing — an instance variable of a class type holds
    that class or a subclass, so the consumer's front end puts the `+`
    back.

  51 of the 60 `bench/std_*_exercise.iyi` round-tripped through
  `--emit-iyimod` and `--use-iyimod` before this, 53 do now: `std/log`
  and `std/symbol`. Seven are left, each on a defect of its own.

- **A generic's splat parameter did not travel, so the two types the
  prelude declares with one could not be read back.** `*T` and `T` are
  different declarations and the parser says so: `struct ::Tuple(T)` is
  `type var must be *T, not T`. The artifact carried the parameter
  names and not the marker, so `std/tuple` and `std/named_tuple` — both
  of which reopen `Tuple` and `NamedTuple` — were refused before
  anything in them was looked at.

  The marker rides in the list, which is the convention a def's splat
  already uses in `Signature#parameters`: the renderer joins those
  verbatim, so the marker *is* the text and no field had to be added
  for it. 49 of the 60 `bench/std_*_exercise.iyi` round-tripped through
  `--emit-iyimod` and `--use-iyimod` before this, 51 do now.

- **A module the module keeps to itself did not travel, and its object
  code did.** A `.iyimod` carries the types a consumer cannot name but
  the module's own machine code does — and the walk that collects them
  took classes, structs and enums. A nested `module` fell through it,
  while `ObjectCode` kept taking one unit per non-generic type declared
  under the module: the artifact carried the machine code of a type it
  never declared. The first body that named one stopped the consumer —
  `undefined constant Std::Float::Float32Text`, about the `module
  Float32Text` that `std/float` writes its single-precision printer in
  and that `::Float32#to_s` calls. `std/float`, `std/math` and
  `std/benchmark` were all unusable as artifacts.

  It travels with `extend self` where the module wrote one, and with
  its methods taken from **both** sides: a module keeps everything on
  its metaclass, so `def self.twice` is not among its own `defs` and
  walking that side alone carried a module with nothing in it. Carried
  classes get the same correction, which is where it was already owed:
  a `def self.` on one is what a travelling body calls it by.

  46 of the 60 `bench/std_*_exercise.iyi` round-tripped through
  `--emit-iyimod` and `--use-iyimod` before this, 49 do now.

- **A line typed into a Windows console was read in the code page too.**
  The write side became `WriteConsoleW` two branches ago and the read
  side stayed `ReadFile`, which on a console handle answers the *active
  code page*: measured on a real console under code page 437, typing
  `Türkçe-日本` — fifteen bytes of UTF-8 — gave the program eleven bytes,
  `T?rk?e-??`, with `ü` and `ç` folded to one byte each and the two
  Japanese characters gone. `IyiConsole.read` uses `ReadConsoleW` now and
  converts back through Windows' own conversion; the same line arrives as
  its seventeen bytes (fifteen, and the CR and LF the console adds). The
  wide buffer is a third of the caller's, which is the bound that cannot
  overflow it — a character of the basic plane is at most three UTF-8
  bytes, a surrogate pair two wide characters for four — so a longer line
  is read in pieces, which is what reading a stream does anyway.

  A redirected stdin is untouched and still byte-transparent: sixteen
  bytes of UTF-8 through `< file` arrive as the same sixteen. The console
  half cannot be gated here — a runner has no console attached, and the
  measurement above needed a pseudo-terminal — so the gate covers the
  pipe and this entry carries the console evidence.

- **A Windows program could not be told anything it could not spell in a
  code page.** Two surfaces, one cause, both measured from PowerShell so
  what was sent really was UTF-16:

  - **Arguments.** `ARGV_UNSAFE` is the C runtime's `argv`, which is the
    *ANSI* command line: `ünïcode-çğış` arrived as `ünïcode-çgis` —
    `ğ`, `ı` and `ş` replaced by the code page's best-fit letters — and
    `日本` as `??`, so a file named in an argument named a different file
    or none. `Program.args` reads `GetCommandLineW` now and splits it
    itself, by Microsoft's own rules (2n backslashes before a quote are n
    and the quote toggles, 2n+1 are n and a literal quote, `""` inside
    quotes is a literal quote), because `CommandLineToArgvW` lives in
    shell32 and a second DLL is a floor this library does not move.
    Checked against `CommandLineToArgvW` itself on seven command lines —
    quotes, doubled quotes, trailing backslashes, an empty argument, tabs
    and non-ASCII — seven of seven identical.
  - **The environment.** The CRT's `_environ` is the ANSI environment,
    so `değer-日本` read back as `deger-??`; and the worse half, which
    the reading defect hid: `ENV[]=` *wrote* the CRT's table, which
    `CreateProcess` does not copy, so a variable an iyi program set was
    never in the block a child inherits — proven with a probe reading
    both tables, where the Win32 block answered nil for a variable the
    CRT table held. Windows' own block is the single source of truth now:
    `GetEnvironmentVariableW` to read, `SetEnvironmentVariableW` to write
    and delete, `GetEnvironmentStringsW` to enumerate. A name or value
    that is not valid UTF-8 answers nil rather than half a conversion,
    and a write with one is refused by name.

  `bench/windows_exercise.sh` gates both: an 18-byte argument and a
  13-byte variable arrive whole, and the step runs only on Windows,
  because everywhere else the bytes are the bytes.
- **The first completion after the language server replaced its worker
  came back empty.** `iyi lsp` runs two processes and retires the one
  that compiles — on a memory bound, or after a pause — handing its
  successor the open buffers with `iyi/adopt` and warming it on the
  *focused* file. Every other open buffer arrived with the text and no
  program behind it, and a cursor question in a buffer that does not
  compile is answered from the last program that did. Mid-edit is what
  a buffer being typed in *is*, so the answer was nothing: `s.up`
  offered `upcase` before the replacement and an empty list after it,
  which an editor shows as no suggestions at all.

  The handover carries the last text a verdict called *clean*, and the
  successor keeps it as a seed: the first question about a buffer that
  no longer compiles compiles the seed, once, and answers from it.
  Which text that is has to be exact, so `publishDiagnostics` carries
  LSP's optional `version` now and the proxy pairs a clean verdict with
  the version it holds — a verdict about a version the person has
  already typed past says nothing about what the buffer is.

  Compiling every adopted buffer at the handover was the first shape
  and it was the wrong one: it put that work in front of whatever the
  person typed next, and `bench/lsp_latency.py` measured a didChange
  2,032 ms against its 2 s budget. Seeded and lazy, the same run
  measures 226 ms.

  `bench/lsp_memory.py` holds it — the same question either side of a
  retirement, in a buffer that does not compile, with the focus moved
  elsewhere so the warm-up cannot cover it. The memory bounds are
  unchanged: 551 MB peak while typing without a pause, 186 MB at rest.
  `bench/lsp_session.py` step 37 had been failing on this defect
  whenever a worker happened to retire at that point, which is a gate
  that fails for a real reason and names none of it.
- **`@[Primitive]` is a declaration a module makes, and the artifact
  threw it away.** A def wearing one has no body — the instruction is
  the body, and the compiler puts one there — so the rule that keeps
  `allocate` and the prelude's own instructions out of an artifact
  ("anything whose body is a `Primitive` is the compiler's") swept up
  the module's too. `std/float` declares the whole `@[Primitive]`
  matrix for `Float32` the way the prelude declares it for `Float64`,
  and a consumer that read the artifact got a `Float32` with no
  arithmetic at all: `wrong number of arguments for 'Float32#+' (given
  1, expected 0)`, about the prelude's unary plus, which was the only
  `+` left.

  The two are told apart by whether the annotation is on the `Def` —
  the compiler's instructions arrive without one — and the annotation
  travels with the signature, which is what makes the consumer's copy
  the same instruction rather than a promise of a symbol nobody
  emitted. No body travels with it: there is none.

  **`.iyimod` is format v52**, because a signature carries its
  annotations now. An artifact from v51 is refused and rebuilt, never
  migrated (SPEC.md IV.5), which is what the version is for. SPEC.md
  said v19 — thirty-three bumps behind, and nothing checked it, so
  `bench/doc_numbers.py` reads the constant now like it reads every
  other number there.

  41 of the 60 `bench/std_*_exercise.iyi` round-tripped through
  `--emit-iyimod` and `--use-iyimod` before this, 46 do now:
  `std/atomic`, `std/compress`, `std/int`, `std/number` and
  `std/reference_storage`.

- **An enum travelled with no methods, including the ones its author
  wrote.** An enum gets a question method per member wherever it is
  declared, so carrying those hands a consumer a second copy of what
  its own compiler already made — and the rule that avoided it carried
  nothing at all. A `def self.native` on `Path::Kind` is neither the
  compiler's nor optional: `std/path` and `std/dir` were refused with
  `undefined method 'native' for Std::Path::Path::Kind.class`, about a
  method the module's own source has.

  The two are told apart where they are written rather than by
  guessing at names: `Def#iyi_compiler_made` is set on the question
  methods as the enum visitor makes them, and everything else on the
  enum goes through the same walk every other type's methods go
  through — both sides of it, because a `def self.` lives on the
  metaclass and that is most of what an enum's author writes.

  38 of the 60 `bench/std_*_exercise.iyi` round-tripped through
  `--emit-iyimod` and `--use-iyimod` before this, 41 do now: `std/dir`,
  `std/path` and `std/errno`.

- **A parameter written wider than its callers linked against a symbol
  nobody emitted.** The consumer keys a call on what the declaration
  says — that is the contract, and widening to it is what makes the
  call reach the artifact's machine code — so the object code has to
  have been keyed the same way. Inside an ordinary build it is not:
  codegen is demand-driven, so `path : Path | String` called with a
  `String` is compiled as `cd<String>` and the consumer asks the
  linker for `cd<(Std::Path::Path | String)>`. Five of the library's
  own modules stopped there — `std/dir`, `std/env`, `std/gc`,
  `std/big` and `std/capsule` — on a union, a nilable, or an abstract
  number's `Int+`.

  This was written down in `collect_iyi_object_code`'s own comment,
  eight lines of reproduction and no fix: what `iyi bind` does about
  it is a keep file, a second build that names every declared
  signature, and an `--emit-iyimod` build has no second build to do it
  in. So the body travels instead, the way a block-taking def's
  already does, and the consumer compiles it at the types it asked
  for. The producer's own narrow instantiation stays in the object
  code for its own callers; the two have different names and do not
  collide.

  Only where the two can disagree: a parameter written as a leaf type
  is the type every argument to it has, so the ordinary method keeps
  its body behind, which is what IV.2 is for and most of what an
  artifact saves. The price, measured on the module set `std/dir`
  pulls in: 667,199 bytes of `.iyimod` became 674,638, up 1.1%.

  34 of the 60 `bench/std_*_exercise.iyi` round-tripped through
  `--emit-iyimod` and `--use-iyimod` before this, 38 do now.

- **An alias travelled as what it resolved to, and a resolved type is
  not always something that can be written down again.** `pub alias
  Ary = ::Array` came back as `alias Ary = Array(T)` — a generic prints
  with its type variables — and the consumer said `undefined constant
  T` about a letter nobody wrote. `pub alias BitArray = ::BitArray`
  came back as `alias BitArray = BitArray`, because a resolved name has
  no `::` on it, and inside `module Std::BitArray` that name is the
  alias being declared: `infinite recursive definition of alias`.
  `std/annotations`, `std/bit_array` and `std/static_array` each hand a
  prelude type out under its own name.

  It travels as the module wrote it now. The argument for resolving it
  was that a name resolved where the module was read may not resolve
  where the artifact is, and that is the wrong way round: the
  declarations text replays the module's imports, its requires and its
  `using` directives and declares its own nested types, so a name the
  module could write is a name that text can write. The resolved type
  is kept for the one case the written value cannot be read back — an
  expression the parser does not take as a type.

  Two more of the 60 `bench/std_*_exercise.iyi` round-trip through
  `--emit-iyimod` and `--use-iyimod`: 32 before this, 34 after.

- **A method with keyword-only parameters crashed the compiler when it
  was read from an artifact.** Not refused — crashed: `Nil assertion
  failed` or `Index out of bounds`, a page of this compiler's own
  frames, and an invitation to file an issue. `Time::Span.new(days:
  2)` is the shape, and `std/time`, `std/json` and `std/kernel` were
  all unusable as artifacts because of it.

  A def read from a `.iyimod` is a header: the machine code is in the
  artifact and the call reaches it by symbol, so the compiler fills the
  defaults locally and forwards the whole parameter list to that
  symbol. That forwarding is written for a plain parameter list and
  passes everything by position, and a bare `*` is a nameless
  parameter in the middle of one — upstream never sends a def with a
  splat down that path, because it keeps the body instead.

  So a header with a splat keeps its body too, which is also the thing
  that links: a producer emits one symbol per named-argument
  combination — `Span::new:days<Int64>` — and the expansion the
  consumer builds is named from the same named arguments, so it is the
  one the artifact carries. The body it keeps is the header's empty
  one, which makes the expansion a header as well; unmarked, codegen
  inlined the nothing it saw and the call disappeared.

  A header *and no more*: the mark says "declared elsewhere", so it
  belongs only on the expansion that keeps the empty body. Put on
  every expansion, it stopped the consumer emitting the ordinary `new`
  it compiles for itself, and kemal's four boundaries would not link —
  `undefined reference to Kemal::Exceptions::CustomException::new`,
  from the artifact's own object code, which is what
  `bench/kemal_serves.sh` is for.

  Round-tripping the 60 `bench/std_*_exercise.iyi` through
  `--emit-iyimod` and `--use-iyimod`: 29 built and ran before this, 32
  do now. With the three entries below it, 21 before this session's
  work and 32 after.

- **An enum a module keeps to itself arrived with its question methods
  and none of its members.** A `.iyimod` carries two kinds of type: the
  ones a consumer can name, and the ones it cannot but the module's own
  object code does. The second kind went through a branch written for a
  class, so an `enum Kind` was described by the `Small?`/`Large?`
  methods the consumer's own compiler generates from the members —
  while the members themselves, which are the whole of what an enum
  is, were left out. The consumer read the file and said `enum Kind
  must have at least one member`, about a type nothing outside the
  module can write.

  Both sides build the declaration the same way now, members and the
  integer they are numbered on included: the module's object code was
  compiled against those numbers, and a consumer that counted from zero
  again would agree with it only by luck. `@[Flags]` rides along, minus
  the `None` and `All` the compiler adds wherever a flags enum is
  declared.

  Seven of the 60 `bench/std_*_exercise.iyi` were refused this way.
  Round-tripping through `--emit-iyimod` and `--use-iyimod`, 28 built
  and ran before this and 29 do now — the other six reach a further
  defect apiece, which is what this measurement is for.

- **A class variable refused the module it was written in, over a value
  the artifact was already carrying.** The rule that stops a build from
  linking against a module whose type body has code to run was written
  for exactly this case: a `@@count = 7` belongs to the type, so the
  module's initialiser does not hold it. That reading stopped being
  true when `TypeDecl#class_vars` began carrying the value as written —
  a consumer reads `@@count : Int32 = 7`, declares the global and
  initialises it like any other. So the refusal was over something that
  travels.

  Checked on the shapes that could have made it untrue rather than on a
  number: a collection literal, whose node `CleanupTransformer` has
  already rewritten into temporaries by the time an artifact is written
  (which is why the *source* is what travels), and `@@base : Int32 =
  seed + 1`, whose value calls a private def of the module — a body the
  consumer never sees and reaches in the artifact's own object code.
  Both answer the same from source and from the artifact.

  What the rule still refuses is what it is for: a statement in a type
  body. `puts "x"` there is not a declaration, so nothing in `Exports`
  carries it, and it is not the module's own top level, so the
  initialiser does not either — a program built against that artifact
  would run without it. The spec that pinned this named a class
  variable and now names a `puts`, because it was pinning the wrong
  shape.

- **A `lib`'s `fun` and a constant a macro wrote were read as code that
  has to run, and refused the module they were written in.** Both are
  declarations, and the check that asks whether a module's type body
  has code an artifact cannot carry did not recognise either — so it
  answered its conservative "yes" and the consumer was refused.

  A `lib` body holds a `fun` (a C prototype), a `type` (a name for a
  pointer), a `struct` or `union` (a layout) and a `$name` (an external
  symbol). None of the four runs, so none of them can be the piece of
  setup the rule exists to protect. `std/math` binds `llvm.sqrt.f64`
  and `llvm.copysign.f64`, and every program that imported it as an
  artifact was told it "has code inside a type body that has to run",
  about two intrinsics. A constant in a `lib` is deliberately still
  refused: nothing carries one yet.

  A macro is where the constants of the modules that bind a platform
  live — `std/file` writes `AT_FDCWD` inside a `{% if flag?(:linux) %}`
  — and the walk that now carries a type's constants reads what a macro
  expanded to, the same way the module's own top level already did. The
  expansion is the right thing to carry: an artifact is rejected unless
  the consumer's target and flags match the producer's (IV.5).

  Measured the same way as the entry below, over the 60
  `bench/std_*_exercise.iyi` built with `--emit-iyimod` and consumed
  with `--use-iyimod`: 25 round-tripped, 28 do now, and the refusal
  that names a type body is down from 4 of them to 1. That last one is
  `std/file`'s `@@temp_counter = 1000_u64` — a class variable, which is
  the case the rule was written for.

- **A constant in a type body was in the artifact nowhere, so thirteen
  of `src/std`'s own modules could not be consumed as one.** `pub struct
  Math` writes `PI = 3.14…` inside itself. That is a declaration with a
  value, and a `.iyimod` had no place for it: `Exports` carries types
  and signatures, and the initialiser — which is where a module's own
  constants travel as source — stopped at the type's body. So the
  producer marked the module as one with code inside a type body that
  has to run, and every consuming build was refused: `"std/math" has
  code inside a type body that has to run`, about `PI`.

  It travels qualified now — `pub Math::PI = 3.14…`, written after the
  declarations that make the namespace exist — which is exactly how
  `iyi tool bind` has always carried a bound Crystal namespace's
  constants. `pub` rides along, nesting is kept (`Capsule::Frame::MAX`),
  and a `private` one is carried without the word, which is the same
  trade the bind side makes: a qualified assignment has nowhere to put
  it, and iyi does not gate a constant on it.

  What is still refused is unchanged and is the point of the rule: a
  class variable's initialiser belongs to the type, is not carried, and
  a build given one would link and run with that part missing.
  Measured over `bench/std_*_exercise.iyi`, each built with
  `--emit-iyimod` and then consumed with `--use-iyimod`: 21 of the 60
  round-tripped before, 25 do now, and the refusal that named a type
  body fell from 20 exercises to 4. Those 4 are a second defect behind
  the same message — a `lib`'s `fun` read as code — not this one.
  `spec/compiler/iyimod_spec.cr` holds it: the module's source is
  deleted before the consuming build and the program is run, because a
  constant that arrives declared and never initialised answers zero.
- **One empty collection answered 0 and another panicked, in the same
  program.** `Set(Int32).new.sum` was `0` and `([] of Int32).sum` was
  `iyi: panic: sum of an empty array`: the prelude's own `Array#sum`
  won over the trait's, and it had no zero to start from, because an
  identity belongs to the *type* and there is no element to ask when
  the collection is empty. The prelude has one now - `Int32.zero` and
  its four siblings, a table beside the numbers themselves
  (`src/iyi/number.iyi`) - so both answer 0, and `std/traits` stops
  writing `self.zero` for those five because a `.iyi` file may not
  redefine a method the prelude has (R-3).

  Summing something that is not a number is a compile error now rather
  than a panic at run time: `["a", "b"].sum` says a sum starts from the
  type's zero, that only numbers have one, and that strings are put
  together with `join`. Crystal refuses the same program for the same
  reason. `bench/std_set_exercise.iyi` holds the agreement - the empty
  set and the empty array, in one line, both `0`.

- **"undefined method 'tally' for Array(Int32)" was true and useless
  when `import std/enumerable` was the whole answer.** std implements
  the traits for the prelude's types (R-3 gives the line to the module
  that owns the trait), so the method a person asked for is often one
  import away rather than absent - and the message sent them to `iyi
  doc` or to `--crystal` for something the library already has. It now
  names the module and the trait: "`std/enumerable` implements
  `Enumerable` for Array and that is where `tally` is". A file walk, on
  the error path only, no `Regex` (the compiler links no pcre2, III.9).
  Where no std module has the method, the size rule is still what the
  reader is shown.

- **A block given to the plain name now names the `_by` sibling.** This
  library pairs `sum` with `sum_by` and `min` with `min_by` where
  Crystal passes a block to the same name, so "'Array(Int32)#sum' is
  not expected to be invoked with a block" was a full stop one word
  from the answer. The pair is looked up on the receiver rather than
  listed, so it cannot go stale.
- **Installing iyi over iyi left the last release's files in the
  library, and that is a broken `--crystal`.** `install.sh` unpacked the
  tarball into the prefix, and `tar` knows nothing about files a release
  has deleted, so they stayed - and `share/iyi/crystal` is a library,
  not a pile of files: `crystal/dwarf.cr` requires `./dwarf/**`, so a
  file nobody ships any more is still *required* by the glob that
  outlived it. Found on a machine that had upgraded in place:
  `crystal/dwarf/line_numbers.cr` from an older release was still there
  and **every `--crystal` build died** with `Error: undefined constant
  FORM`, naming a file inside the install that the person never wrote
  and cannot find in the repository. The fresh-install gate could not
  see it, because it installs into an empty directory - the path only a
  first-time user takes.

  Each install now writes down what it unpacked
  (`share/iyi/installed-files`, straight from `tar -tzf`) and the next
  one removes exactly that, so `bin/` and `lib/` - shared with whatever
  else lives under the prefix - lose only iyi's own files. An install
  from before that list exists leaves none, and for it the two
  directories iyi owns whole are replaced instead, which is where the
  library that poisons a build lives. `make install_iyi` clears
  `$(DATADIR)/iyi` for the same reason. `install.ps1` already did this
  and said why; the sh installer never learned it.

  `bench/install_upgrade.sh` is the gate, in the clean room beside the
  fresh-install one: install, plant the exact shape (a `.cr` under the
  library, in a directory a `**` require reaches, that does not
  compile), install again, and demand that the file is gone and a
  `--crystal` program builds. It holds both upgrade paths, refuses a
  file list that climbs out of the prefix, and against the installer
  before this fix three of its steps fail.

- **`UInt16` had no operations, and answered `false` instead of saying so.**
  The prelude crosses five numeric types for comparison and `UInt16` was
  not among them, so every comparison on one fell through to
  `Object#==`, whose answer for anything it does not know is `false`.
  Measured: `46_u16 == 46_u16` was **false**, and `46_u16.to_s` printed
  the string `UInt16`. Two Windows call sites did nothing because of it,
  both silently: `__iyi_wide_rooted?` answered no about every rooted path
  (so every path took the `GetFullPathNameW` route, which is why nothing
  failed visibly) and `File.readlink` never stripped the `\??\` a
  reparse point stores. A third was found while writing the PDB reader —
  scanning a UTF-16 path for its last `.` found no dots in a
  forty-character path — and had to be written over the byte view.
  `UInt16` is in the prelude's comparison cross now, and only there: the
  conversions stay at five types because `std/int` declares the whole
  tower's, and a wide character against a double is `std/int`'s too,
  since every value narrower than a double is one exactly.

  Not closed, and written into `src/iyi/primitives.iyi`'s header: the same
  silence still covers `Int8`, `Int16`, `UInt32` and the rest of the
  tower without `import std/int`. Refusing it needs both operands' types
  at once, which a method body does not have — a guard on the receiver
  alone refuses `5 == nil`, where `false` is the right answer, and was
  measured breaking eleven exercises. The fix belongs in overload
  resolution.

- **Three things `std/file` answered wrongly on Windows, each silently.**
  Measured with one probe, all three visible in its output:

  - `File.tempfile` wrote into `C:\Windows\Temp`, a system directory an
    ordinary account cannot write to, with a POSIX separator glued on:
    `C:\Windows\Temp/wperm_0_1001`. It reads `TMPDIR`, `TEMP` and `TMP`
    first now — the order `Dir.tempdir` already read, because the two
    answering different directories is how a program loses a file it just
    wrote — and joins with the platform's separator:
    `C:\Users\dogru\AppData\Local\Temp\wperm2_0_1001`.
  - `File.chmod` did nothing at all. Windows has one bit of a POSIX mode,
    FILE_ATTRIBUTE_READONLY, and the owner's write bit is what decides it;
    before, `File.chmod(path, 0o444)` returned normally and the next
    `File.write` succeeded, so a program that asked for a file to be
    unwritable was told it had been. Now the write is refused.
  - `File.writable?` ignored that attribute, so it disagreed with the
    library beside it: after a `chmod` to `0o444` it answered `true` while
    the write panicked. `info?` clears the write bits of its default mode
    when the attribute is set, and the probe now reads `false`, `true` for
    `readable?`, and `true` again after `0o644`.

  `File.chown` still does nothing on Windows, and that is now written down
  rather than left blank: an owner there is a SID in a security descriptor,
  not a numeric uid and gid, so there is no honest thing to do with the two
  numbers the method takes.
- **`iyi build --debug` aborted on every program, and described the
  wrong fields on the compilers where it did not.** iyi does not keep a
  class's type id in the object's struct - it is the high half of the
  header word under the pointer (GC_DESIGN.md Stage 5), which is why a
  binary tree's node is 16 bytes here and not 24. Every place in
  codegen that indexes a field asks `iyi_object_layout?` about that
  except the one that wrote debug info, which kept Crystal's rule that
  field zero is the type id and so asked LLVM for the field *after* the
  last one, for every class in the program. On LLVM 21 and later - what
  a current distribution ships - `LLVMOffsetOfElement` past the end
  calls `report_fatal_error`, so the compiler died on `SIGABRT` with a
  message about scalable vectors: `puts 1` was enough. On LLVM 20 and
  earlier it answered a garbage offset instead, so a debugger read the
  neighbouring field's bytes and the last field's off the end - wrong
  quietly, for as long as the flag has existed.

  The index is computed the way the rest of codegen computes it now,
  and `LLVM::TargetData#offset_of_element` has its bounds check back
  (it was commented out, inherited): a compiler bug there is a named
  error rather than a fatal error from a library about a type nobody
  wrote. `bench/debug_info.py` is the gate - the build, the offsets read
  out of the compiler's own `--emit llvm-ir` so no `llvm-dwarfdump` has
  to exist, all 27 samples built with `--debug`, and where the machine
  has `gdb`, a breakpoint and `print *shape` reading `width = 3,
  height = 4`. Against the commit before the fix, every one of the 27
  samples fails to build.

- **SPEC.md's ceiling breach quoted two figures that did not agree.**
  "624 lines for Windows' arms" and "the library at 3,618" is one
  platform's arms subtracted from a sentence about every platform's, and
  both numbers were counted by hand. `bench/doc_numbers.py` measures the
  platform floor now - the lines inside a macro conditional whose
  condition names an OS, architecture or ABI flag, every arm of it, a
  build-configuration flag like `gc_boehm` excluded - and the library
  without it: **1,489** and **3,295**, held to the sentences that quote
  them like every other number. The ceiling is still 3,734 and the
  breach is still what the floor costs — 1,040 over, as the library with
  every platform's floor stands today; what changed is that the two
  numbers the rule choice rests on are now arithmetic that checks rather
  than arithmetic that disagreed with itself.

- **A fiber's stack running out died of a bare access violation on
  Windows, with no sentence anywhere.** The main thread's overflow was
  named; a fiber's was not, and the reason is that a vectored exception
  handler runs on the stack that faulted. A fiber stack's only guard was
  the first page of its reservation, left uncommitted, so at the moment
  the handler was asked to print there was nothing under the fault to
  stand on and the process died of the fault it was handling. Windows has
  no `sigaltstack` to move it to.

  A fiber stack ends in three parts now (`IyiFiber#map_stack`): the
  uncommitted page at the bottom, which is the hard wall a frame big
  enough to jump the guard lands in; 16 KB of committed slack, which is
  the handler's room and the same size `SetThreadStackGuarantee` reserves
  for the same code on a thread's own stack; and one committed page
  carrying PAGE_GUARD, which is what the program trips on.

  Measured, not assumed. The fault arrives as STATUS_STACK_OVERFLOW
  (0xC00000FD) rather than a guard-page violation, because
  `switch_stack` writes the fiber's bounds into the TEB's StackBase and
  StackLimit and the kernel therefore reads a fiber stack as the thread's
  own; the handler entered with its stack pointer inside the page it had
  just tripped (fault at `0x21504254ff8`, entry `rsp` `0x215042545d0`);
  and with the slack filled with a pattern and read back inside the
  handler, the deepest byte it touched was 6,968 below the top of the
  guard page — 4,096 of that is the guard page itself, so 2,872 bytes of
  slack were used and 13,512 were spare. With `GUARD_SLACK = 0` the same
  program prints its sentence and then dies of an access violation on the
  way out, which is the handler walking off the bottom of the guard page
  into the page nobody committed: that is what the slack buys.

  `bench/panics.sh` runs its overflow loop on all three stacks on Windows
  now — main, a fiber's and a thread's — and still holds the wild pointer
  apart as a memory fault. The Windows skip and the comment that named
  this as owed work are gone.

- **`std/udp`'s Winsock arm and the night's `SockLen` met at the merge.**
  The `make_sockaddr` return type names an alias each platform arm
  declares; the Windows arm (#97) was written beside it and did not, so
  the merged tree's `std/udp` would not have compiled on Windows. The arm
  declares it now, and every program under `bench/` cross-compiles to
  `x86_64-windows-msvc` from the merged tree.

- **A cursor beside a node the front end never typed was -32603.**
  96,608 requests over every position of every std module - hover,
  definition, completion, references, rename, signature help, highlights,
  call hierarchy, selection ranges, symbols, tokens, folding, lenses,
  links, inlay hints - found eighteen internal errors and two causes:
  `ContextVisitor` read `.type` off a variable assigned only inside a
  macro branch this target does not take (`{% if flag?(:win32) %}` in
  `std/dir`) and off one assigned inside an `if` nobody reaches
  (`s_len` in `std/path`), and the answer was "BUG: ... has no type". An
  untyped node is no context now. `bench/lsp_soak.py` holds it. The
  soak also measured the server's memory: `iyi lsp` is built without a
  collector, like every binary, and a long session grows without bound -
  40 edits of a ten-line file are 1.6 GB, and the `references` sweep over
  `std/big` was killed by the kernel at 19 GB; with `collector=1` the same
  session holds at 210 MB. Whether the long-lived verbs (`lsp`, `daemon`)
  should carry the collector the one-shot compiler does not is a decision
  this entry records rather than makes.

- **A list of floats did not sort.** `std/float` writes `Float64#<=>`
  itself, answering `Int32?` - nil for NaN - and `std/traits` imports
  it; the type's own def wins over the impl's, so `Comparable`'s bound
  held and the body did not: `List(Float64).new([...]).sorted` was
  refused with "expected block to return Int32, not (Int32 | Nil)", and
  so was `Float32`, `max`, `Heap(Float64)`. One `<=>` per type now, and
  it is a total order: NaN after everything and equal to NaN, which is
  what a sort needs and what Rust calls `total_cmp`. `<`, `==` and the
  rest keep IEEE's answer against NaN - only `!=` is true - including
  the exact wide-integer comparisons that had been reading `<=>` and
  would have said `NaN > 5_u128`. The other half of the round: two tasks
  parked on one socket is refused by name by the runtime, as designed;
  a sibling's error releases a parked `receive_from` with `Cancelled`,
  and `receive_datagram?` beside it answers nil at once - both held by
  `bench/std_udp_exercise.sh` now, the sort by `bench/std_exercise.sh`.

- **Definition-site typing (R-2c) skipped every def that was not `pub`.**
  `def f : Int32` with a body answering `"s"` passed `check` and `build`
  whenever nothing called it; make it `pub def` and the same body was
  refused. The probe called from outside the module and so could only
  reach what outside reaches, which made `pub` the condition of a rule
  that is about the definition. The probe is the definition asking about
  itself now - `Call#check_visibility` lets a synthetic call through the
  wall and past `protected` - so a module's unmarked function and a
  type's `private def` are typed like an exported one; a mixin `module`'s
  defs stay caller-typed, since `self` there is the includer's. Typing
  every def in the tree this way found one: the runtime's eager
  `IyiMark.sweep` called `sweep_one` with no argument, an arity that had
  moved under it, and nothing native ever called `sweep`.
  `bench/agent_loop.py` holds the rule; SPEC.md R-2c says it.

- **Three typos `iyi fix` had nothing for.** Found by injecting one to
  three typos into every sample and asking `fix` to converge: 5 of 25
  did not. A prelude method with an optional parameter - `"ab".ljuts(5)`
  - was never a suggestion, because the Levenshtein pass only tested defs
  whose *maximum* arity was the call's, and `ljust(width, char = ' ')`
  has two; the sentence then said the prelude is "small by rule", which
  was false. The range is what is asked now. A module's own function
  called inside one of its impls (`shut` for `shout`) was not in the
  candidate list, though it is in scope there; it is. And the compiler's
  pseudo-methods (`i_a?` for `is_a?`, `or_pnic` for `or_panic`) are on no
  def list; they are candidates by name. `bench/agent_loop.py` holds the
  three; 100 injected samples now converge 100.

- **`bench/generic_boundary.py` counts a reopening module apart.** Once
  `std/int` and `std/float` carried what they add to the prelude's types,
  every body of theirs travels - the machine code sits in the owner's
  unit, which is the prelude's - and the corpus went to 60% bodies over
  the 50% line. The line is about a module's own surface; the two are
  printed on their own row, with the number that would take them out
  named: codegen owning a reopening's code by the module that wrote it.
  The script's section table was also two numbers stale (`reopened` is
  17, `libs` 18, `layouts` 64), so it had never seen a reopened section.

- **A stray `!` before the module header crashed codegen.** A unary
  operator reaches across a newline for its operand, so `!` on the line
  above `module x` parsed as `!(module x ...)`: past the one-module rule,
  never typed by the semantic pass (`check` said nothing), and the build
  died on "BUG: `module x` has no type". Found by 10,500 mutants of the
  samples and std under `check` and `build` - the one crash among them.
  A declaration is refused as a unary operand at the line: "unexpected
  '!': a module header is a declaration, not a value to negate", and the
  same for `-` before a `def`. `spec/compiler/parser/parser_spec.cr`.

- **`iyi doc` crashed on six std modules, refused fifteen, and printed
  twelve as a bare header.** One sweep of `iyi doc` over every file in
  `src/std`, which nothing had run. The crash: an `enum` nested in an
  exported class (`Path::Kind`, `Colorize::ColorANSI`) was asked for
  `instance_vars`, which every type answers `responds_to?` to because the
  base declares it as a raise; the walk asks `is_a?(InstanceVarContainer)`
  now. The refusals were R-2's, and right: `doc` writes the artifact, and
  that is where an exported signature is asked for its types, so fifteen
  modules that every gate compiled from source could not be packaged at
  all - `Deque#dig(*subindexes)`, `Math.sin(value)`, `Benchmark.bm(&)`,
  four `==(other)` catch-alls, `JSON.to_json(obj)`, `Steppable#step`.
  Each says its types now; `Indexable`'s variadic `dig`, whose answer no
  annotation can name, is gone. `bench/std_exercise.sh` writes every
  module's artifact from now on. The bare headers were the twelve modules
  that only reopen a prelude type (`std/int` is `struct ::Int` and the
  tower, `std/text` is `class ::String`): their artifacts carried nothing
  - `exports (none)`, `object code (none)` - so a program reading
  `std/int` from its artifact was told `12.gcd` is undefined, which is R-1
  broken for each of them. The producer collects what a module added to
  types it does not own now (`Section::Reopened`, every body travelling,
  since the machine code sits in the owner's unit), `doc` renders it, and
  `12.gcd(18)` reads from the artifact. Not finished on the consumer's
  side: 39 of the 60 std exercises still do not build from artifacts,
  for reasons the morning owns - `@[Primitive]` defs need an annotation
  field a `Signature` has no room for (a format bump), macro-written
  bodies render as they expanded, "code inside a type body" refuses ten
  modules, and one consumer build dies of an `IndexError`.

- **The parallel marker's "pool never recycles" proof did not fire on a
  three-core runner.** The tree's marks publish batches only by donation -
  when the pool is empty and a helper is idle - so how many they publish
  is the machine's, and on darwin CI a copy with `free_batch` removed
  stayed inside the pool's first piece. `bench/parallel_mark.iyi` marks
  the 300,000-wide object with helpers before the pool check now: a stack
  past `SPILL_AT` publishes on every push, which is thousands of batches
  on any machine, and thousands never recycled are eleven megabytes.

- **A type the standard library declares names its module.** `Deque`,
  `JSON`, `Random`, `BigInt`, `Path`, `UUID`, `Base64`, `CSV`, `Log`,
  `OptionParser`, `Comparable`, `HTTP` - each was a bare "undefined
  constant" while `std/<module>.iyi` declared it under `pub`. The compiler
  reads the search path's `std/` for a top-level `pub` declaration of the
  name, on the error path only, and says `import std/deque` and `using
  std/deque::{Deque}`; the hand-written sentences (`Time`, `ENV`) keep
  their place above it, and "Did you mean" comes after, since `Deque` is
  not a misspelling. `spec/compiler/semantic/iyi_spec.cr` holds it.

- **Three arrival hints denied modules the tree has.** `p 1` was told
  "there is no `p`" while `std/kernel` declares `p` and `pp`; `rand` was
  told there is no random source "in `std` yet" while `std/random` has
  had one; `ENV` was told there is no map of the environment while
  `std/env` is that map. Each names the module and the `using` line now,
  the way `sprintf` and `Time` already did. `spec/compiler/semantic/iyi_spec.cr`
  holds the three.

- **Three more arrivals get a sentence.** `def f(a : Int32) -> Int32` was
  "expecting token '.', not 'NEWLINE'" - the arrow parsed as a proc
  literal opening the body - and says a return type is `: Type` here;
  `a : int32` and `: bool` were "unexpected token" and name the capital
  (`Int32`, `Bool`); `else if` with one `end` was "expecting 'end' to
  close the if that began at line 1", true and unhelpful, and adds that
  `else if` opened a second `if` and `elsif` is the spelling. A `.cr`
  keeps the parse it had. `spec/compiler/parser/parser_spec.cr` holds
  the three; the other thirty shapes probed - a missing `end` at every
  depth, a stray one, `fn`/`let`/`var`/`elif`, an open bracket, brace or
  paren, a bare `def f a` - already answered by name.

- **`bind --mods` and `migrate --out` died of the filesystem's words for a
  directory that will not take a file.** `--mods ro/` was
  `ro/x.bind.log: Permission denied`, naming the log and no flag;
  `migrate --out ro/` the first module's; and `--out` naming a file was
  `mkdir`'s `File exists`. Each is refused up front by the flag it was
  given, in the sentence `build -o` already uses. `bench/verbs_exercise.sh`
  holds the three. A probe of forty edges found nothing else: an empty
  shard, a missing entry file, a cyclic require, a hyphenated name, a
  shard depending on a shard, `--out` inside the tree, and a syntax error
  each answer by name.

- **`sleep` on wasm32-wasi was a bare "undefined method".** The prelude's
  `sleep` parks a task on the scheduler and lives with the runtime, which
  wasm32-wasi does not carry (SPEC.md III.4); `group` had its reason at
  the same spot and `sleep` had none. It is refused by name now, in the
  same macro block, and `bench/wasm_concurrency_probe.sh` step 4 holds
  it. A probe of thirty-odd programs under wasmtime found nothing else:
  a panic prints and exits 1 with its defers run, overflow, a bad index
  and a missing key panic by name, `File` refuses by name, `Program.env`
  is nil, stdin/stdout/stderr work, `std/time`, `std/format`, `std/env`
  and `std/random` answer. The stack running out is still wasmtime's
  trap (exit 134), as the stack-guard entry says.

- **`File.touch(path, time)` set "now" on darwin whatever `time` said.**
  The Linux branch writes the second it is given through `utimensat`;
  the darwin branch passed a null `times` to `utimes`, which is the
  kernel's spelling of "now", so `touch(path, 1)` was the epoch second on
  one platform and the clock on the other — one name, two behaviours,
  decided by the machine (III.1.7a). It writes the `timeval` pair now, in
  the shape the Linux branch writes its `timespec`s. The exercise had
  asserted it all along and been red on every darwin machine;
  `bench/std_file_exercise.sh` now also proves, on whichever branch the
  host compiles, that a `touch` which drops its argument is caught at the
  time check.

- **Checks that were red on darwin for reasons that were theirs, not the
  modules'.** Each is fixed where it lived:
  - `bench/std_compress_exercise.sh` wrote its zlib oracle with
    `zlib.compress(data, level, wbits=...)`, whose `wbits` arrived in
    Python 3.11. Under an older interpreter the generator died on the
    first stream, the gate carried on against an empty directory, and the
    verdict it printed was the decoder's — "DEFLATE: the stream ends
    inside a block" — about a file that was never written. It uses
    `compressobj` now, which every Python 3 has, refuses to continue when
    the oracle cannot be produced, and counts the 79 fixtures it expects.
  - `bench/std_atomic_exercise.sh` read the instruction each verb emits
    off the host's IR, and on aarch64 the back end has rewritten every
    `atomicrmw` into a load-linked / store-conditional loop by the time the
    `.ll` is written, so its six `atomicrmw` patterns could never match
    there. The audit reads x86_64-linux's IR on every host now, through
    `--cross-compile`, which writes the IR and links nothing: what it
    asserts is the ordering the module asks for, and that is the same
    request on every target. The strengthened-copy proof catches exactly
    the six relaxed instructions it patches, where before it counted
    nine with three of them always missing.
  - `bench/std_io_exercise.sh` and `bench/std_time_exercise.sh` carried
    their own copies of the darwin floor from before panics printed
    backtraces, so every darwin program's `backtrace` and
    `backtrace_symbols_fd` read as "something new". Recorded, with the
    reason `bench/dependency_floor.sh` already gives.
  - `bench/std_errno_exercise.sh`'s two platform proofs patched the Linux
    branch on every host, and on darwin that branch is inside a
    `{% if flag?(:linux) %}` the compiler never enters, so the copy built
    the same and the proof reported "does not test this" about a check it
    could not reach. Each host patches the block it builds now: a
    collision with a neighbour and the other platform's number leaking in,
    which are the two mistakes the numbers have had.
  - `spec/compiler-cli/crystal-daemon_spec.cr` asked for a socket at
    `daemon-absent/absent.sock` under `$TMPDIR`, which on darwin is
    `/var/folders/xx/<thirty characters>/T/` and made the path 106 bytes
    against the kernel's 103. The compiler refused it with its own
    sentence about the limit, correctly, and the spec — which is about the
    *other* refusal, "no daemon listening" — never reached it. Short names.

- **`iyi fix` answered `"clean": true` over a file it had not finished.**
  The loop applies one edit per round and the verdict was read from a
  variable only its `break` paths ever set, so a run whose every round
  applied an edit fell out of `32.times` with that variable still nil:
  forty consecutive fixable typos went in, thirty-two were fixed, eight
  were left, and the verb answered clean with exit 0. `iyi check` on the
  same file exited 1 in the next breath. It is the one sentence this verb
  exists to say, it was wrong in the one case that is entirely its own
  doing, and an agent branching on `clean` shipped the file. The cap is on
  the edits now and the loop is unbounded, so the compiler is asked once
  more after the thirty-second edit and its answer is the answer; `--json`
  carries `capped` beside `clean` so a caller can tell "look at this file"
  from "run me again", and the prose says which. Two steps in
  `bench/agent_loop.py` hold both halves: the capped run is not clean and
  the file does not compile, and the next run finishes it.

- **A boundary never went stale, so an edited shard was compiled against
  last week's surface.** A module compiled from source answers staleness
  with the digest of the one file at its module path (IV.3); a bound shard
  has no such file, `tool bind` wrote no hashes at all, and the reader's
  "an artifact from before the hashes cannot answer" branch then reported
  it fresh — unconditionally, forever. Edit the checkout, rebuild, and the
  consumer type-checked against the declarations the boundary had when it
  was written and linked the object code beside them, with nothing said:
  the one failure a build cache must not have, and the only path left that
  could produce a wrong build from a stale artifact. A boundary records the
  files it was written from now, each with what it hashed to
  (`Section::Inputs`, `.iyimod` is **v51**), and every one still on the
  machine is asked again; one that is gone is not, because a boundary
  travels without its checkout and then the artifact is all there is. The
  module-path questions are not asked of a boundary at all — its
  `source_path` is the entry file the bind ran on, and asking anyway
  answered "the name moved" about a name that had never pointed there —
  and an edge `tool bind` wrote, which records a name and no hashes, is not
  read as a claim that the far end hashed to nothing. The refusal names
  the verb that rebuilds what it is about: `iyi bind` for a boundary,
  `--emit-iyimod` for a module of one's own. `bench/bind_roundtrip.sh`
  holds both directions — an edited shard is refused by name, and a
  boundary whose checkout is gone still builds — and that the inputs are
  the shard's own: "under the shard's directory" was a bare `starts_with?`
  on the dirname, so `lib/radix/src-extra/extra.cr` was recorded as
  `lib/radix/src`'s and the boundary went stale whenever the neighbour
  changed. The same rule decided which types and defs were the shard's;
  the directory carries its separator now, in every one of those places.

- **`Hashable` promised what `std/traits` had not loaded.** `hash_key`
  forwards to the value's own `hash`; the prelude defines `hash` for
  `Int32`, `String` and a handful more, every other integer's lives in
  `std/int` and both floats' in `std/float`, and `std/traits` imported
  neither while writing `impl Hashable` for all of them. So a program that
  imported `std/traits` got `Object#hash` — the type's id — for `Int8`,
  `Int16`, `UInt16`, `UInt32`, `Int128`, `UInt128`, `Float32` and
  `Float64`: `1_i16.hash == 31337_i16.hash` was true, one slot for every
  value of eight types, and a `Hash` or `Set` keyed on any of them probed
  linearly. The two imports are named in `std/traits` now — both, though
  `std/float` imports `std/int` itself, because an integer's hash is not a
  thing to reach through a float. `bench/std_exercise.iyi` asks all eight
  by value and keys a `Hash(Int16, Int32)` on two of them, and
  `bench/std_exercise.sh` proves the three ways it can fail: the tower's
  `hash` renamed away, both floats' renamed away, and the import taken out
  of `std/traits`.

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
  - `std/udp`: `Datagram[i]` panics unless `i` is 0, 1 or 2.
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

- **`std/regex` was quadratic, longest-match, and read half its syntax as
  letters.** The header promised RE2's contract and the engine restarted
  the NFA from every byte, so `a*c` on 20 KB of `a` was killed at twenty
  seconds; `a|ab` on `ab` answered `ab` where RE2 and Python answer `a`;
  `split` and `replace` dropped the byte after every empty match, so
  `x*` on `abc` replaced to `----` and `^` on `ab` ate the `a`; `\b`
  `\A` `\z` `\x41` `a{2}` were the literal letters and braces; `[\d]`
  was the letter `d`; `[\d-z]` was a range; `(?i)` was refused as
  lookaround and `a*?` as nothing to repeat. The engine is a Pike VM now
  — one pass, a thread list in priority order — so it is linear and
  leftmost-first, and the syntax the header lists is the syntax it has:
  `\b \B \A \z`, `\xHH`, `{n}` `{n,}` `{n,m}`, lazy quantifiers,
  `(?:…)` and named groups, `\d \w \s` inside classes. An empty match
  costs no text, by Python's rule. What is not regular is refused by its
  own name; a class holding a byte past ASCII is refused rather than
  matching half a character. `bench/std_regex_exercise.sh` holds it
  against Python's `re` on 2,214 pattern/subject pairs and a million
  bytes in one pass.

- **The scalar traits covered `Int32` and hashed a string by its length.**
  `List(Int64).sum` and `List(Float64).sum` did not compile, `Char` could
  not be sorted, and `"aa"` and `"bb"` were one `hash_key`. `Int64`,
  `UInt64`, `UInt8` and `Char` hashed as their type, so a `Hash` of them
  was one slot. `Cmp`/`Num`/`Hashable` now cover the prelude integers,
  `Float64`, `Float32`, the rest of the `std/int` tower, `String`, `Char`
  and `Bool`; `hash_key` is the value's `hash`. `bench/std_exercise.sh`
  holds it.

- **`Number#round(mode)` ignored the mode, and `RoundingMode` was not
  `pub`.** The default named `TIES_EVEN` in a scope that could not see
  it, so even naming the mode failed to compile. The enum is `pub` as
  `TiesEven` / `TiesAway` / `ToZero` / `ToPositive` / `ToNegative`; a
  float uses the mode, an integer is already whole, and `round` with no
  arguments stays the prelude's (ties away from zero).
  `bench/std_number_exercise.sh` holds it.

- **`File.exists?` on wasm32-wasi panicked with `File.read`'s sentence.**
  The predicate went through `path_open`, which this prelude does not
  have, and the panic named File rather than `exists?`. It is refused
  as `File.exists?` now, the way `File.delete` already was.
  `bench/sandbox_story.sh` holds it.

- **The std/io exercise asked `hexdump -C` for an oracle the CI image does
  not have.** The dump itself was already checked by the program; the gate
  then died on a missing command. The oracle is python3 now, the same
  encoding `hexdump -C` prints. `bench/std_io_exercise.sh` holds it.

- **Two shards that declared the same root wrote one artifact, and the
  second overwrote the first.** The name on disk is the namespace, so
  `alpha` and `beta` both saying `module Shared` both wrote
  `mods/shared.iyimod` and `iyi bind` exited 0. The second is refused:
  `beta also declares Shared, and alpha already wrote mods/shared.iyimod`.
  `bench/bind_roundtrip.sh` holds it.

- **Two generic-boundary specs asked `std/box` after that module shipped.**
  They delete the fixture and compile from the artifact; the import then
  finds the library's `std/box`, and the artifact is about the fixture.
  The fixtures are `pack/box`, a path the library does not own.
  `spec/compiler/iyimod_spec.cr` holds it.

- **The std exercises named `environ` and, on darwin, `pthread_join`.**
  Samples never called `Program.env` or joined a thread, so the floor
  did not see them. `std/colorize` and `std/path` walk the C runtime's
  `environ`; `IyiThread.join` on darwin is libSystem's `pthread_join`,
  the other half of `pthread_create` the collector already named.
  `bench/dependency_floor.sh` holds it.

- **A sibling `Std::Tuple` hid the prelude's `::Tuple`.** Looking `Tuple`
  up from `Std::Enumerable` walked to `Std` first, found the sibling
  unit, and the import wall refused a name the file never meant. Lookup
  skips a module namespace the writing file does not reach, so `::Tuple`
  is found; a name nothing else resolves is still refused with the
  wall's sentence. `spec/compiler/iyi_import_spec.cr` holds it.

- **A `case` over `Array(Any) | Hash(Any, Any)` sent an Array to the Hash
  arm.** The object-header census walked `ClassType`s; `Array(Any)` is a
  `GenericClassInstanceType` and was laid out headless while
  `object_type_id` still read the word under the object. The census asks
  the same two shapes it lays out. `spec/compiler/codegen/iyi_object_type_id_spec.cr`
  holds both that case and a `Foo(Int32)+` virtual call.

- **The commonest slips in a `.iyi` file were answered with the token the
  parser wanted.** One `end` too many was `expecting token 'EOF', not
  'end'`; a `[` or `{` or `(` left open was `expecting token ']', not
  'puts'` at the next line's first word, with nothing about the line the
  literal began on, and the file ending inside a parenthesis was
  `unexpected token: EOF`; `def 1` and `x.` at the end of a line were
  `expecting any of these tokens: IDENT, CONST, \`, <<, <, <=, ==, ...`,
  thirty-three of them; and a definition written with another language's
  keyword — `fn f(x : Int32) : Int32` — parsed as a call to `fn` and
  failed on its own return type with `unexpected token: ":"`. Each is a
  sentence now: `unexpected 'end': nothing is open for it to close`,
  `unexpected 'when': no \`case\` is open for it`, `expecting token ']',
  not 'puts'; the array literal that began at line 3 is still open`,
  `unterminated parenthesized expression` at the `(`, `expecting a name
  after 'def', not '1'`, `expecting a method name after '.', not the end
  of the file`, and for `fn`, `func` and `function`, that it is a call
  here and a function is `def name(args) : Type` — said at the `:` or at
  the stray `end`, whichever the parser meets. `and` and `or` are named
  as `&&` and `||`; `elif`, `let`, `var`, `println`, `console`, `len`,
  `str`, `int`, `input` and `null` get the spelling here beside the
  undefined-method line. A stray `)` inside an array literal was reported
  as `unterminated array literal` at the `[`; it is the `)` now, and
  "unterminated" is kept for the file ending inside one. The parser's
  specs hold every sentence.

- **`migrate` rewrote a file that does not parse, and dropped a require it
  could not answer without a word.** A `.cr` with a `def` and no `end` was
  written through line by line and noted as a module "left nested, which
  nothing outside can reach" — a finding about the wrong thing, on a file
  that is not Crystal yet. The tree is refused now, at the file, line and
  column, in the parser's words: `src/a.cr:4:1: does not parse as Crystal,
  so there is nothing to migrate yet: expecting 'end' to close the def
  that began at line 2`. And `require "./nope"` naming a file the tree
  does not have was dropped from the module silently, which is a module
  that compiles by accident or refuses in another module's name; it is a
  note now, one heading with three shapes — not there, outside the tree,
  a glob that matches nothing. `bench/migrate_gate.sh` holds both.

- **`bind --lib shard.yml` said there was no `shard.yml/` here.** A file
  where a directory goes was reported as a directory that is missing,
  with `run \`shards install\`` as the advice; `--mods shard.yml` died of
  `mkdir`'s own `shard.yml: File exists`, which names no flag; and an
  empty shard name was `no shard named  under lib/`, the two spaces its
  whole answer. Each is a sentence about the flag and the file now, in
  the family's words. `bench/verbs_exercise.sh` holds the three.

- **The language server answered a client's mistakes in its own name, and
  one of them took it down.** A frame whose body is JSON but not an object
  — `[]` — raised outside every rescue, and the server died with a
  backtrace on the one thing its value depends on, being there for the
  next keystroke. A request with no `params` was `-32603 Nil assertion
  failed` and one whose params were the wrong shape was `-32603` with the
  JSON library's sentence: the server blaming itself, in its own words,
  for the client's omission. A request with no `method` got nothing, and
  the client waited; a request before `initialize` was answered as if the
  root were the working directory; and `exit` without `shutdown` exited
  0. Each has the protocol's own code now — `-32600` for a frame that is
  no request and for a request with no method, `-32602` for params that
  are missing or misshapen, `-32002` before the handshake, exit 1 for an
  `exit` that skipped `shutdown` — and the session goes on after every
  one of them. `bench/lsp_session.py` holds all six.

- **`iyi doc Int32` had no arithmetic in it.** The surface printer left out
  every primitive, on the rule that what the compiler puts on every type
  (`allocate`) is not the program's to call — and `+`, `-`, `*`, `<`, `==`,
  `to_i64` and `to_f64` are primitives too, declared by the prelude's own
  `primitives.iyi`, so "what can an Int32 do" was answered with `abs`,
  `times` and `to_s`. A primitive the prelude declares is the type's own
  surface now, and the rule keeps out what has no line in any file:
  `Int32` prints its 115 signatures, `Proc` its `call`, and `allocate` and
  the two type-id hooks of Crystal's runtime ABI stay out.

- **`help nonesuch` said yes.** `iyi help nonesuch` printed the whole usage
  and exited 0, which reads as "that is a command", and `iyi help build`
  printed the same page, as if the verb had no help of its own; `iyi
  version extra` printed the version and dropped the word, the way
  `clear_cache extra` used to. A verb's help is the verb's now, a word
  that is no verb is said to be none, and `version` takes no arguments.
  Under both names.

- **The stack running out is a panic the program prints itself.** An
  infinite recursion faulted on its guard page, and the fault was the
  kernel's to report: `Segmentation fault`, exit 139, or `iyi run`'s guess
  that a memory fault is "nearly always the stack". A handler on an
  alternate signal stack — per thread, because the stack that overflowed
  has no room to run anything — reads the faulting address and the
  interrupted stack pointer, and a fault at the stack's own edge is `iyi:
  panic: stack overflow: the stack ran out, which is infinite or very
  deep recursion`, exit 1, on the main stack, a fiber's and a thread's.
  No defers run, on a stack that is gone, which is what Go and Rust
  answer the same fault. A fault anywhere else is handed back to the
  signal — a `Pointer` at nothing still dies of what it did, and `iyi
  run` still explains that death in iyi's words, now without guessing
  at the stack. Linux and darwin, with or without the collector;
  Windows and wasm32 keep the driver's sentence.

- **The directory fix moved a symptom the sweep gate pins.** `IyiIO` had
  grown a word for "the read failed", and `bench/sweep_exercise.sh`'s
  "sweep frees the live" proof — a patched prelude that frees live
  objects, expected to die at a named check — died a word later, at a
  stream, on every platform. The flag lives in the read limit now, as
  `-1`, which no read leaves: the stream is the size it was, and the
  proof dies where it did.

- **A typo in an `import` or a `using` was answered with a rule.** `import
  calc/ad` beside `calc/add.iyi` got the sentence about a module's path
  being its file's path, which read as if the rule were the problem; it
  says `Did you mean `calc/add`?` now, chosen from the `.iyi` files in the
  directory the import named under every root the import would be resolved
  from, `IYI_PATH` included (`import std/lst` names `std/list`). `using
  calc/add::{ad}` was told to add `pub` to a declaration that does not
  exist: the two mistakes behind "does not export" are told apart now — a
  name the module has and did not mark `pub` keeps the sentence about
  `pub`, and a name the module does not have at all gets `has no `ad`` and
  the nearest exported name.

- **`std/socket`'s `recv(-1)` died of arithmetic.** A negative count went
  into a `to_u64` and came back `arithmetic overflow`, a sentence about
  neither the count nor the call. `negative count: -1`, which is what the
  library says for one everywhere else.

- **`File.read` of a directory answered an empty file.** `open` takes a
  directory and `read` refuses it with EISDIR, and the refusal read as the
  end of the file: `File.read("adir")` was `""`, exit 0, from a call that
  had failed. `IyiIO` keeps a failed read apart from an ended one now, and
  `File.read` says `cannot read adir: it is a directory, or the read
  failed`. Paid for in prose, so the library sits on its ceiling still.

- **`"+5".to_i` was not a number.** The prelude's `to_i?` took `-` and
  refused `+`, while `"+5".to_f` and `std/text`'s `to_i?(base)` read it —
  one name, two answers, in the library whose rule is that a name means
  one thing. A leading `+` reads; a `+` alone is nil, as `-` alone is.

- **Two wasm jobs went red on a download.** The day github.com answered
  504 for one release asset for an hour, `curl -sSL | tar` saved the error
  page as the tarball and the job died of `gzip: stdin: not in gzip
  format`; in the other job wasmtime's installer failed inside its pipe and
  the gate reported `wasmtime not found` — two red jobs about a download,
  on a commit that changed no wasm. `scripts/install-wasm-toolchain.sh`
  fetches both halves now: it fails on an HTTP error instead of saving it,
  retries, falls back to the release API's own asset endpoint (which
  answered 200 on the same day the download URL answered 504 — the script
  was run against that outage, and installed), checks that what arrived
  is the archive it claims to be before extracting, and runs each tool once
  before saying it is installed. Both jobs restore the toolchain from
  `actions/cache`, keyed by the script that pins the versions, so a
  fetched toolchain is fetched once.

- **`rescue` compiled and never ran.** `begin ... rescue ... end` in an
  iyi file was accepted, and the program died of the panic with `caught`
  never printed: an error is a value the caller handles (SPEC.md III.1),
  and a panic unwinds by registry to a task boundary (III.1.4), through
  no handler on the way. `ensure` was the quieter half of the same lie —
  it ran on the ordinary exit and not on the panic, which is the half of
  cleanup that matters, and III.1.4 already says `defer` is the word. Both
  are refused now in an iyi file under iyi's library, each sentence naming
  what to write instead; a `.cr` source keeps its exceptions, and so does
  the handler `defer` itself lowers to.

- **More of Crystal's spellings are answered with iyi's.** `Time.now`
  said `undefined constant Time` and nothing about `import std/time`;
  `printf` and `"%d" % 1` said the prelude is small by rule and offered
  `--crystal`, when `import std/format` is the answer; `exit`, `gets`,
  `spawn` outside a group, `rand`, `.try` and `Int32::MAX` said "undefined"
  and stopped. Each names what this language has — `stdin.gets`,
  `group do |g| g.spawn`, the literal edges, `if x = a[0]?` — or says
  plainly that it has nothing yet, which is what `rand` gets.

- **`sprintf` printed the shortest digits, not the value's.** `%.0f` of
  1e23 answered `100000000000000000000000` where the double is
  99999999999999991611392; `%.0f` of 2^70, an integer the double holds
  exactly, answered `1180591620717411300000`; `%.20f` of 0.1 answered
  twenty zeros where the value's digits are `0.10000000000000000555`; and
  `%e` of the smallest denormal answered `5.000000e-324` for
  4.940656e-324 — at the default precision. The fixed and scientific
  formats took the shortest digits, the ones that round-trip, and padded
  them with zeros; past the seventeenth there was nothing there. Both are
  exact now: the value's integer scaled by the power of ten the precision
  asks for, divided, rounded half to even against the remainder, and
  rendered — every digit the double has, 2,500 random cases against
  Python's exact formatting with no disagreement. Precision is capped at
  400 places, which the printer's bignum holds for the largest double.
  Two refusals came with it: an argument no specifier took was dropped
  without a word (`sprintf("%d", 1, 2)`), and is `too many arguments for
  format string: 2 given, 1 used`; and a numeric verb given something
  that is not a number printed it as text — `%d` of `"abc"` was `abc` —
  and is `%d wants a number, and "abc" is a String`. A float under an
  integer verb is truncated, which is what Ruby, Python and Crystal
  answer to it.

- **`String#chop` cut a character in half.** `"hé".chop` dropped the last
  *byte*, and answered `h` plus half of `é` — two bytes that are not a
  string, which the next `puts` wrote to the terminal as such. It drops
  the last character now, however many bytes it is, and `\r\n` still goes
  as one.

- **`std/time` before year 0 was a day off, and its parser took dates that
  do not exist.** `Time.utc(-1, 1, 1)` printed `-0002-12-31`: the civil
  arithmetic is Hinnant's, whose `- 399` makes a truncating division floor
  for a negative year, and `days_from_civil` floored it a second time — so
  every date before the era came back one day early from the instant it
  was written as, while `civil_from_days` (the other direction) was right,
  which is how the two disagreed. `parse_rfc3339("2024-02-30T00:00:00Z")`
  answered March 1st, a date nobody wrote, where `Time.utc(2024, 2, 30)`
  refuses; the parser checks month, day, hour, minute and second the way
  the constructor does now, keeping RFC 3339's one allowance, the leap
  second, which reads as the instant it names. `to_rfc3339(12)` and
  `to_rfc3339(-1)` printed no fraction in silence — 0, 3, 6 or 9, or a
  refusal — and `DayOfWeek.new(8)` was Sunday, because `to_s` answered
  Sunday for whatever it did not recognise; a day is one of seven. The
  exercise round-trips every week from -800 to 800 and drives each
  refusal.

- **A program the kernel killed was reported in the kernel's words.** An
  infinite recursion runs the stack out and dies of a memory fault, and
  `iyi run` relayed `Process terminated because of an invalid memory
  access` — a sentence that sends a reader hunting for a null dereference
  in a language whose nil is a type. `iyi test` was worse: the test came
  back `fail` with nothing under it, the one failure that printed no
  evidence from the verb whose contract is that a failure prints its own.
  Both say what a memory fault nearly always is for an iyi program — the
  stack running out, infinite or very deep recursion — and what it is
  otherwise: a `Pointer` the program wrote, or a bug in the runtime that
  is ours. Any other signal is named rather than called "an unhandled
  signal". `test --json` carries the sentence in `output`; a `--crystal`
  program keeps Crystal's own handler and its own words.

- **A syntax error's `size` was `null`.** `check -f json` promises "file,
  line, column, size, message" as data, and a type error's `size` is
  always an integer; a syntax error's span is unknown and came out as
  `null` — the one field of the five that changed type, on the error
  class an agent meets first. It is `0` now, which is what the LSP
  already made of it.

- **`fix` on a file whose error is in the module it imports invited itself
  to be run again.** `iyi fix main.iyi` with the typo in `app/lib.iyi`
  printed main's frame, `undefined method 'helperr'` and `Did you mean
  'helper'?`, applied nothing and exited 1 — and never said that the edit
  it was quoting belongs to a file it does not edit. An agent reads that
  as "run it again". It names the file now — `the cause is in
  app/lib.iyi:8:3, which this run does not edit: run iyi fix app/lib.iyi`
  — and `--json` carries it as `cause` with the file, line and column,
  which the MCP tool's description says too. Only for a file of the
  program's own: a frame in the prelude or `std` is nobody's to fix from
  there, and points at nothing.

- **A panic `std` raised named `std`'s own line.** `each_slice(0)` died
  with `at …/src/std/enumerable.iyi:442` — the library's line, which is
  not where the bug is, and III.1.4 already says so for the prelude: a
  panic the prelude raises prints no line. The rule reads the path, and
  the path it read was `src/iyi/` alone. It reads `src/std/` too now, so
  the two halves of the library that ship beside the compiler answer the
  same way, and a `raise` in the program's own code still names its line.
  `bench/panics.sh` holds all three.

- **`--use-iyimod` handed an artifact said the artifact was not there.**
  `--use-iyimod mods/app/lib.iyimod` — the file, where its directory goes —
  answered `there is no mods/app/lib.iyimod` about the artifact the author
  had just been looking at. A file that is there is not a directory that is
  missing; the sentence says which it is.

- **An empty argument, wherever a shell can put one.** `"$FILE"` with
  `FILE` unset lands as `""`, and every place that took one answered with
  a hole where the name goes — `no such file: `, `no daemon listening on `,
  `Error:  is a directory, not a source file` — or worse. `iyi tool format
  ""` normalised to `./` and rewrote every source under the working
  directory, in place. `iyi check --affected ""` took the working directory
  as the changed file, and `test --affected ""` ran everything with ` is
  not there` as its reason. `--prelude ""` went looking for a file called
  nothing and came back with Crystal's advice about shards. `IYI_PATH=""`
  is a list with nothing in it, and the missing-prelude note read
  `Searched, in order:` followed by nothing. Each is a sentence now, the
  same shape `-o ""` and `IYI_CACHE_DIR=""` already got: the entry file
  for `run`, `build`, `check` and `vet`; `fix`, `test` and `mod dump`'s
  file; `--emit-iyimod`, `--use-iyimod`, `--prelude`, `--affected` and
  `--socket`; `tool format`'s path; and the search-path note says
  `IYI_PATH is set and empty`. No path at all still means the working
  directory where it did, on purpose; `""` is not that.

- **`-o` naming the source replaced it with the binary.** `iyi build -o
  good.iyi good.iyi` — one word, typed twice — read the source, built it
  and linked the executable over it: the program's only copy was 12 KB of
  ELF, at exit 0. The compiler checked for this only on the name it
  derives itself (`build foo` from a `foo` with no extension); a name the
  author typed was never asked. It is refused before anything runs now,
  naming the file it would have replaced, and a module the entry imports —
  the same mistake one step removed — is refused once the build knows what
  it read, before the first object is written.

- **`check --affected` on a deleted module answered "all compile".** A
  deletion is the one change certain to break every importer, and
  `iyi check --affected app/lib.iyi` with the file gone said `0 consumer(s)
  checked, all compile`, exit 0 — while `user.iyi` still imported it. The
  import closure is computed by parsing, and it dropped any import it could
  not open, so a deleted file was in nobody's closure. An import names a
  path (SPEC.md R-1), and the path outlives the file: the closure keeps it
  now, so the importers are selected, compiled alone, and each says `can't
  find module 'app/lib'`. A changed file that is not there is also said
  out loud — `app/lib.iyi is not there, so the consumers are whoever
  imports that path`, `affected_not_found` in `--json` — because a typo
  and a deletion look the same from here and "0 consumers, all compile" on
  a typo is a clean verdict about nothing. A directory is refused as a
  changed file, as `test --affected` already did.

- **`test --timeout 0` killed every test.** Zero and negative deadlines
  were taken, and every test came back `hung: killed at -1.0s` — a verdict
  about the flag, printed as one about the tests, and a run an agent
  computing a deadline from a budget can produce. A wait is a positive,
  finite number of seconds; `0`, `-1`, `inf` and `nan` are refused by
  name.

- **A permission gate could not fail as root.**
  `bench/verbs_exercise.sh` drove "an output directory that will not take
  the file" at a `chmod 500` directory, and the write bit does not bite for
  root — which is what CI runs as, in a container. So the build wrote its
  program there, exited 0, and the arm reported "nothing was refused" on
  every run since it was added, about a compiler that was answering
  correctly. The directory is the first one `access(W_OK)` refuses now,
  which is the question the compiler asks: the mode-500 one where the bit
  binds, a read-only filesystem where it does not. The unreadable-module
  case further down the same file reads `/proc/self/mem` for the same
  reason.

- **`iyi clear_cache` deleted the project.** `IYI_CACHE_DIR=""` is what a
  shell makes of `IYI_CACHE_DIR="$DIR"` with `DIR` unset, and
  `File.expand_path("")` is the working directory: a build dropped its
  `.bc` and `.o` files, its linker probe and its link templates beside the
  source under names nobody typed, and `clear_cache` — which is `rm -rf`
  on that answer — took the directory it was run in, sources and notes and
  all, at exit 0. The same shell accident as `-o ""` further down this
  list, and the same answer: a blank one names no directory, so it is
  refused before anything is written or removed.

- **A cache directory that cannot be one was skipped in silence.**
  `IYI_CACHE_DIR` is the first of a list of candidates and the list falls
  through, so pointing it at a file, or at a directory with no write bit,
  meant the build went on and wrote its megabytes into `~/.cache/iyi` —
  which is the whole thing the variable was set to stop. The defaults
  below it still fall through, because falling through defaults is what a
  default is for; a path the author named is an instruction, and a refusal
  names it. Both of these refusals spell the variable the author actually set:
  `CRYSTAL_CACHE_DIR` reads the same (`Config.env`), and a sentence about
  `IYI_CACHE_DIR` to somebody who set the other one names a variable they
  do not have.

- **A corrupted object in the cache was linked forever.** The cache
  guarded one shape of damage — a `.o` of zero bytes, "if the user
  cancelled a previous compilation" — and the cache produces others: a
  process killed between `emit_obj` and `File.rename`, a full disk,
  another build's cleanup deleting this one's directory mid-codegen, which
  is why `CacheDir#directory_in_use?` exists. What those leave is a short
  file, or a file of something else, and every later build handed it to
  the linker again: `ld.lld: error: <file>:1: unknown directive: garbage`,
  about a source the author had not touched, until somebody guessed at
  `clear_cache`. A cached object whose first four bytes are not this
  target's is a miss now — ELF, Mach-O thin or fat either endianness,
  wasm, and COFF by the one thing its first two bytes must be, the
  target's machine number (`64 86` for x86_64, `64 aa` for aarch64, read
  off what LLVM writes) — and the unit recompiles, on one line saying
  which file and why. A guess that refused a good object would recompile
  the world on every build, which is why `bench/verbs_exercise.sh`
  asserts both halves, the corrupted object that is rebuilt and the
  `--stats` line that says an intact cache is reused whole.

- **The MCP server answered two mistakes with the wrong one.** A
  `tools/call` with no `name` came back `unknown tool: ` — a sentence
  about a tool whose name is nothing, which reads as a tool this server
  has and the caller misspelled. What was missing was the field, so the
  field is what it says, with the five names an agent may have meant. A
  request with no `method` at all came back `-32601 method not found`,
  which tells a client to ask for something else; JSON-RPC spells "what
  you sent is not a request" `-32600`, and the two mean different things
  to the code reading them. An unknown tool name carries the catalogue
  too, because a caller that guessed wrong has no other way to learn the
  five and the list is five words long. `bench/agent_loop.py` holds all
  three.

- **`iyi tool format --check` passed on a path that is not there.** It
  printed `file or directory does not exist: ./nosuch.iyi` and exited 0,
  so `iyi tool format --check "$FILE" || exit 1` — the shape every CI
  line takes — passed on a typo, which is the one case where the check
  certainly did not run. It is a failure now, with the same sentence.

- **A crash pointed at the wrong project.** The compiler's catch-all
  said "you've found a bug in the Crystal compiler" with
  `crystal-lang/crystal/issues`, and the formatter's told the reader to
  run `crystal tool format --show-backtrace` — a command they may not
  have, about a repository that does not ship the binary that just
  crashed on them. Both name this compiler and `iyilang/iyi` now, and
  the formatter's advice repeats the name the binary was invoked under.

- **A missing prelude was answered with the other language's advice.**
  `IYI_PATH=/nowhere iyi build x.iyi` printed `can't find file
  'iyi/prelude'` and then asked whether the author had run `shards
  install` and whether they were "running the compiler in the same
  directory as your shard.yml" — to a program in a language with no
  shards, whose `require` is refused by a rule three lines earlier in the
  same file, and whose `import` is a different node resolved elsewhere.
  What reaches that path is the prelude this compiler injected, and a
  prelude is a file on the search path, so the search path is what it
  prints: the entries in order, and that unsetting `IYI_PATH` uses the one
  the compiler was built with. The note asks for both halves — an injected
  prelude require *and* a program whose library is iyi's — because each
  alone names the wrong language: every prelude require carries that flag,
  Crystal's included, and a bare `Program` carries iyi's library by
  default, which is what made a `require` written in a `.cr` file answer
  with iyi's search path instead of Crystal's advice about shards.

- **`-o` with nothing behind it wrote where it liked.** `-o ""` is what a
  shell makes of `-o "$OUT"` with `OUT` unset, and it meant the current
  directory: the program landed beside its source under a name nobody
  typed, or `ld.lld: error: cannot open output file <cwd>: Is a
  directory` after a whole compilation had been paid for. It takes a
  path now. An output directory that exists but will not take the file
  was the same three lines of linker, for a permission bit; that is a
  sentence before the compile starts, like the missing-directory case
  beside it.

- **A one-sample perf budget failed a commit that touched no
  allocator.** `bench/arena_exercise.sh` asserts the size-class arena
  costs no more than 2.5× a bump pointer measured in the same run, which
  is the right shape — a regression multiplies — but it compared single
  samples, and a shared three-core darwin runner gave the bump pointer
  its best run (13 ns) next to one of the arena's worst (44). It takes
  the minimum of three runs of each now, which is this repository's
  answer to noise everywhere else it measures time.

- **Any malformed frame killed the build daemon.** `daemon_accept` read
  its request with no rescue, so anything a client could do wrong went
  wrong all the way out of the accept loop and took the daemon down with
  the analysed prelude that is the entire reason to run one. Connecting
  and closing without speaking — `iyi daemon build` under Ctrl-C, or
  anything that probes a socket — was `Error: End of file reached`,
  exit 1. A length header with nothing behind it, the same. A body that
  is not JSON was a `JSON::ParseException` with a stack trace; a 4 GB
  length header was `Bytes.new(4294967295)` and an `OverflowError`
  through the allocator; a request without `cwd` was `Missing hash key`.
  Worst of the set: a refusal written to a client that had already hung
  up is EPIPE, and EPIPE reaching `Command#run` means `::exit 0` — the
  `mod dump | head` rule, right for a command writing to a pipe and
  fatal for a server writing to one of its clients. The daemon exited
  *successfully*, mid-sentence, and the next build said "no daemon
  listening". One client's mistake is one client's mistake now: the
  frame reader has a bound (8 MB, past `ARG_MAX` on both platforms), a
  request that is not a build request is refused in a sentence, a client
  that hangs up costs one log line, and a connection that says nothing
  costs none — `daemon start` asks that way. Nine cases in
  `bench/daemon_protocol.py`, on Linux and on macOS.

- **A second `iyi daemon start` stole the first one's socket.**
  `File.delete?(path)` ran unconditionally before `UNIXServer.new`, so
  the incumbent's address was unlinked and a new daemon listened on a new
  socket with the same name. The first kept running: a compiler and a
  warm prelude behind a socket with no name, unreachable by any client
  and never reaped. It refuses now, naming the path, and a stale socket
  file left by a killed daemon is still taken over — the difference is
  whether anyone answers on it.

- **`--socket` with nothing behind it used the default.** `iyi daemon
  build --socket` talked to whatever daemon was running in `~/.cache`,
  and `--socket -o out.bin` read the next flag as a path. Both are
  refused by name, as `--out`, `--mods`, `--lib` and `--affected`
  already were. A directory named as a socket answered "no daemon
  listening on <dir>", which is true and points at the wrong thing —
  nothing can ever listen there — and a stale socket *file* got the same
  sentence, though its remedy is to remove the file. Both say what they
  are now.

- **`iyi test --affected` turned its discount off in silence.** A changed
  file that no longer exists cannot be proven untouched by anything, so
  the flag correctly falls back to running everything — but it did so
  without a word, and a mistyped path produced a full run that reads
  exactly like a selective one. It names the file now, in text and as
  `affected_not_found` in `--json`. `--affected .` took a directory and
  did the same thing; `iyi test --nonesuch .` reported a flag as a
  missing path. Both refuse by name. Two steps in `bench/test_verb.sh`.

- **The language server answered "nothing" where the protocol has a
  word.** Five edges, each probed against a running server. An unknown
  method came back `result: null`, which a client cannot tell from "there
  is nothing at that position" — and -32601 is how it learns to stop
  asking, so the comment that called an empty answer friendlier had it
  backwards. A frame whose body is not JSON was dropped in silence, and
  the request inside it was never answered: the client waits forever,
  where `iyi mcp` has answered -32700 all along. A file the client named
  that is not there came back -32603 — "this server is broken" — carrying
  the runtime's own `Error opening file with mode 'r'`, the wording the
  command line stopped using earlier in this release. A request with no
  `textDocument` came back with the JSON library's `Missing hash key`. And
  a request after `shutdown` was half answered instead of refused. They
  are -32601, -32700, -32602, -32602 and -32600 now, each with a sentence,
  and five cases in `bench/lsp_session.py` hold them.
- **The flag an agent branches on was the constant `false`.** `iyi mcp`
  serves `check`, `fix`, `context`, `test` and `doc` as tools, and every
  result said `isError: false` — a missing file, a directory, bytes that
  are not text, an unknown prelude type and a missing test directory all
  came back as success envelopes whose text began with "Error:". A harness
  that reads the protocol's own error flag read them as answers, and for
  `check`, whose contract is "[] when clean, else the errors as data", it
  parsed a sentence as JSON. The exit code cannot decide it alone — `check`
  exits 1 when the file has diagnostics and `test` exits 1 when a test
  fails, and both of those are answers — so the question asked now is
  whether the tool produced the shape it promises: the four JSON tools
  answered when their output parses, `doc` when it exits 0.
- **Colour in output nobody could see.** Three of the compiler's error
  paths — a source file that is not text, a linker it cannot execute, a
  library it cannot find — coloured whatever they were writing into, while
  the diagnostic path beside them has asked `Colorize.default_enabled?`
  all along. So `iyi check` down a pipe answered `\e[31;1mError: …`, and
  those bytes reached the JSON an agent parses, every redirected log and
  every CI transcript. The same question is asked now, of the streams the
  compiler was given, which also silences it for the in-memory ones `doc`
  compiles into. Four cases in `bench/agent_loop.py` hold both halves.
- **The numbers the docs quote from an instrument had no keeper.**
  `bench/doc_numbers.py` measures the tree and holds every *counted* number
  to it; the eleven scripts that produce the *measured* ones — seconds,
  megabytes, ratios — run nowhere, so a published figure could stop being
  true in silence, and four had. `GC_DESIGN.md`'s allocator table named a
  column `-Dgc_iyi`, a flag the script stopped passing when the flip that
  table argued for made the collector the default and renamed the bump
  pointer `-Dgc_none`: the header had swapped meaning with the column
  beside it, so nobody could re-run the measurement it cites. SPEC.md's own
  "numbers that are current" table said the compiler was 84,068 lines where
  the tree has 109,815 and the same file says so forty lines later, said
  the edit-loop project was 7,208 lines where the generator writes 7,207
  (in seven places, while README.md said 7,207 in five), and said nine
  samples of which five rebuild from artifacts where there are
  twenty-seven and six. `bench/machine_probe.py`, the script README.md
  points a reader at to attach a machine to a figure, was reporting a
  *failed* build as a 0.009 s front end: it never read the exit code and it
  set `IYI_PATH` for a binary that answers `CRYSTAL_PATH` — the same defect
  two of its siblings had fixed and it had not.
  `bench/measured_numbers.py` is the keeper for what a shared runner can
  check: not the seconds, which the same binary reads as 0.048 s and
  0.109 s minutes apart, but the experiment — that every row, column, size
  and parameter a sentence quotes is one its instrument still produces. It
  names, in its own output, the nine figures it cannot check and why.
  `machine_probe.py` prints the attachment those need: CPU, cores, memory,
  OS, kernel, libc, LLVM, the compiler's version line with its commit, the
  checkout's revision, the date and the command — and refuses by name
  rather than print a timing for a build that failed.
- **The two things `Enumerable` would not do, and the one `Slice` and
  `List` could not reach.** `each_` takes a block everywhere in that trait
  — `each`, `each_with_index`, `each_with_object`, `each_cons_pair`,
  `each_step` — except `each_slice` and `each_cons`, which refused one and
  materialised `Array(Array(Elem))` instead: every window allocated up
  front, which is the cost a block exists to avoid, and a shape `Indexable`
  had had all along. Both take a block now, and still answer with the array
  for a caller that wants them all. And `std/iterator`'s header says a
  concrete collection provides its own iterator constructor and names
  `Slice` twice as one that should; neither `Slice` nor `List` had one, so
  the only route from either into the lazy tower was `to_a`, copying the
  whole sequence — the cost the tower exists to avoid. `SliceIterator` and
  `ListIterator` live in their own modules, where that header says they
  belong.
- **The verbs nothing had ever probed.** `bench/verbs_exercise.sh` drove
  seven of the eighteen commands; the other eleven had never been handed a
  mistake. `iyi fix` on bytes that are not text exited 1 printing **nothing
  at all** — the compiler's refusal went into the `IO::Memory` `fix` hands
  it and the process died silently, which is the only thing worse than a
  refusal in the wrong words. The same verb called a directory a missing
  file, called an unknown flag a missing file, and fixed the first of two
  paths while dropping the second at exit 0. `iyi vet` with no file printed
  `Usage: iyi tool unreachable`, a command nobody typed, because the
  analysis it delegates to named itself. `iyi env NOPE` printed a blank
  line at exit 0 — indistinguishable from a variable that is set and empty
  — and `iyi clear_cache extra` and `iyi mcp --nonesuch` swallowed what
  they were handed, the second by starting a server the caller had not
  configured. Each answers with one sentence at a non-zero exit now, and
  the nine cases are in the gate.
- **"No such file" about a path that is right there.** Every verb that
  takes an entry file came through one place — `gather_sources` — and that
  place said `no such file` for a directory, so the reader ran `ls`, found
  it, and learned nothing. `run`, `build`, `check` and `vet` now say
  `<path> is a directory, not a source file`, which is the sentence `doc`,
  `mod dump`, `mod diff`, `mod context` and `fix` give, all of them
  unified on `is a directory, not a <thing>`.
- **`make format` failed on code this repository does not own.** The
  formatter's `-e lib` default is anchored at the top level, so the
  `shards install` that `samples/crystal/kemal` asks for put another
  project's source one directory down and the check walked straight into
  it: green in CI, red for anyone who had followed the sample. The target
  formats what git says the repository owns — tracked, plus new files that
  are not ignored — which keeps `bench/migrate_fixture/lib`, a fixture
  this repository does own, in the check. CI runs `make format check=1`
  now rather than its own directory list, so the command that gates the
  branch and the command a developer runs cannot drift apart again.
- **Four gates that ran nowhere, and one of them had gone stale in the
  dark.** `bench/windows_exercise.sh`, `bench/wasm32_exercise.sh`,
  `bench/sandbox_story.sh` and `bench/wasm_concurrency_probe.sh` were
  never named in the workflow. Three of them had their *positive* half
  copied into it by hand — link the exercise, run it, grep the last line —
  which is the half that cannot fail; the patched-prelude proofs that make
  them gates ran on nobody's machine. The fourth ran nowhere at all, and
  its first step had rotted meanwhile: it asserted that wasmtime refuses
  `-W stack-switching=y`, which is what Cranelift answers on arm64, where
  the file was written, and not on x86_64, where the same wasmtime 48.0.1
  accepts the flag and runs the module. That step records what the host
  answered now, with the reason the answer does not matter (nothing in
  wasi-sdk can emit the instruction), and the file's iyi-owned check — the
  compiler refusing `group` for wasm32-wasi — runs even where there is no
  toolchain, which is what kept the whole file out of CI. All four run
  now: the Windows collector driver beside the other five collector gates
  (it needs no Windows — a host run, a cross-compile that stops at the
  object, three proofs), and the three wasm drivers against the tarball's
  compiler, because the container that can build a compiler cannot run
  wasmtime and the runner that runs wasmtime cannot build one. The
  transcriptions are gone, and so are the four cross-compiled objects they
  were reading.
- **`mod context` dropped the flag it was handed.** The context pack is
  the verb a model calls, and it read `--json` and `--budget` only *before*
  the path: `iyi mod context file.iyi --json` printed the text pack and
  exited 0, so whatever was reading JSON found out somewhere else. A
  second path went the same way, an unknown flag was reported as a missing
  `.iyi` file, and a directory was "no such file". It reads its arguments
  the way `mod dump` and `mod diff` do now, and three cases in
  `bench/verbs_exercise.sh` hold it.
- **`max` without `max?`.** `std/enumerable` states the library's naming
  rule and names this very pair as the exemplar — `?` is the nilable one,
  the plain name raises, which is what iyi does instead of Crystal's
  `max!`/`index!` now that `!` is out of identifiers (III.1.7) — and
  `std/iterator` keeps it for `first?`/`first` and `find?`/`find` and then
  defines `max` and `min` with no halves. On an iterator "the largest, if
  there is one" could only be asked by taking a panic. Both pairs are whole
  now, and `Iterator#any?` — the one method in the tower that consumes
  *part* of its receiver, one element, silently — says so where it is
  defined.
- **The two traits were wired to nothing.** `Slice` wrote `unsafe_fetch`
  with the comment "required for Indexable" and never implemented
  `Indexable`, so the most random-access type in the library — a pointer
  with a size — had no `last`, `fetch`, `values_at`, `each_index`,
  `reverse_each`, `bsearch`, `dig`, `equals?`, `rindex` or `sample`, all of
  which `Array` has through that same trait. In the other direction
  `Indexable`'s header claimed its `each` "satisfies Enumerable's abstract
  def each requirement" — it does not, and SPEC.md II.6 says so and
  prescribes the pair: `impl Indexable for T`, then `impl Enumerable for T`
  answering only `type Elem`. The second line was never written for
  `Array`, so `slice.zip(array)` did not compile ("Array(Int32) does not
  implement Enumerable, required by `O` in `zip`") and `array.take(2)` did
  not exist. Both lines exist now, the header says what is true, and six
  assertions in `bench/std_exercise.iyi` hold them.
- **A `List` was not equal to itself.** `List` is the shareable value of
  SPEC.md III.4.7 — the thing handed between tasks — and it had no `==`, so
  `Object`'s answered: the constant `false`. `list == list` was **false**,
  `[list].includes?(list)` was false, `uniq` folded nothing, and every
  `List(Int32)` hashed to its type id, so a `Hash` keyed by lists put them
  all in one slot. This is the defect the prelude already diagnosed and
  fixed for `Tuple`, one library up, written out at `object.iyi:111-120`.
  `List` now has element-wise `==`, a `hash` that mixes its elements the
  way `Indexable#hash` does, a `to_s` that prints them (it printed
  `Std::List::List(Int32)`), and `[]`/`[]?` beside the `at` it had — it was
  the one sequence in the library that could not be indexed with brackets
  or asked for an element that might not be there. `Slice` had the other
  half of the pair: element-wise `==` since it was written, and no `hash`
  to follow it.
- **One mistake, six sentences.** Asking an empty collection for its first
  element panicked with `first of an empty array` (Array), `first of an
  empty collection` (Indexable) or the bare word `empty` (Enumerable and
  Iterator, where `max`, `min`, `max_by`, `min_by`, `minmax` and their
  `_of` and `_by` siblings all raised the same unattributable word). An
  index past the end said `index 5 out of range for 3 elements` (Array),
  `index out of bounds: 5 for size 3` (Slice) or `index out of range`
  (Indexable — naming neither the index nor the size, the one message the
  mistake could not be read from). A negative count was refused by
  `Array#first(n)` and answered with `[]` by `Enumerable#take`, which is
  what `first(n)` forwards to. A zero step said `step size must be
  positive` from `Enumerable` and `step size must be >= 1` from inside an
  iterator adaptor the caller never named — the leftover of the
  `each_slice(0)` sweep two entries down. Each of those is now one
  sentence, the same one, from whichever tower answers, and `step` refuses
  at the door the way its neighbours do. `Slice` also called a negative
  count "out of bounds" and printed an exclusive range as an inclusive one
  (`0...9` reported as `0..9`, in the one message whose whole subject is
  the difference), and `Enumerable#join` made the separator mandatory where
  `Array#join` and `Indexable#join` default it, so `slice.join` was a
  compile error. Gates: eleven assertions and seven panics across
  `bench/std_exercise.{iyi,sh}`, and the slice gate's two pinned bounds
  phrases moved to the wording the three sequences now share.
- **A refusal that escaped its own handler.** `Command#run`'s `rescue ex :
  IO::Error` clause turned EPIPE into a clean exit and `raise ex`'d
  everything else — and a `raise` inside a rescue clause is not caught by
  the later clauses of the same `begin`, so every `File::Error` left the
  process as a raw `Unhandled exception:` with a backtrace, past the
  catch-all that exists to prevent exactly that. It is answered in the
  clause now, as the path and the reason: `Error: prog.iyi: Permission
  denied`. The read and the lexer inside `import_file` moved inside the
  guard with it, so an imported module of bytes that are not text says
  "file 'X' is not a valid iyi source file" at the `import` line that asked
  for it, the same sentence an entry file has had since the verbs gate was
  written.
- **`iyi doc` answered about a module that does not exist.** It took the
  module's name from its file's basename, so `iyi doc deep/inner/thing.iyi`
  imported `thing`, resolved nothing of the sort, and printed `module
  thing` with an empty surface at exit 0 — a documented module reported as
  exporting nothing. The name comes from the `module` header now, the
  search path from the directory that header is relative to, and a file
  whose header is not its path is refused by R-1 rather than half answered.
  Three more from the same verb: bytes that are not text crashed with
  twelve frames and an invitation to open an issue against the *other*
  language; a module that does not compile answered `while importing "X"`,
  the wrapper rather than the diagnostic inside it (a `TypeException`
  carries what it wrapped in `inner`, not in `cause`); and a directory
  named `x.iyimod` was reported as "no such file", which sends the reader
  to `ls`, where they find it.
- **`migrate`, `bind` and `mod dump` took what they were not given.**
  `iyi migrate` read `.cr` files with `File.read`, which substitutes U+FFFD
  for bytes that are not text and never says so: a file of four stray bytes
  was *rewritten* and reported as `2 files → 2 modules`, exit 0. A
  migration copies bytes, so it refuses the file by name. `--out` and
  `--mods` tested only for end-of-argv, so `iyi migrate tree --out --check`
  created a directory named `--check` and exited 0; a value that begins
  with `-` is now named as the flag it is. `iyi mod dump FILE --json`
  printed prose and exited 0 because flags were read only before the path;
  both flags are read in either position, a second path is refused by name,
  and asking for both outputs at once is refused rather than half served.
  And an artifact the process cannot open said it was damaged and should be
  rebuilt — the one remedy that cannot fix a permission bit — with the
  Crystal exception class in the sentence; it says what happened instead.
- **The gate they should have been in.** `bench/verbs_exercise.sh` covered
  `build`, `run`, `mod dump` and the daemon, and never invoked `doc`,
  `migrate` or `bind` — which is how eight defects survived it. Thirteen
  cases and two answers were added, including the one that proves a refused
  migration writes nothing. Its own `refuses` helper could not check a
  phrase beginning with `--`: `grep -qF "$phrase"` read the phrase as its
  own options, so the two flag cases failed until it grew a `--`.
- **`"ab" * -3` answered `""`.** `String#[](start, count)` has said for a
  long time that a negative count "is not a wrap, it is a mistake"; `*` said
  nothing and handed back the empty string, where Crystal raises — one name
  meaning two things, which is what III.1.7a is about. It refuses by name
  now, and so does a repeat that does not fit: `"abcd" * 600_000_000`
  panicked with "arithmetic overflow", naming the machine's adder rather
  than the string, and the size is a division checked before the multiply.
  Paid for at the prelude's 3,734-line ceiling by folding `rjust` and
  `ljust`'s pad-less overloads into a default argument — two methods for one
  question — so the library is still exactly 3,734 lines. Four edges of the
  prelude's own `String` are in `bench/std_text_exercise.sh`, which CI
  reaches through `bench/std_exercise.sh`'s sibling walk.
- **Three ways a command answered with the compiler's guts instead of a
  sentence.** `iyi daemon start --socket <a path longer than the kernel
  takes>` died with "Path size exceeds the maximum size of 107 bytes
  (ArgumentError)" and a backtrace through `src/socket/address.cr` — a file
  the author never opened, about a socket they did ask for. A unix socket's
  path is a fixed field in `sockaddr_un`, so the length is checked where the
  path is decided and every verb that takes `--socket` gets the same
  refusal, naming the path, its length and the machine's limit. A `.iyi`
  file of bytes that are not text was reported as "not a valid **Crystal**
  source file" — the other language's name for this one's file, in the
  compiler and in the formatter both; each names the language the file is
  written in now. And `-o nodir/prog` reached `ld.lld`, which answered
  "cannot open output file" from a program the author did not run, after a
  whole compilation had been paid for; the directory is checked before the
  work starts.
- **A refusal about the command line waited on the machine.** `iyi daemon
  start` on an ordinary multi-threaded compiler execs the single-threaded
  server binary, and it went looking for that binary before it read the
  arguments it was about to hand over: on a runner with no `iyi-daemon`
  built, a 147-byte `--socket` came back as a page about `make iyi-daemon`
  that never mentioned the socket. Whether a path fits in `sockaddr_un` is
  not a question about this machine, so it is answered first — and reading
  `--socket` there does not consume it, so the server still gets the flag
  and still listens where it was told.
- **And the verbs have a gate.** `bench/verbs_exercise.sh` drives seventeen
  mistakes a person makes at the command line — an unknown verb, an unknown
  flag, a missing file, a directory as the entry, two module headers,
  unreadable bytes, a missing output directory, a truncated artifact dumped
  and imported, a flipped byte, a source file dumped as an artifact, an
  artifact directory that is not there, an over-long socket path to three
  verbs, a server binary that is not there, a daemon that is not listening
  — and asserts the same three things of each: a non-zero exit, a phrase
  that names what was asked for, and *no* trace. The trace detector is
  proved against a recording of the daemon crash above, because a check
  that cannot fail is not a check.
- **A proof that raced.** The hidden-buffer arm of `bench/server_load.sh`
  needs the freed chunk handed to a canary *and* the kernel writing epoll's
  answers into it before the run ends, and two hundred connections did both
  on every machine that wrote the file — then, once, on a loaded CI runner,
  neither: the buffer was freed and simply never reused, so the proof went
  green and proved nothing. Measured on a machine held at sixteen times its
  cores, four of twenty-four runs survived at two hundred rounds, none of
  twenty-four at a thousand, none of twelve at two thousand. That arm runs
  at two thousand now. The claim is unchanged and so is the cost: a run
  that dies does it in the first collections.
- **One tree of `.iyi` files nothing checked.** The formatter gate reads
  `src spec samples`, so `bench` — thirty-two exercises, the gates
  themselves — was never checked and had drifted: `bench/server_load.iyi`
  carried unaligned constants and continuation lines the formatter indents
  differently. It is formatted, and `bench` is in the gate and in `make
  format` now.
- **A range that ends at the type's maximum stepped past it.** The inclusive
  walk was `while value <= @end` followed by `value = value + 1`, so the
  last step left the type on the checked `+` and
  `(2147483645..2147483647).each` panicked with "arithmetic overflow" at the
  value it was asked to yield last — `Int64`'s maximum too. It stops *at*
  the end now and yields it there. `Array(Int32).new(-1)` was the same shape
  of message about the wrong thing: a negative capacity reached `to_u64` and
  panicked about arithmetic, where "negative capacity" is what happened.
  Both are in `bench/collections_exercise.sh`, one of them with a proof that
  puts the old step back and watches the overflow return.
- **`%f` and `%e` rounded the shortest decimal, not the number.** Two
  corrections, both measured against the other language, C and Python over
  908 cases. A tie went *away from zero*, so `%.1f` of 0.25 answered 0.3 and
  `%.0f` of 2.5 answered 3 where every reference answers 0.2 and 2 — a tie
  goes to the even digit. And a tie was read off the value's *shortest*
  decimal, which is not the value: 2.345 is stored a shade above and 1.015 a
  shade below, so `%.2f` answered 2.34 and 1.02 against 2.35 and 1.01. The
  tie is now decided by asking the number — `f * 2^e` against the tie
  decimal, both sides scaled to integers and compared with the prelude's own
  bignum — and only when the digits actually say "half", so the ordinary
  path is unchanged. 568 fixed-point cases and 340 exponent cases match the
  references exactly. `bench/format_exercise.iyi` pins the fourteen that
  moved, and the check that read `%.0f` of 2.5 as "3" — a deviation from
  every reference, pinned as if it were a rule — now reads 2.
- **A year before the era printed as `000-1-01-01`.** `pad4` filled a
  four-character field with zeros in front of a minus sign, so the sign
  landed inside the year. The conversions were right all along — every epoch
  from year -100 to 9999 round-trips through `Time.unix`/`to_unix` — so this
  was the printing alone: ISO 8601 spells it `-0001`, and now so does this.
- **Ten text methods panicked on a character above ASCII.** `"a☃b".index('☃')`
  died of "arithmetic overflow" — a sentence about arithmetic for a question
  about text — because a `Char` was narrowed to one byte through a *checked*
  convert. In the prelude that was `index`, `split`, `starts_with?`, `chomp`
  and `lchop`; in `src/std/text.iyi` it was `lstrip`, `rstrip`,
  `ends_with?`, `split`, `index`, `rindex`, `delete`, `squeeze` and `count`
  as well. Each compares the character's own bytes now, which is what
  `Char#to_s` writes and what the string holds. Two more answered wrongly
  rather than panicking: `center` padded by bytes, so `"héllo".center(9)`
  came back eight characters wide, and `tr` used a 256-entry byte table, so
  `"a☃".tr("☃", "x")` answered `"axxx"` — one `x` per byte of the character
  it was asked to replace once. Both count characters now, and `%s`'s width
  and precision in `src/std/format.iyi` do too, which is the same decision
  the prelude's `ljust`/`rjust` made.
- **An array appended to itself grew until the arithmetic stopped it.**
  `concat` walked *other*'s size with `each` while `<<` grew it, so
  `[1, 2].concat(itself)` never reached the end: it grew the buffer until
  the capacity arithmetic overflowed. The length is read once now, so it is
  a doubling. `bench/collections_exercise.sh` is the gate it arrived with —
  `Array`, `Hash` and `Set` at their edges, eight panics with names and
  eight broken methods of a copied prelude.
- **Two checked-arithmetic panics in the trait floor.** `Indexable#hash`
  mixed with `31 * h + …` on the *checked* operators, so a collection long
  enough to leave `Int32` panicked instead of hashing — six two-digit
  numbers were enough, while the five-element cases in the gates passed. A
  hash is a number modulo the word, so it wraps now. And `impl Cmp for
  Int32` defined `cmp` as `self - other`, so `2000000000.cmp(-2000000000)`
  overflowed and every `Enumerable` method that reads `cmp` — `sorted`,
  `min`, `max`, `includes?`, `clamp` — refused a pair that `<` answers for.
  It compares now. `impl Cmp for String` called a `<=>` the prelude's
  `String` does not have, which nobody could ever have called.
- **A port and an address are checked before they are packed.**
  `IyiSocket.listen(70000, 1)` packed the port into sixteen bits without
  asking and bound **4464**; `-1` bound 65535. And the address parser
  accumulated digits unbounded, so `"999999999999.1.1.1"` left `Int32` and
  panicked about arithmetic rather than naming the address it could not
  resolve. Both refuse by name now, driven from `bench/socket_exercise.sh`.
- **One window, three answers.** `each_slice(0)` and `each_cons(0)` raised
  a named panic in `Indexable`, yielded nothing in `Enumerable`, and shifted
  an empty array inside the `Iterator` adaptor — the same call on three
  trait towers. All three refuse by name now. And `Slice#to_s` printed its
  elements with `to_s` where `Array#to_s` inspects them, so the same data
  read back two ways (`Slice[a, b]` beside `["a", "b"]`).
- **The float surface was probed and found right, so it is pinned.** The
  same question asked of `Float64` — which methods disagree with each other
  at the edges — came back with nothing: `NaN` is not itself and cannot be
  found again as a key it nevertheless occupies, `-0.0` equals `0.0` and
  shares its slot, a comparison sort handed a `NaN` comes back with
  everything it was given, `to_i` truncates toward zero the way `//` does,
  and every conversion that cannot fit — `1e20.to_i`, `NaN.to_i`,
  `Infinity.to_i`, and the boundary `2147483647.9.to_i` — is a panic rather
  than whatever the hardware left behind. The boundary is the interesting
  one: it truncates to a value that fits and is still refused, which this
  compiler and the other language were both measured doing. Sixteen of
  those properties are checks in `bench/number_exercise.iyi` now, with four
  driver-run panics and two proofs that break `floor` and `round` in a
  copied prelude — a clean probe is worth keeping only if it becomes a
  gate.
- **`Int32::MIN` can be read back from what it prints, and the division
  that overflows is a sentence rather than a signal.** Three defects at the
  edges of the integers, all found by one probe. `String#to_i?`
  accumulated the *positive* magnitude, so the one value with no positive
  twin was unreadable — `"-2147483648".to_i` panicked with "arithmetic
  overflow" — and every out-of-range string panicked the same way instead
  of answering the `nil` a `?` promises. It reads a negative magnitude now
  and checks the last digit before using it, so `MIN` round-trips and
  `"2147483648".to_i?` is nil. `src/std/text.iyi` carried the same defect
  twice, in `to_i?(base)` and `to_i64?(base)`, and carries the same fix.
  And `MIN // -1` — the one division whose result the type does not hold —
  reached `unsafe_div` and **killed the process with SIGFPE**: "Process
  terminated because of a floating-point system exception", for an integer
  divide, which is the exact sentence the zero divisor was checked to avoid
  one commit earlier and the overflow beside it was not. Checked now for
  `Int32` and `Int64`; `MIN % -1` is zero and answers zero rather than
  trapping underneath.
- **And `//` truncates while `%` takes the dividend's sign**, which is
  C's pair and not Crystal's floor-and-modulo. It was never written down,
  and it is the sort of difference a program ported from Crystal keeps
  silently: `-7 // 2` is -3 here and -4 there. Self-consistent — the
  identity `(a // b) * b + (a % b) == a` holds for all four sign
  combinations, measured — and `src/std/time.iyi` was checked against
  negative epochs and negative spans before this was recorded rather than
  changed. `bench/number_exercise.sh` is the gate for all of it: the edges
  plain and optimised, the four panics driven from the driver because a
  panicking program has no next line, six broken methods of a copied
  prelude, and a seventh proof that asks for SIGFPE itself to show the new
  guard is load-bearing.
- **A tuple and a range are their members, which is what `==` had never
  said.** The prelude wrote `Tuple#size`, `#[]`, `#to_s` and `#inspect` and
  never `==` or `hash`, and wrote neither for `Range` either, so `Object`'s
  answered — identity, on a value type — and `{1, 2} == {1, 2}` and
  `(1..3) == (1..3)` were both **false**. Everything that asks a value
  whether it is equal was wrong with them: a key was never found in a `Hash`
  (`table[{1, 2}]?` after `table[{1, 2}] = "x"` answered nil), a `Set` of
  them was a list, `includes?`, `index` and `uniq` over `zip`'s *own* result
  answered no, and a `case` over a tuple matched nothing, because a `when`
  is `===` and `===` is `==`. All four written now, element-wise, and
  hashing follows equality because a key is found by its slot first and
  compared second. Found by probing the prelude's collections for the same
  self-disagreement the string surface had, and `bench/value_exercise.sh`
  is the gate: both surfaces plain and optimised, the sample whose `zip`
  reaches one, and ten broken methods of a copied prelude to prove each
  check can fail.
- **And the reason, measured rather than argued.** SPEC.md said for one
  commit that a type-id hash "starts being wrong" once a type defines
  equality. It does not: the requirement runs one way — equal values must
  hash equally — and a coarser hash keeps it, so `Object#hash`'s default is
  correct and slow. Keyed two ways with 40,000 lookups each, 2,000
  `Array(Int32)` keys (an `==` of their own, no `hash`) answer in 28 ms
  against 3 ms for tuples, and at 4,000 keys it is 104 ms against 8. The
  broken direction is a hash *finer* than `==`, which nothing in the
  prelude has. `Set` and `Hash` still compare by identity, which is
  coherent for references and is recorded beside `Array#==` because the
  prelude's collections do not all answer that question the same way.
- **Padding is measured in characters, because `size` is.** `ljust` and
  `rjust` counted bytes: `"héllo".ljust(7, '.')` answered a string whose own
  `size` was 6, so the one thing padding is asked for — lining a column up —
  worked for ASCII and for nothing else. The pad was written as one byte
  too, so a multi-byte one (`'·'`) left a lone continuation byte inside the
  result. Both fixed: the width is the count `size` reports and the pad
  travels as its own bytes. ASCII is unchanged, which is every sample.
  Found by probing the prelude's string surface for the same
  self-disagreement `each_char` had — `size` said 5 and the method said 6 —
  and `bench/std_text_exercise.iyi` now holds the padded widths with two
  more proofs that patch the prelude where they live (eleven in all).
- **The scheduler's fiber states are named.** They were an `Int32` with
  seven numbers and their meanings in a comment, because the prelude had no
  `Enum` surface when the scheduler was written. It has one, and the comment
  was the argument for keeping the integer: every line of the scheduler
  reads or writes a state under the runtime lock, and what those
  comparisons cost is measured, so naming them is a change that had to be
  measured too. It was. `enum IyiFiberState : Int32` with `Running`,
  `Runnable`, `Sleeping`, `WaitingIo`, `WaitingCh`, `Joining` and `Done`,
  across nineteen sites in `concurrency.iyi` and the one in the collector's
  root walk that skipped a running or finished fiber by number. Two million
  channel round trips cost 127 ms optimised and 343 ms plain, against 164
  and 343 for the integer — inside the noise either way, because `==` on an
  enum is its value compared and a member is a constant. `server_load`,
  `concurrency_exercise`, `thread_exercise`, `thread_floor`,
  `parallel_mark`, `concurrent_mark`, `panics`, `runtime_exercise`, the
  five collector gates and `dependency_floor` all hold.
- **A module may not replace one of the prelude's methods either.** The
  rule said "a `.iyi` file may add to the other language's type and may not
  replace one of its methods", and stopped at the other language on the
  reasoning that under iyi's own prelude the type is this language's.
  Reopening the prelude *is* how a module extends it — and replacing is a
  different act there for the same reason it is under `--crystal`: a prelude
  method is the answer every program already has, so a module that writes
  one again hands its own answer to every program that imports it, with one
  import line as the whole diagnosis. Refused now, naming both definitions
  and where each was written; the prelude may still replace its own, which
  is how `number.iyi` writes a method `primitives.iyi` declared. Found by
  reading a library written against this fork, and then it found two of
  ours: `src/std/text.iyi` was replacing the prelude's `Char#to_s` and
  `String#each_char`, so **a program that did not import it printed `'é'`
  as one invalid byte and iterated `"héllo"` six times while `size`
  answered 5**. The prelude encodes and decodes UTF-8 itself now — one
  definition each, and `size`, `each_char` and `chars` agree — and
  `std/text` keeps what the prelude does not have. `Array#join` with no
  separator and a `byte_slice` helper were the prelude's twice over and are
  its once.
- **And a macro is the same act, one layer wider.** R-3 was asked of `def`
  and not of `macro`, which is where it costs more: `getter` is a
  *declaration* macro, so `class ::Object; macro getter(*names)` in one file
  decided what every field declaration in the program meant — including the
  ones in files that never heard of it — and `getter value` answered 99 with
  nothing said at either definition. Macros travel in an artifact too, so a
  consumer could inherit one from a module whose source it never reads.
  Asked at the same place now: `add_macro` answers which macro this one took
  the place of, the way `add_def` always has. An addition is still an
  addition, and a macro on a type the module declared is its own — a
  program's `class Holder; macro getter` is untouched, because `Holder`'s is
  not `Object`'s. A class method was already covered and a constant is
  refused by name (`already initialized constant`); those were checked
  rather than assumed.
- **An artifact whose module path now reaches another file says so.** A
  path is a file's path (R-1) and it resolves from the entry's directory
  before `IYI_PATH`, so a program with its own `std/text.iyi` has that file
  while it exists and the library's `std/text` after it is deleted. The
  artifact is refused, which is right — its surface is not the surface at
  that path — but the reader compared the two source hashes and said
  "`src/std/text.iyi` has changed since it was written", naming a library
  file the author has never opened. The artifact records the path it was
  written from, so the paths are compared first: `"std/text" is <the
  library's file> now, and this was written from <the program's>`.
- **The dependency floor measures `src/std/` and reads what the library
  declares.** It built every sample and nothing else, so a module no sample
  imports was measured by nothing — and importing one proves nothing on its
  own, because codegen is demand-driven and `import std/socket` asks the
  linker for no socket symbol. It builds each `bench/std_*_exercise.iyi`
  now, the program that calls its module's surface, into the same two sets.
  And because a measurement cannot see a `@[Link]` nobody calls yet — the
  shape a link line grows in — every annotation under `src/iyi` and
  `src/std` is read as text against the three the library has reasons for.
  A planted `@[Link("ssl")]` fails the gate with nothing calling it.
- **An `enum` in iyi is its name, its order, its value and its members.**
  The compiler gives an enum two methods — `value`, the integer the member
  was numbered with, and `new`, which wraps one — and the prelude gave it
  nothing, so every other answer was `Object`'s: `Level::Warn ==
  Level::Warn` was **false**, `"#{Level::Warn}"` printed the *type's* name,
  and `case level when Level::Warn` matched nothing, because a `when` that
  names a member lowers to `Level::Warn === level` and `===` is `==`. The
  compiler's own per-member question methods (`level.warn?`) are that same
  `==`, and a `@[Flags]` enum's are `includes?`, so those were broken by one
  gap apiece. Reproduced on 0.12.0 as released.
  `src/iyi/enum.iyi` is the surface, and `samples/iyi/enums.iyi` is what
  asked for each piece of it: equality and the `case` built on it, an order
  (`level >= Level::Info` is the first thing written after a `case`), the
  member's name and the value's digits where no member has it, `hash` so a
  member can be a `Hash` key, the members as a list (`values`, `names`), a
  name read back (`parse?`, folding case, `nil` for unknown text), a value
  read back (`from_value?`), and for a `@[Flags]` enum the membership its
  question methods ask plus `|` and `&`. Read off the type at each
  instantiation, so nothing walks a table at run time: `to_s` is a `case`
  over integers. 161 lines, which leaves the library at 3,570 of its 3,734
  ceiling. `bench/enum_exercise.sh` runs the exercise plain and
  `--release`, runs the sample, and then breaks one method of a copied
  prelude eight times over to prove each check can fail.
- **And a `pub enum` crosses a module boundary**, which is the half of the
  feature that had never been asked of it. Three defects were in the way,
  each invisible until an enum was exported. The per-member question
  methods the compiler writes carried no return type, so R-2 refused the
  module that declared one: "`debug?` is exported and does not say what it
  returns", about a method nobody wrote whose answer is never anything but
  a `Bool`. The artifact writer asked an enum for its instance variables —
  `BUG: Level::Level doesn't implement instance_vars` — where what a
  consumer needs is the *members* and the numbers they were given, since
  the module's own object code was compiled against those and a consumer
  that counted from zero again would agree with it only by luck. And an
  enum's members read as code inside a type body, so the module could not
  be imported from an artifact at all ("has code inside a type body that
  has to run") — a member is an `Arg` the compiler numbers where it is
  written, and there is nothing to run. A `@[Flags]` enum also travels with
  the word that numbers it, and without the `None` and `All` it is given
  wherever it is declared: carried, they arrived as a redefinition of the
  consumer's own. Both writers take that rule now, the iyi-native one and
  `iyi tool bind`'s. `bench/enum_exercise.sh` builds a consumer against a
  module's source and against its `.iyimod` and requires the same answers;
  `spec/compiler/iyimod_spec.cr` pins the declaration.
- **A `.iyi` file may add to the other language's type and may not replace
  one of its methods.** `import std/text` in a `--crystal` program answered
  `private method 'byte_slice' called for String`, at a line in Crystal's
  own `Path#drive` that had not changed: `src/std/text.iyi` writes a
  `private def byte_slice(start, count)` helper of its own, a name iyi's
  prelude does not have and Crystal's `String` does, so the import replaced
  the library's public method with a private one under the whole program.
  A reopen that *adds* is what a reopen is for and stays; one that replaces
  is refused, naming both definitions and both files. It asks where each was
  written, and it does not apply when the prelude is iyi's own — there the
  type is this language's and reopening it is how the prelude is extended.
  What it settles about `src/std/`: nine of the twelve modules are
  library-agnostic and build under `--crystal`, while `std/text` and
  `std/format` are written against iyi's own prelude — byte-indexed `index`,
  `split` and `sub`, a `%` that formats — and are refused there instead of
  silently standing in for Crystal's, which is what they had been doing.
- **A module used as a type survives the boundary: the consumer's own
  includer is in the dispatch.** 0.12.0 shipped this diagnosed and not
  fixed, and it is the one thing a bound kemal application did not
  survive — it booted and faulted on the first request. A module held as
  a type (`@next : HTTP::Handler | Nil`, the handler chain every
  middleware joins) is compiled as one type-id test per *including* type,
  and the includers are whichever ones the producing build had;
  `codegen_dispatch` ends in `unreachable`, so a consumer that writes its
  own middleware falls off the end of the chain. IV.1g's sentence about
  blocks and generics, said about **sets**: an instantiation whose machine
  code enumerates the members of an open type is the whole program's
  answer, so its body travels and the consumer compiles it — and so do the
  bodies that *call* one, because a caller the producer compiled binds to
  the producer's copy by name. `Iyi::OpenTravel` marks the call where the
  set is read, walks this build's instantiated defs and marks every
  caller. `bench/kemal_serves.sh` answers what the source arm answers now,
  and `bench/open_dispatch.sh` holds the forty-line fixture both ways:
  `IYI_OPEN_TRAVEL=off` writes the boundary the way it was written before
  the rule and still prints `first ` where the source prints
  `first mine end`.
- **The closure follows every call, because a copy is a call too, and
  which bound is right was measured rather than reasoned.** The obvious
  bound is the module's own types — everything else is the consumer's to
  compile, so the symbol a shard's object code calls is the consumer's own
  and the includers are the consumer's. IV.1g says why that is wrong:
  while a module's unit is emitted, a callee it does not own is *copied*
  into that unit with internal linkage, so a library method with a
  dispatch in it sits in the artifact holding the producer's set, and only
  a caller that travels replaces it. Measured: on kemal's four boundaries
  the wide walk changes nothing at all — the same 325, 36, 35 and 11
  travelling bodies — because what reaches a dispatch there already
  travelled for another reason; on `db` and `sqlite3` it is 45 bodies more
  out of 217, with no change in either gate's wall time. The one place it
  looked expensive was the defect below rather than a cost.
- **A `fun` that answers one of the shard's own enums crosses as that
  enum.** It crossed as the enum's *base type*, which is the right answer
  for a parameter — what a C function takes is the integer, and Crystal
  converts without being asked — and the wrong one for a return: the
  shard's own code reads what it declared. `sqlite3` writes `case
  LibSQLite3.column_type(self, col) when Type::TEXT`, so a body compiled on
  the far side cased over an `Int32`, matched no member, took the `else` and
  raised: `another row available`, on the first query a consumer ran. Named
  globally — `::SQLite3::Type` — because a shard's `lib` is declared at the
  top level, where its name is what the producer's symbols are made of, and
  a name looked up in there reaches neither the module's scope (`Type` is
  `undefined constant`) nor its namespace (`SQLite3::Type` was too).
  `bench/bind_roundtrip.sh` carries the shape now: a module's body cases on
  a `fun`'s enum, and with the base type back the two arms answer `many`
  where they answer `one` and `two`.
- **Five declarations a travelling body needs, which never crossed.** Each
  was invisible while the body that names it was machine code in the
  artifact. A declaration's members are written *inside* it now, so a
  private nested type is the name the shard wrote (`private constant
  Kemal::ParamParser::LimitedBodyIO referenced`, on the class that
  declares it). A method the shard alone cannot type travels as its body:
  `exception_page` writes `def self.new(context : HTTP::Server::Context,
  exception : Exception)` and requires no `http`, so instantiating it here
  is refused and a consumer of `Kemal::ExceptionPage` got the synthesised
  `new` alone — `wrong number of arguments (given 2, expected 4..10)`. A
  nested module says whether it writes `extend self`, carried as the word
  rather than as a second copy of every method, because
  `Backtracer::Backtrace::Parser.parse` is how the shard calls it
  (`.iyimod` v50). Every method of a *private* type travels, because
  `keep_type` cannot name one and so the producer emits no symbol for any
  of them (`undefined symbol: *Kemal::HeadRequestHandler::NullIO::new<…>`).
  And an **empty** body travels as `nil`: the format spelled it exactly the
  way it spells a header, so `def backtracer` with nothing in it arrived as
  a promise of a symbol nobody emitted.

## 0.12.0 — 2026-09-11

**A Crystal project becomes iyi modules, and the thing people download
carries the library it names.** `iyi migrate` writes a checkout out as
iyi — a whole project, or one file at a time beside its source — and it
was written against twelve real projects taken as they come from GitHub,
`crystal-db`, `shards`, `halite`, `ameba`, `amber` and Kemal's own among
them, which is where five of its rules came from. `iyi bind` puts every
shard under `lib/` behind a boundary a program imports, and the sixteen
defects in that boundary were found the same way: by consuming one. The
tarball this release publishes is also the first to carry
`share/iyi/src/std`, so `import std/text` resolves out of an install
rather than answering "can't find module", and the first to publish
`SHA256SUMS` beside the tarballs, which `install.sh` checks before it
unpacks anything.

**A server survives its own collector.** Two runtime mistakes of one
shape — a heap pointer held as a number, where the collector is precise
over a typed object's fields, and a fiber's stack mapped and never handed
back — took a kemal port down at request ~400 under `wrk -c 100 -d 10`.
The same program now serves 237,066 requests at 23,705/s behind 299
mappings and 14 MB flat, and the stack pool's link moved to a word that
is writable where a page is 16 KiB. The editor holds too: `▶ run` no
longer ends the session, a workspace pull reads its inbox between files
(a hover behind a 94-file walk: 10.9 s to 0.23 s), and a panic that could
not be printed is a sentence on descriptor 2 instead of a segfault.

`.iyimod` is v49.

### Added

- **The header root is a fallback, not a replacement.** `iyi migrate
  --check` compiles a nested module on its own, which needs IV.6 read
  backwards: `module a/b` in `<root>/a/b.iyi` names `<root>`, and imports
  resolve from there. Applied to every build it *replaced* the entry's own
  directory, and the samples whose header path happens to end their file
  path — `samples/modules.iyi` copied to a work directory — stopped
  resolving their imports; `bench/arena_exercise.sh` said so by name. The
  root the header names is now tried after the entry's directory, never
  instead of it.
- **`migrate` and `bind` match through the compiler's own engine.** Both
  verbs were written with `Regex` literals, which put pcre2 back on the
  link line and `bench/dependency_floor.sh` refused the build (SPEC.md
  III.10, Appendix B #17). They use `Iyi::Rx` now, and the one check a
  pattern would have been compiled per name and per line for — does this
  line name this word on its own — is hand-written.
- **A template travels to the path the build looks in.** Its path is
  written from the directory the *original* program was built from -
  `ECR.embed("src/views/x.ecr")` resolves against the build's working
  directory - and the copy went to a path relative to the *migrating
  process's* cwd instead. Migrating from anywhere but the project root
  therefore compiled 91 modules and refused the first template with `No
  such file or directory`. The root is the tree's now; the gate migrates
  from `/` and builds the result.
- **`iyi migrate FILE.cr`: one file at a time.** It writes `FILE.iyi`
  beside the source under its own name, with the header path an importer
  writes; it carries what the *tree* requires, because a module is a
  compilation unit and what one file uses another file required
  (`base_log_handler.cr` names `HTTP::Handler` and requires nothing); its
  own relative requires stay `require`s, since those files are still the
  other language; and nothing else is touched - no manifest copy, no
  assets, no `lib` link. It goes from the top only: a file a *module*
  already requires is refused, because a `require` that finds a `.iyi`
  gets a compilation unit and none of its names, and Crystal files that
  require it are a note instead - they keep reading the `.cr`. Measured:
  the application's entry alone becomes a module, the program builds with
  the other 98 files still Crystal, and it answers the Crystal build byte
  for byte.
- **Twelve real projects, and the five rules six of them found.**
  `crystal-db`, `shards`, `halite`, `ameba`, `amber` and Kemal's own
  checkout, migrated as they come from GitHub. The library a tree is
  written against is the one it *requires*, not a bare prelude: `HTTP`
  is undeclared until something requires `http/client`, so halite
  reopening `HTTP::Headers` was read as a module of the tree's own and
  imported in a cycle. A merge can make a cycle, so merging repeats
  until it cannot (`shards` had fourteen modules refused by a cycle its
  tree did not have). A `require` under a wrapper's `end` does not stop
  the peel, while a macro there does - `{% for cls in
  Exception.constants %}` after a peeled `module Exception` found the
  other language's and aliased its constants over the module's own
  classes. `class Error < Error` means the enclosing namespace's, not
  itself. And a bang accessor keeps its visibility
  (`protected getter! segment`), which had left a `!` in a name.
  The one shape the verb does not rewrite is now named at every site
  instead of arriving as `can't declare instance variables in X because
  X extends it`: a module *mixed into a type* is a `trait` and an
  `impl` here, and `--check` counts those as their own kind.
  `crystal-db` 4 of 6, `shards` 3 of 5, `halite` 5 of 7, Kemal's
  checkout 11 of 12; `ameba` and `amber` need `shards install` first,
  which the refusal says.
- **Pointed at a project, the verb reaches what the project reaches.**
  Four fixes from one report - `iyi migrate <project> --out <dir>` on a
  shard checkout produced nonsense, and it did. A project root is not a
  source tree: a shards project's library is its `src` and everything
  beside the manifest is a program of its own, so Kemal's root read 79
  files instead of 34 and merged 24 of them into one module; the library
  is migrated and the narrowing is printed. A merged module is named
  after the project (`kemal_and_others`, where joining stems
  alphabetically said `cli_and_others`). The shards the tree requires
  are reached from the tree that is written - a `lib` symlink beside the
  modules, since `require "exception_page"` resolves from `./lib`
  relative to the compiler's cwd and every module used to refuse with
  `can't find file` until a person exported `CRYSTAL_PATH` by hand; the
  manifest travels beside it, so `shards install` there replaces the
  link. And a return type goes before a `forall`, not after it. Kemal's
  own checkout: 0 of 12 modules compiling → **11 of 12**, the twelfth
  being R-2 asking for one signature. The migrated application now
  builds and serves with no environment set at all.
- **The migrated application answers byte for byte, on real data.** Run
  against the demo database beside the Crystal build of the same tree,
  the 91-module program returns identical bodies and status codes on all
  nine routes tried: the API root, `cities`, a city's districts,
  `discover`, `tags`, a search, a city's submissions, a user, and one
  route the environment turns off. Earlier runs only compared an empty
  environment's 404s, which proved less than it looked.
- **`iyi migrate --annotate`: the types R-2 wants, read off the
  program.** Crystal code does not write them and they are not missing —
  the compiler bound them to compile the program. `--annotate` compiles
  the tree once per entry (every file nothing requires) and once for the
  spec suite - where a *library* keeps its call sites - and writes them
  in: a parameter from the instantiated def, where the binding happened,
  and the answer from the call, because a boundary is about what a caller
  is handed; a parameter two instantiations bound differently is written
  as neither and reported as both. On the 99-file application it writes
  **226** types in 46 s and names the 53 it cannot, each with what is
  missing; `radix` types nothing without its specs and eleven
  declarations with them.
  Two rules came with it: `pub` is what another module names, so a def or
  constant nothing outside names stays the module's own (a *type* keeps
  its `pub` — a shard's macro names the class that includes it), and a
  `private def` is not R-2's business, which refused every tree with a
  private helper in an exported class. `bench/migrate_gate.sh` annotates
  the fixture, emits a `.iyimod` per module and builds the program from
  those, byte for byte. A Crystal bang is rewritten by whose method it
  is, which needs the same reading: `def sort!` and its calls drop the
  bang together (both spellings present, the mutating one becomes
  `sort_in_place`), `getter!`/`property!` become `getter?`/`property?`
  and a reader that raises, and `@items.uniq!` alone on a line - the
  mutation whose copy nobody reads - puts the copy back on the `@ivar`.
  A call nothing in any program made is named with its file, line and
  the alternative rather than guessed at. Three more rules came from
  running it over the shards the application depends on: a **bare** call
  to a bang method (`validate_typ!(x)`, no receiver) is rewritten where
  the name is one the tree defines, the **manifest travels** because a
  shard's `version.cr` runs `shards version` on its own directory, and a
  **merge follows the `require`** rather than the file - a class body
  with `require "./x/*"` under it is loaded before the files that reopen
  the class, and ordering them first left `abstract class` as a second
  definition the other language ignores. With `--annotate --check`:
  `exception_page` 3 of 3,
  `radix` 5 of 5, `dotenv` 1 of 1, `jwt` 5 of 7, `faker` 2 of 3,
  `micrate` 4 of 6, `kemal` 11 of 13, `backtracer` 2 of 5 (regex
  literals, IV.1d's). A **sidecar** - the `.cr` file a
  reopening of somebody else's type stays in - names the tree's own
  types too and has no `using` line to reach them through, so every such
  path is written in full and what it names counts as crossing: Kemal's
  `context_crystal.cr` asked for `Kemal::Route` after `Route` had moved.
  Two of the refusals were not migration's: that one, and a def of a
  `private class` nested in an exported one, which III.1's
  definition-site probe wrote the name of from outside - `nameable?` now
  answers false for a private type, and the fixture plants one.
  Two more line-local rewrites could not see enough: a file name is not a
  module name (`micrate-wrapper.cr` gave `module micrate-wrapper`, a
  subtraction), and a chain's `.not_nil!` on a line of its own has its
  receiver above it, so `( || raise …)` was written where nothing
  preceded it - `.try { |value| value } || raise …` composes and takes
  the whole chain. Three shards were refused by the *language*, not by
  the migration. A **regex literal** is refused where the program has no
  runtime `Regex` - iyi's own prelude - and that was read off the file's
  extension: under `--crystal` the library is Crystal's and `Regex` is in
  it, so a `.iyi` file that already writes `Regex.new("a.c")` may write
  the sugar for it (`backtracer` 2 of 5 → **4 of 4**). And `pub` did not
  admit an **alias** or an **annotation**, which are both surface - a
  name for a type, and a mark a *consumer* applies. Both take `pub` and
  both travel in the artifact, the alias as what it resolved to
  (`validator` 8 of 11 → **11 of 11**). With them came a codegen fix that
  was not theirs: code emitted into `_main`, such as a constant's
  initialiser, kept whichever module's closure host was open, so
  `~$Regex:<hash>:const_init` referred to a `Regex.new` copied into a
  module's unit with internal linkage and the link ended undefined. Two
  more rewrites: a `macro is!` loses its bang the way a `def` does, and a
  def whose parameter list runs over several lines is named rather than
  annotated (writing the return type after the `(` produced
  `def before_check( : ::Nil`). And a `module` whose file has trailing
  declarations under its `end` is peeled after all - `module Validator`
  with `alias Valid = Validator` beside it was left nested, and every
  consumer's `using` refused. `--check` says whose each refusal is now: a
  `require` this machine cannot resolve is the environment's (`shards
  install` comes first, and that is all twelve of `kilt`'s), R-2's
  question is the author's, and what is left is the verb's own and asks
  to be reported. The list of what R-2 still wants moved
  after the `pub` pass and grew a return-type case: it used to name
  declarations that then lost their `pub` - entries nobody could act on -
  and left `zip_types is exported and does not say what it returns` to
  arrive as a compiler refusal instead of a note. Each entry now names
  the module that forces the export and *when* the question is asked:
  the next compile for a module's own `pub def`, the artifact for a
  public method of an exported type, which is how a tree compiles clean
  with the list still long. A `lib/` with a manifest beside it is `shards
  install`'s, not the tree's: `migrate .` on the application read 889
  files, 756 of them somebody else's, and merged 359 into one module. It
  is skipped and counted, and pointing the verb at a project root says
  that the library is its `src`. `--out src` used to write the modules into the tree
  it was reading and leave a `src/src` behind; it is refused, and the
  gate holds the source tree untouched. And when `--check` comes back clean the verb says
  what to type next: the build command with the entry filled in, the
  per-module check an editor asks on every change, and `iyi bind`.
- **`iyi migrate`: a Crystal project, written out as iyi modules.**
  `iyi migrate SRC --out DIR [--check]` reads a tree of `.cr` files and
  writes the iyi program it is: the namespace becomes the path (wrappers
  peeled one at a time, `DB` spelled `d_b`), every constant path the tree
  declares is resolved the way Crystal resolves one — outwards through
  `include`, inside string interpolation too — and rewritten to the bare
  name its module exports under a `using` line, `require "./x"` becomes
  `import`, one module owns the shard requires and every other imports it
  (III.5 orders the effects), an import cycle becomes one module and is
  named, a reopening of a type the tree does not own moves to a `.cr`
  beside its module (the compiler is asked which names the library owns),
  `not_nil!` becomes `(x || raise …)` and any other `foo!` its non-bang
  spelling, and the templates a macro embeds travel with their constant
  paths rewritten. `--check` compiles every module written and prints the
  first refusal of each. On an 8,079-line, 99-file kemal application:
  **99 files to 91 modules, all 91 compile**, the program builds and
  answers what the Crystal build answers. `bench/migrate_gate.sh` holds
  the whole path on a hermetic fixture that plants every case, artifacts
  included, and runs in CI. SPEC.md III.6 has the rules, the numbers and
  what it does not do.
- **`iyi bind`: every shard under `lib/`, behind a boundary, in one
  command.** The boundary existed as two commands per shard run in
  dependency order by a person who knew the order and each shard's root
  namespace - Kemal is four shards and eight commands, and the sample's
  README wrote the loop out. The verb is the loop: it reads `lib/` as
  `shards install` left it, orders the shards by their own `shard.yml`
  dependencies, reads each root off its entry file, and runs `tool bind`
  and the fill build as itself, each shard against the artifacts before
  it, with the search paths made absolute because the fill build runs
  inside `mods/`. `iyi bind` on the kemal sample: four `.iyimod`s in 35 s,
  and the program that wrote `require "kemal"` writes `import kemal`.
  `bench/kemal_serves.sh` runs the verb now, so the gate is the verb's;
  the tarball's `iyi` does it too, against the Crystal library it
  carries. A shard that fails is named and the rest go on - a surface
  that is macros, a fill build that refuses, a dependency that did not
  bind - and the exit code says whether everything asked for was bound;
  a half-written artifact is removed so the next build fails at the
  cause. SPEC.md III.6 says what was built where it said PROPOSED, and
  Appendix B #12 is decided: checked, and nobody writes the signature.
  And what it is worth in build time is written beside it: 8% on the
  kemal sample (2.03 s to 1.88), because a `--crystal` build's bill is
  Crystal's library and the program's own code, not the shard. On a
  real 21-shard application it binds 18 of 19 and writes 22 artifacts,
  because a shard with more than one namespace is more than one
  boundary; the one it does not bind is macros, which do not cross.
- **A boundary a program can import: sixteen defects, found by consuming
  one.** `iyi bind` wrote artifacts a reader could parse and a program
  could not use. A probe that does nothing but `import <name>` now
  builds, links and runs against 21 of the 22 artifacts a real 21-shard
  application produces, where 11 of 18 did. Every one of the fifteen is
  a shape `bench/bind_roundtrip.sh` carries now, and the fixture fails
  without the fix that found it. A class variable's `@[ThreadLocal]`
  travels, because a consumer that declares the variable without it
  writes to a different global than the object code does — `relocation
  R_X86_64_TPOFF32 cannot be used against symbol` from a link with
  every declaration in hand. One the shard declared `uninitialized`
  renders as the assignment it wrote, and one whose default calls a
  private method carries that method (`email`'s `@@log : Log =
  create_logger`). A private method named only *after* a non-ASCII
  character in a travelling body travels: the search for what a body
  calls was byte arithmetic on a character index, so `gcry`'s
  `append_hex` read as uncalled. A shard's own top-level `fun` crosses
  as source, because its machine code is in a main module and main
  modules do not travel — and the text joins the consumer's tree, since
  a `fun` is emitted where it is written rather than where it is called.
  A macro call at the top level does not travel at all: it is a
  declaration written compactly, and copying `Kilt.register_engine("ecr",
  ECR.embed)` into the initialiser handed a consumer `ECR.embed` with
  nothing in it. A class variable reached only through `pointerof`
  travels (`gcry`'s `@@old_segv`), a type layout may be past 64 KiB
  (`Gcry::Heap`, offsets now u32), a match type is named the way its
  `~match<...>` symbol is rather than the way it prints, and one is
  resolved part by part — a union of virtual types, a module used as a
  value, a generic instantiated with either — instead of being refused
  whole. A private type of Crystal's library is not a name a boundary may
  write and *is* a value it may hold, which is two questions and now two
  tables. And a bare name from another boundary is not adopted where
  Crystal's library or this shard itself declares one: `Kilt::Exception`
  had been rewriting every `class Error < Exception` bound after it, and
  `jwt` came out importing eleven boundaries it names nothing from
  because the edge test was a substring match.
- **A type id is a question about the program.** It was asked at the
  import that raised it, which is a stricter order than the question:
  `pg` declares `PG` and `PQ`, its wire protocol, and `PG` names
  `PQ::Field` in its signatures while `PQ` numbers `PG::Error` in its
  object code. Whichever of the two a consumer reads first refers to a
  type the other has not declared yet, and no ordering of two boundaries
  fixes it — the dependency runs both ways while an import graph is a
  DAG (R-1). The names an artifact's object code refers to, ids and
  match types both, are recorded at the import and resolved once, after
  the top-level pass has read every one of them; the refusal, where a
  name really is missing, still points at the import that named it and
  now says which module to import. `import p_g` builds, and 21 of the 22
  artifacts a real application produces are importable on their own.
  `bench/bind_roundtrip.sh`'s two namespaces name each other now, so the
  fixture fails without this.
- **One boundary per namespace, and per part.** A boundary is rooted at
  one namespace and a shard need not have one: `pg` declares `PG` and
  `PQ`, its wire protocol, and `PG`'s signatures name `PQ::Field` while
  its units number it. `tool bind` reports the namespaces it found
  beside the one it was given (`also declares: PQ`), and `iyi bind`
  binds each — the root first, because binding it is what finds them,
  then again with them beside it. The parts a shard's entry never
  requires are boundaries too: `bindata` ships `src/bindata/asn1.cr`,
  which `jwt` requires and `bindata`'s own entry does not, so `jwt`'s
  object code numbered an `ASN1::BER` no artifact carried. What is left
  is the cycle: `PQ` numbers `PG::Error` while `PG` names `PQ::Field`,
  an import graph is a DAG (R-1), and those two are the pair a program
  cannot import today.
- **What cannot compile cannot cross.** A shard can hold a method whose
  body does not typecheck when it is instantiated — nothing in
  `ed25519` calls `RistrettoPoint#==`, whose body calls an
  `assert_rst_point` that shard never defined — and the keep file calls
  everything, so the fill build died and took the shard and every shard
  behind it. The method the error trace lands in is written to
  `<artifact>.drop`, both builds run again without it, and the boundary
  carries the rest: `ed25519` loses two methods and `jwt`, which
  depends on it, binds. The keep file marks each call with the key that
  names it, the drop file says what it left out and why, and discovery
  is each run's — a shard fixed since the last one binds whole.
- **The context pack says how a consumer names what it shows.** Every
  block of `iyi mod context` opens with the two lines a file writes to
  reach the surface beneath - `import kemal/dsl`, then `using
  kemal/dsl::{after_all, app, before_all, ...}` with every exported name
  in it, or bare `using kemal/dsl` for all of them. The surface rendered
  a module's offer and nothing about its spelling; the raw sources a
  pack replaces carry their own `using` lines and so show it by
  accident, and the rounds arm of `bench/context_pack.py` lost a round
  to exactly that. Six pack-grounded attempts since, read one by one:
  none wrote the `using` wrong. The pack is 59% of the kemal closure
  where it was 55%, and 52% of calc's where it was 43%, under the 70%
  line.
- **A one-character string where a `Char` is wanted says the `Char`.**
  `"/a/b".split("/")` was "expected argument #1 to 'String#split' to be
  Char, not String" and a list of overloads - true, and the guess every
  arrival from Crystal, Ruby or a model makes about `split`, `index`
  and `chomp`. It now adds `Did you mean '/'? A one-character string is
  still a String; split takes a Char, written in single quotes`, and
  carries the `Char` as a `suggested_edit` spanning the literal, quotes
  included and escapes written (`'\t'`, `'\''`), so `iyi fix` and the
  editor's quickfix apply it. A raise can name its span now
  (`TypeException.for_node`'s `size`), where before it was the node's
  name and a literal has none. `bench/agent_loop.py` steps 9 and 10.
- **The installer verifies what it unpacks.** A release ships
  `SHA256SUMS` beside its tarballs, and `install.sh` checks the tarball
  it downloaded against them before `tar` runs - what comes out of one
  reaches the linker. A mismatch is refused with nothing unpacked and
  the two sums named; a release from before this (0.11.0 and earlier)
  publishes none, and the script says the install was not verified
  rather than passing over it. `IYI_RELEASE_URL` points the script at
  a directory instead of the release, which is how it is gated: the
  clean-room job installs the tarball the run just proved through the
  script, then flips a digit in the sums and requires a refusal.
- **R-4, measured for the first time.** README read "what R-4 says
  about generics crossing a boundary is specified and unmeasured", and
  half of that was too kind: the dictionary is not built, and what
  stands in for it - a generic's body travelling in the artifact and
  every consumer compiling it again - had no number. `bench/generic_boundary.py`
  reads the sample corpus's eleven artifacts by section table: of the
  35,340 bytes a consumer's front end reads, 37% is bodies it compiles
  again; `std/list`, `std/enumerable` and `std/traits` ship no object
  code at all; and `immutable.iyi`, a consumer of the all-generic
  `std/list`, builds its front end from artifacts at 1.04x its time from
  source. The gate pins both ends of the spectrum to the shape R-4 as
  built gives them and holds the bodies' share under 50%, a tripwire;
  it runs in CI beside the rebuild gate. SPEC.md III.9 carries the
  numbers where it said the rule had nothing behind it.
- **The first program that remembers what it has seen.**
  `samples/iyi/visited.iyi` walks a graph with a cycle in it, breadth
  first, and ends only because it keeps a set of where it has been; the
  prelude grew `Set(T)` for it - a `Hash` with nothing attached to the
  answer, so insertion order and the index come for free - with `add`
  answering whether the element was new, `includes?`, `delete`, `each`,
  `to_a`, `-`, and `to_s` as `Set{"a", "b"}`; `Array#to_set` and
  `Array#shift?` came with it, the queue's own verb. SPEC.md's 0.1.0
  list said "no `Set`" because no sample asked; the seventh program of
  the first hour asks.
- **The first program that forgets.** `samples/iyi/sessions.iyi`: a
  table of who is signed in, which has to lose an entry when somebody
  signs out, and the prelude grew the one thing it took - `Hash#delete`,
  the value that was there or `nil`. The entries that remain keep their
  order, so a person who signs out and back in goes to the end of the
  table; the gap closes in the dense arrays and the index is built again
  over what is left, once per deletion, rather than tombstones every
  probe would step over from then on. `hash.iyi`'s header said "nothing
  deletes, because no sample asks" since the day it arrived; this is the
  sample asking.

### Changed

- **A pull's `resultId` is per file, folded over what the file's verdict
  depends on.** 0.11.0 gave `workspace/diagnostic` one id for the whole
  workspace: any change anywhere was a full answer for every file, so an
  editor being typed in was the build farm every two seconds that an
  idle one had stopped being. The id is now a fold over the file's own
  stamp - an open buffer's text, a disk file's size and mtime - and the
  stamps of every module its imports reach, read off the header block
  the way references now read it, plus one stamp all files share for
  `lib/`, `iyi.mod` and `iyi.sum`. A keystroke in a leaf module is one
  compile on the next pull and `unchanged` for the rest; one in
  `calc/lexer.iyi` is three (lexer, parser, `calc`) where it was
  thirty-two. `bench/lsp_session.py` 31c and 31d hold both: a changed
  file alone, then a changed import and its importers.
- **A workspace question compiles the entries that can answer it.**
  References, rename and incoming calls compiled every open document
  and every `.iyi` under the root, one front-end compile each, and the
  section called that the architecture priced honestly. R-1 prices it
  lower: a module refers to a def only through the module that declares
  it, imported directly or through another import. The cursor's file
  compiles first and names the declaring files; then only the entries
  whose import graph reaches one of them compile, the header block read
  as text (II.3 rule 4), an entry with no header asked anyway, a target
  outside the workspace asking everybody. On the 32-module corpus with
  the release compiler, references go 1.7 s to 70 ms p50 / 113 ms p95,
  same answers; `bench/lsp_session.py` step 34b holds the case two
  imports away, and `bench/lsp_latency.py`'s references budget is 3 s
  where "ask everybody" reads 4.6 s unoptimised.
- **The rounds arm runs `iyi fix` before it asks the model again.** The
  loop AI_FIRST.md section 2 describes has `fix` in it and the gate's did
  not: a compiler that says the `Char` bought nothing on a model that
  reads prose and spends a round retyping it (run five, lost 6 to 4).
  After a failed build, `bench/context_pack.py` applies the compiler's
  own edits on both arms, a program fix converges is green on the round
  that wrote it, and what fix changed is printed. Driven with
  `--agent 'cat prog.iyi'` on the `split("/")` program: one round, the
  `Char` applied, green. Run six, against the model: tokens by 34%,
  rounds 4 to 4, the bar passed on a tie - and fix fired in none of its
  trials, which AI_FIRST.md section 5 says plainly.
- **The server's keystroke, measured again on the prelude it has now,
  and the daemon's cache declined again on the number.** `bench/lsp_latency.py`
  on the release compiler, 32 modules: a verdict in 44 ms p50 / 76 ms
  p95 (the gate's fixture 37 ms), hover under 1 ms, completion 3 ms,
  workspace references 1.7 s at one compile per module. SPEC.md III.8
  read 36 / 55 from when the corpus was 26 modules and the prelude a
  fraction of its 11,804 lines; `--stats` puts the growth where it is,
  the top-level pass at 30 ms of a 48 ms front end. IV.1d's
  `Preanalysed` is exactly that 30 ms and Appendix B #15 asks whether
  the server should live on it: adoption mutates the held `Program`,
  which is why the daemon forks per build, so an editor would need a
  clone per request or an invalidation story for 44 ms to about 15
  under a debounce it already applies. Not built; the section says so
  with the number beside it. And the number not to mistake for it: an
  unoptimised `make iyi` compiler answers the same keystroke in 250 ms.

### Fixed

- **The standard library is in the package now, under its own name, and
  only once.** `import std/text` is a line a program writes, so the
  modules have to be inside the thing people download. 0.11.0 shipped
  `share/iyi/src/iyi` and nothing beside it: `import std/enumerable`
  answered `can't find module 'std/enumerable'` out of the released
  tarball, and every tarball gate passed it, because all of them run
  `hello.iyi`. `make install_iyi` names `src/std` — and stops shipping
  the second copy that `cp -R src/.` left inside the other language's
  library directory, where `import std/...` resolved from by accident:
  153 KB of a library that already shipped, and a copy that answers for
  the real one going missing (moving `share/iyi/src/std` aside still
  built, out of `share/iyi/crystal/std`). Nothing in Crystal's library
  requires `std/...`, so it leaves with `iyi/`.
- **A gate that reads the package instead of running `hello.iyi`.**
  `bench/tarball_std.sh <unpacked-root>`: every `src/std/` module
  present byte for byte, each one imported, built and run from a work
  directory with `IYI_PATH` and `CRYSTAL_PATH` unset — so the binary's
  own `$ORIGIN/../share/iyi/src` is what resolved it — the eight shipped
  samples that import std built from where the tarball put them, and
  then the shipped directory moved aside to require the failure, which
  is what catches a second copy answering for it. It runs on both
  tarballs (Linux and darwin, the platform whose `cp` flattened this
  directory once already) and on the prefix `install.sh` writes, so the
  bytes a person downloads are the ones checked.
- **A server died at its first collection: the poller's event buffer was
  a number, and the collector is precise.** `IyiSchedulerState#events`
  held `Pointer(UInt8).malloc(...).address` — an address, in a `UInt64`
  field — and a typed object's fields are traced by layout, so the one
  reference to that heap buffer was invisible. The first collection
  freed it; the kernel went on writing epoll's answers into a chunk the
  allocator had already handed to somebody else; the free list it
  scribbled over took the next allocation down. `wrk -c 100 -d 10`
  against the sample web application died at request ~400 inside
  `String#+` with "invalid memory access", and the trail read the same
  every time: a 192-byte untyped chunk (sixteen epoll entries of twelve
  bytes) written *after* it was freed. The field is a `Pointer(UInt8)`
  now, which the layout traces. Same program, same load: 237,066
  requests at 23,705/s and still serving.
- **A fiber's stack was mapped and never handed back.** 256 KiB and a
  registry node per fiber, kept on the grounds that a done fiber's
  stack is never *reused* — true of the fiber, read as true of the
  mapping. A server is a fiber per connection: the address space grew
  with the request count, every collection walked a registry holding
  every request the process had ever served, and the mappings killed it
  first — `/proc/self/maps` outgrew the 64 KiB buffer the root walk
  reads it with, and the program exited saying `no [stack] line in
  /proc/self/maps` (20,000 fibers, half a second, no sockets needed).
  A finished fiber now hands its stack to the fiber that runs next —
  nothing can free the ground it stands on — and leaves the registry
  and its group's child list on the way out. Two hundred sequential
  connections run on **one** stack; the sample application holds 299
  mappings and 14 MB across repeated runs where it used to grow without
  bound. Gated by `bench/server_load.sh`, with both failures proved.
- **The editor froze on `▶ run`, and the thirty-second guard could not
  fire.** `iyi run` hands its pipes to the program it builds, and the
  server handed *its* pipes to `Process` as `IO`s — which makes `wait`
  wait for end-of-file on them as well as for the child. A program that
  serves never closes them: the wait never returned, the timeout's own
  `receive` waited on the same channel, and the single-threaded loop was
  gone for good. One click on a web application's lens and the session
  never answered anything again, which is what "iyi lsp froze" was on a
  kemal port with a server in every file. The verb rides its own fiber
  now and owns its pipes: the loop is free the whole time, the answer
  joins the queue when the program is done, the kill travels (`iyi run`
  forwards `SIGTERM`/`SIGHUP` to the program, so the port is free
  afterwards), and a program printing in a loop is read to a megabyte
  and then hung up on. Measured on the project that found it: a hover
  sent 0.3 s into a `▶ run` over a listening server was answered in 0.3 s
  where it had been answered never.
- **The workspace pull owned the loop for every file it compiled.**
  `workspace/diagnostic` is a compile per file, and the walk was written
  inside the response: nothing could stop it. On this repository that is
  94 compiles, and a hover sent 50 ms in was answered 10.9 seconds later
  — the "it freezes while I type" a person reports as the server being
  broken. The walk now reads its inbox between files: a cancel for the
  pull is `-32800`, and anything else waiting stops it with `-32802` and
  `retriggerRequest`, which is the code the diagnostic request carries
  for exactly this and which the client answers by asking again two
  seconds later. Verdicts are kept by `resultId`, so the pull that is
  asked again resumes instead of starting over. The same hover is
  answered in 0.23 s now, and a warm pull is unchanged at 20 ms.
- **A panic that could not be printed was a segfault.** `raise` printed
  through the program's own output stream, whose failed write raises —
  so the panic printed, failed, printed the failure, failed again, and
  recursed until the stack ended. `iyi run prog | head -3` died of
  "invalid memory access" whose whole cause was the message about the
  broken pipe. A panic goes straight to descriptor 2 now, through a
  write that ignores its own failure: not the program's output (`prog >
  data.json` was putting panics inside the JSON) and not a stream object
  either, because `raise` is reachable before the globals one would use
  are built — reaching for `STDERR` there flushed 22 zero bytes into the
  front of every program's output. A refused write also says what a
  refusal means now - `write failed: the reader is gone, or the device
  refused it` - because "write failed" told nobody anything, and the
  errno that would name which is not reachable on every target the
  prelude has (the Linux path answers `-errno` from the raw syscall,
  darwin's `LibC.write` answers `-1`, and one sentence that is true
  everywhere beats two that differ by platform).
- **A private helper the declarations pruned because its default names its
  own module.** `prune_declaration` refuses a method whose text names a
  type the artifact did not carry, and a parameter's text holds its
  *default* as well as its type: kemal writes `limit : Int32 =
  Kemal.config.max_request_body_size`, the walk asked whether `Kemal` was
  one of the carried declarations — the root is not a declaration inside
  itself — and dropped `ParamParser#read_body_with_limit`. The module a
  consumer imported is always a name it can resolve, so the root answers
  for itself now. Invisible until a body that calls it travelled:
  `undefined method 'read_body_with_limit' for Kemal::ParamParser`.
- **Diagnosed, not fixed: the application boots and faults on the first
  request.** A module used as a *type* — `@next : HTTP::Handler | Nil`, the
  handler chain every kemal app installs — is dispatched as a test per
  includer, compiled against the includers the *producing* build had. A
  consumer's own middleware joins that set, the artifact's
  `Kemal::InitHandler@HTTP::Handler#call_next` matches none of its cases,
  falls through to the union's `Proc` arm and calls a pointer that was
  never a function. `bench/open_dispatch_fixture/` is the same defect in
  forty lines with no shard in it — `first ` where the source build prints
  `first mine end` — and SPEC.md III.6 now states the rule the fix needs:
  an instantiation whose machine code enumerates an open type's members is
  the whole program's answer, so the body travels. A prototype of that rule
  fixes the fixture and uncovers two further shapes behind it, one of them
  the pruning defect above; it is not landed, because the tail is longer
  than one change.
- **A boundary carried its declarations and not what a consumer compiles
  against them.** The 8,079-line kemal application was built against
  `mods/` instead of `lib/` for the first time, and it took twelve defects
  to get from "22 artifacts written" to a binary that boots. Each was found
  by a real call site, not by reading the tool: a shard's **macros** never
  crossed (`Kemal::HandlerInterface` offers `only` and `exclude`, so every
  middleware in the application was `undefined method 'only'`), nor did
  `macro included` — how `DB::Serializable` defines `new(rs)` and
  `from_rs`, without which a query mapping rows into structs typed
  `Array(NoReturn)` — nor the `annotation Field` that hook reads off every
  instance variable. A macro that crossed was not exported (`Kilt does not
  export 'render'`, inside an expansion the consumer never wrote), and
  neither was the constant it names. `DB.open(uri)` was dropped, because
  `db` is an interface library and the shard alone cannot type it — the
  answer exists only in a program that also has `pg` — so the block-taking
  overload beside it was the only one left and the application read
  `'DB.open' is expected to be invoked with a block`. A parameter that
  takes a *class* is one instantiation per class the caller names, and
  three such methods (`read(type : DB::Mappable.class)`,
  `read(type : Enum.class)`) were measured, refused and dropped rather
  than travelling as source. A module carried no `include`, so a
  middleware including `Kemal::HandlerInterface` was not an
  `HTTP::Handler`. A private overload sharing a public one's name stayed
  behind under a generic (`radix`'s `find(path, result, node, first =
  false)`), and the public `find` that travels called it: `no parameter
  named 'first'`. A named argument at a boundary call was keyed on what
  the call site passed rather than on the declaration, so `pg` asked `db`
  for `*DB::ConnectionLost::new<DB::Connection+, IO::Error+>` — one symbol
  per exception class a caller happens to hold. And a module *body*'s
  statements never travelled at all: `PG::Decoders` fills its decoder
  registry with five `register_decoder` lines under the hash they fill, so
  every column came back raw — `the column count returned a Slice(UInt8)
  but a Int64 was expected` — from a build whose front end was clean.
- **What binding costs, on that application, measured both ways.** Cold
  cache, same compiler, same tree: from shard sources **17.0 s**, against
  the boundaries **24.3 s**. The whole difference is the top-level pass —
  2.3 s to 12.1 s — which is reading 267 MB of artifacts; the
  application's own main pass *falls*, 7.9 s to 6.8 s, and codegen and
  linking are level. A program that does nothing but import the twenty
  boundaries spends 11.7 s there against 2.2 s for the same `require`s
  from source. The binary is **14.2 MB from source and 209 MB from the
  boundaries** (`.text` 7.0 MB against 112 MB): a source build's codegen
  is demand-driven, and a consumer links every unit every artifact
  carries. So the boundary's promise — the front end reads declarations
  instead of code — is real and is currently paid for twice over by the
  read itself. The next work is on the artifact: what it carries, and
  when it has to be decoded.

- **A green round is a program that does what was asked.** An empty
  file compiles, and a raw-grounded trial of the rounds arm was seen to
  answer nothing and score a one-round win for it. Green now means the
  build passes on an answer that mentions the task's own literals; an
  answer that does not is re-prompted with what it skipped, and counts
  its round.

### Learned

- **What a migration from Crystal would need, measured before any
  converter.** On an 8,079-line, 99-file kemal application: `tool bind`
  on its own namespace reads 866 public methods, 496 with signatures
  written, 193 a machine can write, 177 an upper bound for a human; the
  new `bench/migrate_count.py` reads the shapes a file-per-module
  language must act on - 204 undeclared instance variables the compiler
  types, 69 `not_nil!` sites, one file reopening a foreign type (R-3).
  One model converted by hand with five edits, none in a method body,
  checks clean and is consumed across an `import`. The rule the exercise
  found: a Crystal namespace is an iyi path and a type's qualified name
  changes with it, a global and mechanical rewrite. SPEC.md III.6 has
  the account; it is the measurement an `iyi migrate` verb would be
  built on.
- **The fourth rounds-arm run refuses by one, and the round is a
  body's.** Under the corrected gate, with the pack carrying the
  `import`/`using` pair: tokens won by 39%, rounds lost 6 to 5, and every
  lost pack round was `split("/")` where the prelude's `split` takes a
  `Char`. The raw sources never call `split`; they carry `chomp('/')`
  inside a body, and a model that has read a single-quoted separator once
  writes the `Char`. That is what a surface cannot carry (R-4), and
  AI_FIRST.md section 5 says what could move it instead: a refusal of a
  one-character string where a `Char` is expected that suggests the
  `Char`, the shape of "did you mean", an edit `iyi fix` applies.

## 0.11.0 — 2026-09-07

**The first half hour of programs, and the header word out of the object.**
0.10.0 took the type id off the front of every object; this release takes
the word behind it out too, wherever nothing reads it. A class carries its
id ahead of its instances only when the program that links says something
dispatches on it — a virtual type was made, a reference union holds it,
the id does not fit sixteen bits — and everything else is its fields and
nothing before them, with the allocator's flags and the colour in two
tables at the arena's head. A 16-byte node is 20 bytes of arena where it
was 24 and Go's is 16; binary trees reads 19 MB resident against Go's 18
where it read 25. Around it, the collector's footprint was read from
`smaps` rather than stated: an arena's first four megabytes refuse huge
pages, the marker's pool is a free list rather than a 64 MB reservation,
a worker's stack begins at 8,192 entries and doubles, the warm budget is
counted in payload and split at the line. Binary trees ends at 16 MB
resident where it ended at 33, runs 0.180 s to 0.150, churn 0.052 to
0.044, and the wall time is under Go's and under Boehm's on all three
programs. `.iyimod` is v45.

The prelude grew by the rule the first half hour set — nothing arrives
before a sample asks for it — and six samples asked: a struct, a file of
`key = value` lines, a table, a trait, a pool of tasks, and the second
half hour's word counter. What they took is what a person expects to
find: `each_with_index`, `any?`, `find?`, `max_by`, `split`, `lines`,
`strip`, `zip`, `uniq`, `Range#map`, `loop`, `assert`, a `Hash` that keeps
insertion order and prints as it is written. `Float64#to_s` is the
shortest decimal that reads back and `String#to_f` the correctly rounded
double, on the prelude's own bignum. The ceiling the prelude is held to
is stated about the library now — 2,814 of 11,773 lines, counted and
gated — where the sentence before contradicted itself. And the compiler
says more when it refuses: a type out of reach names its module and the
`using` that brings it, a nilable receiver names the two idioms, a
missing `end` names the construct it was to close, "did you mean" catches
a transposition, and Crystal's spellings — `ARGV`, `ENV`, `p`, `pp` — get
iyi's answer rather than "undefined". `iyi doc` prints a prelude type's
surface, one line per def, and `iyi mcp` serves it.

Two refusals stand in the record. `iyi lsp` idled at a gigabyte and a warm
fan — VS Code pulls `workspace/diagnostic` every two seconds and the
server compiled the whole root on every one, keeping every program it
built; a pull answers `unchanged` by `resultId` now, and the kept programs
are the open documents, eight at most. And the AI-first gate's rounds arm,
run a third time before this release, lost rounds 5 to 3 on a `using`
line the context pack does not carry; the README says so beside the
number, and the pack carrying it is the next thing that arm asks for.
The website is its own repository. Identity is the released version, as
ever: a 0.10.0 artifact is rejected by a 0.11.0 build and rebuilt, never
migrated.

### Added

- **The second half hour.** `samples/iyi/basics.iyi` counts the words of
  a sentence and prints the three most frequent, and the prelude grew what
  that took, on the rule the first half hour set: `String#each_char` and
  `String#<`, `Char#letter?`, `digit?`, `alphanumeric?` and `whitespace?`,
  `Array#sort_in_place_by` and `sorted_by` (a key rather than a comparison,
  III.1.7a's pair one name longer), `Array#first(n)`, and `to_s`/`inspect`
  on `Array` and `Hash` that print them as they are written - `[1, "a",
  nil]`, `{"a" => 1}` - where a value used to print as its type name.
- **The first program with a struct in it.** `samples/iyi/inventory.iyi`:
  a record type, a list of them, and the questions a list gets asked. The
  prelude grew what it took, on the same rule: `Array#each_with_index`,
  `count`, `any?`, `all?`, `find?`, `max_by`, `min_by` and `last`, and
  `Hash#keys` and `values`, in insertion order.
- **The first program that reads text.** `samples/iyi/config.iyi` parses
  `key = value` lines into a `Hash` or an error carrying the line number,
  and the prelude grew `String#split(Char)`, `lines`, `strip`, `index(Char)`
  and `ends_with?`, and `Array#pop`. `split` counts the way the other
  library counts - `"a,".split(',')` is two, `"".split(',')` is one -
  and `lines` drops the piece a final newline would open, so a program
  reads the same under both.
- **The first program with a table in it.** `samples/iyi/grid.iyi`, and
  the prelude grew `Array(T).new(n) { |i| }`, `Array#index(value)`,
  `delete`, `reversed`, `uniq`, `zip` and `join` with nothing between,
  `Range#map`, `select` and `sum`, `Int32#even?` and `odd?`, a bare `puts`
  that ends a line of `print`s, and `Tuple#to_s`/`inspect` - `{1, "a"}` -
  where a tuple printed as its type name.
- **The first program with a trait of its own.** `samples/iyi/shapes.iyi`,
  and with it `Array#sum` over a block and `compact`, `String#to_i?`
  (`to_i` is now the panicking spelling of it), `Float64#round(digits)`,
  `**` on `Int32` and `Float64` by squaring, `<<`, `>>` and `abs` on the
  integers, `loop`, and `puts a, b`. And a message: a bodiless `def` in a
  trait followed by another `def` was "can't define def inside def", true
  of the parse and false of the mistake; it now says the requirement is
  spelled `abstract def`.
- **A type out of reach is named.** `Stack(Int32).new` after `import
  lib/stack` and no `using` was "undefined constant Stack"; it now says
  which module exports it, the `using lib/stack::{Stack}` that brings it
  in, and the qualified spelling - the answer a call already got - and
  a type declared without `pub` is reported as the module's own.
- **The first program with tasks in it.** `samples/iyi/workers.iyi`: a
  pool of three workers over a channel of jobs, and two fetches at once
  as a typed group. III.4 had an exercise and no sample. Writing it found
  the return-type report showing a partial union - "returning (Panicked |
  Timeout)" for a group that also answers a tuple, the type bound when the
  check fired - so the report now names the members outside the declared
  type on their own, and says what `Panicked` is when it is one of them.
- **`Int32#chr`**, the other half of `Char#ord`, for the Caesar shift
  `basics` now does; and `**` no longer squares its base past the last
  use, which overflowed `2 ** 30` on the way to an answer that fits.
- **`assert`.** `assert add(2, 2) == 4, "add broke"` is the one word a
  `*_test.iyi` needs: a false condition panics with the message and the
  caller's site, which is exactly the contract `iyi test` reads - a
  program that prints what failed and exits 1 - and no framework under
  it. `bench/agent_loop.py`'s own tests printed "add broke" and exited 0,
  which is not a failing test; they assert now, and the gate checks that
  a false assert fails and names its line.
- **`Hash` keeps insertion order.** Two dense arrays and an index over
  them, the compact layout, so `each` follows the order things went in and
  a word count prints its words in the order it met them. Measured
  (`bench/runtime.py`, three readings on mains): the hash workload reads
  0.10x of the other library where the old open-addressed table read
  0.17x, and the README's table is re-read on the same runs - string
  building at 1.8x with the collector off, where the last reading had
  3.6x. Deletion is still not there; no sample asks.
- **`items.sort_by! { ... }` says what it is.** The `!` read as a
  propagation and the `{` was reported as a stray token; the parser now
  names the call - `` `sort_by!` is not a method here `` - and the
  spelling this library uses, before the block it cannot take. The
  participle hint inflects the first word of a compound name
  (`mapped_by` for `map_by`), and the `def sort!` message names
  `sort_in_place` rather than the plain verb it once claimed mutates.
- **The sweep's kept pages outlive the pause.** A budget's worth of
  whole dead pages is kept warm each epoch, and it was kept as chunks on
  the sweep's batch - a list, and a pause drops every list, so whatever
  the program had not got to was gone at the next collection and the
  next epoch's sweep found and linked the same pages again while the
  program carved the frontier or waited on a slice. The sweep lists the
  pages as well now (a bit per page in the arena's header), a refill
  that takes a batch unlists the batch's pages, and the pause turns what
  is still listed into idle warm pages the refill threads into the
  cache's list before it sweeps a slice or carves a slab; the sweep
  meets them as idle and ages them against the epoch's budget, so a
  class the program stopped allocating keeps a budget's worth at most.
  `bench/sweep_exercise.sh` gates it - four thousand chunks, two
  collections, the next four thousand from the first's pages, cleared,
  the class's high water where it was - and its two mutations fail by
  name: warm runs never threaded, and a chunk handed out dirty.

- **`bench/resident_probe.iyi` and `bench/resident_probe.py`.** A
  500,000-node live list under 384 MB of churn in a class of its own,
  and the driver reads peak RSS per process from `wait4`, the pages every
  arena has touched and the sweep's page counters, building a second
  prelude tree beside this one (`--tree`) and running the two
  interleaved so a number is a min-of-N against its neighbour. The
  finding it was built for is in GC_DESIGN.md's footprint section: the
  gap between live set plus budget and what the process holds is the
  concurrent mark's floating garbage - 10 to 17 MB allocated while the
  22 MB list is marked beside the program, born black, dead only at the
  next sweep - and the probe's own number moves by a third between runs
  with where the mark falls.

- **`IYI_HEADER_CENSUS=1`: which classes need their type id in the
  object.** A measurement rather than a mode, printed by codegen to
  stderr one line a class: a class needs the id at `P-4` when something
  reads it there, and what reads it is a virtual type over an ancestor
  or a reference union the class is a member of. Binary trees 0 of 58,
  live churn 0 of 57, the web sample 0 of 76, the concurrency exercise 0
  of 108, calc 0 of 74; a program written to dispatch, 3 of 59.
  GC_DESIGN.md's note on the last eight bytes says what that decided,
  and the census is the decision's print-out now (Changed, below).

- **Crystal's spelling gets iyi's answer.** `ARGV` says the arguments
  are `Program.args`; `ENV` says `Program.env("NAME")` and that there
  is no map of the whole environment; `p` and `pp` say `puts
  value.inspect`; `sleep 0.1` says `sleep` takes milliseconds; `x /
  2` on integers says integer division is `//`; `not_nil!` says `!`
  propagates an error here and how to narrow a nil. The tables are
  `IYI_ARRIVAL_*_HINTS` in `call_error.cr`: names somebody arriving
  from Crystal writes first, not a list of what the prelude lacks. And
  a method a prelude type has not got, with nothing near it in
  spelling - `"a,b".split(",")`, `[1].each_with_index` - says the
  prelude is small by rule, that a method enters when a program in the
  repository needs it, that `iyi doc String` lists what it has, and
  that `--crystal` gives a program Crystal's library; a class the
  program declares gets no such note.

- **A nilable receiver says what to do.** "undefined method '+' for
  Nil (compile-time type is (Int32 | Nil))" named the type and stopped;
  it says now "x can be nil here: narrow it first (`if x`) or give the
  nil an answer (`x || default`)" - the narrowing form `if value = @v`
  for an instance variable.

- **"Did you mean" catches a transposition.** The finder behind the
  suggestion measured plain Levenshtein distance with a tolerance of a
  fifth of the name - one edit under ten characters - and `cuont` for
  `count` is two edits by that measure, so the commonest typo was the
  one never suggested. The finder counts an adjacent transposition as
  one edit now (`Levenshtein.osa_distance`; `Levenshtein.distance` is
  unchanged for programs that call it).

- **`iyi doc String`: a type of the prelude, documented the way a
  module is.** `iyi doc` took a module or an artifact; "what can a
  String do" had no verb, and README.md's answer is prose. A type name
  runs the prelude alone through the front end and prints the type's
  header, then each public method's doc comment and signature, the way
  `IyiMod.surface` prints a module - `iyi doc String`, `Array`, `Hash`,
  `Float64`, `Program`; the compiler's own `allocate` and the primitives
  left out, as the artifact leaves them out. A type's doc comment is
  the first it was given: Crystal let every reopening with a comment
  replace it, and `Int32`, opened in three prelude files, was described
  by the last one's note on division. `iyi doc prelude` lists
  the prelude's types one line each, for the reader who does not know
  what to ask about. `bench/packages_resolve.sh` checks both, and `iyi
  mcp` serves it as a fifth tool, `doc`, taking a module, an artifact
  or a prelude type's name (`bench/agent_loop.py`).

- **`Float64#to_s`.** `puts 0.75` printed "Float64" through
  `Object#to_s`, because no sample had asked for a float in writing; a
  program that computes an average and prints it asks. It prints the
  shortest decimal that reads back as the same double - Steele & White's
  free-format algorithm with Burger & Dybvig's scaling, on a small
  unsigned bignum of 32-bit limbs (`src/iyi/float.iyi`), no table of
  powers and no libc, since the prelude links nothing - in Crystal's
  notation: `1.0`, `0.1`, `123.456`, `0.0001`, `1.0e-5`, `1.0e+15`,
  `-0.0`, `Infinity`, `NaN`. Three thousand random doubles read back
  and matched Python's `repr` digit for digit. And `String#to_f`, the
  other direction, correctly rounded on the same bignum - the quotient
  taken to 54 bits with a sticky remainder, half to even, subnormals and
  the format's ends included - so `"0.1".to_f` is the double `0.1` is
  and what `to_s` wrote reads back to the same bits; 2,500 random
  decimals matched Python's `float`. With them `Float64#abs`, `floor`,
  `ceil` and `round` (half away from zero, Crystal's), and an integer
  divided by a float is a float, as in Crystal. `bench/float_text.sh`
  pins forty printed cases and twenty parsed, prints and reads back
  twenty thousand doubles to their bits, and fails by name when the
  digits do not stop short, the notation's range moves, or the parser
  truncates.

- **The arena exercise's speed numbers are the best of three passes.**
  The gate is a ratio against the bump pointer measured in the same
  run, and one pass on darwin's shared runner read 2.7x where the next
  read 2.2 - a scheduler's tick in one loop and not the other; each
  loop runs three times now and the least is the number, the way every
  number in this repository is read.

- **A panic names the value.** `index 5 out of range for 2 elements`,
  `index 7 out of range for a string of 3 bytes`, `no such key "b"`,
  `not a number: "12x"` - where it was `index out of range`, `no such
  key`, `not a number`. And `String#inspect` is the string in double
  quotes, the way the literal is spelled, which is what `Object#inspect`
  promised and did not do.

- **A panic names its site.** `iyi: panic: boom` is followed by
  `  at /path/to/file.iyi:12` when the `raise` is in the program's own
  code, the compiler filling the file and line in at the call; a panic
  the prelude raises - an index out of range, a division by zero -
  prints no prelude line, since that is not where the bug is. The first
  line is what it was, so what greps for it still does.

- **`"0.5".to_f` in the REPL.** A session's line is evaluated the way a
  macro is, and the macro interpreter had `StringLiteral#to_i` and no
  `to_f`; it has both.

- **A missing `end` names what it was to close.** "expecting
  identifier 'end', not 'EOF'" at the last line of the file sent a
  reader back through the whole file for the one unclosed construct;
  the parser keeps the constructs still open - `def`, `if`, `unless`,
  `while`, `until`, `class`, `struct`, `module`, `begin` - and says
  "expecting 'end' to close the def that began at line 1, not the end
  of the file".

### Changed

- **The prelude's ceiling is stated about the library, and measured.**
  SPEC.md read "11,765 lines, ceiling 3,734", a sentence contradicting
  itself: the 3,734 was Crystal's 0.1.0 *library*, and iyi's prelude has
  since taken on what that prelude got from libgc, pthreads and libc's
  printf - the collector, the scheduler, the float text - which are most
  of its lines. The figure held to the ceiling is now the library on its
  own, 2,814 lines: everything under `src/iyi/` except `concurrency.iyi`,
  `thread.iyi`, `float.iyi` and the block between two marks in
  `prelude.iyi`, counted by `bench/doc_numbers.py` and gated like every
  other number. The whole-prelude figure stays beside it.
- **The website is its own repository.** `site/`, `doc/website/`,
  `bench/site_facts.py`, `bench/website_citations.py` and the site
  workflow moved to `sdogruyol/iyi-lang.sdogruyol.io` with their
  history (`git subtree split`), and the site is published from there at
  https://iyi-lang.com. The site still reads this tree - the
  samples, README.md, SPEC.md, CHANGELOG.md, `bench/doc_numbers.py`'s
  measurements - through an `IYI_REPO` path (default: a sibling
  checkout named `iyi`), and its build checks out this repository to
  do so. The citation gate went with the documents it gates; the
  identity floor lost the allowances that existed only for the site's
  files. Found on the way: four code spans in SPEC.md and CHANGELOG.md
  escaped inner backticks with a backslash, which CommonMark does not
  read inside a code span, so the site's prose gate saw words welded
  across a stray `<code>`; they are double-backtick spans now.

- **An object is its fields; the header word is per class, and only
  where something reads the type id off the object.** A class carries
  its id in a word ahead of its instances when the program that links
  says so (`gc_layouts.cr`, `iyi_headed?`): a virtual type over an
  ancestor was ever made, a reference union has the class or an
  ancestor, the id does not fit sixteen bits, or it is `String`, which
  the prelude builds from bytes and stores the id under itself. The
  answer is a byte per class, `Name:headed` beside `Name:type_id`,
  defined in the main module at the end of codegen (codegen makes
  virtual types late) and read by a unit's object code the way
  the id is, so a module allocates right under a consumer that
  dispatches on a class it never did; codegen allocates an instance
  through `__iyi_new(size, type_id, flags)`. Untyped memory -
  `Pointer.malloc`'s, `String`'s bytes aside - is headless whatever
  the class: a 4096-byte buffer is a 4096-byte chunk where it was
  5120. Past the top class an object is a mapping and headed. What the
  word carried moved to two tables at the arena's head, indexed by the
  chunk's number on the grid: an entry of three bytes - the
  allocator's flags and a headless object's sixteen-bit type id, one
  line for both because the mark reads both - and a colour byte of its
  own, because the allocator writes the entry and the helpers write
  the colour. A 16-byte node is 20 bytes of arena where it was 24 and
  Go's is 16; the race table reads binary trees at 19 MB resident
  against Go's 18 where it read 25. The price is the mark's on eight
  cores - a shade is two table lines and the object's - binary trees
  4% at the minimum of forty-one interleaved runs once the words the
  helpers read per shade left the lines the carve writes; on one core
  the three programs are where they were.
  Measured and turned back on the way, with the numbers in
  GC_DESIGN.md ("The header round, built"): the grid arithmetic on the
  allocation path (a free chunk's second word is its grid index now,
  the carve keeps its cursor's entry beside the cursor), a walk of a
  batch for its pages (the range rides in the batch head's two words'
  high bits), the epoch's parity read before a refill's lock (the
  thread exercise found live lists freed), a free colour in the mark
  table, born-white objects, a barrier that pushed without graying,
  and a compare-and-set without a read first. The two gates that
  pinned the header moved with it: the arena exercise's `header:` check
  allocates a headed and a headless object through `IyiHeap.new_object`
  and reads both back; `object_header.cr` says which objects keep the
  word. `.iyimod` is v45: v44 object code stored an id under every
  `__crystal_malloc64`, which under this prelude is the chunk before.

- **Huge pages per arena, past its first four megabytes; and the heap's
  neighbours read from `smaps` and cut.** An arena's first four
  megabytes (`IyiHeap::HUGE_AT`) refuse transparent huge pages and the
  rest of it is the kernel's default; the rule was to refuse the first
  eight arenas and let the ninth and after take them whole, and the
  ninth arena is not the large one: binary trees carried five arenas of
  a few objects each at exactly 2 MB resident, 10 MB of a 33 MB set.
  Asking for the tail with `MADV_HUGEPAGE` was built and measured out -
  compacted for on the fault path, a mutator answered a stop late, and
  live churn's longest pause read 4 to 10 ms in three runs of twelve.
  Read from `/proc/self/smaps` at the end of binary trees and of the
  probe, three more terms that had been stated otherwise: the marker's
  64 MB pool region was 2 MB resident (a huge page on its first touch,
  for 425 KB of batches), the arena directory another 2 MB the same
  way, and the workers' 32 MB stacks 40 KB resident across eight but
  272 MB of address space. A batch taken from the pool is free again
  (a lock-free free list; new words from 64 KB pieces that refuse huge
  pages; the reservation and its "pool region is full" gone - 64 KB
  through eleven marks of a million nodes with fifteen helpers); a
  worker's stack begins at 8,192 entries and doubles as a mark needs
  it; the directory refuses huge pages. Binary trees ends at 16 MB
  resident where it ended at 33, and reads 22-24 MB peak on the race
  table where it read 26-31, live churn 180-186 where it read 192-206,
  the resident-set probe 100 MB median on two cores where it read 123 to 140.
  `bench/parallel_mark.sh` gates the pool's size and the stack's growth
  and fails each by name; `bench/arena_exercise.sh` reads `statm` for
  twelve one-object arenas and the flags the kernel holds for an
  arena's two halves in `smaps`, reports what `AnonHugePages` says it
  gave, and removes and stretches the refusal in a copy of the prelude.

- **The warm budget is counted in payload and split at the line.** A run
  of dead pages kept or released whole overshot the budget by the run,
  and a run is an arena when the arena is all dead: 13 MB warm for a 4
  MB budget. And the budget was counted in pages against the bytes the
  program asks for, so a 64-byte class's warm pages held an eighth less
  than the epoch's demand and the tail of every epoch's dead pages went
  cold and was faulted in again - churn released and reopened 5,444
  pages over its 122 collections, and releases none now. With the
  sweep's loop testing the parity first, binary trees runs 0.180 s to
  0.150 and churn 0.052 to 0.044 on `bench/gc_race.py`, the median of
  four interleaved against the tree before; live churn is where it was.
  Both are under Boehm's wall now, binary trees under Go's.

- **A free chunk of the current epoch's parity is a list's.** The sweep
  took every free-flagged chunk as dead; a chunk the program handed back
  this epoch sits on the cache's list, and the sweep of its arena would
  have put it in a run under the list. `IyiHeap.free` stamps the epoch's
  parity, and the sweep leaves a free chunk of the current parity where
  it is - the same stamp a threaded warm run wears.

### Learned

- **The collector's bits in a byte table beside the objects, measured
  out.** Built as the first step of the round that would take the header
  word out: colour, free, atomic and the epoch's parity in a byte per
  sixteen bytes of each arena, the mark shading and the sweep restamping
  the byte rather than the object's line. The mark of a million-node tree
  ran 14.1 ms to 15.7 alone and 6.3 to 7.2 with helpers, churn 40 ms to
  48, binary trees and live churn 5% slower - the object's line is loaded
  for its fields regardless, and the byte is a second dependent line and
  an arena lookup on every shade, scan and pop. Reverted; the number is in
  GC_DESIGN.md's note on the last eight bytes, where it now prices the
  headerless layout too.

- **What the resident-set probe did not find, and what was measured out.**
  The probe was built on the hypothesis that a budget's worth of pages
  kept warm was never taken up by the carve, and 151 MB touched against
  a 68 MB design would fall to 70. The kept pages were being consumed
  every epoch; what was unmapping them was the scavenge, every pause,
  because a churning class's arenas are all dead at every mark. Five
  things were built and taken out with a number each (GC_DESIGN.md):
  warm runs as bump regions the carve took first (churn 48 ms to 73 -
  the carve became the fast path, and it is not one); warm runs threaded
  into a list the moment the sweep closed them (67 - a pass over memory
  the sweep had just made); a refill spinning for a helper's slice to
  end; the scavenge sparing an arena the epoch had allocated from (the
  probe 140 MB median against 129 without it, on two cores, the race
  table unmoved - a dead arena is resident garbage until the sweep
  reaches it); and the scavenge sparing an arena holding warm pages
  (spared nothing a churn leaves). Found and kept on the way: a run that
  continues one a slice's end cut begins on its own first page; and the
  two places a page is released late leave the first page alone when a
  chunk of the page before reaches into it, because that chunk may be an
  object by the time the `madvise` lands, and the `madvise` would zero
  its tail.

### Fixed

- **`iyi lsp` idled at a gigabyte and a warm fan.** Two things, found
  with two Cursor windows open and a battery draining. VS Code's client
  pulls `workspace/diagnostic` two seconds after every answer, for as
  long as the window lives; the server ignored the `previousResultIds`
  the pull carries and compiled every `.iyi` under the root - up to two
  hundred - on every one, so an editor doing nothing was a build every
  two seconds. And every one of those compiles was kept: the last good
  `Compiler::Result` per path, a whole typed program each, held for a
  hover fallback on files nobody had open. Measured on this tree's
  `samples/`: 1,026 MB resident and five CPU-seconds per pull, forever.
  Now a pull answers with a `resultId` - a fingerprint of the open
  buffers and every `.iyi`, `iyi.mod` and `iyi.sum` under the root by
  size and mtime, a stat per file - and a pull that hands the same id
  back gets `unchanged` for every file and no compile: 190 MB, and
  0 ms after the first. The fallback is kept for open documents only,
  at most the eight compiled most recently, and released on close.
  `bench/lsp_session.py` steps 31b and 31c are the gate: the second
  pull is unchanged and under half a second, a file touched on disk
  makes the next one full again.
- **The allocation gate was a number, and the number was one
  machine's.** 0.10.0's arena exercise asserted a 40 ns ceiling on a
  release allocation: 13 ns on a twenty-core Linux box, and 41 on
  darwin's shared three-core runner, where the bump pointer it is
  supposed to be compared against reads 28 to Linux's 11. The platform's
  own floor moves by two, so the gate failed the second machine while
  passing every regression the first has seen. It is a ratio now - the
  arena's allocation against the bump pointer measured in the same run,
  2.5x - because what a regression does is multiply: a lock taken per
  allocation read 3.5x, a sweep walked per refill 4.7x.

- **The docs' race table and the two claims that outlived it.** The
  table GC_DESIGN.md carried was read before the sweep round's retry
  landed, and it stated the longest pause as "Go's or near it" on every
  program. Read again on the tree 0.10.0 shipped, on mains, the median
  of four runs: the wall time is under Go's on all three and under
  Boehm's on two, and the total paused is a fortieth to a tenth of
  Boehm's - but the longest pause is under Go's only on churn, and is
  three to four times Go's on live churn and binary trees, whose second
  stop retreats over a 200,000-node chain held on a register. The
  spread is printed with it, README and SPEC III.4.11 say the same
  thing now, and SPEC's allocation price is the release build's 13 ns
  the arena exercise gates rather than the plain build's.

## 0.10.0 — 2026-09-05

**An object is its fields, and which thread a mark runs on is measured.**
0.9.0 gave the collector its design and a number beside the collector it set
out to match; this release takes the last word out of the object and the last
estimate out of the collection. Crystal's layout carries a type id at the
object's front, and iyi's header carried one in the mark word's high half
too: every class object was eight bytes larger than its fields, and binary
trees' node — two pointers — was a 32-byte chunk where Go's is 16. The front
copy is gone. A class is laid out as its instance variables and nothing
before them, every dynamic type-id read is the `u32` at `P-4`, and the header
word is under the pointer in every allocator mode the prelude has, because a
module's object code has to link under one without corrupting under another.
`.iyimod` is v44. The footprint is every object's eight bytes: binary trees
29 MB resident to 25, live churn 249 to 186, and a 200,000-node list marks
200,000 times eight bytes fewer.

Which thread a mark runs on was an estimate — the last mark's live bytes
against a megabyte — and an estimate is the last mark's, not this one's:
binary trees' second mark read sixteen bytes, the stretch tree having gone,
and then marked the three-megabyte long-lived tree inside its pause, 2 ms in
a table whose other rows are tens of microseconds. There is no estimate now,
on either platform. Every collection stops the world, pays the sweep debt,
shades the roots and marks up to a thousand objects on the triggering thread;
a mark that ends inside that bound *was* the whole mark — one stop, no helper
woken, which is all 122 of churn's collections at 87 µs longest — and one
that does not is a large live set, and goes beside the program with every
helper there is. Binary trees' longest pause is 102 µs on Linux where the
estimate left it at 2 ms, and 88 µs on darwin where it left it at 2.0.

Eight bugs, and the two that decided the release were found where cores are
few. `POOL_ACTIVE`, whose fall to zero is how a mark knows it is over, was
pre-set to the helper count the mark asked for; a permit lets a helper skip a
generation, and then the count never fell — the collector's own gate hung on
a two-core runner and the thread exercise on three. And the sweep round's
retry, which keeps a helper at the round when every arena with work is inside
another's slice, looked again after 64 pause hints: every look takes the
runtime lock, the one every refill takes, and it came to 4.6 million looks
across binary trees where the wait this ships comes to 71,000. That was
darwin's throughput, five times 0.9.0's wall time on the three-core runner,
and the wait is a slice long now. Interleaved on one machine with the two
helpers three cores give, minimum of fifteen: binary trees 0.199 s against
0.9.0's 0.217, churn 0.050 against 0.066, live churn 0.095 against 0.091, and
the longest stop 88 µs against 283. The eighth was found by the release's
own gate run: a mark's taker count was the count asked less the permits
left, two words set one after the other, and a helper reading them across a
round's reset underflowed the difference — the takers are a counter now.

An allocation has a ceiling as well as a printed number now, 40 ns in release
against the 13 to 15 it measures, because this cycle put a lock in the
allocator's path and measured it away again — and a number nobody asserts is
a number that drifts.

Identity is the released version, as ever: a 0.9.0 artifact is rejected by a
0.10.0 build and rebuilt, never migrated.

### Added

- **Every collection starts stopped and goes beside the program if the
  live set turns out large.** Which thread a mark runs on was decided
  from an estimate - the last mark's live bytes against a megabyte -
  and the estimate was wrong in both directions: binary trees' second
  mark read sixteen bytes, the stretch tree having gone, and marked a
  three-megabyte tree inside its pause (2 ms in a table of tens of
  microseconds), while churn's tiny live set read as tiny for a mark
  with four megabytes of fresh allocation to walk. There is no estimate
  now. Every collection stops the world, shades the roots and marks up
  to a thousand objects on the triggering thread; a mark that ends
  inside the bound was the whole mark, one stop and no helper woken
  (churn's 122 collections are all of them, 87 µs longest), and one
  that does not hands its stack to the pool and goes beside the program
  with every helper there is - beside the program the mark's length is
  what the mutator pays for, and the cores are otherwise idle, where
  inside a pause fifteen helpers over three megabytes cost twice what
  three did. Binary trees' longest pause is 102 µs where the estimate
  left it at 2 ms.

- **A mark asks for the helpers it needs.** A mark's permits are as
  many as it asks, taken one each by whichever helpers wake first, and
  the first taker is the one that finishes a concurrent mark; a helper
  woken without one parks again. What the mark waits for is the count
  *taken*, never the count asked - a helper can spend its wake on the
  sweep round and find the mark's generation already seen by the time
  it looks again, and a wait for a headcount that never arrives is a
  hang, which three cores found one run in three
  (`bench/thread_exercise.sh`, eight threads; it reproduces on Linux
  under `taskset -c 0-2`).

- **A thread-local is one load under iyi's prelude, on ELF.** Crystal
  reaches a `@[ThreadLocal]` through a `noinline` accessor, which is
  what keeps LLVM from hoisting the address across a fiber switch that
  lands the fiber on another thread. An iyi fiber belongs to its
  scheduler thread and never moves, so the address is a constant for
  the fiber's life: the accessor is gone on Linux and the allocator's
  cache pointer is one `%fs:`/`tpidr_el0` load, where it was four calls
  per allocation. Mach-O keeps it: there is no local-exec there, a
  thread-local's address comes from `_tlv_bootstrap` through a call
  whatever the model, and one accessor per read is what keeps that call
  out of the middle of an allocation. A `--crystal` program keeps it
  everywhere, its fibers being Crystal's.

- **A Linux helper spins before it parks; a darwin helper spins.** A
  parked helper has to be woken and then scheduled before it marks, and
  on a machine with three cores that latency is the mark's: the mutator
  keeps allocating under a mark that has not started, paying the barrier
  and its assists. A park was built for darwin's helpers - a pipe each,
  there being no futex there and a signal handler being allowed `read`
  but not `os_unfair_lock_lock` - and it was measured on CI's three-core
  runner and refused: binary trees 1.07 s against the spin's 0.23,
  churn 0.19 against 0.075. darwin's helpers keep spinning on the
  generation, which is what 0.9.0 shipped, and the core one burns while
  idle is worth less than the mark it delays. Linux keeps the futex
  park, whose wake is microseconds, with a spin of about fifty
  microseconds before it - collections come in bursts, and a helper that
  spins through one is hot for the next.

- **Which thread the mark runs on is measured on both platforms.** The
  bounded first stop was Linux's alone for most of this cycle, and
  darwin kept 0.9.0's estimate on a measurement of the rule without its
  drain: the decision was opened to every collection while the bounded
  mark itself stayed behind a Linux-only flag, so every collection went
  beside the program whatever it found, and churn's 122 of them cost
  0.49 s against 0.075. With the drain on both platforms churn's 122
  marks all end inside the bound - one stop each, 18 µs at their
  longest, no helper woken - and what the estimate cost darwin is gone
  with it: binary trees' second collection read sixteen bytes of last
  mark, marked 2,097,568 bytes stopped and paused 2.1 ms, where every
  other stop in that run is under 230 µs. One rule now, where
  `concurrent_possible?` decides.

- **An assist yields to a stop.** A mutator that assists the mark scans
  up to a thousand objects inside the allocator, where a stop is
  deferred until the thread leaves - a hundred microseconds a second
  stop waited for. It stops assisting the moment a stop is asked for.

- **An allocation has a ceiling, not just a printed number.**
  `bench/arena_exercise.sh` reported the allocator's nanoseconds and
  nobody reads a printed number twice. It asserts them now, in release,
  where a program ships: 40 ns for an allocation and for an alloc+free
  pair, against the 13 ns they measure on the Linux machine and 15 on
  darwin. The ceiling is what a regression has to cross rather than a
  target to tune to - a lock taken per allocation put it at 39 ns, a
  sweep walked per refill at 80 - and this cycle wrote the first of
  those and measured it away.

- **One type id: an object is its fields.** Crystal's layout carries
  the type id as an `i32` at the object's front, and iyi's header
  carried it in the mark word's high half too, so every class object
  was eight bytes larger than its fields - binary trees' node a
  32-byte chunk where Go's is 16. The front copy is gone: a class is
  laid out as its instance variables, every dynamic type-id read is
  the u32 at `P-4`, `offsetof` and the layout tables lost their shift,
  and a string literal is `{header word, {bytesize, length, bytes}}`.
  Every allocator mode of the prelude leaves the header word under the
  pointer - the bump pointer and wasm keep their size at `P-16`,
  Boehm's and the process heap's blocks grow by eight with the pointer
  eight bytes in - so an object's layout is one thing under all of
  them and a module's object code links under any. A `--crystal`
  program and the compiler's own bootstrap keep Crystal's layout
  (`Program#iyi_object_layout?`). `.iyimod` is v44. Binary trees is 29
  MB resident to 25, live churn 249 to 186, and a 200,000-node list
  marks 200,000 times eight bytes fewer (GC_DESIGN.md, "One type id").

### Fixed

- **The mark's wake, taken apart on darwin and put back.** Three things
  were found while a park for darwin's helpers was built and then
  refused (Added, above, has the numbers). A pipe made with a heap
  allocation asks the allocator for the runtime lock the collector is
  holding while it waits for that very helper to announce itself:
  darwin's thread exercise deadlocked on its first step. A wake for a
  helper that is not parked leaves its byte in the pipe, and 65,536 of
  them fill it: the next waker blocks inside `write` holding the
  runtime lock, which is every thread in the program. And a symbol the
  runtime reaches for lands on six gates' darwin allowlists, the thread
  floor's twice. None of it ships; all of it is why the spin stayed.

- **A mark counted the workers it asked for, not the ones that came.**
  `POOL_ACTIVE` - the number of workers holding work, whose fall to zero
  over an empty pool is how a mark knows it is over - was pre-set to the
  helper count the mark asked for. With permits a helper may skip a
  generation, and then the count never fell: the helpers that did take
  work spun in the drain forever. It hung the collector's own gate on a
  two-core runner and the thread exercise on three. Every worker counts
  itself in now, in `drain`, which is the only place that knows a worker
  arrived.

- **A mark's taker count was a difference of two words, and the
  difference raced.** How many helpers took a permit - the count the
  mark waits for, and each taker's slot - was the count asked less the
  permits left, two pool words set one after the other at every round.
  A helper whose CAS on the permits landed just before a round reset
  both read the new count asked, zero, less its old permit, and the
  subtraction underflowed: `iyi: panic: arithmetic overflow` out of the
  thread exercise, once in eighty runs on eight threads. The takers are a
  word of their own now, counted up by each taker, whose slot is the
  count it found; nothing is subtracted.

- **A bounded first stop left its live counts in the worker's page.**
  A mark that ends inside the bound does not reach the drain's end,
  where the pending per-arena live counts are flushed, so the scavenge
  read an arena whose only live objects sat in that count as empty and
  handed its mapping back under them - a segfault one run in seventy.
  Flushed before the scavenge now.

- **A helper at the sweep round left it when every arena with work
  was inside another's slice.** It read that as nothing left and went
  back to its park; the allocating thread then swept the heap itself,
  slice after slice - 8,600 slices to the helpers' 1,200 on binary
  trees once its nodes fit one arena. A helper waits and looks again
  now, and the wait is a slice long, because a slice is what it waits
  for: a claim is let go at some walker's slice end, and the wait ends
  early when a helper's does. Looking again after 64 pause hints, as
  the first cut did, took the runtime lock - the lock every refill
  takes - 4.6 million times across binary trees where the slice-long
  wait takes it 71,000, and it took it from the allocating thread: on
  darwin, whose helpers spin where Linux's park, binary trees ran
  1.33 s against 0.33, churn 0.32 against 0.061 and live churn 0.33
  against 0.124 (a ten-core M2 Pro, interleaved, min of nine; 0.9.0
  measures 0.30, 0.082 and 0.116 there). The longer wait costs the
  round nothing - the helpers take 13,295 slices against the short
  wait's 10,292, and leave the allocating thread 34 against the 471
  it swept with no retry at all.

- **The concurrent mark's failure proof assumed a black holder.** The
  exercise moves a payload into a holder and, with the barrier's shade
  removed, expects the payload freed; that holds only if the holder was
  black at the move, and with objects eight bytes smaller the workers
  reached the 200,000-cell chain first and the holder last. The move
  waits for the holder's colour now, which is what its message claimed.

## 0.9.0 — 2026-09-03

**The collector races Go, and is measured against it.** 0.8.0 seated iyi's
own collector as the default; this release gives it the rest of its design
and a number beside the collector it set out to match. The runtime has a
kernel thread now — raw `clone` and `futex` on Linux, libSystem's pthreads on
darwin, a stop-the-world by signal that reads the stopped thread's registers
out of its context, and a thread-local that is the language's own
`@[ThreadLocal]` — measured against the dependency floor before it was
designed, and the floor did not move. On it: a parallel mark on helper
threads with a stack per worker and a pool of batches; a mark that runs
beside the program on a write barrier the compiler emits, a collection being
two stops of tens of microseconds where it was one of milliseconds, with
Go's two answers to a mutator outrunning the mark — allocate black, and
assist; a sweep that runs beside the program too, in slices of an arena
taken by the helpers after every collection and by an allocating thread only
for the slice it needs; and a footprint that follows the live set — a
one-word object header, eight-byte size classes, pages handed back to the
kernel by the sweep and taken up again by the carve, and `IyiMark.growth`,
Go's GOGC with Go's meaning.

`bench/gc_race.py` is the measurement: three programs written once in iyi
and once in Go, under iyi's collector, under Boehm as Crystal ships it and
under Go's. On the twenty-core Linux machine GC_DESIGN.md records, the
longest pause is Go's or under it on every program, the wall time is under
Go's on all three and under Boehm's on two, and the footprint is Go's on
churn and a budget or two over it on the rest; on darwin's three-core CI
runner the shape is the same. Every mechanism has a gate that fails by name
when it is removed, and the gates run on Linux x86-64, on aarch64 under
emulation, and on darwin arm64.

`Share` is built: a type's marker is decided structurally on the compiler's
AST, `@[Share]` is trust, and a thread's block may capture only what it
carries. The tarball went on its diet — a minimal static LLVM, 70 MB on Linux
where it was 86 and 50 MB on darwin where it was 72, with the clean-room proof
unchanged — and Windows' run-time diagnosis is retired after thirty-six clean
builds of a watch that is a gate now.

`.iyimod` format is unchanged at v43, and identity is the released version
as ever: a 0.8.0 artifact is rejected by a 0.9.0 build and rebuilt, never
migrated.

### Added

- **The sweep runs beside the program, in slices (GC_DESIGN.md Stage
  8).** Two measurements decided it, both on release builds: the
  write barrier, removed by renaming its entry point so codegen emits
  none, was one percent of binary trees' wall time under a
  stop-the-world mark - not the gap; the sweep on the allocating
  thread, timed with `rdtsc` around the allocator's own walks, was a
  fifth of it (41 ms of 214, with 15 ms the whole gap to Go), a third
  of live churn's, a fifth of churn's. A sweep is a walk of every chunk
  header in the heap at memory's speed, once per collection, and the
  thread that allocates was walking it. Now an arena is swept in 64 KB
  slices from a cursor it carries: an allocating thread that finds
  nothing swept for its class takes one slice of an arena of that
  class, microseconds, and allocates from it; after every collection
  three of the mark's helpers take slice after slice until nothing is
  left, handing each slice's batch to the centre as they go. The walk
  claim is held for a slice, so three helpers share one arena; the
  cursor is written before anything can stop the writer, so a pause
  finishes whatever is left from the cursors, and the triggering
  thread does the same before it stops anything - a half-swept arena
  wears two epochs' colours, and the mark reads one. Pinned to the
  fast cores and interleaved, minimum of ten: binary trees 222 ms to
  199, live churn 102 to 101, churn 52 to 40; the pauses unchanged;
  the thread exercise's allocation under four threads 99 ns to 104,
  under thirty-two 19 µs to 10. What the first cut got wrong is
  recorded with the design: whole arenas on the helpers made the
  allocating thread wait an arena or carve, helpers woken inside the
  stop preempted the waker and made a 90 µs pause 1.6 ms, fifteen
  helpers sweeping cost the allocating thread its core's other half,
  and a lock on every refill of a class with nothing left made eight
  threads' allocation 8 µs. `IyiMark.swept_by_helpers` counts the
  arenas the helpers began; the trigger gate's lazy proof counts them
  with the allocator's, and its failure proof removes both.

- **The tarball went on the diet its own Learned entry prescribed.** The
  Linux release package used to carry libLLVM and everything libLLVM asks
  for — libedit, libxml2, libicu (icudata above all), libncursesw, libzstd,
  179 MB of `lib/` — because the compiler linked the distribution's shared
  monolith. It now links a minimal static LLVM built per Crystal's own
  recipe, recorded in 0.6.0's Learned entry and collected here:
  `BUILD_SHARED_LIBS=OFF`, `MinSizeRel`, only the five targets the
  compiler reaches (X86, AArch64, ARM, AVR, WebAssembly), and zlib, zstd,
  libxml2, ffi, z3 and libedit all `OFF`, so the closure never comes into
  existence rather than being bundled well. `lib/` is libgc and libstdc++
  at 3.4 MB, the tarball fell from 86 MB to 70 MB, and the installed
  footprint halved (227 MB to 107 MB). The clean-room proof is unchanged
  and passed on the first build: unpack somewhere else, run, and the
  package names nothing outside itself but the loader and libc.

  Two guards moved with it. `bundle-runtime-libs.sh` now reads which
  direction the binary chose: a shared-LLVM compiler must ship libLLVM —
  the original guard — and a static one must ship none, because a
  libLLVM in `lib/` would mean the link quietly went shared after all.
  And CI builds the static LLVM in its own container rather than
  downloading one built elsewhere, cached on the recipe key: a static
  archive must be linked by the glibc it was compiled against, and an
  archive from a newer machine is a link error or a silent
  binary-for-newer-glibc. The roughly-an-hour build is paid once per
  LLVM bump, not per push. darwin's tarball kept brew's shared LLVM for
  one commit, stated rather than implied, and the entry below is its diet.

- **darwin's tarball went on the same diet, and the recipe became one
  file.** 0.8.0's darwin package carried brew's shared libLLVM in `lib/`
  and, by the bundler's fixed point, everything it names outside
  `/usr/lib` and `/System` — because the compiler linked
  `/opt/homebrew/opt/llvm`. The darwin job now builds the same static
  minimal LLVM the Linux job builds, links against it, and ships `lib/`
  with libgc alone; `bundle-runtime-libs.sh`'s direction guard applies
  unchanged, and `otool -L` on the packaged binary must name nothing
  outside the package but `/usr/lib` and `/System`, which was already
  darwin's only self-containment proof and is now the one that matters.

  The recipe moved out of the workflow into `scripts/build-static-llvm.sh`
  on the way, because two cmake lines in two jobs are two recipes the day
  one is edited. It asserts what it built — `llvm-config --shared-mode`
  must say `static`, and no `libLLVM.so`/`.dylib` may exist under the
  prefix — and CI keys both caches on the file's own hash plus the
  runner's platform: editing the recipe is what invalidates the cache,
  no version token has to be remembered, and a darwin archive can never
  be restored into the Linux container (cache keys are repository-wide,
  and the previous key named no platform). The Linux cache rebuilds once
  for the key change. brew's `llvm` left the darwin install line: nothing
  in the job asks for it any more, and the bootstrap Crystal brings what
  it needs for itself. The recipe was run to completion on Linux before
  this entry was written — 13 minutes on 20 cores, `--shared-mode`
  `static`, the five targets, `-lrt -ldl -lm` as its whole system list —
  and the tarball built against it packages libgc and libstdc++ and
  nothing else, exactly as CI's own build did.

  darwin was then run the same way, on an M2 Pro (10 cores, Xcode's
  clang 21, macOS 26.5). The recipe took 9m36s, answered `static`, and
  its whole system list is `-lm`; `make -B iyi-tarball` against it said
  "static LLVM: no libLLVM to carry, and none carried", bundled
  `libgc.1.dylib` alone, and closed. Against 0.8.0's darwin package:
  the tarball fell from 72 MB to 50 MB and the unpacked footprint from
  217 MB to 154 MB; `lib/` went from 173 MB (libLLVM.dylib at 164 MB,
  libz3, libzstd, libgc) to 208 KB. It fell by less than Linux's because
  `bin/` grew from 30 MB to 139 MB — `iyi` and `iyi-daemon` each carry
  LLVM inside now, 72 MB apiece. `otool -L` on the packaged `iyi` names
  `/usr/lib/libSystem.B.dylib`, `/usr/lib/libc++.1.dylib` and
  `@rpath/libgc.1.dylib`; the bundler's fixed point converged in one
  turn; unpacked under `/tmp` the package ran `hello.iyi`, the kqueue
  exercise, `--crystal` and the daemon, and `iyi version` reported a
  release build. The four gates held against the compiler it built, and
  the floor's measured list for the compiler is `libc++ libgc libSystem`
  — libLLVM left it. One thing the run found that CI cannot: a shell
  exporting brew llvm's suggested `LDFLAGS=-L/opt/homebrew/opt/llvm/lib`
  rides into `--link-flags` ahead of `llvm-config --ldflags`, the linker
  takes brew's LLVM 22 archives for the static 20.1.2 ones, and the link
  dies on zstd and zlib symbols. Unset it.

- **What a kernel thread costs the floor, measured before the design
  that needs one.** Every open row in the tree waits on threads —
  GC_DESIGN.md's Stages 4, 7, 8 and 9, and `Share`, which III.4.7 counted
  and then refused to build without a caller — and III.9's objection was
  exact: a scheduler that reached for pthreads would put libc back on the
  link line. `bench/thread_floor.iyi` reaches for the kernel instead and
  the objection dissolves on Linux: `clone` with the thread flags onto a
  stack of the program's own mapping, the child's whole life inside the
  asm, `futex` on the tid word the kernel clears at exit for the join,
  and the binary keeps the five C-template names and nothing else —
  asserted by `bench/thread_floor.sh`, plain and release, with the
  aarch64 arm run under emulation in CI beside III.4's. The same probe is
  a stop-the-world entire: `rt_sigaction` with the kernel's four-word
  struct and a two-instruction `rt_sigreturn` restorer where x86_64
  needs one, `tgkill` to every thread, a handler that counts itself in,
  parks on a futex and counts itself out on one wake. Release build, 20
  cores, 200 rounds, threads spinning the whole time: stopping 1 thread
  is 2.1 µs best, 4 are 5.0 µs, 16 are 22 µs, and 64 — past the core
  count — are 84 µs best and 139 µs mean, because a handler that parks
  gives its core up and the next signalled thread runs on it at once.
  Resume is where the oversubscription lands: 0.6 µs for 1 thread, 2.9
  µs for 4, 11 µs best but 0.4 ms mean for 16, and 6.4 ms best for 64,
  because every woken thread goes back to spinning and the last one to
  count itself out waits for a timeslice. So marking workers never
  exceed the core count and the mutator side is bounded the same way,
  or a pause is milliseconds by construction. That reading replaced a
  first one that put the milliseconds on the stop and called the resume
  one wake at 0.3 µs: the release build's `xchg` store had clobbered
  the register the three counters were zeroed from, so nobody parked
  and the resume woke no one (the Fixed entry below has the
  instruction; the plain build of the same probe gave the shape above
  all along). The probe also priced two absences by running without
  them: no thread pointer at all, so the compiler emits nothing
  thread-relative for a body that neither allocates nor raises, and the
  real first cost of threads is that the scheduler, the poller and the
  arena are one thread's class variables; and no atomic in the prelude,
  so the probe's `lock xadd` and `ldaxr`/`stlxr` are what the mark
  word's CAS will be. GC_DESIGN.md carries the reading. darwin's thread
  is libSystem's by III.9's rule and is measured in the entry below.

- **Per-thread state has its mechanism, and it is the language's own
  `@[ThreadLocal]`, on the floor.** The thread floor's first run had no
  thread pointer at all and located the real first cost of threads: the
  scheduler, the poller and the arena are one thread's class variables.
  The second run answers it. A `@[ThreadLocal]` class variable is now
  emitted local-exec outright — one `%fs:`-relative or
  `tpidr_el0`-relative load at a link-time offset, inside the
  `noinline` accessor the compiler keeps for every thread-local (so a
  fiber that changes threads never reads a cached address) — because a
  program iyi links is always an executable, never a shared object. The
  general-dynamic default was relaxed to the same instructions by the
  linker but left `__tls_get_addr@GLIBC_2.3` undefined in the dynamic
  symbol table: a name on the link line the dependency floor counts,
  for a call that was never made. It is gone; a program with a
  thread-local variable keeps the five C-template names and nothing
  else, and the aarch64 object carries `TLSLE` relocations and a `mrs
  TPIDR_EL0`. `bench/thread_floor.iyi` then lays out a block per raw
  thread the way a static libc's startup does — PT_TLS found by walking
  the program headers from `__ehdr_start`, the initialised image copied,
  the pointer placed by the ABI's variant and handed to `clone` with
  `CLONE_SETTLS` — and every thread saw the image's initialiser in its
  own copy and its own tid in its own slot for the whole run, with the
  main thread's slot untouched. The driver's new failure proof drops the
  one flag bit, so every thread shares the main thread's block, and the
  program names the clash. The runtime's cutover to threads is therefore
  a spelling, not a mechanism: the scheduler's state becomes
  `@[ThreadLocal]` per scheduler thread and the allocator's fast path
  per-thread, with the shared structures behind the atomics the probe
  already wrote. GC_DESIGN.md carries the reading. The LLVM binding
  gained `LLVM::ThreadLocalMode` and `Value#thread_local_mode=` for it;
  `spec/compiler/codegen/thread_local_spec.cr` and `class_var_spec.cr`
  pass, and the wasm32 cross-compile of a sample and of `--crystal`'s
  stdlib sample still compile to their objects.

- **The park is a pipe, because a signal handler may call `read` and
  may not call `os_unfair_lock_lock`.** The per-thread lock the darwin
  probe chose by its numbers is not on Apple's list of async-signal-safe
  calls; it works, with no promise, which is not a footing for a
  stop-the-world. Two parks POSIX does promise were measured against it,
  same machine, release, 200 rounds: `sigsuspend` on a mask that admits
  SIGUSR2, released by a second `pthread_kill` per thread — Boehm's stop
  everywhere, one name in place of the lock's two, a resume that pays
  the kill loop twice (8 threads: 711 µs mean against 135) — and a pipe
  per thread, the handler blocked in `read`, released by one `write` per
  thread, which is the lock's numbers below the core count: stop 2.0 /
  20 / 50 µs best and resume 0.8 µs / 27 µs / 122 µs mean for 1, 4, 8
  threads, against the lock's 2.1 / 25 / 56 and 0.3 / 34 / 136. The
  pipe is the probe's park now, for `pipe` and `read` where the lock
  cost `os_unfair_lock_lock` and `_unlock`; the lock and `sigsuspend`
  stay as `-Dtf_park_lock` and `-Dtf_park_sigsuspend`, each held to its
  own exact list and printed in its own table up to the core count.
  Past it the pipe's stop mean is several times the lock's (16 threads:
  3.6 ms against 0.5) for a reason not read yet, outside the regime the
  design lives in and recorded as such. Go's park was weighed and not
  built: its handler blocks nowhere and rewrites the context so the
  thread parks itself in ordinary code, which on aarch64 needs a
  register no code ever holds live to jump back through after every
  other is restored — Go's compiler reserves R27 for it; LLVM reserves
  nothing for iyi, and darwin's reserved x18 is zeroed by the kernel on
  exception return. That is a codegen decision (reserve a register, at
  one fewer for every function) and GC_DESIGN.md records it as Stage
  4's open option against the pipe.

- **The stop handler reads the held thread's registers, and measures
  its own depth.** The probe's handler used to count itself in and park;
  the part between, which is the collector's, is in it now: the
  interrupted thread's sp and pc read out of the `ucontext` — the
  kernel's on Linux (160/168 on x86_64; 432/440 on aarch64, past the
  128-byte sigmask), libSystem's on darwin (the mcontext pointer at 48,
  sp at 264, pc at 272) — with the assertion that the sp is on that
  thread's own stack, the Linux mapping's bounds or a first-frame local
  on darwin, because a context that is not the thread's would scan the
  wrong stack and root nothing. The driver's third failure proof moves
  one offset by a word, so the handler reads pc as sp, and every handler
  says so. Proven on all three arms, the Linux two on real kernels in
  containers on Apple silicon (arm64 natively, x86_64 under Rosetta).
  The handler also records how far below the interrupted sp it ran —
  the kernel's frame, the trampoline and its own — and the number is
  Stage 4's next design input: 5.7 KB on x86_64 Linux, 4.7 KB on
  aarch64 Linux, 1.2 KB on darwin. A signal lands on whatever stack the
  thread is on, and a scheduler thread is on a fiber's 256 KiB mapping
  most of the time, so Stage 4 keeps that much spare above every fiber
  stack's guard page or gives each scheduler thread a `sigaltstack`;
  GC_DESIGN.md carries the reading.

- **darwin's thread is measured, and its floor is the pthreads price by
  name.** III.9's rule on darwin is the reverse of Linux's — raw
  syscalls are not a stable ABI, libSystem is the platform — so
  `bench/thread_floor.iyi` grew a `{% elsif flag?(:darwin) %}` arm that
  runs the same table, atomics, run and assertions through libSystem,
  and `bench/thread_floor.sh` now holds the darwin binary to an exact
  symbol list and only libSystem on `otool -L`, with the same two
  failure proofs, in the darwin CI job beside the dependency floor.
  What a thread costs there, each name a dependency taken on and
  recorded here: `pthread_create`, `pthread_join`, `pthread_kill`;
  `pthread_threadid_np`, the 64-bit id asked once by the thread and
  once by its parent of the handle, so the two views are compared the
  way `gettid` and the tid word are on Linux; `sigaction`, libSystem's
  sixteen-byte struct with `SA_SIGINFO` in the flags half of the
  second word, and libSystem's own trampoline for the return, so there
  is no sigreturn to write; `os_unfair_lock_lock` and
  `os_unfair_lock_unlock`, the park; and `__tlv_bootstrap`, a
  `@[ThreadLocal]`. Eight names over the runtime's twelve, none of
  them in `bench/dependency_floor.sh`'s list, because no sample
  spawns a thread and the list is a record of what samples cost. The
  park was chosen by measurement, because darwin has no futex and the
  `__ulock_wait` under libSystem's locks is private: a mutex and
  condition (four names) resumed 4 threads in 39 µs mean and 8 in 89
  µs; one shared `os_unfair_lock` (two names) resumed them in 177 and
  415 µs, because the kernel hands the lock waiter to waiter, a
  wakeup a link; one `os_unfair_lock` per thread on its own line,
  released by N unlocks back to back, is two names and 28 and 107 µs,
  and is what the probe keeps — the handler finds its lock through a
  thread-local, as Stage 4's will find its thread. `sched_yield` in
  the main thread's wait was measured and refused: a ninth name that
  cost the one-thread stop its own 4 µs reschedule (6.1 µs mean
  against 2.2) and bought nothing below the core count; above it the
  yield halved the stop mean at 64 threads (1.1 ms against 2.2) and
  left the resume at the same tens of milliseconds. A thread-local on
  darwin arrives differently from Linux and it is the eighth name:
  Mach-O has no local-exec, so a `@[ThreadLocal]` read is
  `adrp`/`add` to a 24-byte descriptor in `__thread_vars`, a load of
  its thunk and a `blr` — the thunk being `__tlv_bootstrap` from
  libSystem, which dyld rebinds to its own `tlv_get_addr` at load
  (`dyld_info -fixups` shows the bind) — and dyld lays every thread's
  block out itself from `__thread_data` on first touch, so `Tls.make`
  has no darwin arm and the isolation assertion is the whole proof:
  every thread read the image's 7 in its own copy and its own tid in
  its own slot, plain and release. The darwin failure proof deletes
  the annotation, since there is no flag bit to drop, and the program
  names the clash on the first thread joined. The numbers, release,
  M2 Pro (10 cores), 200 rounds, spinning threads, on the 24 MHz
  counter (CLOCK_MONOTONIC_RAW; see the clock entry under Fixed):
  stop 1 thread 2.0 µs best / 2.2 mean; 4 threads 23 / 35 µs; 8
  threads 54 / 100 µs; 16 threads 90 µs best, 0.95 ms mean, 15 ms
  worst; 64 threads 0.5 ms best, 2.2 ms mean. Resume 0.2 µs for 1, 10
  / 45 µs for 4, 18 / 155 µs for 8, then 4 ms best and 20 ms mean for
  16 and 110 ms mean for 64. The stop is the `pthread_kill` loop: each
  kill after the first costs 6–7 µs in the call itself (the loop alone
  is 24, 83 and 612 µs for 4, 8 and 16) where Linux's `tgkill` is
  about one. Past the core count the resume is XNU's 10 ms quantum,
  the way it is Linux's timeslice, so the core-count bound on
  marking workers and on M holds on darwin with more force. Two
  things found on the way: `bzero` was in every darwin `--release`
  binary, `hello` included — the aarch64 back end's lowering of a
  memset it will not inline, and the compiler zeroes every
  `Pointer.malloc` with one; a plain binary with a large constant one
  named it too — and no gate had seen it because
  `bench/dependency_floor.sh` builds plain; it is the prelude's own
  now, under Fixed. The price of the spelling is measured too: ten million
  read-modify-writes of a `@[ThreadLocal]` against a plain class
  variable, release build, each in its own `@[NoInline]` frame, cost
  3.2 ns to 2.0 on darwin and 4.7 to 3.0 on aarch64 Linux in a
  container — two accessor calls, one for the load and one for the
  store: the IR of both targets shows the compiler wrapping every
  thread-local's address in a `noinline` function so a fiber that
  changes threads never reads a cached address, and on darwin the
  thunk call sits inside it, dyld's fast path being a `tpidrro_el0`
  read and a table lookup — so the price is the accessor, not the
  platform, and the cutover's thread-local scheduler state is a call
  everywhere but not a cost; the driver prints the line beside the
  pauses. The other darwin
  stop was measured and refused: Mach's `thread_suspend` on the port
  `pthread_mach_thread_np` answers, which returns held, and
  `thread_get_state` for the registers — Boehm's darwin mechanism, no
  handler, no park, four names for the signal arm's four. Kept under
  `-Dtf_mach` with its own exact list and its own table in the driver.
  It loses at every count: stop 3.8 µs to 2.0 for one thread, 52 µs
  to 35 mean for 4, 5.4 ms to 0.95 for 16, 31 ms to 2.2 for 64, and a
  3 ms mean resume for 8 threads against 155 µs — each suspend returns
  only once its target has been through a core and stopped, one after
  another, where N kills are queued at once and the handlers stop in
  parallel. So Stage 4's darwin stop is the signal and a per-thread
  park — the lock, until the entry below asked whether a handler may
  call it. And the probe's "best" sentinel was 0,
  which a microsecond clock can measure; it is the first round now.
  GC_DESIGN.md carries the reading.

- **The prelude has an atomic, and the thread floor is its first caller
  and its gate.** `Atomic(T)` (`src/iyi/atomic.iyi`, SPEC.md III.4.10) is
  a struct holding one word, `T` one of the four integers `primitives.iyi`
  gives arithmetic to, and six verbs with Crystal's names and answers:
  `get`, `set`, `add`, `sub`, `swap`, `compare_and_set` — the
  read-modify-writes answer what the word held before, the exchange
  answers that and whether it happened. The instructions are the
  compiler's, four `@[Primitive]`s in `primitives.iyi` (`atomicrmw`,
  `cmpxchg`, an ordered load, an ordered store) on a holder of their own,
  because a call on a generic instance's class passes the class as a
  first argument and the atomic primitives take their operands from the
  front — the same reason Crystal's sit on `Atomic::Ops`. One ordering,
  sequentially consistent, and no parameter to weaken it: Go's rule, and
  a decision rather than an omission, argued in the section — an
  ordering parameter is the part of an atomic API people get wrong and
  nothing can check, and on x86_64, where the floor was measured, a
  sequentially consistent `add` and a relaxed one are the same `lock
  xadd`. The aarch64 difference (`ldaddal` against `ldadd`) is not yet a
  number, and the measurement that names it is what adds a weaker verb.
  `fence` is not built, and a pointer `T` is refused by name; each
  arrives with its caller.

  The thread floor's three `fun`s of inline asm — the ones whose `xchg`
  clobbered a register in the release build — are gone, and its counters
  are `Atomic(UInt64)` over the same words: `lock xadd`, `xchg`, `mov`
  and `lock cmpxchg` on x86_64, `ldaxr`/`stlxr`, `ldar` and `stlr` on
  aarch64, read off the release binary and the cross-built object. The
  floor holds by the gate's existing assertion — five C-template names
  and nothing else, plain and release — which is now also the proof that
  an atomic costs no `__atomic_*` name. The gate grew a seventh step,
  the atomic's own failure proof: every thread adds to one shared word
  on every turn of its loop beside a word of its own, the two totals
  must agree at the end, and under `-Dtf_plain_add`, a load and a store
  in the atomic's place, they do not — 4 threads, 23,689 adds, 12,477
  landed, exit 1 naming the 11,212 lost. With the contended add in every
  thread's loop the pauses kept their shape (release, 20 cores, 200
  rounds: stop 1.7 / 4.0 / 19 / 78 µs best for 1, 4, 16, 64 threads,
  resume 5.8 ms best at 64). On wasm32, which has one thread, LLVM
  lowers the same instructions to plain loads and stores, so the type is
  on every target and gated on none.

- **The scheduler's state is per thread now, behind one thread-local
  pointer, and the collector still finds it.** The thread floor's
  second finding was that the runtime's first cost of threads is the
  scheduler, the poller and the arena being one thread's class
  variables, and GC_DESIGN.md wrote the cutover down as a spelling:
  every field becomes `@[ThreadLocal]`. That spelling was measured
  before it was written and it lost — a `noinline` accessor per field
  per entry (the floor's touch line: three times a class variable's),
  and the run queue's head in a TLS block the root walk never scans.
  The scheduler is cut over the other way: `IyiSchedulerState`
  (`src/iyi/concurrency.iyi`) holds the running fiber, the run queue,
  the sleep and io lists, the poller and its buffer, and one
  `@[ThreadLocal]` pointer names the thread's own — Go's `g`. An entry
  pays one accessor and then plain loads, and every state ever made is
  linked on a class variable in the image's data, so the walk that
  scans the globals reaches it and the thread-local is a cache of a
  pointer the globals already hold. `bench/collect_trigger.sh` holds
  that as its own check: the state's address and its main fiber's are
  taken XOR'd with a key in a frame of their own, 64 MiB of churn runs
  64 collections, and the chunk must not carry the sweep's free flag
  — the proof unlinks the list and the flag is set after 8. The price:
  `bench/defer_cost.sh` reads about 8 ns per defer where it read about
  5, a `defer` being two `IyiScheduler.current` calls, and the release
  binary of the concurrency exercise has one `%fs:`-relative load (one
  `mrs TPIDR_EL0` on aarch64) where it had none, with no name added on
  Linux. darwin pays a name, `_tlv_bootstrap` — Mach-O has no
  local-exec, every thread-local descriptor names dyld's thunk, and
  every darwin program reaches the scheduler — recorded in the five
  gates that hold darwin's floor in this commit, by that script's own
  rule. The allocator's fast path was the half not cut over; the entry
  below is its cutover.

- **The allocator is a cache per thread and a centre under one lock,
  and the fast path touches no shared word.** `IyiHeap` was the
  directory page — a free-list head and a fill arena per class — as one
  thread's class variables, the other half of the thread floor's first
  cost. The split is Go's. The cache is one page a `@[ThreadLocal]`
  address names, laid out as the directory was and linked on
  `@@caches` when it is made, so the scavenge can strip every thread's
  lists and a stopped thread's cache is reachable by the thread that
  stops it; the centre is the class lists the sweep fills, the arena
  list and the large list, behind a spin lock that is one
  `Atomic(UInt64).compare_and_set` on a word of the centre's page.
  Allocation pops the cache or carves the cache's own arena, no lock;
  a cache that runs dry takes the centre's whole list for the class
  under the lock, one pointer swap (a bounded batch is the fairness a
  two-thread profile may ask for, and is not guessed); `map_arena` and
  `take_large` push under the lock; the sweep links an arena's white
  chunks as it walks and splices them to the centre under one take of
  it, and the scavenge strips the centre and every cache before the
  unmap. `free` goes to the caller's own cache: sent to the centre it
  cost a grow-by-doubling loop two lock cycles a step, 61 ns an
  alloc+free pair against 27, and the chunk a thread frees is the
  chunk it allocates next. The numbers, from `bench/arena_exercise.sh`,
  which measures release builds now beside plain ones because a person
  ships release: 4 ns to 6 ns an allocation in release — the one
  `%fs:` load — and 23 ns to 27 in a plain build, the one call; and
  `bench/collect_trigger.sh`'s pause total fell from 86 ms to 70 ms
  over 87 collections, the batched splice being cheaper than a `free`
  per chunk. Every collector gate holds, and `bench/sweep_exercise.sh`'s
  "frees nothing" proof now removes the splice rather than the `free`
  it no longer calls. What the split decides for Stage 4 is written in
  GC_DESIGN.md: a thread stopped while it holds the heap lock deadlocks
  the sweep, so the stop must defer past a held lock — Go's "no
  preemption inside mallocgc". The trigger's `allocated_since` is
  still one class variable every `take` adds to; it becomes a
  per-cache count when the thread that would race it exists.

- **The runtime has a kernel thread, and the collector stops it: Stage 4,
  built.** `IyiThread.start { }` (`src/iyi/thread.iyi`, SPEC.md III.4.11)
  is the thread floor's mechanism moved into the prelude — raw `clone`
  onto a guarded mapping with a TLS block laid out from PT_TLS on Linux,
  `pthread_create` on darwin, the futex on the tid word or `pthread_join`
  to join — and it costs the Linux floor no name. A thread gets a
  scheduler state and a heap cache on first touch, spawns fibers and
  allocates without a lock, and is not a task: nothing owns or cancels
  it, no channel crosses it, `Atomic(T)` does, and `Share` — whose
  reason for waiting was that no second thread existed — is the next
  piece owed. A collection takes the runtime's one lock, signals every
  other thread, and the handler copies the interrupted registers from
  the ucontext onto the thread's line and parks (futex; a pipe per
  thread on darwin); the collector scans each stopped thread's spill
  and its stack from the recorded sp to the top of the mapping holding
  it, the thread's own or a fiber's. A thread inside `IyiHeap.take` or
  spinning for the lock is asked rather than parked and parks itself
  where it holds nothing, which is Go's "no preemption inside mallocgc"
  reached from the deadlock it prevents; `SA_RESTART` restarts what a
  stop interrupts. A thread's last act returns its cache to the centre.

  Three things the first eight threads found, and their fixes. The
  trigger's count is the centre's atomic now, folded per cache every 64
  KiB, and the decision to collect is made again under the lock so the
  second of two threads crossing the budget together does not sweep the
  heap the first just swept. A refill that took the centre's whole list
  let one thread hoard every freed chunk while seven carved, and the
  heap and every sweep grew with it: the centre keeps a class's chunks
  as the sweep's own per-arena batches and a refill takes one. And a
  budget floored at a MiB met eight allocating threads as 4,000
  collections a second, each a stop of eight and a sweep of eleven
  arenas, 300 µs where one thread's was 15 — the budget is floored at
  half of what the sweep walked, which bounds a collection's cost per
  byte allocated whatever the threads carved; the single-thread gates
  keep their arithmetic exactly, and eight threads went from 634 ns an
  allocation to 239. Two entry points that were `fun`s put 12 KB of
  thread runtime into every binary, `hello` included, because a `fun`
  is emitted whether or not it is called; they are closure-free procs
  whose first word is the function, and `hello` is back to its size.

  `bench/thread_exercise.sh` is the gate, in the samples job, the
  darwin job and the aarch64 cross-run: eight threads allocating from
  their own caches while collections run from whichever crosses the
  budget, a live list in each thread's frames alone surviving them by
  checksum and by the sweep's free flag — after one explicit collection
  with every worker spinning on its list, and after twenty bursts of
  churn — fibers on threads with a parked one holding an object's only
  reference, 32 threads past the core count, the floor's five names,
  and the failure proof: the thread-root walk removed from a copy of
  the prelude, and the spinning threads' lists are swept out from under
  them, exit 1 by name. Forty runs at eight threads, plain and release,
  none hung and none failed. The price, release, 20 cores: 76 ns an
  allocation with one thread, 162 with four, 268 with eight — wall time
  per allocation per thread with every pause included, and the pause is
  every thread standing still for a sweep one thread runs, which is what
  Stages 7 and 8 exist to change. The stop half is the floor's number:
  22 µs for seven threads, 7% of a pause. The signal frame runs on
  whatever stack the thread is on, a fiber's included; the probe's 5.7
  KB is what a fiber must have spare above its guard, and a `sigaltstack`
  per thread is the answer built when a program's fiber is ever that
  deep. Every existing gate holds over the threaded runtime.

- **`Share` is built, and a thread's block may capture only what it
  marks.** SPEC.md III.4.4's marker, refused three times as a mechanism
  with no caller, has one: the block `IyiThread.start` runs on another
  thread. `Iyi::Share` (`src/compiler/iyi/semantic/share.cr`) decides a
  type structurally on the compiler's own AST, the way
  `bench/share_count.cr` counted it — a field is mutable if any method
  other than `initialize` assigns it, by `=`, `+=` or a multiple
  assignment, or a setter `field=` exists; every field's type must be
  shareable in turn; integers, floats, `Bool`, `Char`, `Nil`, `Symbol`
  and enums are, `Pointer` is raw memory and is not, nor are
  `StaticArray` and a `Proc`, and a tuple, union or base-typed class is
  when every member or subclass is. `@[Share]` on a declaration is the
  trust half — shareable whenever the type arguments are, whatever the
  fields do — and `Atomic(T)` and `samples/iyi/std/list.iyi`'s `List(T)`
  carry it, the list the spec said should stay short. The marker
  travels: a producer writes `@[Share]` into the artifact declaration
  of every type it found shareable, in the annotations slot the
  declaration already had, and a consumer reads that and never
  recomputes, because the bodies that said no field is assigned are not
  in the artifact — an imported type without the marker is refused with
  the artifact as the reason. The gate is in the cleanup pass beside
  the one that refuses a closure to a C function: every variable the
  block captures, and `self` when the block reaches an instance
  variable, is asked, and the refusal names the variable, its type and
  the field that failed one level at a time —
  ``captures `items : Array(Int32)`, which is not Share: Array(Int32)'s
  field @size is assigned in `unsafe_set_size` ``. Eight shapes in
  `spec/compiler/semantic/iyi_spec.cr`, the artifact round trip in
  `spec/compiler/iyimod_spec.cr`, and `bench/thread_exercise.sh`'s new
  last step: a program capturing an `Array` that must not compile, and
  does not, by name. A channel's `T : Share` waits for the channel that
  crosses threads.

- **The sweep is lazy: a collection marks and returns, and the allocator
  sweeps what it needs.** The pause was the mark plus a walk of every
  carved chunk, and on `bench/gc_race.py`'s binary trees the walk was most
  of a 12.8 ms pause. A collection now marks, stamps a new epoch and
  returns; every arena behind the epoch is sweep debt, and
  `IyiHeap.refill` pays it one arena at a time when a class's chunks run
  out — the sweep's cost lands on the allocations that need its memory,
  in proportion to them, never in the pause. Sound because every chunk
  wears the parity of the epoch it was handed out in (mark-word bit 4):
  a white chunk of the current parity was allocated after the mark and
  is alive by construction, one of the last parity was unmarked and is
  dead, and a survivor is restamped when the sweep repaints it. The
  budget comes from the mark itself, which adds each object's size as it
  blackens it — twice what is live, Go's GOGC=100, floored at 4 MiB —
  and the budget floored at the sweep's walk is gone, with the feedback
  it had: on binary trees it took the heap to 160 MiB for 3 MiB live.
  Arenas are 16 MiB-aligned now, and a byte per slot of the address
  space says which slots are arenas, so `base_of` is an AND, a shift and
  a load where it walked the arena list per pointer the marker met. The
  scavenge is the pause's: the mark counts what it blackened per arena,
  and an arena with nothing alive goes back with every thread stopped —
  a sweeper on one thread cannot strip a running thread's cache. The
  numbers, `bench/gc_race.py`, release, 20 cores: binary trees 12.8 ms
  longest pause to 2.7 ms, 182 MiB peak to 46; live churn 28 ms to 8.8;
  churn 0.15 ms to 0.04 and 9 ms paused in all to 0.3 — and binary
  trees' wall time rose from 0.163 s to 0.266, because 54 marks of the
  live tree replaced 11, each on one core while nineteen idle, which is
  the next entry's job. Three things the first threaded run found: a
  thread that read the epoch before parking in `map_arena`'s lock spin
  linked an arena that looked like debt and was not counted as any, the
  next pause swept it in place of a real one, the real one kept the last
  mark's black, the mark never re-counted those objects, and the scavenge
  handed a mapping of live objects to the kernel — the epoch is read
  under the lock and the pause sweeps every arena behind the epoch, not a
  counted number; the deferred park at `take`'s exit was inlined and the
  chunk `take` was returning sat in a scratch register nothing scanned,
  so `park_if_requested` and `stop_here` are `@[NoInline]`; and the carve
  stamps a chunk's parity before it publishes the cursor, with an ordered
  store, so a sweeper on another thread cannot read a fresh chunk as last
  epoch's dead. `bench/collect_trigger.sh` holds the sweep to being lazy
  — the allocator must sweep at least an arena per collection, and the
  proof that removes its sweep is named — and every collector gate holds.

- **The mark is parallel: helpers on kernel threads, a stack per worker,
  a pool of batches between them — Stage 7.** `IyiThread.start_helper`
  gives the collector kernel threads the stop never names — no line, no
  cache, nothing allocated from the heap — and the marker keeps its state
  on one page per worker named by one `@[ThreadLocal]`, read once when a
  drain begins, because every thread-local read is a `noinline` call and
  fifteen of them per object doubled the mark before the page. Gray goes
  to the worker's own stack; a stack past 512 spills its top as a batch
  to the pool, and — the finding — a stack of any depth donates its
  bottom half when the pool is empty and a worker is idle, at most every
  256 pushes: a depth-first mark of a tree keeps a stack as deep as the
  tree and no deeper, its oldest entries are its widest subtrees, and a
  marker that only spilled a full stack never shared a tree at all
  (fifteen helpers idle through binary trees), while one that donated on
  every push chopped a million nodes into eight-entry batches through
  one lock and took twice as long as alone. Shading is a compare-and-swap
  on the colour bits when helpers run and a plain store when the mark is
  alone — a fence per object was a third of a mark — and blackening is
  always a plain store, since only the worker that grayed an object holds
  it. Helpers are sized by the work, one per MiB the last mark found
  live, up to the core count less one capped at fifteen, and parked on a
  futex between marks (a spin with a yield on darwin, which has none);
  a mark under a MiB runs alone. Termination is a count of workers
  holding work beside an empty pool, and a helper that read the
  generation after it turned would have slept through the mark and hung
  the collector waiting for its answer, so a helper counts itself ready
  at its first park and the collector waits for every helper it started
  before it turns the generation. `bench/parallel_mark.sh`: a million
  typed nodes, 40 MiB, five marks alone and five with helpers, 12.7 ms
  to 6.0 on 20 cores with the helpers blackening 95% of the nodes, and
  the proof that a marker which never donates is refused by name. On
  `bench/gc_race.py`: binary trees' longest pause 2.7 ms to 2.3, total
  paused 94 ms to 51, wall 0.266 s to 0.219. A linked list — live churn —
  gains nothing, as no parallel marker can: a chain is one worker's walk.

- **The mark runs beside the program, on a write barrier the compiler
  emits — Stage 9.** A collection is two stops now and neither is the
  mark: the first, on the triggering thread, grays the roots, raises a
  byte (`__iyi_marking`), wakes the helpers and resumes the world — 15 to
  35 µs; the helpers drain beside the program; the second, on helper 0
  once every helper found the pool empty, flushes every thread's barrier
  stack, rescans the roots, drains what that found, and turns the epoch.
  Codegen wraps every store that can put a heap pointer into heap memory
  — the `assign` funnel every typed store comes through, a C struct's
  field, a closure's captured variables, parent and `self` — in a test
  of the byte and, while it is up, a call after the store with the
  destination's words, each heap pointer among them grayed onto the
  storing thread's own stack (Dijkstra's insertion barrier, by re-reading
  the destination, so one shape serves a word and a struct). Stores into
  stack slots, walked through the GEPs and casts to their `alloca`, are
  not wrapped: the stack is rescanned at the second stop. Objects born
  under the mark are born gray; a `realloc`'s copy is shaded whole; and
  the bracket around a store is the allocator's own depth counter, so a
  thread is never parked between a pointer store and its shade. The
  second stop looks before it drains: a white root, or a pool past
  sixteen batches, and it resumes the program, marks beside it once
  more, and stops again, up to eight times — a pointer loaded from a
  white object into a register was a 200 000-node chain walked inside
  the stop, 2 ms, before the retreat — and what the last stop finds it
  drains alone, because waking fifteen helpers inside a stop cost up to
  1.5 ms for a thousand entries. The first collection of a program goes
  beside it too, helpers spawned before the stop; stopped, it was the
  longest pause in every table. The last epoch's sweep debt is paid by
  the triggering thread before its stop, under the lock the allocator's
  own sweep takes — 500 µs of sweeping was the first stop's largest part
  against 20 µs of roots, and paying it beside the program is Stage 8.
  What was allocated under the mark is counted marked but not survived:
  the budget is twice the rest, and those bytes open the next budget.
  `bench/concurrent_mark.sh`: twenty-four rounds each move a payload out
  of an unmarked 200 000-node chain into a holder the marker blackened
  first, under a mark the round started itself, and read it back after
  — its header without the sweep's free flag, its bytes the pattern
  written — and the failure proof removes the barrier's shade and the
  first payload is freed by name. Release, 20 cores: the chain marked
  stopped is 1.9 ms; beside the program the longest first stop 0.6 ms,
  the longest second 0.2 ms. `bench/gc_race.py` against Go: binary
  trees' longest pause 0.10 ms to Go's 0.19 (was 2.3 with the parallel
  marker), live churn 0.47 to 0.10, churn 0.03 to 0.48; total paused
  2.6 ms to 2.1, 1.1 to 0.3, 0.3 to 3.6. Resident memory is Go's column
  still (62 MB to 18 on binary trees), the price of no assists; that and
  Stage 8 are next. `IyiMark.settle` waits out a collection in flight,
  for a program that reads the count after churn: the count is of
  finished collections, and a mark beside the program is not one yet.

- **The heap's footprint follows the live set: a one-word header,
  eight-byte size classes, pages handed back to the kernel, and Go's two
  answers to a mutator outrunning the mark.** Binary trees held 6 MB
  live in 62 MB resident, three times Go, and the reasons were four.
  The header was three words ahead of every object - a size, a type id,
  a mark word - so a 16-byte object cost 40 bytes of heap where Go's and
  Boehm's cost 16; the size is the chunk's, which the arena knows, and
  the type id is 32 bits in a word that had 58 to spare, so the header
  is one word at `P-8`, the type id its high half, stored by codegen as
  a u32 at `P-4`. The classes were powers of two, so a 24-byte object -
  two pointers behind a type id, the commonest shape - took 32 and a
  40-byte one 64; they are eight-byte steps to 128 and quarter steps
  above, 67 in all. The sweep hands runs of dead pages back with
  `madvise(MADV_DONTNEED)`, a bit per page in the arena's header page,
  and the carve takes a run up again before it touches the frontier,
  which it carves a slab at a time so the heap fills from its low
  addresses. Every free list is dropped at the pause, because a chunk
  left on one between two dead ones broke their run and kept its page
  resident (1.5 MB live keeping 12 MB); the epoch's sweeps keep a
  budget's worth of free pages resident and release what is free beyond
  it, because releasing on sight cost a 64-byte allocation 220 ns for
  the fault and the syscall (21 now); the marker's stacks and the
  heap's first eight arenas refuse transparent huge pages, two megabytes
  resident for a class with ten objects, and past 128 MB of arenas the
  heap takes them, for the page walk they save a large heap (live churn
  17% faster). Objects born under the mark are born black, not
  gray: born gray they fed the pool a batch per sixty-four allocations
  from every thread and the mark could not find the pool empty to end.
  And the assist: a mutator that allocated 64 KB under a running mark
  scans a thousand objects of the pool's first - thirty-two threads bore
  13 MB beside a 4 MB budget without it, and every collection's end was
  the next one's trigger. Two things left the stop on the way: the
  scavenge's `munmap` (half a millisecond per resident 16 MB mapping,
  ten of them a 5 ms stop) waits for the program to be running, and the
  allocator's sweeps run outside the runtime lock, in parallel, claimed
  by epoch - thirty-two threads refilling at once after a collection
  and sweeping in turn under one lock were a convoy the thread exercise
  measured as a hang. An arena is one cache's at a time; a region is
  never set in an arena a walk holds; a walk parked through a pause
  discards its batch; the scavenge leaves alone what is claimed, walked,
  or named by a parked walker. `bench/gc_race.py`, release, 20 cores:
  binary trees 62 MB resident to 29 (Go 17, Boehm 18), longest pause
  0.16 ms (Go 0.17); live churn 316 MB to 171 (Go 115), 0.08 ms (Go
  0.11); churn 38 MB to 15 (Go 15), 0.03 ms (Go 0.45). The thread
  exercise's price, release: 26 ns an allocation with one thread, 63
  with four, 162 with eight (22, 58, 139 before the pages).
  `IyiHeap.size_of` answers what the header's size word did;
  `IyiMark.settle` waits out a collection in flight; `IyiMark.growth =`
  is Go's GOGC with Go's meaning, defaulting to 200 where Go's is 100
  (at 100 binary trees traded a fifth of its wall time for a smaller
  peak); the arena
  exercise's size-class and header checks say the new shapes. And the
  allocation path lost what it did twice or checked for nothing: codegen
  no longer zeroes an aggregate the clearing entry handed back zeroed,
  the counters on the cache page add without an overflow branch, and the
  small classes' index is a shift inline rather than a call - binary
  trees 239 ms to 226. The thread exercise's oversubscription step runs
  twice the cores' worth of threads, at least nine and at most 32: 32 on
  the darwin runner's three cores outlived the step's five minutes. And
  `IyiMark.workers=` caps at the cores less one, for the same runner:
  fifteen helpers asked of three cores, spinning as darwin's do when
  parked, held the parallel mark's exercise past its five minutes too.
  The exercise names its phases as it runs them now.

### Fixed

- **The Windows run-time diagnosis is retired, and the watch is a gate.**
  The prelude memset's stride was fixed with the collector's merge and
  CI's twenty-run watch of a Windows binary, with a 50,000-iteration
  self-check in every run, was to watch without failing until several
  builds in a row read twenty right and nothing else. Thirty-six in a
  row did: 720 runs, 36 million self-checks, no wrong output, no crash.
  The job fails by its tally now, and the README, SPEC III.9 12c and
  GC_DESIGN say what Windows is and is not: a binary that runs right,
  not a test target, no collector, no threads.

- **The thread floor's `sigsuspend` variant lost a wakeup on darwin,
  one CI run in ten.** The stop handler's `sa_mask` was empty, so a
  resume signal that landed between the handler's count-in and its
  `sigsuspend` ran the empty resume handler and left the thread parked
  for good. The variant's stop handler blocks SIGUSR2 now, so the
  resume stays pending until the `sigsuspend` unblocks it. The variant
  is still refused - the race was the reason - and now it is refused
  by measurement rather than by a hang.

- **The pause clock's stamp was one page for every caller.** Linux's
  `now_ns` wrote `clock_gettime`'s timespec into a page of the
  collector's own, shared, and two threads reading the clock at once
  tore it: a probe that timed the allocator's sweeps from an allocation
  while helper 0 read the clock under the lock saw time go backwards
  and died of the subtraction. The runtime's own calls were all under
  the lock, so no shipped program hit it; the stamp is a struct on the
  caller's stack now, and the page is gone.

- **The runtime lock's spin was a CAS, and fifteen spinners slowed the
  holder.** A failed `compare_and_set` still takes the line for
  writing; the lock reads the word first and pauses between tries, and
  a `try_lock` exists for a walk that must not park where it stands.

- **A thread carving fresh chunks took the runtime lock on every
  allocation, for nothing to sweep.** With every list dropped at the
  pause, a thread past its lists refills on each allocation, and each
  refill reached for the sweep: a lock and a walk of the arena list, 39
  ns of a release build's 24-byte allocation on Linux and a microsecond
  on darwin. The sweep answers no debt without the lock: 9 ns now, and
  live churn 172 ms to 118. And the page the sweep hands back is the
  kernel's: darwin arm64's is 16 KB, and its `madvise` refused a run of
  four-kilobyte ones.

- **The thread floor's probe ran under the collector's trigger, and on
  darwin the trigger's first collection took its signal.** The probe
  installs its own handler on the collector's stop signal; a collection
  run beside the program registers the main thread and installs the
  collector's handler over it, and the probe's sigsuspend variant then
  waited for threads the collector had parked. The probe turns the
  trigger off: its stop is its own to measure.

- **darwin's helpers were started with a heap allocation under the
  runtime lock, and the parallel mark hung at its first mark with
  helpers.** `pthread_create`'s handle word was `Pointer.malloc`'d; the
  collector starts helpers under the lock with the world stopped, and
  once the pause dropped the free lists, that allocation refilled, found
  nothing, and reached for the lock it held. The handle is a local:
  nobody joins a helper.

- **The second stop's probe left live counts in its page, and the
  scavenge unmapped an arena under its live objects.** The bounded drain
  the second stop runs counts what it blackens per arena on helper 0's
  page and flushed nothing before the scavenge read the arenas' counts;
  an arena whose only live objects were in that pending count read as
  empty, was handed back, and the next collection's flush wrote into the
  unmapped page - a segfault one run in ten with thirty-two threads,
  and corruption before that. The probe flushes before the scavenge.

- **Helpers' marked bytes were folded twice, and live churn's budget
  was twice its live set's double.** The second stop folds every worker
  page's bytes for the mutators' assists, and a helper's page is on that
  list too, already folded at its drain's end: 40 MB live read as 76.
  A helper's fold zeroes what it folded.

- **The layout table refused a `StaticArray`, and any program holding
  one in an `uninitialized` local failed to build.** `gc_type_layout`
  asked an LLVM array for its struct elements; a static array has no
  fields, every word of it is an element, and it gets no entry now — the
  marker word-scans an object it has no entry for to its size, which is
  exactly the elements. Found writing a debug print with a stack buffer.

- **The darwin floor lists were behind the parallel marker by two
  names, and the identity floor found the race script calling the
  upstream compiler by its name.** `pthread_create` and `sysctlbyname`
  joined every darwin program with Stage 7 — the collector starts its
  helpers as kernel threads sized by `hw.ncpu` — and `pipe` and
  `sigaction` join with Stage 9, whose second stop registers the main
  thread and installs the stop's handler, and a line's park on darwin is
  a pipe; and `madvise` with the pages the sweep hands back. The seven
  darwin lists carry the five, the thread floor's runtime list rather
  than its probe's, and `bench/dependency_floor.sh` says why. `bench/gc_race.py`'s docstring
  said the Boehm arm was what Crystal ships; it is what the upstream
  compiler ships.

- **A helper's stop stopped nobody in a program that never started a
  thread, and the sweep ran beside it.** The main thread has no line
  until the first `IyiThread.start`; the trigger registers it before its
  first concurrent collection, before the lock, because registering takes
  it. Found by `bench/collect_trigger.sh`'s no-lazy-sweep proof, a
  segfault in the scavenge one run in four.

- **The first concurrent collection hung one run in twenty: the pool's
  page was made by whichever thread reached it first.** With the helpers
  started before the stop, a helper and the collector reached it at
  once, each mapped a page, and the helpers counted ready on one the
  collector never read. The collector makes it before the first helper
  exists.

- **A mark worker's stack cost 2 MB resident for 4 KB used.** The 32
  MiB mapping, touched at one end, was given a transparent huge page at
  its first touch — 34 MB across sixteen workers, on a program with a
  4 MiB budget. The worker stacks and the helper threads' stacks refuse
  huge pages by `madvise(MADV_NOHUGEPAGE)`, a syscall on Linux and no
  name on the floor: churn's resident memory 49 MB to 19.

- **The thread floor's x86_64 store clobbered its own value, and the
  release build handed `clone` a stack of 0.** `__tf_store` was the
  `xchg` idiom for a sequentially consistent store with its value
  register declared an input; `xchg` writes that register back with what
  the memory held. The plain build reloaded every value from the stack
  and never noticed; the release build kept the thread's stack base live
  in the register across the store of it into the table, got 0 back, and
  the child's first instruction faulted at 0x3fff0 — a segfault with no
  line, in the samples job, on the commit that added the held-context
  read. Found by building the release for x86_64-linux-gnu and running
  it under Rosetta in a container with a SIGSEGV handler that prints
  rip, rsp and the faulting address out of the same ucontext offsets the
  probe measures. The store is `mov` and `mfence` now. `__tf_add`'s
  `lock xadd` was already right: its register is tied to the output.
  It was not the first reuse, only the first that faulted: the release
  probe had zeroed its three counters through one register from the
  start, `xchg %rcx,(%rax)` three times with no reload between, so the
  second and third stores wrote the first counter's old value — the
  thread count — into `resumed` and `resume`, no handler ever parked,
  and the first Linux reading's "resume is one wake at 0.3 µs" was a
  wake of nobody. The reading above was taken again with the fixed
  store, and the plain build of the old probe, which reloads, had been
  giving the corrected shape all along.

- **A darwin binary clears its own memory: `bzero` is the prelude's.**
  Every darwin `--release` binary — `hello` included — and any plain one
  with a large constant `Pointer.malloc` asked libSystem for `bzero`,
  because codegen zeroes every allocation with an `llvm.memset` and the
  aarch64 back end spells a zeroing memset it will not inline `bzero`,
  not `memset`; the prelude intercepted `memset` by defining it and had
  never heard of the other name, and no gate read a release binary on
  darwin until the thread floor did. The measure is Go's: a runtime
  competing with it links libSystem for the kernel's door and for
  nothing it can write itself, and a clear loop is the first thing it
  can. The prelude now defines `bzero` beside `memset` in the collector's
  branch (the `-Dgc_none` branch takes libSystem's allocator by choice
  and keeps its `memset` and `bzero` with it). The body is inline-asm
  stores, a word then bytes, on both darwin architectures, and not a
  loop or a call to `memset`: the loop-idiom pass spares only functions
  named `memset` and `memcpy`, and the first version, written as
  `memset`'s loop, came back from the optimiser as a tail call to
  itself on its own byte tail and hung the root exercise. A release
  `hello` on darwin is back to the runtime's twelve names; the thread
  floor's release list is its plain list; the root gate's list lost the
  name it had carried for a day.

- **darwin's clock is the 24 MHz counter now, not a microsecond
  rounding of it.** The prelude read `clock_gettime_nsec_np(6)`,
  CLOCK_MONOTONIC, for the sleep queue, the collector's pause stamps and
  the arena exercise's stopwatch, and on arm64 that clock answers in
  whole microseconds: the thread floor's 2 µs stop came back as 2000 or
  3000, its sub-microsecond resume as 0, and every `IyiMark.pause_*_ns`
  a darwin program reports was rounded the same way. CLOCK_MONOTONIC_RAW
  (4) is the counter itself, 42 ns a tick, the same libSystem name and
  no new one; it stops in sleep and counts from boot exactly as 6 does,
  and lacks only the slew a duration never wanted. All three readers use
  it, and the thread floor's own darwin clock, written to get around the
  rounding, is gone.

- **The thread floor's aarch64 Linux arm never ran to the end in CI, and
  now does.** `clone`'s argument order differs by architecture: x86_64
  takes (flags, stack, parent_tid, child_tid, tls), aarch64 takes (flags,
  stack, parent_tid, tls, child_tid), and `__tf_clone`'s aarch64 asm
  loaded them in x86_64's order. Every raw thread's pointer was therefore
  its table line and the kernel wrote its tid into the TLS block's
  control word, and the first check — the tid the thread read against
  the tid word the kernel wrote — failed with a 0 on every thread. The
  cross-run job, the one place that arm runs, was red on all three
  thread-floor commits, and the entries above that say "aarch64 under
  emulation in CI" described the job that was meant to prove it, not a
  pass. Two registers swapped; proven this time on a real arm64 Linux
  kernel (a debian container on Apple silicon, no emulation): two and
  eight threads, every property, the clone-flag failure proof naming
  the clash, and the same `every property held` line the job greps
  for.

- **The collector's five gates and the defer cost now run in the darwin
  job, and running them found what nobody had.** The owned collector
  has been darwin's default allocator since the flip, and the darwin
  job ran samples, III.4, III.1.4 and the floor — not
  `bench/{arena,root,mark,sweep}_exercise.sh` or `collect_trigger.sh`,
  which the samples job runs on Linux. Run on a Mac, four of the six
  failed. Three were allowlists that predated the machine they were
  read on: the arena, root and mark gates' darwin lists still carried
  `malloc`, `memset` and `realloc` from before the flip — entries that
  would have let a fall-back to libSystem's allocator pass — and had
  never learned the names the poller (`kqueue`, `kevent`, `__error`,
  `clock_gettime_nsec_np`) and root discovery (`pthread_self`,
  `pthread_get_stackaddr_np`, the two `_dyld_get_image_*`) put on every
  darwin program's line; each list is now the exact set the gate's
  binary asks for, with a reason beside every name (`bzero` was among
  the root gate's for a day, until the prelude owned it). The fourth was real:
  `collect_trigger.iyi`'s release build on darwin panicked at
  "scavenge: 6 arenas at the peak and none went back to the kernel",
  because the spike's root sat in a global written and never read, the
  optimiser dropped the store, the chain was collected before `peak`
  was measured, and the scavenge check compared a heap that had
  already shrunk with itself — the same defect the sweep gate's 2 MiB
  root had and fixed, on a step written after that fix. Linux was not
  spared the elision — the release IR for x86_64-linux-gnu carries no
  trace of the global at all, on either target it is gone — and its
  gate passed only because something on that machine still named a
  node when the collect ran, which is the kind of pass a conservative
  scan hands out and a gate must not rely on. The exercise reads both
  of its roots back now, which is what makes them roots on either.
  `sweep_exercise.sh` and `defer_cost.sh` passed as they were. All six
  are steps in the darwin job beside the thread floor.

- **`make -B iyi-tarball` packaged an unoptimised compiler past the guard
  that exists to refuse one.** `release := 1` is the goal's own variable
  and does not travel into the `$(MAKE) install_iyi` the recipe runs; `-B`
  does travel, through `MAKEFLAGS`, so the sub-make rebuilt `iyi` again
  *after* `check_iyi_is_release` had passed, without `--release`, and
  installed that. Nothing about the tarball looked wrong: `bin/iyi
  version` inside it said "not built in release mode". Found by running
  the tarball that way once while proving the recipe above. The sub-make
  is now handed `release=1` explicitly; the same `-B` run builds release
  twice and packages release, and the plain `make iyi-tarball` against a
  stale unoptimised binary still refuses by name.

### Learned

- **The next 18 MB of tarball is the compiler's own backtrace, and it
  stays.** After the diet the Linux package is 215 MB unpacked and
  `bin/` is 197 MB of it: `iyi` and `iyi-daemon` at 103 MB each, the
  same sources built with and without `-Dwithout_mt`. `size -A` on one
  says 38 MB of that is DWARF — `.debug_info` 10.8 MB, `.debug_line`
  6.9 MB, `.debug_ranges` 3.6 MB and their strings — all of it Crystal's
  default line tables for the compiler, since MinSizeRel LLVM emits none.
  Stripped, the package would be 143 MB and the tarball 52.5 MB against
  70. Measured, and refused: a three-line program built `--no-debug`,
  `strip`ped, or `strip --strip-debug`ged prints its unhandled exception
  as `from ./bt in '??'` on every frame, because the runtime takes
  function *names* from DWARF too, not from the symbol table. A downloaded
  compiler whose crash report is three rows of `??` is the wrong 18 MB to
  save. The Linux runtime reads DWARF from the executable alone
  (`Exception::CallStack.load_debug_info_impl`), where darwin already
  looks for a sibling `.dSYM`; a `bin/iyi.debug` companion the Linux
  runtime could learn to open would make the saving free, and is the
  shape this should take if it is ever taken. The other 103 MB — the
  daemon being a second copy of the compiler with LLVM inside — is a
  runtime question (`fork` against multithreaded codegen), not a
  packaging one.

## 0.8.0 — 2026-09-01

**The collector is the default.** 0.7.0 built it; this release seats it: a
plain `iyi build` on Linux x86_64, Linux aarch64 and darwin allocates from
the owned arena, collects under its own allocation-pressure trigger, hands
empty mappings back to the kernel, and times every pause on the kernel's
own clock — with the dependency floor exactly where it was, and on darwin
lower: `malloc`, `realloc` and `memset` left the symbol list, `mmap` and
`munmap` joined it, and on Linux the object still leaves nothing undefined
at all. The measurement came before the decision (`bench/gc_default.py`):
the collector wins or ties every time column against both predecessors and
holds RSS at the live set where a heap that never frees holds it at the
garbage.

The doors out are chosen now, not shipped: `-Dgc_none` is the bump pointer
— the old default, the last nanosecond, unbounded memory — and
`-Dgc_boehm` is libgc, arriving only when asked for. Along the way the
header learned to say *atomic* (an `Array(Int32)` buffer is never
word-scanned again), the sweep learned to return whole arenas, the pauses
got `last`/`max`/`total` in nanoseconds, and every property has a gate
that fails by name when the mechanism is removed.

`.iyimod` format is unchanged at v43, and identity is the released version
as ever: a 0.7.0 artifact is rejected by a 0.8.0 build and rebuilt, never
migrated.

### Added

- **The heap breathes out, and the pauses have numbers.** Two things a
  collector must do before "collector" stops needing qualifiers. A sweep
  that finds an arena with no live chunk now hands the whole 16 MiB
  mapping back to the kernel — the class's free list stripped of that
  mapping's chunks first, the arena unlinked from the heap's own walk,
  then the `munmap`, in that order because the order is the safety
  argument. One warm arena per class stays as the cushion that spares a
  spike-then-idle program the mmap on its next allocation. Before this a
  heap only ever reached a high-water mark: chunks came back, mappings
  never did.

  And every collection times itself — a raw `clock_gettime` syscall on
  Linux writing into a page of the collector's own, because a collector
  must not allocate a timespec from the heap it is collecting, and
  libSystem's `clock_gettime_nsec_np` on darwin — with `last`, `max` and
  `total` nanoseconds riding the statistics. `bench/collect_trigger.sh`
  grew the step that holds both: a 64 MiB chain forced ten arenas into
  existence, dropping its root gave four back to the kernel with the
  count asserted and named when the scavenge is disabled, and the pause
  line prints from the real run — sub-millisecond steady-state
  collections, tens of milliseconds at the spike's conservative peak —
  reported rather than asserted, because a pause budget would be a
  number the gate made up before anything reads it.

- **The owned collector is the default allocator.** A plain `iyi build` on
  Linux x86_64, Linux aarch64 and darwin now allocates from the arena,
  collects under the allocation-pressure trigger, and hands memory back —
  with the dependency floor exactly where it was: on Linux the arena is
  raw syscalls and the object still leaves nothing undefined, on darwin
  it is libSystem's `mmap`/`munmap`, named in the floor's list with the
  flip as the reason. The measurement came first
  (`bench/gc_default.py`): the collector wins or ties every time column
  against both predecessors and holds RSS at the live set where a heap
  that never frees holds it at the garbage.

  The doors out: `-Dgc_none` selects the bump pointer — allocate, never
  free, the old default, still the right tool for a short-lived program
  that wants the last nanosecond — and `-Dgc_boehm` selects libgc, both
  held by `bench/dependency_floor.sh`: libgc arrives only when asked for,
  and the opt-out stays as library-free as the default it used to be.
  `-Dgc_iyi` still names the collector and is now the default spelled out
  loud. The selection lives in two places that must agree — the prelude's
  allocator seam and `Program#iyi_gc_arena?` in the compiler, which gates
  the type-id store and the layout table — and each names the other,
  because a compiler writing ids into a header the prelude did not
  allocate is memory corruption, not a degradation.

  Every collector gate now drives the *default* build and a `-Dgc_none`
  arm where the bump pointer is the thing under test; the concurrency and
  panics gates run collector-backed default builds, which makes them the
  first integration proof that a program can schedule, panic and collect
  in the same process without noticing. Appendix B #23's known leak —
  "a default that ships a known leak" — is retired the way its own last
  sentence promised: the never-collecting mode is chosen now, not
  shipped.

- **The header says atomic, and the default-flip question has its
  numbers.** `bench/gc_default.py` is the measurement the collector's
  record demanded before any default moves: the same programs, iyi's own
  prelude, three allocators, time and peak RSS. The first reading found a
  real defect — the live-set row ran ten times slower under `-Dgc_iyi`
  than under the bump pointer, because the header had no way to say
  *atomic*: a 32 MiB `Array(Int32)` buffer, allocated through
  `__crystal_malloc_atomic64` on the promise it holds no pointers, was
  word-scanned at every triggered collection, twenty milliseconds of
  `base_of` on integers. `ATOMIC_FLAG` is mark-word bit 3, set exactly
  where `clear` is false — the not-clearing path and the no-pointers
  promise are the same path — carried across `realloc` with the data the
  promise is about, and honoured by the marker the way Boehm honours
  `GC_malloc_atomic`: blackened, never opened. The row fell from 0.187 s
  to 0.017 s, level with the bump pointer.

  The table after the fix, best of five, worst peak RSS: the owned
  collector wins or ties every time column — churn at 0.048 s against
  the bump pointer's 0.125 s and Boehm's 0.091 s — and holds RSS at the
  live set (15–34 MiB) where the bump pointer holds it at the garbage
  (551–767 MiB). The flip stays a decision for a release of its own;
  what the table changes is that the evidence now argues for it.
  `mark_exercise`'s graph nodes moved to pointer-element buffers on the
  way, because a graph built in atomic nodes is invisible past its roots
  under either collector — the exercise was leaning on the scan the
  promise forbids.

## 0.7.0 — 2026-09-01

**The language owns a collector, and it runs itself.** Behind `-Dgc_iyi`,
the whole machine: a size-class arena allocator that costs no symbol and
no library, roots from the stack, the spilled registers, the globals and
every suspended fiber's stack, marking that is precise where the header
names a type and conservative everywhere else, a sweep that hands memory
back, and an allocation-pressure trigger — one collection per live-set of
garbage, floored at a MiB, with nobody calling `collect`. Every stage is
gated, every gate proves it can fail, and all of them run in CI.

What it is not, said here rather than found: opt-in — the default build
still allocates and never frees, and moving that default is 0.8.0's
measurement, not this release's side effect. Collections run on the
allocating fiber at allocation points only; arenas stay mapped for their
free lists; finalizers and weak references wait on the language having
the features; threads, and with them parallel marking, wait on threads.

And a fix every released compiler needed: the prelude's own `memset`
strode eight elements where it meant eight bytes, so every runtime-sized
clear left seven of eight bytes dirty and wrote one word in eight far
past its count. Invisible on the bump allocator's zero tail, consistent
with everything the Windows watch ever recorded, fixed on all three
targets that carried it.

`.iyimod` format is v43 — the `Layouts` section carries each type's
pointer map — so a 0.6.0 artifact is rejected by a 0.7.0 build and
rebuilt, never migrated.

### Added

- **The collector runs itself: allocation pressure triggers a collection.**
  Until now every collection was a call the exercises made, which is a verb,
  not a collector. `IyiHeap.take` — the one funnel every `-Dgc_iyi`
  allocation passes through — now reports each request's size, and when the
  bytes allocated since the last collection cross the budget, one runs,
  before the carve, so the object about to be born cannot be swept while it
  has no root. The budget after a collection is twice what survived it,
  floored at a MiB: a program whose live set is L pays one collection per L
  bytes of garbage — the amortised O(1) every tracing collector prices at —
  and a program that never crosses a MiB never pays at all.
  `IyiMark.auto = false` is the door the phase exercises use, the same
  switch Boehm spells `GC_disable`, because a test choreographing colours
  cannot have a string interpolation's allocation collecting mid-check.

  The trigger's steady state found the sweep's quadratic. The freed-chunk
  check was a walk of the class's free list — the design's own comment
  called the O(1) form "not a thing to build before a profile asks" — and
  the first run of the trigger exercise took 106 seconds, one long free
  list walked once per chunk per sweep. The check is now one load: `free`
  sets a FREE flag in the chunk's own mark word (bit 2, the flags the
  header reserved), `take` clears it with the mark word it already zeroes,
  and the same exercise runs in 0.1 seconds.

  `bench/collect_trigger.sh` is the gate, and nobody in it calls
  `collect`: a quarter MiB of churn triggers nothing, 64 MiB triggers
  collections and the heap stays at three arenas with a rooted survivor's
  bytes intact, the same churn against a 4 MiB live set collects an eighth
  as often, and a parked fiber's only reference lives through the pressure
  — the fiber-stack walk carrying weight under a trigger it cannot see
  coming. Two failure proofs: the pressure report removed leaks by name,
  and a budget pinned to the floor fails the growth check. A speed step
  keeps the quadratic from returning. And the collector's gates are in CI
  now — found unwired while adding this one: all five merged green on the
  machine that built them and none was named in the workflow, which is the
  exact defect the workflow exists to prevent.

- **The marker reads the map: precise where the header names a type,
  conservative everywhere else.** The two halves the record said were
  next, built together because each is what makes the other reachable.
  Codegen stores an object's `type_id` into the GC header at the
  allocation site — `allocate_aggregate`, right after the malloc
  returns, exactly where the prelude's header comment said it belonged —
  and the mark loop looks the id up in the layout table the compiler
  already embeds, by binary search, and scans exactly the pointer
  offsets the `TypeLayout` names. An integer field holding something
  address-shaped retains nothing through a typed object now. An id of
  zero — a `Pointer(T).malloc` buffer, a closure environment — keeps the
  conservative word-scan, and a missing table entry falls back the same
  way, never a crash. The symbol grew its promised unconditional
  definition (an empty table rather than an absent one), and its
  declaration moved to `Void*` after the release build refused a
  pointer initializer on an `i64` global — the single-module arm caught
  what the multi-module arm forgave. `bench/mark_exercise.sh` holds it
  from both sides: sixty-four typed nodes' pointer-field children all
  black, their integer-held decoys white by a majority no stale root
  word can fake, and a prelude with the lookup disabled exits 1 naming
  the retention.

- **A suspended fiber's stack is a root now — Stage 3's fourth task,
  closed.** The recorded gap from the collector's rebase: 0.4.0's
  scheduler parks fibers whose 256 KiB stacks the root walk never
  reached, so an object reachable only from one would have been freed
  live. The scheduler now keeps an all-fibers registry — its wait queues
  could not serve the walk, since a channel-parked fiber lives in the
  channel's own nodes and a joiner hangs off the fiber it waits on — and
  `each_fiber_root` scans every suspended fiber from its saved stack
  pointer to its stack top, runnable fibers included, done ones skipped
  by state. The running stack's own scan caps at the current fiber's top
  rather than the thread base, because from a spawned fiber the range up
  to the thread base crosses an unmapped gap and faults.
  `bench/root_exercise.sh` holds both directions: an address held only
  on a suspended fiber's stack is found by the walk, and a prelude with
  the fiber walk removed exits 1 at that check's own name.

- **The collector sweeps, so the memory comes back.** GC_DESIGN.md Stage 6, and
  with it the collector works end to end behind `-Dgc_iyi`: allocate, mark,
  sweep, and the chunk is handed out again. One walk over every carved chunk. A
  white object is unreachable, so its chunk goes back on its class's free list;
  a black one survives and is repainted white for the next cycle, which is why
  sweep needs no second pass. Large objects walk their own list, with `next`
  read before the node is released, because releasing it unmaps the memory the
  link lives in. A chunk already on a free list is skipped rather than freed
  twice, since that would hand one chunk to two callers.

  The check that matters cannot be faked by a counter: 300 objects nothing
  references, collect, 300 more allocations, and **299 of them come back from
  addresses the sweep reclaimed**. A rooted object keeps all 64 of its bytes
  through a collection, comes out white, and its chunk is not handed out again
  across 400 further allocations. Twenty cycles of 200 allocations leave five
  arenas mapped rather than a growing heap.

  `bench/sweep_exercise.sh` proves both directions, as permanent steps: a sweep
  that reclaims nothing exits 1 at "nothing was reclaimed, so no address came
  back", and a sweep that frees regardless of colour exits 1 on the live
  survivor. A collector's test that cannot see both is not testing a collector.

  Finalizers and weak references are not built, and not for lack of time.
  Nothing in this language defines a finalizer: there is no `def finalize`
  anywhere in `src/iyi` or `samples/iyi`, so a finalizer queue would be a
  mechanism no program could put an entry in, which is the shape III.4.8
  refused for a concurrency marker. Weak references are registration based and
  the standard library's `WeakRef` is on the `--crystal` side, so there is no
  table here to walk and null out. Both wait on the language having the
  feature. Statistics are the honest subset, counted as the walk goes rather
  than sampled: chunks swept, chunks kept, bytes freed, collections run.

- **The collector marks, behind `-Dgc_iyi`.** GC_DESIGN.md Stage 5. Roots go
  gray through Stage 3's walker, a queue in its own mapping drains, each
  object's payload is scanned to the bound its size header carries, and what is
  still white when the queue empties is unreachable. The object header is real:
  with `P` the pointer a program holds, `P-24` is the size that `realloc`'s
  contract reads, `P-16` the `type_id`, `P-8` the mark word, and `P` the user
  data. Colour is bits 0 and 1, so a fresh chunk is white without anyone
  writing anything, and every write preserves the flag and reserved bits the
  header promises to a forwarding pointer later.

  The layout table is emitted into the binary and the mark loop does not read
  it, which is deliberate. Nothing writes an object's `type_id` yet: `malloc`
  is handed a size and cannot know the type, so that store belongs at the
  allocation site in codegen and is the next step. Reading a table keyed by an
  id that is always zero would be a lookup no test could reach. So marking is
  conservative, which is what Boehm does in production and which errs in the
  safe direction: a false positive retains a dead object, only a false negative
  frees a live one.

  `bench/mark_exercise.sh` proves it rather than reporting it: 400 live objects
  all black with garbage beside them, a three-node cycle and a self-loop that
  terminate, an interior root that marks the object it points into, and a
  20,000-object chain fully marked, which is the queue growing and the proof
  the walk is not the call stack. Both failure proofs are permanent steps:
  removing the black shading exits 1 with an object left gray, and removing the
  pointer walk exits 1 with the chain's tail left white.

  Three bugs were found by running it. The colour mask, because neither `~` nor
  `>>` is defined on `UInt64` here and the literal 2^64-4 produced colour 3,
  which is not a colour. The idempotence check, which was wrong rather than the
  code: after one pass everything live is black and only white objects are
  enqueued, so a second pass finding nothing is the invariant working. And the
  harness itself, which wrote 20,000 entries into an 8,192-slot mapping and
  crashed; a test that corrupts memory while testing a collector is worse than
  no test, so its ledger bounds itself and raises.

  Nothing sweeps yet. This stage decides what is garbage and Stage 6 reclaims
  it, so `-Dgc_boehm` is still the only way to get memory back.

- **A heap that can hand memory back, behind `-Dgc_iyi`.** GC_DESIGN.md Stage 2:
  size classes to 16 KiB over 16 MiB mmap arenas, per-class free lists, and
  large objects in a mapping of their own released with `munmap`. Two properties
  exist because Stage 3 needs them and not because they are tidy: an arbitrary
  pointer resolves to its arena and size class, answering zero for a pointer
  that belongs to no arena, and the arena list walks.

  The correctness point is clearing, and it is not in the design. Today
  `__crystal_malloc64`'s documented "allocate and clear" is free, because
  `MAP_ANONYMOUS` zero-fills and no byte is ever handed out twice. A free list
  hands memory back out, so a reused chunk is dirty and has to be cleared, or a
  program reads memory it was never given. That is the same defect that makes an
  iyi binary on Windows print `ache\` where `HELLO, IYI!` belongs. The atomic
  entry point still does not clear, matching `GC_malloc_atomic`.

  `bench/arena_exercise.sh` proves it rather than asserting it: 256 blocks
  across 8 size classes keep their patterns, 100 chunks freed out of order and
  reallocated keep every byte, a freed chunk of `0xAA` comes back zeroed, a
  freed large object's mapping is gone (the read faults), and all 13 samples
  print identical output under both allocators. The clearing check was proven
  able to fail: with the clear disabled it exits 1 with `reused chunk dirty at
  byte 0: got 170`.

  Measured, not hidden: 7 ns per allocation for the bump pointer, 20 ns for the
  arena, 15 ns per alloc-and-free pair. A size-class allocator costs more than a
  bump pointer on the fast path, and that is the price of a heap that can hand
  memory back.

  Opt-in on purpose. The default on every target is unchanged, and switching it
  is a separate decision backed by measurement rather than something to slip in.
  Windows and wasm32 keep their allocators: Windows because its binaries already
  print uninitialized memory and a second suspect would confound that, wasm32
  because it has no mmap. The prelude's source grows 468 lines and 19 KB for
  everyone, but the arena is inside a macro branch, so a default build does not
  compile it and the default binary is the same size.

- **The collector's first stage: pointer maps travel in the artifact.**
  `.iyimod` carries a `Layouts` section: per type a module
  owns, its allocation size, its unrounded instance size, and the byte offsets
  of its pointer fields. The offsets come from the target's own data layout, not
  from adding field sizes up, because padding is the target's business and a map
  that misses a field is a collector that frees a live object. A struct of
  `String`, `String` and `Int32` reads back as 24 bytes, scan cap 20, offsets
  `[0, 8]`. `iyi mod dump` shows them. A pointer word past offset 65535 is
  refused by name rather than truncated into a `u16`.

  Alongside it, the object header and its mark word: `type_id` and an atomic
  `u64` holding colour in bits 0 and 1, flags in 2 to 5, and 58 reserved bits a
  forwarding pointer could later use. Colour changes are compare-and-swap and
  report whether they won, so two marking workers cannot both scan one object.
  Proven with two real threads racing 10,000 rounds: exactly one winner every
  round. The round count is 10,000 rather than 1,000 because the measured win
  split at 1,000 was 32/968, one unlucky schedule from a spec that flakes.

  What this is not: no object is allocated with that header, nothing marks and
  nothing collects. `-Dgc_boehm` is still the only way to get collection, and
  every other path still allocates and never frees. Stage 1's own tasks 3 and 4,
  work distribution and write barriers, are design and deferred to Stage 6 by
  their own text. `noscan_offsets` is empty everywhere on purpose: what "not
  traced" means is Stage 6's to define, and guessing now risks a later stage
  reading it as "do not retain" and collecting live buffers. Layouts are per
  instantiation, not per GC shape, because shape keying is R-4 and unbuilt.

### Fixed

- **`memset` strode eight elements where it meant eight bytes — in every
  released compiler.** The prelude's own `memset` advanced its
  `Pointer(UInt64)` by 8 — eight *elements*, 64 bytes — while its counter
  recorded 8, so every runtime-sized clear wrote one word in eight far past
  its count and left seven of eight bytes dirty. Invisible until now because
  the bump allocator's overwrite landed in the untouched zero tail of its own
  mapping; the arena gate's default arm found it by burning a full region —
  2,000,000 allocations of 24 bytes segfault on 0.6.0 as released. The win32
  copy carried the same stride, which is consistent with that target's open
  diagnosis of binaries printing memory they were never given, and wasm32
  carried it at width four. All three loops advance one element now; the
  `-Dgc_iyi` branch's own memset already did.

### Learned

- **A parked fiber's stack is an unscanned root, and the optimiser is part
  of the collector's contract.** Two findings from rebasing the collector
  onto 0.6.0's tree. Root discovery was written when this language had no
  fibers; 0.4.0 gave it a scheduler, so `each_root`'s walk — current stack,
  spilled registers, globals — now has a named gap: an object reachable only
  from a parked fiber's stack would be freed live. Latent, because only the
  single-fiber exercises trigger collection; recorded in GC_DESIGN.md as
  Stage 3's next task rather than a wait on threads. And the sweep gate's 2
  MiB root sat in a global written and never read, which the optimised build
  was within its rights to drop — the exercise now reads the root back after
  collecting, the check that is also what keeps the store alive.

## 0.6.0 — 2026-09-01

**A file reaches exactly what it imports, and a mistake dies where it
was written.** The import wall R-1 promised turned out not to exist —
anyone's import made a module everyone's — and now it stands per-file,
`pub import` the one door through it, closed for `using` and for
qualified names alike; the refusal teaches both fixes by name. And
typing moved home: every fully declared def in user code is checked
against its own signature in the same semantic run, generic bodies
against their bounds through synthesized witnesses — build, `check`,
artifact emit and every LSP keystroke agree about what "clean" means,
and `--shallow` is gone because there is no shallower truth to offer.

The agent's loop is verbs now, all gated: `check` with `--affected`
for the ripple, `fix`, `test --affected`, `mcp`, `run --sandbox`, and
`mod context --budget`. `Program.args` and `Program.env` landed in the
own prelude, so a pure-iyi tool reads its arguments, its environment
and the disk.

`.iyimod` format is v42 — the facade bit travels, one byte per import
edge — so a 0.5.x artifact is rejected by a 0.6.0 build and rebuilt,
never migrated.

### Added

- **The wall closes on qualified names too.** `Lib::Inner.shine()`
  without an import leaked through the type graph — the half the entry
  below recorded as open. It closed at the one funnel every written
  `Path` resolves through: an authoritative lookup that lands in an
  imported unit now demands the writing file reach that unit, directly
  or through `pub import`s, with the same refusal wording. Three fences
  hold it honest: speculative lookups (overload matching trying
  restrictions with `raise` off) keep their answer rather than gaining
  a new way to fail; a unit in no import edge is the current source's
  own and always reachable; and a writer this build never read as a
  file — a mono body or initialiser replayed out of an artifact, which
  carries its far machine's source path — is exempt, because it was
  checked when its own module built. Reachability is memoized per file
  once the top-level pass completes; latency and rebuild budgets are
  unmoved.
- **The import wall is per-file now, and `pub import` is the one door
  through it.** Found while building the door: the wall did not exist.
  `using x` checked *type existence*, which is program-wide — anyone's
  import made a module everyone's, and a consumer could `using` a
  module it never imported so long as some other file had pulled it in.
  That is the phantom-dependency disease R-1 exists to refuse, and it
  compiled here. Now `using` reaches exactly what the file imported,
  plus what those imports hand on with `pub import`, transitively — the
  facade form a mature library needs so its internal layout does not
  leak into every consumer. The refusal teaches both fixes by name.
  The facade bit travels in the artifact (`.iyimod` format v41 → v42:
  one byte per import edge), replays as `pub import` in the
  declarations a consumer compiles against, and moves the interface
  hash — re-exporting, or ceasing to, changes what a consumer may
  reach, which is interface in R-1's own sense. A first cut of this
  entry recorded qualified naming (`Lib::Inner.shine()` without an
  import) as the wall's known open half; it closed in the same wave —
  see the entry above.
- **Generic bodies are checked against their bounds — R-2c's second
  half.** `def total(s : Sized)` was fully written and still
  caller-typed: a trait restriction makes the def generic, and
  duck-typed generics ship the library author's mistake to the
  consumer. Now the bound is enough: the compiler synthesizes one
  witness type per simple trait (`struct IyiDefTypeWitness_Sized` +
  an impl whose stubs return `uninitialized` values), and types the
  body against exactly the bound — `s.size() + s.length()` dies at the
  definition with the witness named in the error, a return lie dies
  the same way, and an honest body is clean. This is the half Rust
  checks always and duck-typed generics never; here it costs one
  synthetic type per trait per compile. Witnesses are declarations, so
  they take one extra top-level visit before the main pass; `self` in
  a requirement spells the witness. Out of reach and stated:
  supertrait, generic and associated-type traits (`Enumerable` stays
  caller-typed), and requirements the stub cannot write. Two keyword
  collisions on the way in — `trait` and `import` are identifiers
  nowhere in this fork, including the compiler's own source.
- **Definition-site typing is the language's rule now — R-2c.** The
  `check` probe of the previous entry grew up and moved into the
  compiler: after the top-level pass, every fully declared def in user
  code is typed against its own signature, in the same semantic run —
  build, `check`, artifact emit and every LSP keystroke agree about
  what "clean" means, and `--shallow` is gone because there is no
  shallower truth to offer. The probes are built from *resolved* types
  (a parse-time draft died twice: a trait restriction is invisible at
  parse, and the top-level macro expander met a scope-less synthetic
  call), anchored at the def they belong to, and marked so reference
  answers never count the compiler's own calls. What stays caller-typed
  is stated: trait-restricted, generic, block-taking, unannotated,
  impl-carried (R-3 keeps those inside their trait context), non-`pub`
  module functions (R-2's wall applies to probes too), and all `.cr`
  sources — each of those probe fences was earned by a sample that
  failed a draft, not designed in advance. First real catch: the
  packages gate's own fixture — a signature edited to `Int64` over a
  body still returning `Int32`, a dormant lie the lazy rule had shipped
  for a release. LSP latency and the rebuild loop stay inside their
  budgets.
- **`check` types the body nobody calls — R-2's dividend, collected.**
  Lazy typing (inherited from Crystal) meant a build said "clean" about
  a def it never visited, and `check` repeated the lie. A fully written
  signature is exactly enough to type the body without a caller, so
  `check` runs a probe pass: for every def whose parameters and return
  are all written, one synthetic call with `uninitialized` values of
  the declared types, under `if false`. Crystal cannot offer this; here
  it falls out of the rule that signatures are written down. What the
  probe cannot reach is stated, not hidden (generic free vars, blocks,
  unannotated parameters, generic and abstract types); `--shallow` is
  the build's exact answer; `fix` compiles with the same probe, because
  two tools answering differently is two tools lying to each other.
  126 ms on the kemal-port sample, both passes included.
- **`check --affected` — the ripple.** `test --affected` answers "which
  tests re-run"; this answers the sibling question "does everyone who
  imports the change still compile": every `.iyi` whose parsed import
  closure reaches a changed file is compiled alone, probe included, and
  every failure is named with its deepest message. The closure now
  resolves from the header-derived project root (IV.6 read backwards,
  the LSP's own rule), which `test --affected` inherits — a nested
  module's consumers were invisible before.
- **The suggestion pool includes `using`-imported names.** `addd` went
  unsuggested while `add` sat one edit away in the file's own `using`
  line: the Levenshtein walk never looked there. The new walk is the
  same namespace climb the call's real lookup performs, seeded the same
  way; selective `using` contributes its selection, bare `using` the
  module's exported names. Flows into prose, `suggested_edit`, the LSP
  quickfix and `fix` unchanged.
- **`Program.args` and `Program.env` in the own prelude.** The loop is
  now around a language that can do work: a pure-iyi tool reads its
  arguments, its environment and the disk, no `--crystal`. Args ride
  the compiler's own `ARGC_UNSAFE`/`ARGV_UNSAFE` (initialised before
  anything runs); env reads libc's `environ` symbol lazily — a first
  draft captured argv from `main` into class variables and read zeros,
  because `__crystal_main` runs class-variable initialisers *after*
  `main`'s prologue stored; symbols have no such ordering. On wasm32
  `env` answers nil for every name: the absence *is* III.12's sandbox.
  The stale "no IO beyond `puts`" sentence is restated in README and
  SPEC where it stood. `bench/agent_loop.py` holds 27 steps.

- **The agent's loop, one verb per step, and all of it gated.** The
  first AI-first menu made the compiler legible (surfaces as data,
  errors as data, a server); this wave makes the loop itself cheap:
  - `iyi check [-f json]` — the front end's verdict alone: no codegen,
    no binary, exit code the answer. Checks exactly what a build
    checks, and its own comment says what lazy typing leaves unvisited.
  - **`suggested_edit` in JSON errors** — the did-you-mean travels as
    data from the raise site: file, line, column, size, replacement, a
    self-contained edit. The refusal recorded in AI_FIRST ("inventing
    edits would be prose wearing a schema") was against parsing prose
    back, not against carrying the name already computed — so now it is
    carried, the III.1.7a participle and `and`→`&&` included, and the
    LSP quickfix reads the field instead of scanning its own messages.
  - `iyi fix [--json]` — applies exactly those edits, one per round,
    recompiling between, until clean or the error carries no edit.
    `check` shows the edit; `fix` performs it; nothing is invented.
  - `iyi test --affected FILE` — only the tests whose transitive import
    closure reaches a change, parsed in milliseconds, exact. Restated
    on the way in because the menu had it wrong: interface hashes are
    the *rebuild* truth, not the test truth — an edit that moves no
    surface still changes what a consumer's test executes. Conservative
    at both unprovable edges: an unparseable test always runs, a
    deleted changed file turns the discount off.
  - `iyi mcp` — check, fix, context and test as Model Context Protocol
    tools over stdio, one JSON-RPC message per line. Deliberately a
    shell around this same binary: no second implementation, no drift.
  - `iyi run --sandbox` — III.12 worn as a verb: cross-compile to
    wasm32-wasi, link through wasi-sdk's clang standing as `cc`, run
    under a wasmtime that preopens nothing. The theft dies at the
    compile fence by name; a missing toolchain is named, never worked
    around.
  - `iyi mod context --budget N` — the grounding pack cut by a defined
    ladder, never truncation: docs off from the last import backwards,
    then surfaces collapse to headers that still name every import and
    the cost of eliding them. A token is four bytes, crude and stated.
    `--json` refuses the flag: JSON is already data.
  `bench/agent_loop.py` is the gate — seventeen asserted steps through
  ground → check → fix → affected tests → MCP → sandbox — in CI beside
  the LSP session.

- **A package that names a library it does not carry is refused.** Taken
  from Crystal's own release engineering, which fails its build when
  `otool -L` on the finished compiler names anything under
  `/usr/local/lib` or `/opt/homebrew`
  (`distribution-scripts`, `omnibus/config/software/crystal.rb`). iyi
  asks the same question at package time on both platforms, and it is
  the only self-containment proof darwin can have from its own job —
  that job runs on a machine which *has* brew's libraries, so "it ran"
  proves nothing while "it names nothing outside itself" proves
  everything. `scripts/bundle-runtime-libs.sh --verify-only` asks it of
  a package somebody else built, and CI now asks it of the release
  artifact before the clean room even starts: the structural answer
  names the offending library, where a bare-image run only says
  `cannot open shared object file`.

### Learned

- **Crystal solves this one layer lower, and iyi should follow.** Their
  LLVM is built for the package rather than borrowed from the host:
  `-DBUILD_SHARED_LIBS=OFF` with `TERMINFO`, `ZLIB`, `ZSTD`, `LIBXML2`,
  `FFI` and `Z3_SOLVER` all `OFF`, `MinSizeRel`, and only the two
  targets they ship. A statically linked LLVM with no optional
  dependencies means the closure iyi now carries — libedit, libxml2,
  libicu, libncursesw, libzstd — never comes into existence, and the
  tarball loses most of its size. What iyi does today is correct and
  proven; what it is not is small. Recorded with the flags, not
  attempted in the same breath: building LLVM in CI is its own piece of
  work with its own budget.

## 0.5.1 — 2026-08-30

**The language reached the machine most developers sit in front of, and
a caught panic stopped costing the process.** darwin arm64 is a run
target and a ship target: the same fibers, defer registry and panic
path, calling libSystem where Linux issues raw syscalls — Apple's rule,
not a compromise — with a native CI job holding the same gates and
shipping its own relocatable tarball. And III.1.4's last sentence went
literal: reading a panicked task's handle catches the panic as a
`Panicked` value and the process outlives the bug; a panic nobody reads
is still re-raised at the join, exactly once.

`.iyimod` format is unchanged at 41; a 0.5.0 artifact is rejected by a
0.5.1 build and rebuilt, never migrated.

And a release is a tag now: pushing `v*` has CI build and *prove* both
tarballs — unpacked somewhere else, samples run, the daemon served —
then attach them, with the notes read from the annotated tag's own
message. Nothing is packaged on a laptop again.

### Added

- **darwin arm64 is a run target and a ship target.** The concurrency
  runtime crossed its second platform: same fibers, same one-word
  context, same defer registry and panic path — the port changed who is
  called, libSystem's `mmap`, `kqueue`/`kevent` and
  `clock_gettime_nsec_np` where Linux issues raw syscalls, which is
  Apple's rule (III.9) rather than a compromise this design settled
  for. kqueue refuses `/dev/null` where epoll refuses a regular file,
  and both refusals answer "readable now". A native macos-14 job builds
  the release binaries, holds the gates a Linux push answers for, and
  ships `iyi-<version>-darwin-arm64.tar.gz` — proven by unpacking it
  somewhere else and running iyi's own prelude, `--crystal` and the
  daemon out of it, which is how the first darwin package was caught
  shipping Crystal's library flattened by BSD cp.

- **Observed bugs are values; unobserved bugs are loud.** III.1.4's
  "catchable at task boundaries", made literal: reading a panicked
  task's handle catches the panic — `value` answers `Panicked`, an
  ordinary `Error` implementor carrying the message, so `case`, `!`,
  `.or` and the typed group's error union handle a caught panic with
  machinery III.1.3 already built, and the process outlives the bug. A
  panic nobody reads is still re-raised at the join, exactly once. The
  gate's step is the sentence: a task panics, the reader prints
  `caught: task blew`, life goes on, exit 0.

### Fixed

- **Two LSP gate steps asserted timing, and the darwin runner said
  so.** The cancellation and burst-coalescing steps sent their frames
  one write at a time and passed on the machine that wrote them by
  luck: a quicker runner answered the request before its cancel
  arrived — the server's documented limit (in-flight work is
  uninterruptible), not a bug in it. Both steps now write their frames
  in *one* write, so "drained together" is a fact, and the burst step
  asserts the stronger thing it always meant: six changes, exactly one
  compile.
- **A release asset that did not exist passed quietly.** Both tarball
  uploads globbed under `.build/`, which `upload-artifact` v4 treats as
  hidden and skips with a warning — so the first tagged run found
  nothing to attach. Staged into `dist/` now, with
  `if-no-files-found: error`.
- **The tarball carries LLVM, and a bare image proves it.** Every
  release before this one shipped a `bin/iyi` that could not start on a
  machine without the exact libLLVM it was linked against — and no gate
  saw it, because every proof of the tarball ran in the environment that
  built it, where that library is present by construction. Moving the
  packaging into CI is what exposed it: the artifact came from a
  container with LLVM 20 and died on a laptop with LLVM 22. The package
  now carries libLLVM in `lib/` and the binaries carry an
  `$ORIGIN/../lib` rpath — escaped past the shell the bootstrap compiler runs its link
  command through, which the first cut got wrong in the way that hides
  the bug: an unescaped token bakes `/../lib`, which resolves to the
  *system* library. And the missing gate exists now: CI unpacks the
  tarball in a bare `ubuntu:24.04` with nothing but `gcc` and builds a
  program there. The cost is honest — tens of megabytes instead of a
  handful — and a
  release cannot ship without passing it.

## 0.5.0 — 2026-08-29

**The language got its editor, and a panic stopped being a process.**
0.4.0 made iyi concurrent and machine-readable; this release makes it a
language you can *live in*. `iyi lsp` grew from a first session into a
server that stands feature-for-feature beside gopls: pull diagnostics an
agent asks for instead of subscribing to, completion that writes the
`import`/`using` pair it knows you forgot, rename that reaches files
nobody opened, a code lens that runs the module over the wire, semantic
tokens so no editor needs a grammar for `.iyi` — and a three-file VS
Code client in `editors/`, with one-stanza configs beside it. The server
answers to five gates on every push: a 49-step scripted session, latency
budgets per verb, an 8,000-token word-boundary sweep, a transport soak
that hits it with garbage and demands a hover after each blow, and the
doc-numbers sweep that keeps every stated figure honest.

And panics landed the way III.1.4 always wanted them: a panic kills the
task, not the process. `defer` registers its cleanup on a per-task list
the panic path walks, so the promise holds with no unwinder, no landing
pads, no libgcc — the dependency floor never moved. A panicking task
drains its defers, its group cancels the siblings and re-raises once in
the owner; main exits 1 after its own drain; `.or_panic` became a real
panic by its lowering not changing at all. The AI_FIRST menu this cycle
opened with closed 8-for-8, every row gated.

`.iyimod` format is unchanged at 41. Released artifacts carry the
version alone, so a 0.4.0 artifact is rejected by a 0.5.0 build and
rebuilt, never migrated — which also retires object code whose panic
was still a process exit.

### Added

- **`iyi vet` — III.8 #3's row, closed as written.** "A verb, not new
  analysis": the analysis is `tool unreachable`, the verb is go vet's
  contract — findings are the exit code, switches pass through.

- **The language server — SPEC.md III.8 #2, built as `iyi lsp`.** Stdio,
  LSP 3.17's earning subset, and no semantic state at all: every change
  runs the real front end on the module under the cursor, which R-1 makes
  a 50–70 ms question on the gate's fixture — so the server is never
  stale, has no invalidation story, and gives no answer a build would
  not. Diagnostics carry the message iyi would print with the SPEC
  section it cites riding in `code` as data and a link in
  `codeDescription`; hover answers from `ContextVisitor`, definition from
  `ImplementationsVisitor`, and the outline comes from the parser alone,
  so it survives a file that does not compile. Two methods go beyond the
  protocol because no other language wrote its interfaces down:
  `iyi/contextPack` serves the grounding pack over the wire and
  `iyi/surface` serves a module's rendered surface, dirty buffer
  included. `bench/lsp_session.py` is the gate: one scripted session, a
  step per claim, in CI beside the other verbs.

- **Editor buffers reach the compiler — `iyi_file_overrides`.** One hash
  of path → buffer, consulted in exactly the two places imports read
  files: `resolve_import` counts an overridden path as existing, and
  `import_file` reads the buffer instead of the disk. The gate's step
  for it is literal: rename a def in an *unsaved* sibling, follow the
  rename in the file that imports it, get a clean verdict while the disk
  still spells the old name. A build that opens no editor pays one hash
  lookup per import. The daemon's prelude-cache rule classified it
  APPLIED_ON_ADOPT beside `iyi_mod_table` — the guard that demands the
  classification caught this commit within the minute, which is what it
  is for.
- **A nested module opened alone finds its root — `iyi_project_root`.**
  The comparison that asked "does this compete with gopls" found the gap
  within five files: a build's project root is the entry file's
  directory, so opening `<root>/calc/parser.iyi` in an editor broke its
  own `import calc/lexer`. The server now derives the root from the
  file's header — IV.6 read backwards: a path that ends with its
  header's path names the root above both — and every module in this
  repository opens clean, 28–81 ms to a verdict, the 1,190-line
  concurrency runtime included. Builds a person runs keep the entry-dir
  rule untouched.

- **Completion, references, rename — the everyday half of `iyi lsp`.**
  The same skeleton three more times: compile, then visit the typed
  result. Completion answers from the last result that held together —
  the buffer stops compiling the moment the dot lands, which is exactly
  when completion fires — and lists the receiver's methods with
  signatures as written, or the scope with its types. References merge
  the compiles of every open document, because under R-1 a def's callers
  live in its consumers' programs; a reference is a resolved edge, so an
  overload sharing the name but not the resolution stays out. Rename is
  references written back, and its gate found the rule worth keeping: a
  `using` line that selects the renamed name is a reference too — miss
  it and the rename leaves a program that does not compile. `UsingDecl`
  carries per-name locations from the parser now, and the gate's step is
  one request, three edits, two files, both buffers clean after.

- **The rest of the protocol — `iyi lsp` at gopls parity.** One session
  now speaks the whole everyday surface. Incremental sync: range edits
  applied in wire units, so a large buffer stops paying full-text tax on
  every keystroke. Signature help while the call is half-typed — the
  callee found by text, because there is no syntax yet; its overloads
  off the typed graph, falling back to every def a call by that name
  already resolved to, which is how a `using`-imported name answers.
  Hover grown to carry the def's signature as written and the `#` doc
  comment above it. Type definition, unwrapping virtual, metaclass,
  generic-instance and union shells to the declaration sites. Document
  highlight — references scoped to one buffer, the declaration marked
  as the write. Prepare-rename, so the refusal arrives before the input
  box opens. Folding — the outline for declarations, the text for
  comment and import runs, all of it alive in a buffer that does not
  parse. Workspace symbols — every `.iyi` under the root, subsequence
  match, open buffers winning over the disk, no index. Formatting —
  `Iyi.format` in process, one whole-document edit. Inlay hints — the
  inferred type after a bare assignment, the parameter's name before a
  positional literal, deduped across a generic's instantiations. The
  compiler's own "Did you mean 'x'?" re-served as a quickfix whose edit
  was computed when the error was. And semantic tokens from the lexer
  alone — which, for a language no editor ships a grammar for, means
  any LSP client colors `.iyi` correctly on day one. One named piece of
  state where the design said none: the last compile is memoised by
  (path, buffer, siblings) — the key is the whole input, so a hit
  cannot differ from a recompile; it exists because one keystroke now
  asks four questions of the same buffer. The gate grew a step per
  claim, each of these sentences asserted in the present tense.

- **The call graph and the pull shape — `iyi lsp`, third wave.**
  `textDocument/implementation` jumps from a trait to its implementors:
  an impl became an `include` in the semantic pass, so the answer is a
  walk of the type tree, not a registry. Call hierarchy makes the
  written def the node — a generic's instantiations collapse back to
  the line the person wrote — incoming edges merged across the
  session's open documents the way references are, outgoing edges read
  from the def's own compile, and the item's `data` carrying the def's
  source key so neither direction re-derives it from wire positions.
  `textDocument/selectionRange` expands off the parse tree alone, alive
  mid-edit. And diagnostics grew their pull shape — the AI-first face
  of the server: `textDocument/diagnostic` answers one buffer on
  request, `workspace/diagnostic` judges the whole project in one, open
  buffers winning over the disk, a file nobody opened still judged. An
  editor holds a subscription; an agent asks a question. R-1 is what
  makes the whole-project question affordable — one cheap compile per
  module, capped so a monorepo cannot turn a request into a build farm.
  The gate holds 32 steps.

- **Workspace-wide references, rename, and incoming calls.** The one
  gap the gopls comparison still named: these three answered from the
  session's *open* documents, so a caller in a file nobody opened was
  invisible — and a rename that missed it shipped a program that does
  not compile. They now walk the workspace the way
  `workspace/diagnostic` does: open buffers first so unsaved edits win,
  then every `.iyi` under the root, same cap, one cheap R-1 compile per
  entry, no index anywhere. The gate grew three literal steps — a
  consumer written to disk and never opened is found by references,
  edited by rename, and named by incoming calls — and holds 35.

- **Auto-import completion, fuzzy-ranked — R-2's dividend.** Bare
  completion now offers the workspace's exported defs beside the
  scope: `pub` is a parse-time fact, so one parse per module names its
  callable surface and the offer works in a buffer that has never
  compiled. Choosing an item inserts the name and the `import`/`using`
  pair arrives as `additionalTextEdits` — a fresh selective `using`
  when the module is unimported, the existing line extended
  (`{token}` → `{token, glyph}`) when it is. Matching is fuzzy (`ucs`
  finds `upcase`) and ranked honestly: scope prefix, keywords,
  workspace exports, fuzzy — the tier leads `sortText`. The gate holds
  38 steps, the new three literal: a never-compiled buffer completes
  `tok`, applies the item, and the verdict is clean.

- **A queue under the one thread: cancels overtake, bursts coalesce.**
  The reader rides its own fiber now, filling a queue while a compile
  runs. A `$/cancelRequest` for queued work answers `-32800` without
  doing the work (in-flight work stays uninterruptible — one thread's
  honest limit, stated); a typing burst's didChanges apply together, so
  six keystrokes cost at most two compiles instead of six, and the
  verdict is the final text's. The gate holds 40 steps.

- **Document links and type hierarchy.** The import block is clickable
  — `import calc/lexer` and its `using` line both target the file,
  resolved by text against the header-named root, alive in a broken
  buffer. Type hierarchy walks the compiled type tree both ways:
  supertypes include the traits an impl brought in, subtypes are the
  implementors walk generalised past traits. The gate holds 43 steps.

- **Code lens that runs, snippets, token deltas.** A runnable module
  carries one lens on its first statement; `workspace/executeCommand`
  executes `iyi.run` — the released verb against the buffer, dirty
  state included, bounded at 30 s — and returns what it printed, so an
  agent can ground, edit, and run without leaving the protocol.
  Completion items with parameters land as snippets when initialize
  said the client renders them. Semantic tokens answer deltas: one
  appended line moves five integers, and the splice reconstructs the
  full answer exactly, gate-checked. The gate holds 46 steps.

- **The speed is measured, and the server ships to editors.**
  `bench/lsp_latency.py` times every verb over the 26-module sample
  corpus and fails CI when a p95 leaves its budget: a keystroke's
  verdict lands in 36 ms p50 / 55 ms p95, hover in 1 ms off the memo,
  completion in 12 ms p50, workspace-wide references in ~1 s — one
  compile per module, the architecture priced rather than hidden.
  And `editors/` makes the server installable: a three-file VS Code
  extension (no grammar — highlighting is the server's semantic
  tokens), with the one-stanza configs for Neovim, Helix, and Sublime
  beside it.

- **A rebuilt binary no longer lobotomises a running session.** The
  first live editor session found it: `make iyi` unlinks the
  executable, `Process.executable_path` goes nil on Linux, and every
  later compile failed with "Missing executable path to expand $ORIGIN
  path" — invisible to a gate that starts a fresh server per run.
  `$ORIGIN` is resolved once and pinned, the server captures its own
  path at startup, and the gate now deletes the executable under the
  running session and watches a fresh compile answer anyway. The gate
  holds 47 steps.

- **The first screenshot taught two lessons.** Semantic tokens now
  classify bare names the way a reader does — `name(` and `.name`
  call, `name:` labels an argument, the rest is a variable — so a
  buffer stops being a sea of plain foreground; the legend grew
  `parameter` for named arguments. And inlay hints learned restraint:
  parameter names only inside parentheses (an operator wearing
  `other:` was the discovery), type hints only on a variable's first
  assignment and never for a bare literal, padded to the `total :
  Int32` the formatter writes. The gate asserts the variable and the
  call by exact position.

- **Whole words, sworn to.** The screenshots' second find: the lexer
  reuses one Token and leaves `raw` dirty between kinds, so an ident
  could inherit the previous number's *length* — every editor showed
  `t`otal, one letter colored. `raw` is now read only for the kinds
  `wants_raw` writes, and `bench/lsp_token_boundaries.py` sweeps all
  8,000+ sample tokens in CI refusing any that colors part of a word.

- **First paint. Crystal colored instantly and iyi a second later,
  because a TextMate pass is synchronous with the first frame and a
  language server round-trip is not. The VS Code extension now carries
  a deliberately minimal grammar — comments, strings, numbers,
  keywords, types, def names; the parts of a language that do not
  drift — and the server's semantic tokens override it on arrival, so
  the fast path is instant and the truth stays with the compiler.**

- **Organize imports, and a transport that does not flinch.** The
  code actions grew `source.organizeImports`: the header block
  canonicalised — imports sorted and deduped, one module's `using`
  selections merged with their names sorted, a full `using` absorbing
  them — and it offers nothing when the block holds anything it does
  not understand, a comment above all. Writing `bench/lsp_soak.py`
  (garbage frames, non-JSON and non-UTF-8 bodies, malformed params, a
  1,500-def module — a hover must answer after each, in CI) found two
  real deaths: a stray blank line read as EOF ended the session, and a
  non-JSON body killed the reader fiber and hung the pipe. The
  transport forgives both; only true EOF ends a session. The gate
  holds 48 steps.

- **`workspace/willRenameFiles` — moving a file renames the module.**
  IV.6 makes the answer deterministic: one WorkspaceEdit rewrites the
  moved file's header and the exact `import`/`using` spans in every
  consumer, open buffers and never-opened disk files alike, before the
  rename lands. The gate moves lexer.iyi to scanner.iyi, applies the
  nine edits across five files, and compiles the moved module clean.
  The gate holds 49 steps.

- **Panics — SPEC.md III.1.4, built, and the unwind owns no unwinder.**
  `defer` now registers its cleanup on a per-task list (`__iyi_defer_push`
  around every deferred scope, popped on ordinary exits), so a panic
  walks the list instead of walking frames: no landing pads, no
  personality function, no libgcc — the dependency floor does not move.
  A panicking task prints once at the site of the bug, drains its
  defers innermost-first, tells its group and dies alone; the group
  cancels the siblings and its join re-raises `a task panicked: <msg>`
  in the owner exactly once; reading a panicked task's `value`
  re-raises too; a boundary-less panic — main's — exits 1 after its own
  drain, cleanup a panic used to skip entirely. `.or_panic` is a real
  panic now, by its lowering not changing at all. `bench/panics.sh` is
  the gate: six steps, each a sentence of III.1.4 in the present tense,
  in CI beside the concurrency exercise.

### Fixed

- **An overflow in a task dies at the task boundary.** III.1.4's one
  recorded residue: `__crystal_raise_overflow` trapped straight to a
  process exit. It steps into the ordinary panic def now, so a task's
  overflow runs its defers, cancels its siblings, and re-raises at the
  boundary like any other bug — gated in `bench/panics.sh`.

### Measured

- **A `defer` costs ~16 ns.** The registry's price — one node, one
  closure under iyi's own allocator — measured by `bench/defer_cost.sh`
  (twenty million calls, release mode, with and without) and budgeted
  in CI so it cannot quietly grow.

- **The rebuild benchmark ran, and corrected its own prediction.**
  `bench/rebuild_speed.py`: an artifact rebuild does *not* beat a
  source rebuild (~1.0x on the sample corpus, ~0.85x semantic-heavy) —
  lazy typing makes unused import surface nearly free, while the read
  pays decode for everything. R-1's wall-time dividend lives where it
  was already gated: the LSP's 36 ms verdict, source-deleted builds,
  the interface hash. CI now holds what the loop owes instead: under
  two seconds per edit-rebuild on either arm, the read within 1.5x of
  the compile it replaces. Recorded rather than tuned.

## 0.4.0 — 2026-08-28

**The language runs concurrently, and a model can read it.** 0.3.0 carried a
shard across a boundary; this release gives iyi the two organs a language
needs to be *used* — and one it needs to be used by the tools of this
decade. Concurrency arrived in exactly the order III.4.8 refused to
shortcut: a scheduler, cancellable blocking primitives, then `group`,
a rendezvous `Channel`, `select` and the typed `group do ... end!` — run,
not just built, on x86-64 glibc, on musl, and on aarch64 under emulation,
with the deadline-and-cancellation claims asserted as wall-clock facts.
Dependencies arrived as III.7's first two steps: `iyi.mod` and minimal
version selection, a git fetcher, and `iyi.sum` noticing when what arrived
is not what arrived last time — proven offline, against a mirror the gate
builds and then deletes.

And the AI-first surface stopped being a plan: a module's exported API as
data (`mod dump --json`), the grounding pack an edit needs (`mod context`),
errors that cite their SPEC sections as fields (`-f json`), a test verb
with no framework under it (`iyi test`), docs riding the artifact, and a
sandbox story measured rather than told. The claim got its gate before the
README got its sentence: eight model runs, two task difficulties, 35–43%
fewer prompt tokens on the pack, and both refusals the gate issued on the
way are still written down in AI_FIRST.md §5.

`.iyimod` goes from format 40 to 41 (`Docs`, and private methods marked).
A 0.3.0 artifact is rejected and rebuilt, never migrated. Released
artifacts carry the version alone, so any 0.4.0 build on the same target
and flags reads them.

### Added

- **Dependencies exist — SPEC.md III.7 steps 1 and 2.** An
  `iyi.mod` beside the entry file is the opt-in: `module <path>` and
  `require <path> v1.2.3`, nothing else. Resolution is minimal version
  selection — the highest of the minimums anything asked for, a worklist
  and no solver — and the fetcher is `git clone --depth 1` at the tag the
  version spells, into the compiler's cache, immutable once fetched.
  `IYI_MOD_MIRROR` redirects fetches to bare repositories under a
  directory, which is how `bench/packages_resolve.sh` proves the story
  without a network: the app asks for liba v1.0.0, its other dependency
  asks for v1.1.0, and the program must print v1.1.0 and never v1.0.0;
  then the mirror is deleted and the second build must still succeed.

  Identity is the import path and the path is a URL, so the import grammar
  admits `.` and `-` inside a segment — in `import` and `using` only,
  because IV.6 #6's strict rule exists so a path and a type name determine
  each other, and `github.com` determines nothing. A requirement's prefix
  never becomes a type: the in-package path does, `using
  example.com/user/liba/colors` reaches `Colors`, and a package's own
  short imports resolve in its own checkout or fail — never passed along
  to the program's roots. A dotted import with no covering requirement is
  refused naming `iyi.mod` and the `require` line to write.

  `iyi.sum` guards what arrives: one line per requirement, a tree hash of
  its checkout, written by the tool and defended by it — a matching entry
  is silence, a tampered one is a refusal naming both hashes, and the gate
  proves both. Building it taught a rule: a checkout is read-only, because
  the first version let a build whose entry sat inside the module cache
  write a sum into the checkout, and the verifier caught its own footprint
  within the hour.

  Not built, and said so in III.7's margin: packages compile
  from source every build (their artifact story is step 5's, with
  signatures), and two packages whose in-package modules share
  a name collide in the type namespace.

- **The AI-first surface, AI_FIRST.md §3's cut.** Three tools, all riding
  machinery the rules already paid for. `iyi mod dump --json` prints a
  module's exported surface as data — exact signatures with their
  `rendered` spelling, types with fields, impls, and the interface hash
  they are keyed by. `iyi mod context FILE.iyi` prints what an edit to
  that file is allowed to know: the surface of every module it imports and
  nothing's body, each import compiled *alone* (R-1 worn as a tool), so a
  half-broken tree still grounds; `--json` makes the pack data. And
  `iyi build -f json` — inherited, measured working — now carries a
  `spec` field: the SPEC sections the message cites, as data, extracted
  by a hand-rolled walk because the first version used a `Regex` and
  `bench/dependency_floor.sh` refused the PCRE2 it linked, by name,
  within the hour. `bench/packages_resolve.sh` gates all three.

  The artifact carries docs now — the one gap III.7 named in its asset.
  `Signature` and `TypeDecl` gained a `doc` field (format v41): the
  comment above a `pub` rides into the artifact, comes back as the
  comment it was in `mod dump --declarations`, and as `"doc"` beside the
  signature in `--json` and `mod context`. Two facts the build wrote
  down: the comment rides the `pub` token, so `parse_pub` captures it or
  `parse_def` never sees it; and a doc is surface for a reader, not the
  type checker, so the interface hash is computed with docs blanked — the
  gate asserts a doc-only edit moves no hash and a signature edit still
  does.

  And the claim got its gate before it got quoted: `bench/context_pack.py`
  is AI_FIRST.md §5, both arms. The token arm is hermetic and in CI — the
  pack must stay under 70% of the raw sources it replaces (measured: 55%
  and 43%) and carry no body, which forced a correction worth the gate's
  existence: the first pack was the compile-against text at 96% of raw,
  because travelling bodies are most of a macro-heavy module, so
  `mod context` now renders the *caller's* document (`IyiMod.surface`) and
  `mod dump --declarations` keeps the compiler's. The rounds arm ran once
  against a real model: the pack won tokens by 35% and tied rounds 2–2 —
  a tie is not a win, so the README stays silent, which is the gate doing
  its job on its own author.

  The gate then ran to a verdict. Three trials per arm on a harder task
  (a mounted sub-router, a filter, path parameters): pack 1+1+3 rounds
  and 17,571 prompt bytes, raw 2+2+1 rounds and 31,053. Eight model
  calls, two task difficulties, one consistent answer — rounds track the
  model, tokens track the grounding, by 35–43% — so the bar was amended
  the way bars are amended here, by the count and in writing: the pack
  must win tokens by a named 25% and must not lose rounds. Both earlier
  refusals stay recorded in AI_FIRST.md §5, and the README's agentic row
  now quotes the measurement with the command beside it.

  `iyi test` closes the loop — the verify verb with no framework
  (AI_FIRST.md §2 #4). A test is a plain iyi program named `*_test.iyi`:
  exit 0 passes, anything else fails and prints its own evidence, which is
  the protocol every gate in `bench/` already runs on. One process per
  test, four verdicts told apart — pass, fail, does-not-build, and
  hung-killed-at-deadline (60 s default, `--timeout`), because a harness
  that can hang is not a harness. `--json` reports the run as data.
  `bench/test_verb.sh` gates all four verdicts.

  The sandbox story is written and measured — SPEC.md III.12. Built by
  subtraction: zero undefined symbols natively, and on wasm32-wasi an
  *absence* rather than a permission, because the prelude never grew a
  `File` surface there. `bench/sandbox_story.sh` holds it to three steps:
  an honest program computes through the boundary, a theft of
  `/etc/passwd` dies non-zero with not one byte in its output under a
  default wasmtime, and the refusal is the prelude's own sentence. And
  `iyi doc` exists — III.8's verb, a renderer over the surface the
  artifact already carries: functions, types, methods, docs; no bodies,
  nothing private; from a `.iyimod` directly or a `.iyi` compiled alone.

- **Concurrency exists, in exactly the order III.4.8 said it must.** A
  scheduler, then cancellable blocking primitives, then `group` and
  `Channel` — never the cheap slices: no `Share` marker gating nothing, no
  sequential `group` wearing concurrency's spelling. `src/iyi/concurrency.iyi`
  is the runtime: a one-word context (the saved stack pointer), a naked
  context switch for x86-64 and aarch64 that `@[NoInline]` had to protect
  before the release build stopped faulting, 256 KiB fiber stacks with a
  guard page each, a run queue, a deadline-sorted sleep list, and an `epoll`
  drained whenever nothing is runnable. Raw syscalls throughout, so the
  dependency floor (III.9) holds: the gate allows the runtime zero new
  undefined symbols, and the aarch64 object still has none.

  The surface is III.4.1's: `group do |g| ... end` with no bare spawn, the
  join deferred so no exit — not a `return`, not an error through `!` —
  leaves a task running; `g.spawn { }` answering a task whose `value` joins;
  the first failing task cancelling its siblings. Cancellation reaches a
  *blocked* fiber (III.4.2) and arrives as a value: a woken primitive
  answers `Cancelled`, an ordinary error member, so `!` drains a cancelled
  task through its remaining waits — III.1.2 doing III.4.2's plumbing.
  `sleep`, `wait_readable` and `iyi_read` are the cancellable primitives,
  and `read_input` goes through them on Linux — III.4.8 named that exact
  call as the one that had to stop being a direct blocking syscall, so a
  fiber reading stdin now parks instead of stalling its siblings, and a
  regular-file stdin (`< file`), which epoll refuses with EPERM, is
  answered "readable now" rather than died on;
  `Channel(T).new` is a rendezvous, as Crystal's is — a parked sender
  carries its value in its queue node's box and an emptied box is the
  delivery receipt — `.new(n)` buffers `n` sends first, a closed channel
  drains before it refuses, and `close` wakes every parked fiber: a
  receiver with `ChannelClosed`, a sender with its box still full. A park
  is named by a nonce, so a queue node a cancellation left behind is
  skipped by arithmetic rather than unlinked by hand — the same protocol
  `select`'s expansion will lean on.

  `bench/concurrency_exercise.sh` gates it, plain and `--release`, with two
  failure proofs: a deadlocked program must exit 1 naming the deadlock
  rather than hang, and the interleaving assert must itself be reachable —
  a misordered copy must fail. The anti-sequential properties are asserted,
  not printed: a channel ping-pong whose letters must alternate, two 150 ms
  sleeps that must overlap, a 10 s sleep that must end in tens of
  milliseconds when a sibling fails, a rendezvous send that cannot print
  its second half before its receiver moves, and three parked senders
  drained in the order they parked.

  `select` works, over any mix of receive and send arms, `else` included.
  The expansion the compiler already had (`::Channel.select({arms})` and a
  case over the index) is served by one variadic def: the arm tuple's
  arity is a compile-time fact a macro walks, so no arity is special. An
  arm parks with the same nonce-named node every plain call uses, a send
  arm can win *while parked* — a receiver empties its box directly — and
  on a cancelled task the first arm answers `Cancelled`, exactly as that
  arm's own primitive would have. Two prelude debts surfaced and were
  paid: `Object#===`, which any integer `case` needed, and
  `TypeCastError`, which the expansion's `.as` names on its failure path
  — a panic wearing the constant's name, since nothing here unwinds.

  The typed group is in — III.4.1's own example, taken literally.
  `group do ... end!` answers the tuple of what its direct spawns
  returned, or the first error member, with `!` propagating it through
  III.1.2's ordinary machinery — the expansion appends `g.join` and an
  `is_a?(::Error)` extraction chain to the block, and `group` now answers
  what its block answers. The build forced one correction worth keeping:
  the first version inlined the block into its caller and the gate broke
  it — an inlined name collided with a later closure's, and closured
  variables do not narrow — so the block stays a block. A spawn in a loop
  keeps the general form, asserted in the gate; `end!` needed the lexer
  told that `!` is not part of a keyword's name either.

  Not built, and said so in III.4's margin: `Share` (one thread cannot
  race, so it would refuse nothing testable), and every platform that is
  not Linux — wasm32 cannot switch stacks, and an imitation is the thing
  III.4.8 refused to ship. The prelude stands at 5,674 lines against a
  ceiling of 3,734 — remeasured, not raised: the ceiling is Crystal
  0.1.0's core, that core shipped concurrency (`thread.cr`, `fiber/`, 183
  lines), and the original list had left it out because iyi then had
  nothing to compare it against. Same tree, same purpose, both sides
  counted.

## 0.3.0 — 2026-08-26

**A shard crosses a boundary.** 0.2.0 swept nine shards through `--crystal` and
served HTTP from source; how many of the rest worked was not something it
measured. This release measures it, and the thing being measured changed:
`crystal tool bind` turns a shard into a `.iyimod` — declarations and object
code — and a program is built against that rather than against the shard's
source. R-1 the whole way down, for code nobody wrote in iyi.

Three shards cross, and twelve of Crystal's own namespaces, each under a gate
that runs the program and compares its answers with the same program built
from source:

| | |
|---|---|
| kemal 1.12.0 | routes, URL and query parameters, the handler chain, `Kemal.run` — through four boundaries, with backtracer, radix and exception_page under it |
| jwt 1.6.1 | a token signed and read back, through four boundaries, over openssl_ext, bindata and bindata/asn1 |
| sqlite3 0.21.0 + db | a table created, rows bound and inserted, a result set read with typed columns — two boundaries, and the first pair where one shard declares what the other must answer |
| twelve of Crystal's own namespaces | `JSON`, `URI`, `Log`, `Path`, `Time`, `Base64`, `UUID`, `INI`, `CSV`, `Colorize`, `XML`, `Random` |

A hundred and nineteen findings came out of it and each is written down below,
measured rather than reasoned about. The ones that changed a rule: a body that travels
is compiled twice and the two are not the same function; an `abstract def` is a
requirement and not a header; a constant has two spellings and which one a
build picks is a fact about that build; and a module is a mixin on the other
side of a `--crystal` boundary, which iyi's own module header had been
assuming otherwise.

What does *not* cross is worth as much as what does. A shard whose surface
needs a human to write it down is refused with the list, not guessed at:
`crystal tool bind` prints what it could write, what a machine could write, and
what nobody can — and the last of those is a number this release moved rather
than eliminated.

`.iyimod` goes from format 19 to 40. A 0.2.0 artifact is rejected and rebuilt,
never migrated, which is the rule below doing its job. Artifacts written by
this release are read by every other build of it on the same target and under
the same flags.

### Added

- **A module is a mixin on the other side of a `--crystal` boundary, and the
  format now says so.** iyi's module header desugars to `extend self`: in iyi a
  module is a compilation unit, not a mixin, so its functions belong to the
  module itself. A boundary's declarations are read under that header, and a
  `--crystal` boundary reopens a module of the *other* language — where a
  module is a mixin, a module function is written `def self.` and an instance
  method is not. Extending it anyway put the module into its own metaclass, and
  `module Random`, which has `abstract def next_u` for its includers to answer,
  then had a metaclass that answered nothing: `abstract def Random#next_u()
  must be implemented by Random:Module`, on a program whose only line was
  `import random`. Plain Crystal refuses `extend self` beside an `abstract def`
  for the same reason.

  So the header supplies it no longer, and the artifact carries it — which is
  the honest place for it, because whether a module extends itself is a fact
  about the module. `Random` crosses; `module Shard; extend self` still has its
  functions on the module on both sides. Two things had been leaning on the
  header without saying so, and both said `undefined` the moment it stopped:
  the constant accessors `tool bind` synthesises are module functions and are
  written `def self.` now on both sides of the boundary, and the `extend self`
  line has to come *after* the requires the header lifts out, or every one of
  them stays inside the module.

  `.iyimod` goes to format 40. A 0.2.0 artifact was already rejected; a 39 one
  is too.

- **Eleven of the library's namespaces cross, and each is a gate.** `JSON`,
  `URI` and `Log` were already there; `Path` and `Time` joined with the
  constant finding below, and `Base64`, `UUID`, `INI`, `CSV`, `Colorize` and
  `XML` found nothing at all. That last part is worth having: a gate that holds
  only the cases that once broke says nothing about the ones that never did,
  and "never did" stops being true the moment somebody changes how a boundary
  is written. Eleven namespaces, bound and consumed, in two minutes.

- **A module's own instance method travels as a body.** It is compiled once per
  including type, which is the fourth thing IV.1g says has no single symbol to
  key on — and the producer emits one only for the including types its own code
  instantiated. `db` has them because `db`'s code closes all three of its
  `Disposable`s; `module Gen` with a `def next_pair` and a `class Fixed` that
  includes it has none, and the link ended on
  `*Gen::Fixed@Gen#next_pair:Tuple(UInt32, UInt32)`.

  The keep file learned the other half. These are declared as the module's, and
  an iyi module header is `extend self`, so a consumer reads them on the module
  *and* on whatever includes it — which is what an including type needs and is
  not a claim about the shard. `module Random` writes `def new_seed` without
  `self.`, and `Random` answers to no such name; called in the keep file, which
  is compiled against the shard's own source, it stopped the fill build on
  `undefined method 'new_seed' for Random:Module`.

- **A module used as a value has no name a declaration can write.**
  `Random::Secure` is `module Secure; extend self; include Random; end`, and
  `Random#split` answers `(Random::PCG32 | Random::Secure:Module)`. The
  nameability scan read `Secure` and `Module` as two names, found both
  nameable, and wrote it down; the consumer's parser stopped on `expecting
  token ')', not 'Module'`. One colon, not two — `Foo::Module` is a type
  somebody could declare.

- **`Path` and `Time` cross, and a constant has two spellings.** A constant
  read before it is initialised is reached through `~NAME:const_read`, a
  function in the main module that runs the initialiser once; one initialised
  before anything read it is a plain global. `initialize_const` picks between
  them on `const.read?` at the moment initialisation is emitted — which is a
  fact about *that build's* order and not about the constant. The producer's
  units read these and it emitted the function; the consumer initialises them
  from its own program and emitted the global, so the artifact's object code
  asked for a function nobody wrote: `undefined symbol:
  ~Iterator::Stop::INSTANCE:const_read`, referenced from `Path`'s
  `PartIterator` unit, in a program whose own source names no iterator.
  `Time::Span::ZERO` is the same thing one namespace over. The consumer now
  defines the missing spelling for every name in an artifact's `Constants`,
  beside the type ids and the match funs it already defines for the same
  reason. The global is defined either way, so a unit referring to that instead
  still links.

  Forcing the flag from the front end instead — a `pointerof`, which is what
  `needs_init_flag?` already answers to — is wrong twice over, and both ways
  are recorded because both were measured: it initialises nothing, so
  `kemal/dsl`'s `APP` came back with its routes unregistered, and with a read
  kept beside it the changed order closed `STDERR` under `bench/bind_chain.sh`.

- **A module's instance method is not a module function.** `owners` took the
  module's own name unconditionally, on the reasoning that a module written
  `extend self` defines its functions there. A module that does *not* write it
  does no such thing: `module Random` writes `def new_seed` without `self.`,
  which is an instance method its includers get and not a name `Random` answers
  to. Read as a module function it produced `Random.new_seed` in the keep file
  and the fill build stopped on `undefined method 'new_seed' for
  Random:Module`. The bare name is taken now only where the module's metaclass
  has the module among its ancestors, which is what `extend self` does.

- **A kemal application in `samples/crystal/kemal`.** Routes, URL and query
  parameters, a JSON endpoint that reads a POST body, and a 404 handler. The
  shard is not vendored: `shard.yml` pins kemal 1.12.0 and `shards install`
  fetches it, the same as any Crystal project. It builds from source and again
  across four `.iyimod` boundaries, and the two answer byte-identically — one
  line differs between them, `require "kemal"` against `import kemal`.
  `bench/kemal_serves.sh` is this program with a gate around it; this is the
  same thing written to be read.

- **`sqlite3` runs a query.** A program that imports `s_q_lite3` opens a
  database, creates a table, inserts two rows with bound parameters, reads a
  scalar back, iterates a result set with typed `read(String)` and
  `read(Int32)`, and counts the rows — through two boundaries, `db` and
  `sqlite3`, and answers what the same program answers from source. The third
  real shard to cross, and the first whose boundary is *two* shards deep: the
  driver implements what the pool declares, and neither one ever sees the
  other's source.

  **A body that travels is compiled twice, and the two are not the same
  function.** The producer compiles it against declarations. Where such a body
  calls an `abstract def`, the producer's world may hold nothing that answers
  it — `db` alone has no driver — and what `db`'s artifact carries for
  `Connection#fetch_or_build_prepared_statement` is a function whose `else`
  branch returns its own argument. The consumer compiles the same body against
  `SQLite3::Connection` and gets the right one. Both wore the same name; the
  consumer's copy is private to its unit and the producer's is global, so every
  call the consumer wrote bound to the producer's. `DB.open` handed back a
  statement whose `crystal_type_id` was 1, and `.class` on it hit the trap at
  the end of a dispatch nothing matched — `Invalid memory access` in
  `SQLite3::Statement#perform_exec`, three frames further on than the cause.
  The consumer's copy now carries a suffix, so a name that means two different
  things is two symbols. The producer's stays global: its own object code calls
  it, and so does `sqlite3`'s — `Statement#do_close` calls `super` — and hiding
  it broke the link instead.

  **An `abstract def` is a requirement, not a method with an empty body.**
  `Def#body` is the empty string for one, which is truthy, so a requirement
  came through the generic path as a concrete method that answers `nil`. The
  format has said `required` since abstract classes crossed; the generic path
  was not saying it. Read back as an implementation, `db`'s
  `SessionMethods#fetch_or_build_prepared_statement` was the null statement.

  **A requirement with a `Nop` body is not a header.** A declaration read from
  an artifact has an empty body and is typed from its return annotation, which
  is what makes a boundary cheap. An `abstract def` looks exactly like one and
  is the opposite: no code answers *it*, the code that answers lives on a
  subclass. Taking the header path there typed the call and emitted none, and
  the caller read whatever the stack held.

  **A written return type is a restriction, and a travelling body keeps it.**
  Three places wrote the return as empty wherever the body answers, on the
  reasoning that a body that travels is read for what it returns. That is true
  and it is not a reason to drop what the shard wrote: Crystal narrows a
  written return to what the body produced, exactly as it does for the shard,
  and *dropping* it made `sqlite3` refuse its own override — `this method
  overrides ... which has an explicit return type of Stmt`. A requirement's
  return type is inherited by the implementation for the same reason its
  parameter types are.

  **The head of a path can be shadowed, not just a bare name.** `db` writes
  `::Log::Metadata::Value` — with the `::`, because a shard's author meets this
  too — and resolving it to `Log::Metadata::Value` put the shadowing one
  segment along: `undefined constant Log::Metadata::Value`, read inside a
  module that has a `Log` of its own.

  **A name inside `responds_to?` is a call, and it is the one call the search
  cannot follow.** The private-callee search reads a travelling body and finds
  the private methods it names; `responds_to?(:name)` names one on a receiver
  that is whatever the caller passed. `db` writes `Pool(T)#checkout` — generic,
  so its body travels — ending `res.responds_to?(:before_checkout) &&
  res.before_checkout`, and `Connection#before_checkout` is `protected`. `Pool`
  is not `Connection`'s ancestor and `T` binds to it nowhere a search can read,
  so the hook stayed behind: `responds_to?` answered false in the consumer,
  `auto_release` was never set, and no connection went back to the pool. Every
  statement got a fresh connection — which a file-backed database does not
  notice and `:memory:` does, losing its table between statements. Every body
  that says `responds_to?` is now searched for every type, which errs long the
  way the rest of that search does.

- **`jwt` works.** A program that imports `j_w_t` encodes a token, decodes it
  back and reads the header out of it, through four boundaries —
  `openssl_ext`, `bindata`, `bindata/asn1`, `jwt` — and answers what the same
  program answers from source. The second real shard to cross, and a different
  kind of shard from kemal: C-linked, written on macros that write classes, and
  with an exception hierarchy of its own. Eleven findings came out of it.

  **A body is what a method is, where the caller decides what the method is.**
  Already the rule for a block whose type nobody wrote; the same question asked
  of the arguments is a parameter with no restriction, a splat, or a double
  splat. `JWT.encode(payload, key : String, algorithm : Algorithm,
  **header_keys) : String` is the whole of making a token, and R-2 refused it
  and asked a human to annotate `payload` — but there is no annotation to
  write. The type is the caller's. Crystal compiles a member of that family per
  call site with the call site's types in the symbol, so there is no single
  symbol to link against and the body is the only honest declaration. The keep
  file learned the other half: a signature with a splat, or a parameter whose
  type holds an `_`, is one there is no value to make and no symbol to keep.

  Two collectors had drifted apart and the type side was behind. The
  module-function collector has read `storable` as a question about a method
  *called by symbol* since `Kemal.run` crossed; the type collector read it as
  unconditional, so `OpenSSL::PKey::RSA.new(encoded : String, passphrase =
  nil)` was dropped over `passphrase` and a consumer got the one overload left:
  `expected argument #1 to 'OpenSSL::PKey::RSA.new' to be Int32, not String`.
  And a body-carrying `new` stays behind *because it is synthesised* — an empty
  receiver is what says so — where `openssl_ext` writes three of its own.

  **`initialize` travels where the `new` made from it did not, and "did not" is
  a question about a shape.** "Only where `new` is absent" held while the only
  `new` was the compiler's. `openssl_ext` writes two `def self.new` on
  `OpenSSL::PKey::PKey` and two `initialize` beside them, and the `new` made
  from `initialize(is_private : Bool)` is a fourth overload nobody wrote,
  refused because an abstract class cannot be allocated. The name test saw two
  `new`s and called the type covered.

  **A constant's value is code, and code has a scope.** The value travels as
  source, and that source can call what R-2 held back — `GETS_BIO = begin …
  io_for(bio) … end` inside `class OpenSSL::GETS_BIO`, where `io_for` is
  `private def self.`. The private-callee search already existed for travelling
  bodies; a constant's initialiser is one. And the value has to be the value as
  *written*: `bindata`'s `KLASS_NAME = [ASN1::BER::ExtendedIdentifier]` reached
  the format as five statements over three temporaries and the consumer said
  `undefined local variable or method '__temp_829'`.

  **What a shard adds to a `lib` is more than its types**, and the correction
  is the previous entry's own reason turned around. A `fun` is a C symbol and
  the linker resolves it — true of the object code an artifact carries, false
  of the bodies it carries, because a body the consumer compiles makes the call
  itself: `undefined fun 'pem_read_bio_rsa_private_key' for LibCrypto`. A
  `lib`'s `enum`s and constants came with it. And the names in `Reopened` are
  names the consumer can write: counted as unnameable, `OpenSSL::PKey::PKey`
  crossed as a *handle* — no fields, and no `new` with them — over an `@pkey`
  field naming the `LibCrypto::EvpPKey` the shard itself declares.

  **A class variable is identified by its owner and its name, and the
  bookkeeping was keyed on neither.** `MetaTypeVar` is a `Var`, whose equality
  is `def_equals_and_hash name`. A class variable declared on a superclass is
  copied onto every subclass that reads one, so `bindata`'s `@@bit_fields` is
  six variables and was one hash key: the unit `ASN1::BER` reads four of them
  and the last write took the entry. The link ended on
  `~ASN1::BER::bit_fields:read`. That copy is also where the initialiser was
  being lost — `lookup_class_var?` carries the type, the thread-local flag and
  the initialiser node, and iyi had added a field the copy did not carry.

  A third way of reading one is visible in the code and stays unhandled on
  purpose: where the owner is a virtual type the read dispatches on the
  receiver's type id through a main-module function, and the main module never
  travels. That is what the symbol above looked like, and it was the wrong
  reading — the fix for it was written and taken back out, because nothing has
  reached that path and a rule with no measurement behind it is worse than a
  gap that is written down. SPEC.md Part V item 12 has it written down.

  **A class is held virtually, and the keep file was naming it.**
  `BinData::VerificationException.to_s(io)` emits
  `*BinData::VerificationException::to_s<IO+>`; a consumer holding the class —
  `io << exception.class` — asks for `*BinData::VerificationException+@…`. The
  keep file now calls the class side through `uninitialized T.class`. Not
  `new`: a virtual metaclass dispatches it to every subclass, and a subclass
  builds itself its own way.

  **`yaml` crosses too, and what stood in its way was one link flag.**
  `bench/yaml_reads.sh` binds a boundary from Crystal's own library — not a
  shard, which is what makes it a different measurement — and a consumer parses
  a document with an anchor and a merge key in it. The older reading, that its
  `@anchors` is typed by merging what two users of a shared module put in it,
  is no longer what happens; what was left was `undefined symbol:
  yaml_parser_parse`.

  **Which C libraries a boundary's object code needs now travels, as `Libs`
  (section 18).** `Requires` says what the consumer has to have *compiled*;
  this says what it has to have *linked against*. The consumer replays `require
  "yaml"` and so has `lib LibYAML` and its `@[Link("yaml")]` — and
  `link_annotations` collects a flag only from a `LibType` that is `used?`,
  which is a question about this build's own code. The call is in the
  artifact's `YAML::PullParser` unit, an object file the consumer reads rather
  than compiles.

  Names and nothing else: everything a link line needs — `pkg_config`,
  `ldflags`, `framework`, static — is already on the consumer's own copy of the
  annotation. What was missing is only that somebody used it.

  **A boundary built from the library is a different question from a shard.**
  `JSON`, `URI`, `HTTP`, `Compress`, `Digest` and `OptionParser` all bind, fill
  and answer what their source answers; `bench/library_boundaries.sh` holds
  three and `bench/yaml_reads.sh` a fourth. `Log` is global state written by
  macros, and it found four things.

  **`tool bind` has to survive its own question.** It asks what a shard's own
  compilation never asks, and for `Log` the answer is that typing the call does
  not terminate — it recurses through `Call#recalculate` building a metaclass
  of a metaclass until the stack ends. A stack overflow is a signal rather than
  an exception, so the `rescue` the tool had could not see one.
  `Program#iyi_instantiation_limit` is nil for every ordinary build and set by
  this tool, and past it the recursion becomes a refusal it knows how to
  report. **And a parameter written `Class` is one there is no value to stand
  for** — every metaclass there is, and there is no end to them.

  **A class variable the library declares is not the artifact's to declare
  again.** A boundary rooted at the library's own namespace writes that type
  whole, the consumer replays the require and has the real one, and the
  variable arrives twice — one initialiser wins and it is not the artifact's.
  `Log.setup` reached a `@@builder` nobody had built. The name still travels in
  `ClassVars`, which is what makes the global exist for the object code.

  **And `MonoBodies` was keyed without the side of the type** (format v35). Two
  `{% for %}` loops in `Log` write `info(*, exception : Exception)` on the
  instance and on the class: same container, same name, same parameters, no
  block, one key. The class method's body took it, and the consumer read
  `Log#info` as `Log#info` calling itself — `recursive block expansion`.

  **`db` and `sqlite3` ask for everything at once**, and they are not through
  yet — eleven more rules came out of them, and one named blocker is left.

  **A record rebuilt field by field loses what was added to it later.** Three
  rewrites constructed a fresh `TypeDecl` by listing its fields, and every list
  was written before `funs` existed — so a reopened `lib` arrived with all its
  types and not one `fun`. `copy_with` names only what changes.

  **A generic module's nested types are not parameterised by being nested**, and
  a generic's `superclass` and `includes` were missing entirely —
  `SessionMethods(Session, Stmt)` includes `QueryMethods(Stmt)`, which is where
  `exec` lives. **A generic module's instantiation is not a `ModuleType`**
  either, so `include SessionMethods(Database, PoolStatement)` was dropped.

  **A `lib` the shard owns outright belongs inside its module**, where its funs
  can name the shard's own types. `Reopened` is for one the library also
  declares.

  **An include is an ordering edge like a superclass, and so is every name in
  it** — the module and each of its type arguments.

  **A block's annotation travelled as written while everything beside it
  travelled resolved**, and resolved it has to stay an arrow: the keep file
  reads the arrow to count block parameters, and the `Proc` form counts the
  output as an input.

  **`uncompilable` is not a question to ask of a private callee**, a bare
  generic is a name rather than a type, and **a body that travels is compiled
  per subclass, so the privates it calls travel per subclass too**.

  **And `NoReturn` is an answer only where the body stays behind.**
  `NullIO#read` raises and nothing overrides it; `DB.build_driver` answers
  `NoReturn` only because this build registered no driver, and its body
  travels.

  **`previous_def` travels** (format v37). A redefinition does not sit beside
  the definition it replaces — `add_def` puts the old one on `previous` — so
  the chain is walked and each link gets its own `MonoBodies` key, numbered in
  the order they were written. The sorts that order a type's methods had to
  become stable for the count to mean anything.

  That numbering exposed a duplicate that had been there for weeks:
  `Kemal::CLI` carried **two** `def initialize(args)`, and nobody could tell,
  because both read the same key and rendered the same body. Numbered, the
  second rendered empty — and an empty `initialize` is the one Crystal's own
  rule keeps. `initialize` is protected, so the private-callee search let it
  past, and that search asked "has this crossed?" by name where it had to ask
  by signature.

  **A method that answers an ancestor's `abstract def` travels whatever its
  visibility** — the body is in one boundary's artifact and the implementation
  in another's, and the requirement is the only thing they share. **A
  parameter's external name is part of the method** (`as type : Class` is
  written `as:` at the call site). **And `forall` is another way of saying the
  caller decides**: one method per binding, so the body travels, and the
  `forall` clause itself was never carried at all.

  Two smaller ones: the private-callee search keyed its pool on parameter
  *names*, so `sqlite3`'s ten `bind_arg` overloads were one; and a synthesised
  `new` must never travel from that search either.

  **A list of what a module defines is only worth having if it is the list of
  what it has.** `Symbols` was collected for every name in `unit_names` while
  the object code was collected only for those with a file behind them, so an
  artifact could claim a symbol it did not carry. `mod dump` now names the
  symbols rather than counting them.

  **A `TypeDecl` carries its annotations** (format v38), and with them every C
  symbol `sqlite3` needs resolves. `Libs` carries *names* on the argument that
  everything a link line needs is already on the consumer's own copy of
  `@[Link]` — true of a `lib` the library declares, false of one only the
  shard has, where the consumer's copy is the only copy and it arrived bare.

  **A keep file stopped at the first method that only raises**, and every call
  after it was discarded: `CleanupTransformer` stops collecting an
  `Expressions` at a statement of type `NoReturn`, which is right for a program
  and ruinous for a file that is one long list of calls. Every keep file this
  tool has written has been truncated that way at some line, and it went unseen
  because a shard usually reaches its own methods somewhere. Each call goes in
  its own `begin`/`rescue` now, and `sqlite3`'s undefined symbols went from
  forty to five.

  **A `lib`'s name is the half that cannot move.** Moving a shard-owned one
  inside the artifact's module fixed name resolution and broke symbol identity
  — the same method mangled two ways, because every symbol whose signature
  names one of the lib's types is built from the lib's name. It goes back to
  the top level, and the funs bend instead: a parameter written
  `SQLite3::Flag` is written as the enum's base type, which costs nothing
  because a C function takes the integer and Crystal converts an enum at a
  `fun` call without being asked.

  **A boundary carries what the shard wrote, and it was carrying Crystal's
  library too** — `Class#name` crossed as a header, which is a promise of a
  symbol per subclass that only the types with units behind them could keep.
  The test is where a method is *not* written: inherited from Crystal it stays
  behind, inherited from another shard it travels.

  **A module's methods are the fourth thing whose body has to travel**,
  alongside a generic's, a block-taker's and an abstract class's, and for the
  same reason: instantiated per *including* type, and the includer may be in
  another boundary. **An empty body is a body** — `protected def do_close; end`
  is a hook, and reading it as nothing to carry sent `super()` past every
  ancestor to `Object`.

  **A shard's top level is more than its constants.** `DB.register_driver
  "sqlite3", SQLite3::Driver` is one statement and the thing that shard exists
  to do; only constants were crossing.

  **A field's default travels, and it travels in the field's place** (format
  v39). Only the type was crossing, so a consumer allocated `@total = [] of T`
  null. The first attempt put the defaults where the class variables go, and
  that was wrong for a reason worth keeping: a field's position in the list is
  its position in the layout, and the module's object code was compiled against
  it.

  **And a default is the third thing to need the value as it was written** — a
  regex literal is replaced by the constant the compiler cached it in.
  Constants and class variables already did this; instance variables now do
  too. A fourth thing cannot travel at all: a body that reads `$~`, which is
  scoped to the method that matched.

  `sqlite3` compiles, links, runs, opens the database and builds its pool. What
  it does not do yet is answer: `SQLite3::Statement#perform_exec` reads from a
  null receiver — a statement that was never built.

  **A declaration cannot name a virtual type, and everything downstream was
  reading that as the exact one.** The symbol is made of the type the method
  actually answers, so a consumer calling `db.checkout` directly asked for
  `*DB::Database#checkout:DB::Connection` and nobody had emitted one. And a
  header's return type was read literally — an ordinary `def f : Connection`
  over an abstract class types its call `Connection+`, but a header has no body
  to widen it. Every generic below was instantiated with the wrong argument,
  and a `SQLite3::Connection` in an `Array(DB::Connection)` read back as its
  own base: `is_a?(SQLite3::Connection)` answered **false**. A program that
  linked and computed the wrong answer.

  **A shard's own `alias` does not travel, and a body names one** — an alias is
  a name for a type rather than a type, so the walk dropped it at the door.

  **And a body's text takes the same rewrite its signature does.** A body names
  things the way the module wrote them, absolute, and the declarations are read
  inside a module whose root has been stripped — so R-2 answered for
  `SQLite3::TIME_ZONE`. One exception: a top-level `def` is rendered outside
  the module, so its body keeps the absolute name.

  Both now have a gate in `bench/bind_roundtrip.sh`, and each took two tries: a
  *written* return restriction on an abstract class is widened by Crystal
  anyway, so the check needs an **inferred** one; and a module function's body
  already took the rewrite, so the check needs a *type's*. A gate that passes
  before the fix proves nothing, and both of these did until they were run
  against the broken compiler.

  **And a name resolves in its own scope first.** `openssl_ext` writes a
  constant `GETS_BIO` inside `class OpenSSL::GETS_BIO`, so the return type R-2
  asks for on its `new` read as the constant. `self` is the spelling with no
  such problem, and on a metaclass it is exactly what `new` answers.

- **What a shard adds to a `lib` travels, and that was smaller than it
  looked.** `openssl_ext` reopens `lib LibCrypto` with a dozen C structs, two
  unions and a handful of `type` aliases, and a consumer stopped on
  ``"open_s_s_l" numbers `Pointer(LibCrypto::Bignum)`, and this build cannot
  name it`` — Part V item 12's own open question, reached.

  **Types only, and the reason is the whole finding.** A `fun` is a C symbol:
  `BN_new` is resolved by the system linker against `-lcrypto`, not by anything
  either side compiles, so a consumer that does not call one itself needs no
  declaration for it. What it needs is to be able to *name* the types, because
  naming is what numbering is made of. That turns a `lib` extension into the
  same shape as `Reopened` — `lib ::LibCrypto` with the members the shard
  wrote — rather than a new kind of thing.

  Two smaller rules came with it, each found by the next failure. A `lib`'s
  alias is spelled `type Engine = Void*` where a class's is `alias`, and the
  renderer knew only the second, so it wrote `type Engine` and closed it:
  `expecting token '=', not 'end'`. And **a class root keeps its class
  variables in its class.** They were written at the module level too — right
  for a module root, which is not a `TypeDecl` and has nowhere else to put
  them, and wrong for a class, which is already carrying them. `bindata` is the
  first shard here whose root is a class, and it said `can't use class
  variables at the top level`.

  What stops `jwt` now is one step further on: `ASN1::BER`'s own
  `@@bit_fields` crosses without the initialiser its superclass's macro gives
  it, and a non-nilable class variable must have one.

  Two things came out of measuring it. `bindata` defines **two** top-level
  namespaces, `BinData` and `ASN1`, and the second lives in its own file that
  `jwt` requires separately — so a shard is not always one boundary, and
  `-e` names a root rather than a shard. And binding into a directory that
  already holds a *later* boundary gives the earlier one an import edge to it:
  the order in `bench/bind_chain.sh` is load-bearing, and a stale `mods` from a
  previous run made three measurements here say `ASN1::BER` when the answer was
  `LibCrypto::Bignum`. Both are the kind of thing that reads as a compiler bug
  and is not.

- **`Kemal.run` — with no block, the way kemal's README writes it.** The
  overload that takes none is `def self.run(args = ARGV, trap_signal : Bool =
  true)`, whose whole body is `run(nil, args: args, trap_signal: trap_signal)`:
  it fills in a default and delegates. R-2 refused it for `args`, and R-2's own
  reason does not apply — a consumer typechecks a call *through* a travelling
  body, exactly as the shard's own callers do, and this body is one line naming
  a method that is already crossing.

  Narrow on purpose. "An untyped parameter is no reason to refuse a method
  whose body travels" is the general form, and it is a much larger claim: it
  would send a body for every method a shard left untyped, each one source the
  consumer has to compile and each one able to name something that did not
  cross. A delegating overload is the shape that shows up in a library's own
  API — the one that exists to be convenient — and widening it is a measurement
  nobody has made yet. `bench/kemal_serves.sh` writes `Kemal.run`, so the gate
  says which of the two this is.

- **A real kemal application serves HTTP through four boundaries**, and
  `bench/kemal_serves.sh` is the gate that says so. `GET /` answers `hello
  from a boundary`, `GET /echo/:word` reads a URL parameter, `GET /missing`
  answers 404, and the two arms — one built from source, one from artifacts —
  answer identically. That was the measure this part existed to reach.

  It is a gate rather than a note because every failure on the way here was a
  *quiet* one: a consumer that linked and then read a field nobody had
  allocated, a `class.to_s` that answered the wrong type for seven handlers in
  a row, a `new` that never ran an `initialize`. A gate that stopped at "it
  compiles" was green through all of them, which is why this one asks for
  pages. The 404 is deliberate: it is kemal's own `setup_404`, which
  `Kemal.run` reaches through a private module function whose body travels, so
  it says the unhappy path crossed too.

  What it took was the one question Part V item 12 had left open: **a shard
  that adds to a type it does not own.** Kemal reopens
  `HTTP::Server::Context` — the library's class — and gives it `@params` and
  eighteen methods. A boundary carries none of the library's types on purpose,
  because the consumer replays the requires and has them, and declaring one
  twice is how a build stops on `superclass mismatch`. So the addition had
  nowhere to go: the consumer said `undefined method 'params'` where its own
  code asked, and where the shard's compiled code asked it read a field the
  consumer had never allocated — a segfault several handlers into a request.

  The answer is the rule the tool already used one level up, asked of a type's
  members instead of a namespace's types: **what the shard wrote travels, and
  what the library wrote stays**, decided by where each member is written.
  `Section::Reopened` carries it, rendered `class ::HTTP::Server::Context`, and
  with bodies — these methods are compiled into the *library's* unit, which a
  boundary does not carry.

  Three things had to travel with it, each its own small rule:

  - **A member written by a macro belongs to the file that wrote the macro.**
    `macro finished` declares three of `Context`'s fields, and their location
    is the expansion. Asked naively they looked like nobody's, so they did not
    travel and the consumer inferred them: `@cached_route_lookup was inferred
    to be Nil, but Nil alone provides no information`.
    `Location#expanded_location` is that walk and already existed. It also
    brought **`get` and `post`** across, which a macro loop writes and which
    are the other half of kemal's DSL.
  - **A field travels with its default.** `@store = {} of String => StoreTypes`
    has one, and the library's own `initialize` knows nothing about it: `this
    'initialize' doesn't explicitly initialize instance variable '@store'`.
  - **And that default is written with its names resolved**, like every other
    text here, because it is read where the shard is not: `StoreTypes` is an
    alias kemal declares inside `Context`, and the consumer said `undefined
    constant`.

  One filter came off on the way. A field whose type this boundary could not
  name relative to the shard was dropped, and a dropped field is worse than one
  that arrives needing a name — the second says so, the first leaves the
  consumer to guess `Nil`. What makes another boundary's `Radix::Result`
  writable is the name mapping, not that filter.

- **A `new` read from an artifact, called without a default argument, never
  ran `initialize`.** The quietest failure a boundary has produced. A def from
  a `.iyimod` is a header — no body, the machine code is in the artifact — and
  a call that leaves out a default gets a wrapper that evaluates the default
  and forwards the whole list to the symbol. Two things stopped that wrapper
  from being written.

  `expand_default_arguments` retains the original body whenever an argument has
  both a default and a restriction, which `ParamParser.new(request, url :
  Hash(String, String) = {} of String => String)` does. Retaining a header's
  body copies `Nop` and drops the forwarding call on the floor, so `new`
  returned the default it had just computed, having allocated nothing.

  And the wrapper's body was never typed: the fast path for an artifact def
  keys on `match.def`, which is still the header, and skips the body visit. The
  default assignment therefore reached `CleanupTransformer` untyped, which
  replaces an untyped node with a `raise` — so the program compiled, linked,
  and died on ``can't execute `url = {} of String => String` `` the first time a
  request reached it. A header's body is `Nop` and a wrapper's is not, which is
  what tells the two apart.

  Measured, through four boundaries: kemal binds its port, logs `Kemal is ready
  to lead`, and a request walks the whole handler chain in kemal's own order.
  What stops it now is the gap Part V names rather than anything here: kemal
  reopens `HTTP::Server::Context` — a type the *library* owns, which a boundary
  deliberately does not carry — and adds `@params` to it. The consumer's
  `Context` has no such field and the artifact's compiled code reads one.

- **A class carries what it includes, and kemal's handler chain runs.** A
  `TypeDecl` had `superclass` and nothing for `include`, so a class that mixed
  a module in arrived as something else entirely: kemal's handlers
  `include HTTP::Handler`, `HANDLERS` is an `Array(HTTP::Handler)`, and the
  consumer — asked directly — said `type must be HTTP::Handler, not
  Kemal::InitHandler`. Where it was not asked directly it dispatched to
  whichever subtype it *did* know, and `handler.class.to_s` answered
  `HTTP::CompressHandler` for seven handlers in a row. The first reading of
  that was a type-id numbering fault; it was a missing edge, and the edge is
  `superclass`'s own argument one word further.

  Written back as `include` lines rather than into `supertraits`: a trait list
  is iyi's own `:` syntax and means something R-2b checks, and this is what the
  shard wrote in the language it wrote it in. After the types the class
  declares, because one of them may be the module — `ExceptionPage` includes an
  `ExceptionPage::Helpers` written inside it — and pruned when the module did
  not travel, by the rule that governs every other name here.

- **An abstract `def` is a written signature, and the method answering it may
  lean on that.** It is the one thing a shard's implementation is allowed to
  leave out: `HTTP::Handler` writes `abstract def call(context :
  HTTP::Server::Context)` and kemal's handlers write `def call(context) : Nil`,
  which R-2 refuses for having no type to write down. R-2 already says this for
  iyi's own impls — the trait wrote the types down, and a consumer types the
  call from the trait — and the same sentence is true of a Crystal module's
  abstract method. Matched on name and arity, which is all an abstract def has.

  Measured: the handler list read through the boundary is now kemal's own, in
  order, each with its own name. `Kemal.run` runs, kemal binds its port and
  logs `Kemal is ready to lead`, and a request walks the whole chain —
  `InitHandler`, `RequestLogHandler`, `HeadRequestHandler`, `ExceptionHandler`,
  `FilterHandler`, `WebSocketHandler`, `RouteHandler`. It stops in
  `ParamParser#cleanup_temporary_files`, which returns early for a request with
  no uploads and did not: `@files.each_value &.cleanup` ran on an empty hash
  and `FileUpload#cleanup` read a null receiver. That is the next thing.

- **A shard's top-level `def`s cross, and kemal's DSL is 22 of them.** A
  boundary is rooted at a namespace and `get`, `post`, `error`, `ws` and `sse`
  are written outside every namespace, on `Object`, where a boundary rooted at
  `Kemal` cannot reach them. `Kemal.run`'s own body reaches one: `setup_404`
  calls `error`.

  They travel in a section of their own (`TopLevel`, format v30), because where
  a declaration goes is not a property of the declaration: the file of
  declarations opens with `module <name>` and never closes it, which is what
  puts everything below it inside the module. These belong outside, so the
  reader parses a second text and accepts it where it stands.

  **With their bodies, always.** Every other declaration names a symbol in the
  artifact's object code, and that code is per type — a `def` outside every
  namespace has no type and so no unit, being compiled into the producing
  program's own main module, the one thing a boundary never carries.
  `render_404` crossed as a header and the link ended on `undefined symbol:
  *render_404:String`. One without a body cannot cross at all, which is honest
  rather than a link error.

- **A setter answers what it was handed, and now it can say so.** R-2 has said
  this since it was written — it is why a setter is exempt from writing a
  return type — and the boundary had no way to carry it. `property thing :
  Thing?` writes `def thing=(@thing : Thing?)` whose body is `@thing = thing`,
  so the shard's own callers get `Thing` from `config.thing = Thing.new`. A
  single annotation cannot say that: `: (Thing | Nil)` is right for the
  declaration and wrong for every call. `config.server ||= HTTP::Server.new(…)`
  in `Kemal.run`'s body came out nilable and the consumer stopped on `undefined
  method 'each_address' for Nil`. So the body travels, like every other
  caller-dependent answer.

- **A body that travels needs what it calls, whatever the shard called it.**
  The search for that was written as "the private methods a travelling body
  calls", and visibility was never the question. `Kemal.run` calls `def
  self.display_startup_message(config, server)`, which is public and whose
  parameters have no types — so R-2 has nothing to write down, it could not
  cross, and the consumer said `undefined method`. A method that could not
  cross is in exactly the position of one the shard keeps to itself.

- **A superclass with the same name as the class is written `::`.** Nothing
  inherits from itself, so two identical names are certainly two types.
  `Kemal::ExceptionPage` extends the `exception_page` shard's own root and both
  lose their namespace on the way out — one because an artifact's declarations
  are relative to its root, the other because a class root *is* the top level.

- **`Kemal.run` crosses a boundary, and nine separate things were in the way.**
  Running a kemal app is behind one method, and every one of these hid the next,
  so each was found only by fixing the one before it:

  - **"Yields without a block parameter" is the body being the shape.** A method
    written `&` — or a bare `yield` — has no annotated block type and so no
    single symbol; its machine code is the caller's and its body has to travel.
    Two spellings of that already counted; the third, which is how Crystal's own
    libraries are written far more often, did not.
  - **The question was never asked.** `Kemal.run(args = ARGV, …, &)` writes no
    type on `args`, so the method was refused as one a human has to write and
    its block was never looked at. The verdict is about a *declaration a
    consumer typechecks against*; a method whose body travels is not declared
    that way.
  - **A name was spent by the first overload seen rather than by the one that
    crosses.** `Kemal` writes four `run`s and two `config`s. Dedup is by
    signature now, which is what tells two methods apart — one per name dropped
    `Kemal.config`'s blockless form, and a travelling body calling it stopped
    the consumer on `is expected to be invoked with a block`.
  - **A module function's body never travelled.** It had a collector and no
    `MonoBodies` line, so the declaration arrived without a body and the
    consumer read a `def` nobody had compiled.
  - **R-2 refused the arrival.** Its premise is "nothing here can be recovered
    from the body, because the body is what stays behind" — and a `MonoBodies`
    entry is the body not staying behind. The exemption is the rule, not an
    exception to it. An author's own `pub def twice(x)` is untouched: the flag
    is set only on a def parsed back out of an artifact.

  The keep file learned two refusals of the same shape. It cannot call a
  method whose parameter has no type — the parameter's *name* stood where the
  type would, `uninitialized args` — and it cannot call one whose block nobody
  annotated, because writing a block needs its arity and `&` says nothing about
  it: `Kemal::Router#namespace(path : String, &)` was handed one parameter where
  the method yields none. Neither is a call worth making. Such a method has no
  symbol to keep alive; that is why its body travels.

  Two more, once the body arrived somewhere it could run. A class's travelling
  `initialize` was collected *after* the search for the private methods a
  travelling body calls, so nothing looked inside it: `Kemal::CLI#initialize`
  travels — its `new` is not a symbol anybody can name — and its body calls
  `parse`, which the class keeps to itself. And a module's own private
  functions never travelled at all. `Exports#carried_functions` was written for
  exactly this case, down to the example in its comment, and `crystal tool bind`
  never filled it: `Kemal.run`'s body calls `setup_404` and
  `setup_trap_signal`.

  `Kemal.run` crosses now, with its body and everything that body reaches
  inside `Kemal`. What stops the call one step further is not a gap in any of
  this: `setup_404` calls `error`, and `error` is a **top-level `def`** in
  kemal's `dsl.cr` — as are `get` and `post`, which is the whole DSL. A boundary
  rooted at `Kemal` cannot carry a method defined outside `Kemal`. That is the
  root-shape question, named rather than worked around.

  Kemal's boundary carries 37 units where it carried 20.

- **A method whose body travels may have an unannotated block.** R-2 refuses an
  exported signature without a block annotation because a consumer typechecking
  a call needs the shape — and a method whose machine code is the caller's hands
  the consumer its *body* instead, which is the shape. `Kemal.run` is written
  `def self.run(…, &)`, and the whole of running a kemal app is behind it. The
  bare `&` is written back as it was, and such a method's parameters travel as
  the source wrote them for the same reason: what a consumer compiles it from is
  the body, not the symbol.

- **A route is added to kemal's router through four boundaries.** That call is
  the DSL's own foundation, and it needed a chain of things to cross:
  `add_route` takes a block, so its machine code is the caller's and its body is
  compiled by the consumer — and that body calls `add_to_radix_tree`, which
  kemal keeps private, which calls `Radix::Tree#add`, whose body calls a private
  overload of itself, which calls `Node#add` and a `protected sort!`.

  Three things were still in the way. A body is found again by its **signature**,
  and a declaration's signatures are rewritten on the way out — stripped of the
  root, then mapped to what a consumer calls another boundary's types — so a key
  left behind was a body nobody found: the declaration arrived without one and
  the link ended on `undefined symbol:
  *Radix::Tree(Kemal::Route)@Radix::Tree(T)#add<…>`. A **bare `*`** is a
  parameter with no name, and written as nothing it is `, ,`. And
  **`protected`** is the same case as `private` here: a name a travelling body
  may call and a consumer may not write.

  `initialize` also travels where `new` could not be declared at all —
  `SharedKeyError#initialize(new_key, existing_key)` writes no restrictions, so
  its `new` is not a symbol anybody can name, and a body that travels and raises
  one met a class it could not construct.

  `bench/bind_chain.sh` adds a route now, in both arms.

- **A private method a travelling body calls travels with it.** A plain type's
  methods are machine code in the artifact, so a consumer needs no declaration
  for what they call — except where a *body* travels, and a block-taking
  method's does, because its machine code is the caller's.
  `Kemal::RouteHandler#add_route` calls `add_to_radix_tree`, which the shard
  keeps to itself, and the consumer compiling that body said `undefined
  method`.

  Which ones is a call graph, and the bodies are text: a private method travels
  if its name stands in one of them as a word, and then what *its* body calls
  travels too, to a fixed point. Reaching too far costs a declaration nobody
  uses; reaching too short is the error above, so it errs long. It travels as
  `private def` — reachable from the bodies beside it and from nowhere else,
  which is what it was — and the keep file does not name one: its parameters
  travel as the source wrote them, so there is not always a type to say
  `uninitialized` of.

  A generic's methods all cross now for the same reason: every one of them is
  compiled by the consumer, so what one *returns* is the consumer's to infer.
  Requiring an answer had dropped `Radix::Tree(T)#add`, and a consumer holding a
  `@routes` had nothing to call on it.

- **A generic type can be built from its boundary.** Its `new` is never carried
  — it is synthesised per instantiation and the consumer makes its own — and
  its `initialize` was not carried in `new`'s place, so a consumer could read a
  `Holder(Int32)` somebody handed it and never make one.

  Three things were in the way. A **default** did not travel, so
  `Node(T).new("", placeholder: true)` named a parameter the declaration did not
  have; parameters carry theirs now, written back as
  `tag : String = "none"`. A **type parameter** was recognised only when it was
  the whole restriction, so `T` passed and `(T | Nil)` did not, and
  `Radix::Node(T)#initialize` never crossed at all — the question is asked of
  each name in the type now. And a **private method a travelling body calls**
  had no declaration: `Node(T)#initialize` calls `compute_priority`, which
  `Node` keeps to itself. A generic's private methods travel as `private def`
  with their bodies, which is what they already were — every one of a generic's
  methods is compiled by the consumer.

  A plain type's private methods do not travel, and that is deliberate: its
  bodies do not either, so a declaration would be a name with nothing under it.

- **A name a shard declares itself is not somebody else's.** A boundary rewrites
  references to another boundary's types so the consumer reads them the way it
  will see them — and the map is keyed on the simple name, so `radix` declaring
  a top-level `Node` made every bare `Node` in `Kemal` into `Radix::Node`,
  including `Kemal::LRUCache::Node`. The consumer stopped on `wrong number of
  type vars for Radix::Node(T) (given 2, expected 1)`. The shard's own names
  are taken out of the map now: a bare name in its source means its own.

  It was invisible until `bench/bind_chain.sh` started binding the way a shard's
  author should — `--use-iyimod mods`, so each boundary sees the ones before it
  — which is also what takes kemal's three handle types to zero.

- **A boundary that crosses without its fields says which field did it.**
  A reference type whose fields name something the consumer cannot write
  crosses as a *handle* — a pointer, with no `new` — and the report said only
  how many. It names them now, and the name inside the field type that failed:
  `RouteHandler — Radix::Result, Radix::Tree`. Which ones matters, because a
  body that travels and touches a field of one cannot be compiled by the
  consumer, and that comes out as `can't infer the type of instance variable`
  in a file nobody wrote.

  It also showed that `--use-iyimod` is not optional when binding a chain:
  without it a boundary cannot see the ones bound before it, so `Radix::Tree` is
  a name `Kemal` cannot write. With it, kemal's three handle types become zero.

- **A block-taking `initialize` crosses, because its `new` cannot.** Crystal
  reaches `initialize` through `new` and marks it not-public, which is fine
  while `new` travels — and it does not when it takes a block, since a
  synthesised `new`'s body is the compiler's, with a temporary for a receiver.
  So the one a consumer needs in order to make its *own* `new` crosses instead,
  and only in that case: declaring `initialize` beside a `new` that also travels
  would be two ways to build the same type. The keep file does not call it —
  `protected method 'initialize' called` is Crystal saying `new` is how you
  build one — and it does not need to: a block-taking method's machine code is
  the caller's.

- **A body that travels is the body as it was written.** `Def#body` stops being
  source as soon as anything instantiates it: `Route.new(method, path,
  &handler)` becomes `_.initialize(method, path, &handler)`, and an underscore
  is not a receiver anybody can write — the consumer said `can't read from _`
  about a body it was handed. It is recorded in the top-level pass now, which
  runs before any of that, and keyed on the name as well as the place: a
  synthesised `new` carries the *location* of the `initialize` it was made from,
  so a key of one alone handed `new` the other's body.

  A block-taking `new` does not travel at all now, for the same reason from the
  other side: its body is the compiler's, with a temporary for a receiver, and
  the consumer makes its own from the `initialize` beside it — which is what
  `new` has always done here.

- **A block that returns `_` crosses.** `&handler : Context -> _` names one type
  and one *absence* of one, and the scan that asks whether a signature's names
  can be written read `_` as a name — so every method whose block returns
  whatever the block returns was dropped, `Kemal::RouteHandler#add_route` among
  them, and kemal's whole DSL is written on top of that one. There is no single
  return type to infer for such a method either, and none is needed: a
  block-taking method's *body* travels and the consumer compiles it, so the
  declaration carries no return type and the consumer reads its own.

- **A shard that reopens a library namespace carries only what it added.**
  `openssl_ext` is `OpenSSL`, and a `--crystal` consumer replays the requires
  and gets Crystal's — so the artifact's declarations met the library's and the
  build stopped on `superclass mismatch for class OpenSSL::SSL::Error`, then on
  `already initialized constant OpenSSL::BIO::CRYSTAL_BIO`. What separates the
  two is where a type or a constant is *defined*: under the shard, or under the
  library. One the library wrote is not declared and not assigned; one they
  both touch counts as the shard's, because what the shard added has to travel
  somehow.

- **A nested declaration's names are stripped to where they are read from.**
  `OpenSSL::PKey::PKeyError` stripped of the root is `PKey::PKeyError` — and
  that declaration is rendered *inside* `module PKey`, where it means
  `PKey::PKey::PKeyError` and resolves to nothing. The stripping goes one level
  deeper with each nesting now, so from in there the name is `PKeyError`. It was
  invisible until a superclass gave a nested type a name to resolve.

- **A method the compiler refuses to instantiate does not travel, and the
  boundary survives it.** `crystal tool bind` already instantiated every method
  it declares — that is how a written return type is held against the answer —
  and a method whose body did not typecheck was recorded as "could not be
  checked" and **declared anyway**. The keep file then named it, and one method
  that does not compile took the whole fill build with it: every declaration on
  disk and no machine code anywhere.

  What separates the two cases is who refused. This tool declining to ask — an
  unannotated block, a splat, a free variable — is not a defect in the method,
  and those still travel. The *compiler* refusing is, and those are dropped.
  `openssl_ext` has a `LibCrypto` call whose argument is a pointer too deep, in
  a method its own compilation never types: it went from **losing its whole
  artifact** to binding at 35 units and 31 MB, and the chain under `jwt` —
  `bindata`, `openssl_ext`, `jwt` — now binds end to end.

- **A boundary says whether its object-code step finished.** `crystal tool bind`
  writes the declarations and a second build fills them, compiling a keep file
  that names every method a consumer might call. A shard can hold code its own
  compilation never types — `openssl_ext` has a `LibCrypto` call whose argument
  is a pointer too deep — and asking for all of it is what finds that. The build
  dies and leaves an artifact with every declaration and no machine code.

  Read as it stands, that boundary promises a hundred methods and defines none,
  and the linker says so a hundred times without naming the cause once. It is
  also indistinguishable from one that legitimately has no object code: an
  abstract class with no subclass in its own shard is complete with zero units.
  So the fill step records that it finished, and a consumer of an unfinished
  boundary is refused by name.

- **A constant's accessor names the constant it reads.** The accessor a boundary
  writes for `Kemal::Config::INSTANCE` is `config_instance`, flattened with `_`
  — and the path it reads was reconstructed from that name by reading every `_`
  as `::`. It works until a type's own name has an underscore in it:
  `class OpenSSL::GETS_BIO` came back as `OpenSSL::GETS::BIO`, and the keep file
  named a constant no program has. The path travels beside the accessor now
  rather than being derived from it.

  Flattening still loses information — `A_B::C` and `A::B_C` both read `a_b_c` —
  so a second constant claiming a taken accessor name is dropped and printed
  beside the artifact, where two defs of one name would have been a broken
  boundary.

- **An abstract class crosses a boundary, and its concrete methods travel as
  bodies.** They are the third thing that has to, beside a generic's methods
  and a block-taker's, and for the same reason each time: they are instantiated
  per *subclass*, and every subclass is somebody else's. A shard that declares
  an abstract class and never subclasses it carries **no machine code for it at
  all** — which is why `exception_page` fills with 0 units, and why that is not
  a bug — so a consumer writing `class Report < Sheet` asked for
  `*Sheet+@Sheet#render` and nobody had made one.

  Two smaller things sat in front of it. The keep file *called* the abstract
  methods, and `t0.title` on a class with no subclass has no type: codegen said
  so as `BUG: … has no type` rather than as an error anybody could act on.
  And neither the method's nor the type's abstractness travelled, so a consumer
  read `def title` where the shard wrote `abstract def title`.

- **`pub abstract class`.** Being abstract and being reachable are different
  questions — one says the type cannot be instantiated, the other says who may
  name it — and `pub` took a class, a struct, a trait, a def, a macro and an
  enum, but not an `abstract` anything. A bound abstract class is a type a
  consumer subclasses and therefore has to be able to write; without this the
  declaration came back as a plain `pub class` and the requirement inside it
  was refused with `can't define abstract def on non-abstract class`.

- **A chain of four bound shards builds and runs.** `bench/bind_chain.sh`
  installs kemal and the three shards under it, binds all four in dependency
  order, and builds a program against the boundaries that prints what the same
  program prints built against their source. Nothing smaller finds what it
  finds: one boundary cannot collide with another's synthesised names, cannot
  have an import edge to get wrong, and cannot be a *class* root standing
  beside module roots.

- **A class root is its own namespace, and needs no module header.** An
  artifact's declarations are wrapped in `module <path>`; for a class root that
  header camelcases to the class's own name, so the class arrived declared
  inside a module of the same name and every type under it gained a level —
  `Widget::Part` was `Widget::Widget::Part`, and a consumer told to number
  `Widget::Part` could not name it. iyi wraps a file in its module only when a
  header is there, so leaving it out puts the declarations where they belong,
  and a `ClassType` is a `ModuleType`, so everything that looks a module unit
  up by name still finds it.

  Two things held the same wrong premise elsewhere. The marker that says "this
  type came from an artifact" walked *into* the scope looking for the root's own
  name, so a class root and everything under it went unmarked. And
  `bound_names` prefixed another boundary's types with its module path, which
  rewrote `Carrier` to `Carrier::Carrier`; with the prefix empty the rewrite is
  a no-op, so the import edge is recorded where the name is **met** rather than
  where the text changed.

- **An artifact says which symbols its units define.** Four undefined symbols
  were four wrong answers to one question. An artifact defines **more than it
  declares** — its own units call methods Crystal owns, so `RouteHandler`'s
  unit calls `FilterHandler#next=` and `next=` is `HTTP::Handler`'s — and
  **less than its types suggest**, because `Reference::new` is instantiated per
  receiver and exists only where something reached it. Assuming the first left
  `Kemal::FilterHandler@Reference::new` undefined; assuming the second made it a
  duplicate symbol; compiling a private copy in the consumer put the definition
  where `_main` could not see it. A `Symbols` section carries the mangled names
  each unit defines and the consumer compiles everything else: a list is not a
  rule and does not have a wrong side.

- **A `~match` function is defined under the name that travelled.**
  `(Socket::IPAddress | Socket::UNIXAddress)` is a union in the producer and
  collapses to `Socket::Address+` in a consumer that knows those are all of
  `Socket::Address`'s subclasses — the same types, the same answer, a different
  symbol. The function is built from the type resolved here and named for the
  one the object code calls.

- **The type-id list is the import graph, so it cannot be filtered.** Two
  separate failures at kemal's scale came from one list being less than whole.

  A module's type id is its *metaclass's*: `Backtracer::Backtrace::Parser:Module`
  is how a module's metaclass prints. Carrying the instance and stopping there
  defined `…::Parser:type_id` for object code that wanted
  `…::Parser:Module:type_id`, because the walk that numbers metaclasses reaches
  only classes. The consumer numbers the metaclass too now.

  And the list had been filtered to the kinds a consumer could not number for
  itself, leaving plain classes out on the reasoning that the consumer has them
  already. It has them only if it *imports the module that declares them* — and
  that import edge is derived from this very list. `Kemal` numbers
  `ExceptionPage::Styles`, the name was filtered, no edge was added, and the
  consumer never read `exception_page` at all. Whole, the list costs `Kemal`
  642 names where it carried 303, and a name is a string.

  The metaclass half takes the kemal consumer from eight undefined symbols to
  six. The import-edge half is not counted the same way: with the edge added,
  `ExceptionPage::Styles` stops being a mangled symbol at link time and becomes
  a refusal that names it, which arrives *before* the linker — so the five
  behind it are no longer measured. Both the refusal and
  `exception_page` filling with 0 units are the same item: a class-rooted
  namespace colliding with its own module wrapper, in Part V item 12.

- **What a generic declares is kept, even though the generic is not.** The keep
  file skips a generic type — rightly, since `uninitialized Holder(T)` is not a
  thing anybody can write — and skipped everything it declares along with it.
  Those have object-code units in the artifact all the same: `Radix::Tree(T)`
  holds two error classes carrying 1.3 MB each, radix's keep file was **empty**,
  and the only `to_s` symbols it emitted were the ones radix's own code
  happened to reach — `to_s<IO::Memory>`, `to_s<IO::FileDescriptor>` — while
  the boundary declared `io : IO` and a consumer asked for the declared
  `to_s<IO+>`.

  A nested type is not parameterised by its container unless it says so, so
  recursing past the generic is all it took. The kemal consumer goes from ten
  undefined symbols to eight, and `bench/bind_roundtrip.sh` carries a
  non-generic class inside a generic one and prints the symbol its declaration
  produced.

- **A variable can be read wider than the slot that holds it, and that is a
  widening.** Inside a dispatch arm the slot holds the arm's concrete type
  while the read wants the type the boundary declared — an `IO` parameter read
  as `IO+` — and `visit(Var)` called `downcast` on it:
  `BUG: trying to downcast IO+ <- IO::Memory`. It is the same correction the
  call arguments already carried, one level in.

  **Which direction it is cannot be asked of `implements?`.** Answering it that
  way broke the compiler's own build: a virtual type implements its base, so
  `Iyi::Def+` held in a slot and read as `Iyi::Def` looked like a widening and
  is the opposite. What separates them is shape — a union or a virtual type is
  the wider thing — so a widening is reading a *concrete* slot as one of those,
  and nothing else is.

  With it the kemal consumer reaches the linker rather than aborting in
  codegen. An earlier entry said that consumer had zero undefined symbols; that
  was not a measurement — the build was dying before the linker ran. It links
  now and waits on ten.

- **Inheritance crosses a boundary.** `TypeDecl` had no field for the `<`, so a
  bound `Derived < Base` arrived without its base and without the fields it
  inherits — a class's own field list is only its own — and the consumer said
  `undefined method 'tag' for Shard::Derived`. The edge travels now, and the
  declarations are written superclass-first so `class Derived < Base` resolves.

  The edge alone left three more, each a place that had only ever seen a class
  with nothing under it. **A method is keyed on the type that defines it**: a
  boundary has one symbol per method where an ordinary build makes one per
  receiver, which is the mirror of the rule the parameter side already carries.
  That symbol is keyed on the class's **virtual form**, because a value of a
  class something inherits from is held as one — the symbol is
  `*Shard::Base+@Shard::Base#tag`. And a class with subclasses has a **second
  unit**, `Shard::Base+`, holding the methods reached through that form; the
  artifact was carrying neither it nor its callees.

  **The undefined symbol was the safe half of the bug.** A match against a
  virtual type compares an id against the *range* its subclasses occupy, and
  ids are assigned by walking that same tree — so a consumer missing an edge
  numbers the tree differently. Defining the function anyway would answer
  `is_a?` wrongly and link cleanly.

  Two more followed from more of a real shard crossing: a type read from a
  `.iyimod` is exempt from the "not initialized in all of the 'initialize'
  methods" check on the branch where the field's type does not include `Nil`,
  as it already was on the other; and a restriction can be virtual while the
  value is concrete — an `IO` parameter matched against `IO+` — which is
  answered with the range rather than a single type id.

  A consumer of kemal's four bound shards goes from **11 undefined symbols to
  10**, and the three the superclass edge was built for — `~match` against
  `HTTP::StaticFileHandler+` and two like it — are among the ones gone.
  `bench/bind_roundtrip.sh` carries a base, a subclass, an inherited method and
  an overridden one.

- **The unions a bound module matches against travel.** `is_a?` against a union
  or a virtual type compiles to `~match<T>`, a function that compares a type id
  against a *range* of the program's own numbering — so it lives in the main
  module, which does not travel, and it cannot be carried as code either: a
  copy compiled by the producer would compare the consumer's ids against the
  producer's numbers and answer wrongly with no symptom.

  A virtual one the consumer could already find for itself, by taking the
  virtual form of every class it numbers. A union it could not: no walk over a
  program arrives at `(Char | Iyi::Keyword | String | Nil)`, which is a type
  kemal's code formed and a consumer of kemal's never would. A `MatchTypes`
  section carries the names and the consumer builds each function with its own
  numbering, the same arrangement `TypeIds` already has. A consumer of kemal's
  four boundaries goes from **22 undefined symbols to 11**.

  `bench/bind_roundtrip.sh` matches against a union its consumer never forms,
  and prints the carried name so the line cannot quietly stop testing anything.

- **A module crosses a boundary, and what was inside it comes with it.**
  `crystal tool bind` recorded a module as a "nested namespace skipped" and
  carried nothing for it. Two failures at kemal's scale were the same failure:
  `Backtracer::Backtrace::Parser` is a module the object code *numbers* and a
  consumer could not name, and `Kemal::Exceptions::CustomException` and three
  like it had object-code units in the artifact — 1.8 MB each — with no
  declaration anywhere, because the walk stopped at `Exceptions` and everything
  under it went with it.

  A module travels as a declaration now, with its nested types, its methods and
  its class variables. Without `pub`: iyi's `pub` takes a def, a class, a
  struct, a trait and an enum, and what a namespace owes is that the things
  *inside* it can be named, each carrying its own visibility. A consumer of
  kemal's four boundaries goes from **40 undefined symbols to 22**, and
  `bench/bind_roundtrip.sh` keeps a nested module with a class and a
  module-level `def self.` in it.

- **A module's own class variables travel, and so do the type ids of modules.**
  Running kemal's four shards through boundaries in dependency order —
  `backtracer` → `radix` → `exception_page` → `kemal` — found both. A
  `TypeDecl` holds a type's class variables and a module is not a `TypeDecl`,
  so `module Backtracer; class_getter(configuration)` left
  `Backtracer::configuration` undefined at the end of a build that had every
  one of that shard's types and their class variables. `Exports` holds the
  module's own now.

  And type ids are handed out by walking `Object`'s subclasses, which reaches a
  class and neither an enum nor a module — `Backtracer::Backtrace::Parser` was
  numbered nowhere in a consumer that never mentions it. `TypeIds` carries
  those too, which turns the link error into the refusal that names the module
  and the type it cannot reach.

  `bench/bind_roundtrip.sh` keeps a class variable on the module root as well
  as on the class under it.

- **A bound shard can match a regex, which took two more holes than the
  constant did.** With the pattern crossing and the class variables crossing, a
  `--crystal` consumer of a shard that *matched* still ended on
  `undefined symbol: *Regex::PCRE2::current_jit_stack` and
  `Regex::MatchOptions:type_id`. Both read as the copy rule failing to bring a
  library method along, and both were something else — `nm` on the unit shows
  the accessor was copied.

  `@@current_jit_stack` is `@[ThreadLocal]`, and a thread-local global is read
  through a `noinline` function that hands back its address rather than
  directly, because LLVM would hoist the address out of the thread. That
  function is the main module's, and a main module does not travel. It is the
  third thing a class variable owes, after the global and the read function.

  `Regex::MatchOptions` is an enum, and "a program defines every type id" means
  every id it has *handed out*. Ids come from walking `Object`'s subclasses,
  which reaches a class and not an enum — an enum takes its id from the first
  code that asks, and a consumer that never mentions it never asks. `TypeIds`
  carries the enums a unit numbers, beside the generic instances it already
  carried, and the two are missing for opposite reasons: an instantiation does
  not exist until it is named, an enum exists and is unnumbered.

  `bench/bind_regex_identity.sh` matches with its patterns now instead of only
  naming them, so each shard's literal is checked against text the other one's
  would reject.

- **A class variable crosses a boundary, which nothing had ever carried.** A
  class variable is a global. The methods that read one travel as a module's
  machine code and refer to it by symbol, and the global itself is defined in
  the main module — the one part of a build that never travels. Nothing in the
  format mentioned class variables at all, so R-1's own claim was false for any
  module that had one, in iyi's own language: build a module with a
  `@@seen : Int32 = 0`, delete its source, build again from the artifact, and
  the link ends on `undefined symbol: App::Counter::Tally::seen`.
  `bench/samples_roundtrip.sh` is the gate for exactly that claim and passed,
  because none of the six samples has a class variable.

  `TypeDecl` carries the declaration now — name, resolved type, and the
  initialiser as written — the way `fields` already do, one level up. That is
  what a module's own needs, and a bound shard's too.

  It is not enough alone, and `@@cache : String? = nil` is the case that says
  so: a nil initialiser assigns nothing, so it is dropped before the artifact
  is written, and the consumer that read the declaration made no initialiser
  from it and emitted no global. So a `ClassVars` section carries the names a
  unit's object code refers to and the consumer defines each. That second
  channel is also all a class variable of *Crystal's* library needs — the
  consumer has the declaration already, having compiled the same library, and
  a bound shard calling `String#upcase` was left without
  `Unicode::upcase_ranges`.

  **The global is not the whole debt, and the consumer cannot work out the
  rest.** A class variable with a live initialiser is read through
  `~Owner::name:read`, a main-module function that initialises on first use;
  one without is read straight off the global. Which a unit emitted is the
  producer's fact, so the section carries a flag beside each name. Both guesses
  were tried and each breaks a different world: assume the direct form and a
  `--crystal` build leaves `~Exception::CallStack::skip:read` undefined, which
  `bench/bind_roundtrip.sh` caught; assume the lazy form and an iyi-prelude
  program dies on `BUG: __crystal_once is not defined`, because that prelude
  has no `__crystal_once` and nothing under it ever takes the branch.

  **The value is caught before the compiler rewrites it.** The initialiser
  travels as source, and the node a class variable holds is not that source by
  the time an artifact is written — `CleanupTransformer` has replaced it with
  the literal's expansion. `@@nums = [1, 2, 3]` reached the format as five
  statements over three temporaries, and the consumer said `read before
  assignment to local variable '__temp_2'`.

- **A regex literal's constant is named after the literal, and what it was made
  from crosses a boundary.** The compiler turns a regex literal into a
  program-level constant, and the name it invented was the order the literal
  was met in: `$Regex:0`. That name reaches the linker — a unit reading the
  constant refers to `~$Regex:0:const_read` — and encounter order is not an
  identity two programs share. A consumer of a bound shard failed on
  `undefined constant ::$Regex:0`, and the obvious fix, skipping such names,
  was worse than the bug: the producer's object code still referred to the
  mangled name, and whichever constant the consumer had numbered zero would
  have satisfied it. A different pattern, silently.

  The name is `$Regex:` and a digest of the pattern and the flags now, so it
  means the same thing in a program that never compiled this source, and two
  modules that wrote the same literal share one constant rather than defining
  two. `$` still keeps it out of reach of anything anybody can write.

  A digest cannot be read backwards, so the pattern travels too, in a
  `Regexes` section beside the names in `Constants` — it cannot go through the
  source channel, because `$` is not legal in a constant and `Exports` is
  parsed text. The consumer builds the constant with the same `Regex.new` call
  the expander builds for a literal met in source, and from there it is
  ordinary: typed when read, initialised where read.

  **The name is the load-bearing half, and the channel alone looks like it
  works.** With the channel in and encounter-order naming restored, two bound
  shards holding one literal each both wrote `$Regex:0`, and the second shard
  matched against the first one's pattern with nothing raised and exit 0.
  `bench/bind_regex_identity.sh` is the gate: it takes two boundaries, because
  one can be wrong about the name and still right about the pattern.

- **A real shard is installed, built against and asked for two pages every
  build.** `bench/shard_serves.sh` takes the README's headline example
  literally: `require "kemal"` in an `.iyi` file, built `--crystal`, serving.
  Nothing here checked it. The samples cannot — none of them requires a shard,
  which is the point of the example — and CI's tarball job builds a *synthetic*
  shard against `crystal/syntax_highlighter`, which proves the library ships
  whole and cannot prove that a real shard's macros parse, that its route
  blocks compile, or that the thing answers.

  It reaches the network, which no other gate here does, and the shard is
  pinned at 1.12.0 so it fetches one version rather than today's. Two routes,
  because a single static string would pass with the router never running; the
  second reads a URL parameter, so the answer is right only if the request
  reached the block the shard's macros defined.

- **A bound shard is built from its boundary, linked and run every build.**
  `bench/bind_roundtrip.sh` is `samples_roundtrip.sh`'s question asked of the
  other kind of artifact: object code that is a shard's, declarations that
  `crystal tool bind` wrote, and a `--crystal` consumer. It binds, fills the
  units, builds the same program both ways, runs both and compares.

  III.6 rule 1 names two failures for a boundary whose signatures are wrong —
  an undefined symbol, or a call returning something of another type — and
  `spec/compiler/bind_spec.cr` reaches neither, because it reads declarations
  back and never links. That was written down as a deliberate limit. Nothing
  covered it, and the first thing this gate did was fail:

  ```
  ld.lld: error: undefined symbol: *Shard::Part#wider:(String | Nil)
  ```

  **And it found the same question on the other side of the arrow.**
  `def discards(io : IO)` is monomorphised on what it is passed, so the keep
  file emitted `discards<IO>` and a consumer handing it `STDOUT` asked for
  `discards<IO::FileDescriptor>`. Both answers that suggest themselves are bad:
  instantiating for every concrete subtype is the whole-program work an
  artifact exists to avoid, and refusing such methods costs real surface —
  `JSON` has 10 of 180 declarations taking an `IO`, `YAML` 10 of 193, `URI` 7
  of 55, counting only `IO`.

- **A call to a declaration read from a `.iyimod` is keyed on the parameter as
  declared, not on what the call site passes.** One line of a consumer said
  which answer the gap above wanted: `part.discards(STDOUT)` failed to link and
  `part.discards(STDOUT.as(IO))` linked and ran. The symbol was callable the
  whole time; the call was reading past the declaration.

  Keying on the argument is right everywhere the body is present to be compiled
  once per argument type. A declaration from an artifact has no body and
  exactly one symbol, so the parameter as written is what the call is keyed on
  and the argument is widened to it — the conversion `.as(IO)` was performing by
  hand. Getting the direction backwards says so plainly:
  `BUG: trying to downcast IO+ <- IO::FileDescriptor`, which is `downcast`
  being handed a widening. Nothing is refused and nothing is instantiated per
  subtype.

- **`pub enum`, and an enum crosses a boundary.** iyi took an `enum` already —
  the language has one and the compiler makes the type — but `pub` did not, so a
  module could declare one and never hand it out. It does now, and
  `crystal tool bind` writes the enum's members with the integer they are
  numbered on, read from what the compiler assigned rather than renumbered: the
  object file a consumer links is what gave them their numbers. An earlier note
  said iyi had no `enum` at all, which came from grepping the prelude and was
  wrong about the language.

- **A private type travels as private.** `JSON::PullParser` holds an
  `Array(ObjectStackKind)` and its object code numbers
  `Pointer(ObjectStackKind)`, so a consumer has to *number* a type it must never
  be able to *write*. Declaring it without `pub` is exactly that, and R-2b keeps
  the name unreachable. Dropping such types was the first answer and only the
  linker said otherwise.

- **A rebuild of a type declaration carries all of it.** Pruning and renaming
  both reconstructed a `TypeDecl` and left `value` and `macros` behind, which is
  how an alias lost its right-hand side and, once enums arrived, how one lost
  its members.

- **`crystal tool bind` asks what the consumer of a bound shard can name, which
  is not what it had been asking.** `nameable?` decides every count this tool
  prints, and it asked what an *iyi-prelude* program could name — a program that
  cannot consume one of these artifacts at all, because the units number
  `Pointer(LibUnwind::Exception)` whatever the shard does. The consumer is a
  `--crystal` program, which has Crystal's library, and now the shard's requires
  besides. Read from where each type was written rather than from a list.

  The surface had been reading low throughout. Without binding anything first:
  `JSON` 168 → **181** signatures and 13 → **0** waiting, `YAML` 166 → **194**
  and 32 → **0**, `URI` 48 → **55** and 9 → **0**. `Kemal` goes from 27 types
  carrying 65 methods to **34 carrying 148**, and `Kemal::Route`,
  `RouteDefinition`, `FileUpload` and three more stop being refused for naming
  types their actual consumer would have.

  Two things had to follow. A top-level name of Crystal's is written `::Log`,
  because an artifact's declarations are rendered inside their own module and
  `Kemal::Log` is a constant that would shadow it. And a generic carries the
  types nested inside it, which is how `Kemal::LRUCache::Node(K, V)` went
  missing while `LRUCache` travelled.

- **A bound shard's requires travel, and so does a dependency that only its
  type ids show.** A unit numbers the types its own `require`s brought in —
  `Radix` reaches `Hash(String, HTTP::Cookie)` — and a consumer whose prelude is
  Crystal's still does not have every file of it, so `require "http/cookie"`
  goes in the artifact. Crystal's only: a require that resolved into somebody
  else's `lib` is another shard, and replaying it would have the consumer
  compile from source the thing an artifact exists to spare it.

  The other half is an import edge nobody could see. `Kemal` names no `Radix`
  type in any declaration and its object code refers to
  `Array(Radix::Node(...))`, so a consumer that imported `kemal` had never heard
  of `radix`. The build that fills the object code reads the boundaries beside
  it and adds the edge, because only that build knows the type ids — `tool bind`
  and this are different processes.

- **A generic type crosses a boundary.** Its methods exist once per
  instantiation and the instantiations belong to whoever writes them — a
  consumer that writes `Holder(Float64)` needs a method the producer never made
  — so what travels is the declaration with its type parameters and the
  *source* of its methods, in `MonoBodies`, which is the answer IV.2 already
  names and `crystal tool bind` was not using. `new` stays out: it is
  synthesized from `initialize`, so a consumer makes its own and a carried one
  would meet it at the linker.

  A generic travels even with no methods to carry, because a consumer may need
  only to *name* it: `Kemal` refers to `Array(Radix::Node(...))` and calls no
  `Node` method. `Radix` carries three types where it carried none.

  What a generic's methods must have is a written return type. The trick that
  rescues an ordinary method — instantiate it on purpose and read what comes
  back — has no single answer when the owner is generic, so 20 of `Radix`'s 33
  methods stay behind.

- **A harness for what a consumer pays for a shard** (`bench/bind_speed.py`),
  from its source and from its boundary, at three sizes. A boundary pays once
  compiling the shard is a real share of the build — near ten thousand lines
  here — and costs a little below that: 2,167 lines costs 2%, 10,087 saves 9%,
  29,767 saves 11%.

  It could not be asked of `Kemal`, which cannot be bound: its object code
  numbers `Array(Radix::Node(...))`, a generic instance from another shard, and
  a generic travels as bodies rather than declarations. What `tool bind` says
  about `Kemal` stands on its own — 254 public methods, 93.3% needing no human,
  31 units of object code.

- **A private constant is not handed out.** The keep file read
  `Kemal::FilterHandler::WILDCARD_PATHS` through a generated accessor, which is
  what the shard's own compiler refuses. It still travels in the artifact's
  initialiser, because *defining* one is not *reading* it and the object code
  refers to it either way.

- **A build that fills a boundary does not link.** The keep file is not a
  program anybody runs — it exists so codegen emits the methods a consumer will
  call — and what the boundary needs is the objects, not the executable they
  would have gone into. Forcing the whole of `IO`'s surface produces a program
  that will not link, on `Crystal::EventLoop::Polling` internals a demand-driven
  build never reaches, and the units are written after the link. `IO`'s artifact
  fills now — 18 units, 14.8 MB — where it had been empty.

- **Measured what the library would be worth as an artifact** (SPEC.md Part V
  item 12e). A generated module the shape of a library — 103,002 lines, 5,000
  exported methods, declarations at the 5% of the source that Crystal's own
  library has them at — reads back from its `.iyimod` in 0.11 s against 0.43 s
  from source, in 25 MB against 163 MB. The daemon, on the same term, is 0.47 s
  to 0.33 s and costs 200 MB rather than saving it.

  `crystal tool bind` already writes a `.iyimod` for a Crystal namespace:
  `JSON` crosses 90.3% of its public surface unaided, `YAML` 78.0%, `URI`
  58.1%. What the rest waits on is the core types — `String`, `Array`, `IO` —
  which are not a namespace and so have no root to point the tool at.

- **The ecosystem and R-1, together: `--crystal` and `.iyimod` now work in one
  build.** A module that requires `json` compiles once into an artifact, and a
  program that requires Kemal links against it without opening its source. The
  two features were each half of the thing anybody actually wants.

  Three things had to be answered, and they were the same question three times
  — *a name in the module's object code that only the consuming program can
  define*, which is the rule `TypeIds` was already in the format for.

  - The main module's helpers, `~match<IO+>` first. The consumer emits them
    with its own numbering rather than the artifact carrying them, because a
    match against a virtual type compares against a range of type ids and those
    numbers belong to the program. A carried copy would have compared the
    consumer's ids against the producer's range and answered wrongly with
    nothing to see.
  - The module's requires. A module that required `uri` and a consumer that did
    not left `URI::Error.class:type_id` undefined at link time. They travel now
    — the new `Requires` section, format v20 — and the consumer replays them.
  - The `!dbg` location, fixed below.

  There is one copy of the library in the result, which was measured rather
  than assumed: `STDOUT` and `PROGRAM_NAME` are the same object on both sides
  of the boundary, and the specs assert it.

  What it saves is small and is written down as such: on a twelve-module app
  the modules cost 0.16 s from source and nothing from artifacts, against
  3.1 s for Crystal's library, which every build still reads from source.

- **`iyi daemon`.** A single-threaded `iyi-daemon` is built and shipped beside
  `iyi`; `iyi daemon start` holds Crystal's library analysed between builds. It
  takes about 0.3 s off the front end of a `--crystal` build — 0.81 s to 0.47 s
  on a twelve-module app — and costs about 200 MB resident per prelude it holds.

  Name your shard in a `--prelude` file of your own and it is held too, which is
  the largest effect by some way: 1.28 s to 0.60 s on the same app with Kemal.
  What the daemon is good at is holding the program's *dependencies*, not the
  library underneath them.

  Not offered before because iyi's own prelude takes 0.03 s to analyse and
  there was nothing to hold. `--crystal` gave it something.

- **A `.iyimod` records which library it was built against**, and importing
  across the two is refused by name in both directions. This replaces the old
  refusal, which was blunter and aimed at the wrong thing: `--emit-iyimod` and
  `--use-iyimod` no longer need iyi's own prelude. What they need is for the
  module and the program to agree on which library they mean. Both worlds are
  compiled by the same compiler and mangle the same names, so a mixed program
  would link — on the names that happen to agree.

- **`samples/iyi/calc`: a language, in the language.** Three modules — a
  scanner, a parser and an evaluator — reading a program from standard input,
  written against iyi's own 17,511-line library and nothing else. Every other
  sample is a page long, and a language that has only been used for pages has
  not been used.

  It grew the prelude by exactly what it asked for, which is the rule the
  prelude grows by: `String#[]`, `String#[](start, count)`, `String#to_i` and
  `read_input`. Nothing else was missing. `/` was not added, and that is the
  interesting one: iyi has no floats, Crystal's `/` on integers returns a
  `Float64`, and a name that means two things is what III.1.7a settled against
  — so integer division stays `//` in both.

- **Files can be removed.** `File.delete` uses `unlinkat` on Linux,
  `unlink` on Darwin and `DeleteFileA` on Windows. wasm32-wasi refuses it:
  deleting a path needs a preopened directory capability the prelude does not
  have. `samples/iyi/files.iyi` now deletes what it creates.

- **`derive` runs once, where the type is declared.** `derive <macro>` in a
  class or struct body resolves through the exported macro table, expands while
  the declaring type is processed, and the methods it generates belong to that
  module and travel in its artifact. `samples/iyi/derive.iyi` is built from its
  artifacts with `std/derives` deleted every build, so a consumer never runs
  the macro. The macro is handed the declaration's name and fields, built for
  the purpose: passing the declaration itself put the `derive` node inside its
  own macro argument, and no build that touched an artifact terminated.

- **A derive can ask what a field's type implements.** Each field carries the
  type it was written as, so `field[:type] <= ToJSON` is answerable — including
  where the type, the trait and the impl all belong to another module and arrive
  from its artifact, which is the `Order` case SPEC.md II.4 designs. The type is
  read from the annotation, because an instance variable's type is settled by a
  later pass and there is nothing to ask yet when a derive runs; R-2 is what
  makes that enough.

  A derive reads the declarations above it, so `getter n : Int32` is a field.
  One written below is refused, naming the call and which way to move it, rather
  than generating a method over the fields it happened to see. And because
  handing over a type hands over every question a macro may ask a type,
  `all_subclasses`, `subclasses` and `includers` raise inside a derive: they
  answer with the whole program rather than with a declaration, which is the
  caching promise R-5 rests on. Outside a derive they are untouched.

- **`derive named, counted` runs both.** Each macro named on one derive line
  runs in turn, left to right, reading the same declaration. A name nothing
  exports is reported at that name rather than at the line.

- **A Windows binary links, and then does something different every run.**
  Windows was one of the seven targets whose emitted objects CI audits and one
  of the six that had never been run. Running it found the object is fine and
  everything after the linker is not.

  Getting it to start needed two things the object audit cannot see. An
  LLVM-emitted object carries no `/DEFAULTLIB` directives, which an
  MSVC-compiled one would, so nothing pulls in `kernel32` or a C runtime. And
  naming the libraries is not enough: the *static* CRT (`libcmt`) links just as
  cleanly and then exits `0xC0000005` before `main` runs, while the dynamic CRT
  (`msvcrt ucrt vcruntime`) starts correctly. That was found with a ladder of
  programs whose smallest rung is `module w1` — it faulted too, which ruled out
  the allocator, the write path and `ExitProcess` in one step.

  What it does at run time cannot be trusted, in three different ways. The same
  binary, twenty runs, nothing changed between them: it has printed the right
  answer, printed `ache\w` (a fragment of a path from elsewhere in memory) where
  the program prints `HELLO, IYI!`, printed `BEEP ` with the digits gone, and
  exited `0xC0000005`. The two wrong-output shapes are a case conversion and a
  number rendered into a string, which looked like a lead until a run
  access-violated: an intermittent AV on a four-line program is a wild write,
  not a formatting bug.

  The obvious theory is recorded as wrong so nobody spends the afternoon on it:
  `HeapAlloc` not clearing cannot be it on its own, because the POSIX path
  allocates atomically with plain `malloc`, which does not clear either, and
  macOS has never printed the wrong thing.

  So Windows is not a run target and the README does not say it is. CI keeps a
  twenty-run watch that always passes and prints the tally — right, wrong,
  crashed — because there is no property of running an iyi program there that
  currently holds twenty times out of twenty.

- **The Windows link command names the libraries it needs.** An LLVM-emitted
  object carries no `/DEFAULTLIB` directives the way an MSVC-compiled one does,
  so `--cross-compile` printed a `cl.exe` command that could not link the object
  it had just produced: seven unresolved externals, six of them `kernel32`. The
  prelude's Win32 blocks now carry `@[Link("kernel32")]` and the dynamic CRT,
  and CI links with the printed command rather than one written into the
  workflow, so the command a person is told to type is the command that is
  tested.

- **An iyi program is run on wasm32-wasi every build.** The module imports four
  `wasi_snapshot_preview1` functions and nothing else, and it linked and then
  trapped on `unreachable` before printing anything. wasi-libc's entry stub does
  not call `main`: clang renames a C `main` to `__main_argc_argv`, the stub
  calls that name, and a module defining only `main` leaves the stub's weak
  reference unbound and traps the first time it is called through. The prelude
  now defines the name the stub calls, and `hello.iyi` runs under wasmtime with
  the same bytes it prints natively.

  And the command printed for this target is now `cc --target=wasm32-wasi`
  rather than `wasm-ld ... -lc`, which linked a module with no entry that no
  host could start. Only the driver knows where its sysroot keeps `crt1.o`, so
  naming the driver is the only way to print a command that produces a program.
  CI runs that printed command with wasi-sdk's clang as the `cc` it names.

- **A Crystal namespace can be bound, built and called from an iyi program, in
  two commands.** `--emit-bind` on the keep file's own build puts the per-type
  units into the artifact, with the type ids and constants they refer to, using
  the collectors an iyi module's artifact has always used — and the consumer
  links what the artifact carries:

  ```
  crystal tool bind -e ABCGreeter --emit-bind mods shard.cr
  crystal build --iyi-keep ABCGreeter --emit-bind mods -o keepbin abc_greeter_keep.cr
  iyi build --crystal --use-iyimod mods -o app app.iyi
  ```

  No `nm` and no `objcopy`, where four printed steps had been and had never
  worked at the end. The object `--emit obj` makes is a whole program and
  carries Crystal's library with it; an ordinary build leaves one object per
  type and the ones a namespace owns carry no runtime at all.

  `--crystal` on the consumer is not decoration: the unit numbers
  `Pointer(LibUnwind::Exception)` whatever the shard does, because a `String#+`
  can raise. The artifact is marked `crystal_library: true` for the same reason,
  which it always was — it was written `false` on an argument about what a
  boundary stands between, and that argument does not survive looking at what
  the unit refers to.

  A constant crosses as the assignment that makes it, so the consumer builds it
  in its own program at the time III.5 says — which is what the unit needs,
  referring to `Store::TABLE` and defining nothing. `Store.word(1)` answers
  `one`, where the same call used to segfault on the first read. Its own
  constants only: a unit refers to Crystal's as well, and those belong to the
  library the consumer already has.

  What a boundary cannot carry is an enum, and `crystal tool bind` says so by
  name instead of calling it a namespace skipped whole. iyi has no `enum`, so
  nothing on the far side declares one: a signature naming an enum cannot cross
  and neither can a type holding one. It is what `JSON` waits on — it binds to
  19 units and 7.5 MB and then stops on `JSON::PullParser`'s `ObjectStackKind` —
  and it is a language feature rather than another thing about object files.

  One nested inside a type under the root crosses as well, written
  `Inner::X = ...` — which defines rather than reopens wherever the namespace
  exists, and the declarations rendered above it are what make it exist.

- **Lookaround, and the reason it was refused was wrong.** `Iyi::Rx` supports
  all four forms, `(?=)`, `(?!)`, `(?<=)` and `(?<!)`, nested to any depth. The
  engine's header and SPEC.md both said lookaround was the price of RE2's
  linear-time guarantee, on the premise that it needs a backtracker. It does
  not: a lookaround over a regular inner pattern is a regular property of a
  position, answered by a pre-pass costing one state set per character and
  nothing per position. RE2 omits it because of its one-pass DFA design, not
  because linear time forbids it. The guarantee is unchanged, and what it
  actually costs is the constructs that are not regular, backreferences,
  recursion, subroutine calls and conditionals. Lookbehind here is not
  length-limited the way pcre2's is, so it accepts patterns pcre2 rejects.
  SPEC.md III.10 and Appendix B #17 carry the correction with the earlier
  reading still in them.

  **A capturing group inside an assertion is refused, and that refusal is
  new.** The pre-pass answers whether an assertion holds at a position and
  never which text its inner pattern consumed, so the group cannot be set.
  Reporting an empty capture where pcre2 reports a real one is the quiet
  difference this engine exists to avoid, so it refuses at compile time with
  the position instead.

- **The escapes and the folding a pattern in this tree actually reaches for.**
  Named groups in all three spellings, `(?<name>)`, `(?'name')` and
  `(?P<name>)`, numbered alongside unnamed ones the way pcre2 numbers them,
  with name lookup on the match. `\p{...}` and `\P{...}` for L, Lu, Ll, N and
  M, braced or single-letter, inside a character class or out, with every other
  category refused by name rather than approximated. `\v` as pcre2's vertical
  whitespace class and `\V` as its complement. `\x{...}` at any digit count,
  refusing at the offending position for no digits, a missing brace, a value
  above U+10FFFF, or a surrogate, which pcre2 in UTF mode refuses too. And
  `(?i)` folds past ASCII now, through
  `Char#downcase(Unicode::CaseOptions::Fold)`, simple case folding, the same
  relation pcre2 uses.

  `spec/compiler/iyi/rx_spec.cr` holds all of it against pcre2 over one corpus,
  31 examples including exhaustive codepoint sweeps for the character classes.
  None of it cost a library: `bench/dependency_floor.sh` still exits 0.

  Three readings stay this engine's own, each narrow and each stated rather
  than left to be discovered. `\d` is any Unicode number where pcre2 under
  `UCP` means `\p{Nd}` exactly, because no public stdlib predicate answers Nd
  alone, which is also why `\p{Nd}` is refused rather than approximated. `ß`
  and `ẞ` do not match caselessly here, because `ẞ` full-folds to `"ss"` and
  chasing that one pair opens others, simple lowercase not being symmetric.
  And lookbehind follows the union law here where pcre2 does not: on `"a"` at
  byte 0, `(?<=(?:a|$))` searched from 0 reports byte 0, the same pattern
  anchored at 0 reports nothing, and the ungrouped `(?<=a|$)` is right, so the
  trigger is the wrapping group rather than the branch lengths.

### Found

- **`UInt32` is barely usable in iyi's own prelude, and its `==` is wrong.**
  `x = 99_u32; x == 99_u32` answers **false**. There is also no `<`, no `>`, no
  `to_i64` and no `to_u64` on `UInt32`. Found while checking the collector's
  header, where the `type_id` is a `u32`: the memory was provably correct, since
  the containing 64-bit word read back as 99, while a `UInt32` comparison
  against the literal said otherwise, which sent two checks chasing a defect
  that was not there. The collector reads that field as part of its 64-bit word
  and is unaffected, and the exercises now do the same and say why. This
  predates the collector work and wants a fix of its own rather than a
  correction buried in a GC stage.

### Fixed

- **A boundary whose root is a module was read as carrying nothing.**
  `bound_names` asks whether the program has a type by each name an artifact
  declares, and asked it bare. That is right when the root is a *class* —
  `-e ExceptionPage` declares `ExceptionPage` and the program has one — and
  wrong when the root is a *module*: `-e Radix` declares `Node`, `Tree` and
  `Result` at the artifact's own top level, and the program has no top-level
  `Node`. It has `Radix::Node`.

  So `radix.iyimod` read as **6 types, 0 this program can name** while sitting
  in the same directory as a `Kemal` that names `Radix::Tree` eight times, and
  every one of those signatures went on waiting for a boundary that was already
  carrying the type. Asked under the artifact's root as well, and recorded
  under it too because that is how the producer writes them.

  Measured on the real shard: **`Kemal` goes from 168 signatures and 12 waiting
  to 182 and 0.** Nothing it names is undeclared any more.

- **A method that takes a block is now called with one, and rule 1's residual
  reaches zero.** `infer_return` instantiates a method on purpose to read what
  it answers, and it did that with no block — so `JSON::Builder#string`, which
  has an overload taking a value and one taking a block, matched the first and
  answered `wrong number of arguments (given 0, expected 1)`. Its return type
  was then the last thing on the boundary standing on the shard's word, over a
  block the annotation had already described in full.

  Two pieces. The call gets a `Block` of the annotated shape — the same block
  the keep file has written as text since blocks first crossed, `{ |b0| nil }`
  or an `uninitialized` of the output where the output is not `Nil`. And it
  gets a `parent_visitor`, because a block's body is code and code is visited;
  a blockless call never needed one, and the compiler says so exactly:
  `Iyi::Call#parent_visitor cannot be nil`.

  **Crossing on a return nobody checked: URI 0 of 55, JSON 0 of 181, YAML 0 of
  194.** Blocks being instantiable moves the other half too — 64 return types
  read in `JSON` where the tool had refused, 81 in `YAML`.

  One of the two this closed was not the tool's fault and is worth saying so:
  `YAML::Any#to_json_object_key` names `JSON::Error` in its body, and the probe
  it was measured with required only `yaml`. The tool refused correctly and the
  input was short. `YAML` reads 194 signatures with both required, against 193
  with one.

- **A block-taking method crossed a bound boundary and could not link.**
  IV.1g settles what such a method does: its machine code is the caller's, so
  the producer emits each instantiation private to the unit that called it and
  no symbol for one leaves the artifact — and its body travels in `MonoBodies`
  instead, for the consumer to compile its own from the block it wrote. That
  paragraph says explicitly that the question is about a `def` and not about a
  type.

  `crystal tool bind` was answering it about a type. Only a *generic* type's
  methods carried their bodies, so an ordinary class's block-taking method
  crossed as a declaration with nothing behind it — a promise nothing could
  keep, and `undefined symbol: *Shard::Part#each<&Proc(Int32, Nil)>` at the end
  of a build with no other complaint.

  It carries the body wherever the method is written now. Both shapes round
  trip and both are in `bench/bind_roundtrip.sh`: one that `yield`s and one
  that captures its block as a `Proc`. The first guess was that only the
  yielding one broke, because `yield` is inlined; a captured block fails
  identically, so the rule is the block. The surface does not move — `JSON`
  180 signatures, `YAML` 193, `URI` 55, before and after.

- **What is left of III.6 rule 1 is counted where it is owed, and it is two
  methods rather than eighty.** The report counted every written return that
  could not be held against an answer: URI 27, JSON 13, YAML 39. Most of those
  methods do not cross at all — a parameter with no type, a block nobody
  annotated, a splat — and are already refused by name further down, so
  counting them as unchecked said the boundary was trusting things it had never
  carried.

  Counted over the signatures that actually travel: **URI 0 of 55, JSON 1 of
  180, YAML 1 of 193**, and the report names them with the whole reason rather
  than a reason cut to a column. `JSON::Builder#string` — the tool builds no
  block for the call it synthesises — and `YAML::Any#to_json_object_key`.

  An abstract def is not among them any more either. It has no body to
  instantiate and no symbol of its own: what a caller reaches is an
  implementation, and every implementation is an ordinary method this tool
  checks as itself. `YAML::Nodes::Node#kind` was being counted as a return
  standing on the shard's word when it is one carried by the methods
  underneath it.

- **`bench/bind_speed.py` said a shard reaching into another one cannot be
  bound, and that stopped being true two commits before anybody reread it.**
  The header gave `Kemal` numbering `Array(Radix::Node(...))` as the case and
  a generic travelling as bodies rather than declarations as the reason. Both
  halves have since been answered — a generic carries its declaration *and* its
  bodies, and the build that fills a boundary reads the boundaries beside it and
  adds the import edge — and the paragraph went on asserting the old state.

  Corrected by measuring rather than by reasoning, and without the network: a
  two-shard tree of exactly that shape — a generic `Node(T)` in one, a second
  whose object code numbers `Array(Node(String))` and whose declarations name
  no `Node` — binds, links, runs, and prints what the source arm prints. The
  order matters and the header now says so: the reached-into shard is bound
  first and named with `--use-iyimod`, because only a build that sees that
  boundary can add the edge. Without it the consumer stops at import with
  `"kemal" numbers Array(Radix::Node(String)), and this build cannot name it`.

  SPEC.md III.6 already recorded the correction and needed nothing; it also
  names what real `Kemal` still waits on, which is three types belonging to
  other shards. The stale sentence carried a stale number besides — it called
  the smallest sweep 1,627 lines where the bench prints 2,167.

- **`crystal tool bind` holds a written return type against what a caller is
  actually handed, and the two are not always the same.** III.6 rule 1 says the
  binding asserts and is not checked. Half of it already was: a method whose
  return type nobody wrote is instantiated on purpose and the answer read. The
  other half — a method that *writes* its return type — was copied out verbatim
  and held against nothing, on the premise that what Crystal was told is what
  Crystal does.

  It is not. Crystal narrows a return restriction to what the body produced, so
  `def wider : String?` returning a `String` types its call **`String`**, and a
  consumer told `String?` holds a union where the object code answers a bare
  pointer. That is rule 1's "a call that returns something of another type",
  reached without anybody writing a wrong signature.

  Five in Crystal's own library, and each is a different shape: `JSON::Any#size`
  and `YAML::Any#size` say `Int`, which is a family head and not a type anything
  can hold; `JSON::Lexer.new` says the abstract base where the factory hands
  back `StringBased` and `IOBased`; `YAML::Schema::Core.parse_scalar` declares a
  union carrying `Slice(UInt8)`, which it never produces. The report names them
  and counts what is left: URI **40 agree, 0 disagree, 27 could not be checked**,
  JSON 119/3/13, YAML 111/2/40. Where the two disagree the artifact carries the
  **answer**, because the symbol is named after the answer and not after the
  restriction — see the round trip below, which is what settled that.

  **The first version of this check read the method's body rather than its call,
  and it was wrong in the direction that matters.** `def discards(io : IO) : Nil`
  has a body producing an `IO` and a caller receiving `Nil`, because `: Nil`
  discards; reading the body reported three defects in `URI` alone that were not
  there. The question a boundary asks is what a *caller* is handed, and the spec
  now pins the `: Nil` case for that reason.

- **A return type is asked whether a variable could hold it, which only the
  parameters were being asked.** `Int` is the head of a family on either side of
  the arrow: a method answering one has a symbol per member exactly as a method
  taking one does, and the generated keep file cannot compile either. `storable`
  looked at the arguments alone, so `JSON::Any#size : Int` was counted as a
  signature that crosses. JSON goes **181 → 180** and YAML **194 → 193**; URI is
  unchanged at 55.

- **`bench/build_speed.py` has not built anything since the identity cutover,
  and it is the gate for the one claim this project is built around.** It asks
  a wrapper where this checkout's sources are, and `f55ba16cb` renamed the
  variables it asks for to `IYI_*` while leaving it asking `bin/crystal`. The
  two command surfaces answer in their own vocabularies by design, so
  `crystal env IYI_PATH` is not an error — it prints an empty line and exits 0.

  The bench checked the exit status, got 0, and passed the compiler an
  environment with no search path in it at all. Every build then failed with
  `can't find file 'iyi/prelude'` and every row of the table printed a dash.
  It does exit non-zero, so it was never *silently* wrong; it was simply not
  being run.

  Two changes, and the second is the one that matters. It asks `bin/iyi`, which
  is the surface that knows those names. And it checks the **answer** rather
  than the status, because an exit code cannot see an empty string — a bench
  that cannot find the path now says which one it wanted.

- **`bench/incremental.py` was broken the same way, and it is the harness
  behind the number on the front page of the README.** Same shape exactly: it
  asked `bin/crystal` for `IYI_PATH`, got an empty line and a 0, and every
  build in it failed with `can't find file 'iyi/prelude'`. Fixed the same way,
  and it exits non-zero too, so this was also not being run rather than being
  believed.

  Running: 30 modules, 300 types, 7,208 lines, editing one module's body —
  **iyi 0.07 s, `go build` 0.09 s, Crystal 0.76 s** on a release compiler. The
  same edit with no artifacts is 0.18 s, so R-1 is worth 0.11 s of it.

  Worth putting beside the other bench rather than apart from it. `medium.iyi`
  is 6,900 lines in **one file** — no modules, no artifacts, nothing to cache —
  and there iyi is 0.13 s against Go's 0.02 s. iyi loses on a monolith and wins
  on a project, and SPEC.md's 0.1.0 section said only the first half because
  only the first bench could run.

- **The same bench withheld iyi's own figures at scale whenever Go was
  absent.** The 300-type pair is timed only after both halves are built and run
  against each other, which is right for the comparison and wrong for
  everything else: on a machine with no Go the whole block was dropped, and
  that block is the size SPEC.md's scale question is about. "The pair disagreed"
  and "there is no Go here" are now different answers. The first still drops the
  rows; the second prints iyi's and marks the Go column as not measured.

  With them back: at 6,912 lines, front end 0.05 s, end to end 0.39 s cold and
  **0.13 s warm** on a release compiler.

- **`gsub` copied the tail twice on an empty match at the end of the subject.**
  `Iyi::Rx.gsub("abc", /$/, "<>")` answered `"abc<>abc"`. An empty match at the
  very end left the cursor behind it, so the text between the cursor and the
  end was appended a second time with the tail. `/$/` over `"abc"` is the
  smallest case and reaches it with no lookaround in sight, so this was already
  wrong before any of the above.

- **`crystal tool bind` says why a bound shard cannot be linked into a program
  that has Crystal's runtime either.** A consumer built with `--crystal` is the
  program that *has* the runtime the shard's initialisation was missing, so it
  ought to be the answer; instead the link fails on `Crystal::Hasher::seed`,
  `Thread::threads`, `Fiber::fibers` and every other runtime global, defined
  once by each side. The object this pipeline makes is a whole program — a keep
  file is compiled like one — so it carries the library with it, and a program
  can have that library once. Without it the shard's state never starts; with
  it, nothing links. The names were not the problem and neither were the
  constants: the packaging was.

- **A harness for what the daemon takes off a whole build**
  (`bench/daemon_full_build.py`), which SPEC.md IV.1d had said was too noisy to
  publish. Twelve modules under `--crystal` with codegen and a link, eight
  alternating pairs, a module edited before every build, and it refuses to run
  on an unoptimised binary — the three corrections IV.1d had to make, built in
  so they cannot be forgotten again. **0.63 s to 0.46 s, or 26%**, with two runs
  agreeing to a hundredth.

  What was called noise was largely the measurement: `/usr/bin/time`, whose
  negative elapsed times IV.1d records, is not installed on this machine. The
  app here is lighter than the one the published table was made from — its
  front end is 0.35 s against 0.81 s — so this is a new row rather than that
  row measured further.

- **The prelude cache key is checked by the compiler now, not by whoever
  remembers.** A cache key is a claim that everything not in it does not matter,
  and this one was written when the only thing reading it was prelude analysis;
  every switch added since had to be checked against it by hand, silently.
  `--use-iyimod` is what happened when somebody did not — accepted, ignored, and
  the build compiled every module from source without a word. Each of
  `Compiler`'s switches is now written down as one of three things: in the key,
  re-applied when a build adopts a preanalysed prelude, or reaching neither.
  Adding a property fails the build until it is given one of them.

  Two of the classifications are judgements rather than facts, and saying so is
  the point: `mcpu`, `mattr` and `mcmodel` reach codegen and not analysis, and
  `progress_tracker` and `stderr` are where output goes — `new_program` sets the
  first and the adopt path sets neither.

- **`crystal tool bind` asked a hand-written list what an iyi program can name,
  and the list was wrong in both directions.** It claimed `Void`, `UInt32` and
  `Float64` — which iyi's prelude never declares — and left out `Slice`, `Int`,
  `Tuple` and `NamedTuple`, which `Program#initialize` creates for every program
  before any prelude is read. Those four were most of what the boundary appeared
  to be waiting on, so the list invented the work it was being read to size.

  `Program#builtin_type_names` records those types where they are made, and the
  tool asks it. `JSON` crosses 152 → 168 signatures, `YAML` 158 → 166, `IO`
  157 → 270 with what it waits on falling 140 → 5. The percentages do not move
  and nothing that crossed stopped crossing. What is left of "the core" is `IO`
  — nearly done itself — and then `Time`, `Time::Span`, `Set`, `File::Info`.
  See SPEC.md Part V item 12e.

- **CI could not package the tarball, and the guard that stopped it was right.**
  `iyi-tarball` carries `release := 1` and make applies that to what it builds
  for that goal — so the workflow naming `iyi` first built an ordinary one, and
  the tarball found it up to date by file times and refused. That refusal is
  exactly what `check_iyi_is_release` was added for; what was missing was the
  workflow catching up with it. It asks for `iyi-tarball` alone now.

- **The four steps `crystal tool bind` prints are taken by a spec now**
  (`spec/compiler-cli/bind-pipeline_spec.cr`): bind a shard, compile its keep
  file to an object, read the symbols, globalise them, and build an iyi program
  that links against it — then run the program and read what it printed. Three
  of the four steps were wrong when they were first run by hand, and each was
  invisible until something later failed, the later thing being `ld`. It skips
  itself where binutils is missing, or where `crystal` and `iyi` were built from
  different commits, since an artifact is read only by the build that wrote it.

- **`crystal tool bind` says that a bound shard's run-time state does not
  cross.** Crystal runs a constant's initialiser from `__crystal_main` and
  compiles the reads unguarded; a consumer has its own `__crystal_main` and
  never calls the shard's, so the constant stays null and the first read
  segfaults. A folded constant is fine — `LIMIT = 10` reads 10 — and one built
  at run time is not.

  Calling the shard's `__crystal_main` does not fix it, which was tried:
  renamed out of the way with `objcopy --redefine-sym` and called from the
  consumer, it segfaults *inside* the initialisation, before reaching any
  constant. Crystal's top level expects Crystal's runtime — a thread, an event
  loop, the exception machinery — and an iyi program is not one. So a boundary
  carries code that needs no initialisation, and that is the bound on it today.

  An earlier draft of this entry said the failure was silent — "no error at any
  step, the program answers wrongly". That was a measurement mistake: the exit
  status being read was a `printf`'s rather than the program's. It segfaults.

- **A method has as many symbols as it has ways of being called, and the keep
  file named one.** The mangled name carries the types at the *call site*, not
  the types in the declaration: `JSON.parse(input : String | IO)` is one
  declaration and three symbols, and the file named only the one where the
  argument is the declared union. Every consumer that passed a plain string
  linked against nothing. It emits the product of the parameters' shapes now,
  which measures smaller than it sounds — a union parameter is about one in
  twenty, 7 of `IO`'s 103 and 1 of `JSON`'s 53 — with a cap that reports itself
  rather than expanding without limit.

- **A `def self.` module function crossed under the wrong symbol.** A module
  written `extend self` puts its functions on the module and mangles
  `*Widget@Widget::polite<String>:String`; one written `def self.polite` puts
  them on the metaclass, which has no `@`. Both were recorded as the first, so
  every `def self.` in a shard produced a declaration the consumer called by a
  name nothing emitted — and Crystal's own library is written the second way
  throughout. The receiver is recorded now, which the artifact's format already
  had a field for and the type path already used.

- **A bound shard's module path is `camelcase` run backwards, and using
  `String#underscore` for it broke every acronym.** `underscore` answers `json`
  for `JSON`, and `json` camelcases back to `Json` — so the producer emitted
  `*JSON@JSON::...` while the consumer asked for `*Json@Json::...`, and `ld` was
  the only thing that ever said so. `camelcase` starts a group at every
  upper-case letter, so the inverse of `JSON` is `j_s_o_n`, which is a legal iyi
  path and comes back whole; `HTTPServer` is `h_t_t_p_server`, which
  `underscore` had flattened to `http_server` and lost. A shard named `ABC`
  links and runs.

  This corrects what the previous release notes said. They claimed `JSON`,
  `YAML`, `URI` and `HTTP` were outside the mapping's image and that the
  library-as-artifact thesis waited on a question about iyi's module paths.
  There was no such question: the mistake was reasoning about `underscore`'s
  image rather than `camelcase`'s.

- **`crystal tool bind` says when a root's name cannot survive the trip.** What
  actually falls outside is a name the grammar cannot spell — `Foo_Bar` needs
  two underscores running and `camelcase` reads two as one, so it comes back
  `FooBar`. Both sides mangle alike, so such a root produces an object file
  whose symbols no consumer will ever ask for, and `ld` is four steps too late
  to hear it.

- **A bound shard's iyi module name was the root downcased, and the symbol is
  what that broke.** Both sides mangle alike, so `Greeter.polite` is
  `*Greeter@Greeter::polite<String>:String` compiled from either language — but
  only if the consumer's module *is* `Greeter`, and a consumer builds that name
  by camelcasing the path it imported. `MyGreeter` became `mygreeter` became
  `Mygreeter`, which mangles to a symbol the shard's object file does not
  contain, and nothing said so until the linker did. The name is `underscore`d
  now, which is what `camelcase` inverts, with `::` as `/`.

  With it, a program built from a bound shard links and runs — the first time
  the four steps this tool prints have been taken end to end.

- **The pipeline `crystal tool bind` prints did not run.** A mangled name
  carries the types it was compiled for and a union prints with spaces in it —
  `*JSON::Any#as_a?:(Array(JSON::Any) | Nil)` — so the unquoted `$(...)` in the
  `objcopy` line split 50 of `JSON`'s 301 symbols into fragments and objcopy
  answered with its usage. It is an `xargs -0` now, and the four lines run as
  printed.

- **A boundary can now name another boundary's type, which is what `IO` was
  for.** `JSON`, `YAML` and `URI` all take an `IO`, so binding them is worth
  nothing unless the artifact can say so. The producer calls the type `IO`; a
  consumer that imported it calls it `Io::IO`, and an artifact that wrote the
  first resolved to nothing. Names from the boundaries passed in `--use-iyimod`
  are written the way the consumer will see them, and the modules they came from
  travel as the artifact's `imports`, so `import json` alone is enough — the
  consumer does not have to work out that it needs `import io` as well.

- **A field's type crossed as `IO+`.** That is how a virtual type prints — a
  fact about this build's dispatch rather than a name anybody can write — and a
  field declared `IO+` is one no consumer can read back. `infer_return` had
  devirtualised its answers since it was written; the field walk never did.

- **A bound namespace's artifact named types the consumer could not resolve, and
  nothing had ever tried to read one back.** The tool had no spec at all: every
  check it carried was a number it printed, and a number cannot say whether
  anything can consume the artifact printed beside it. `spec/compiler/bind_spec.cr`
  is that check, and it failed the first time it ran.

  An artifact's module name is the root downcased, and a consumer builds a type
  back out of it by camelcasing — a mapping iyi keeps reversible on purpose
  (SPEC.md IV.6 #6), so `MyLib` returns as `Mylib` and `JSON` is not in its image
  at all. Meanwhile the declarations inside still said `MyLib::Entry`. A class
  root never showed it, because its own name is a declaration in the file and
  `MySink::Entry` resolves against that wherever the module lands. The producer's
  prefix comes off a module root's declarations now, which is the same property
  said directly: what an artifact declares belongs to the artifact.

- **`crystal tool bind` exported methods that take a block nobody annotated.**
  A block-taking method is compiled per block *type*, so one whose block has no
  written type has no single symbol to declare. `infer_return` refused these
  already — but only when it ran, and a method that writes its own return type
  never reaches it. No count showed it; `Time`'s generated keep file did, by
  refusing to compile with *`Time.measure` is expected to be invoked with a
  block*. They are refused and reported on their own line now.

- **`crystal tool bind` can be pointed at the boundaries already written.**
  `--use-iyimod DIR` — the same switch a build uses — reads the `.iyimod` files
  there, and a signature naming one of their types is no longer waiting on
  anybody. Each name is checked against the program rather than trusted, since a
  class root's declarations are absolute and a module root's are relative to a
  name the file does not record; what is dropped is counted and printed.

  It is what closes the question item 12e opened. With `IO`, `Time` and
  `SemanticVersion` bound, `JSON` crosses 168 → 181 signatures, `YAML`
  166 → 192 and `URI` 48 → 55 — the exact gains the unlock report predicts, and
  it predicts them by a different route, which is the two checking each other.

  The counts also stopped calling a free variable a type. `T`, `self` and a
  block returning `_` are not types anybody can declare, and counting them
  beside `IO` said there was more waiting than there was; they have their own
  line now. What is left: `JSON` and `URI` wait on **nothing** anybody could
  declare, and `YAML` waits on `Set` alone — which is generic, so it travels as
  bodies rather than declarations and belongs to a different piece of work.

- **`crystal tool bind`'s keep file never descended into nested types.** A
  nested type travelled as a declaration while its methods were named by
  nobody, so the artifact promised symbols the object file did not carry — a
  link error rather than a compile one, and invisible until something linked.
  `JSON`'s artifact holds 16 types and the keep file reached 9 of them, leaving
  16 methods on the other 7 unemitted. The walk recurses now, and the counts
  printed beside the artifact are counted through the nesting too, having read
  as top-level-only for the same reason.

- **`crystal tool bind` generated a keep file that could not compile when
  pointed at a core type.** A shard's root is a module — `Kemal`, `JSON` — and
  the tool assumed one everywhere: it reopened the root as `module IO`, which is
  a class, and called `IO.write`, which is an instance method. A class root's
  own surface and its constants now stay behind and are reported by name and
  count, rather than being declared with no symbol to link against. What travels
  is the types under it, which is enough to make `crystal tool bind -e IO`
  produce an artifact and an object file end to end.

  It carries the root itself now. A module's own methods are module functions
  and a class's are its type's, so a class root travels as one declaration
  holding everything under it — `IO` with `IO::Memory` and twelve more inside:
  14 types, 148 methods, 311 symbols. Its constants still stay behind.

- **`crystal tool bind` declared private types.** `IO::Encoder` is private, and
  an artifact naming it names a constant the consumer is not allowed to write.
  Method visibility was already checked; the type's was not. The generated keep
  file is what found it, being the first thing outside the shard to say the name
  out loud.

- **`crystal tool bind` counted a signature as crossing when a variable could
  not hold its parameters.** A name being writable is not the same as a value
  being holdable: `Int` is the head of a family, and a method taking one is
  compiled once per member with a symbol apiece, so there is no single symbol
  to declare. `can_be_stored?` is the compiler's own answer and the tool asks
  it now, reporting those signatures on their own line rather than as types
  nobody has declared. It is what the counts above are corrected by — they
  read 182, 168 and 286 before it.

- **`crystal tool bind` read restrictions as text, and it flattered the core.**
  A method inside `JSON::Token` writes `kind : Kind`, which is
  `JSON::Token::Kind` — the shard's own type, already travelling — and the tool
  counted it as a type nobody had declared. `self` went the same way: a method
  returning `self` in `URI` returns `URI` and waits for nobody. Every such
  spelling pushed the "what this boundary is waiting on" list in one direction,
  *towards the core*, which is the claim that list was being used to support.

  Restrictions are resolved against the owning type now. The boundary the tool
  can already write grows by 33 signatures — `JSON` 142 → 152, `YAML` 142 → 158,
  `URI` 41 → 48 — and the percentages of surface needing no human do not move,
  because those measure a different thing and resolution does not touch it. Two
  `YAML` signatures returning a bare `Array` stopped crossing, which is a
  correction rather than a loss: a declaration that says `Array` without saying
  of what is not one a consumer can use.

  With the list true, `IO` is first for all three namespaces and by more than
  before — +13, +21, +8 — against 21 for everything generic. See SPEC.md Part V
  item 12e.

- **The tarball could be built from an unoptimised compiler, and was.** `build:`
  sets `release := 1`; `iyi-tarball` did not, and even asking would not have
  been enough — make rebuilds on file times, so a `.build/iyi` left over from an
  ordinary `make iyi` is newer than every source and gets packaged as it is.
  Nothing about the tarball would look wrong; every build every user ran would
  simply go through an unoptimised compiler. The target now asks the binary
  rather than the build: `--version` says which it is, and packaging refuses
  otherwise.

  This is also why the daemon numbers first published here were about three
  times too generous — they were measured with one of those binaries. See
  SPEC.md IV.1d for the corrected table and for the other two ways the
  measurement was wrong.

- **The tarball could not build a program that requires Kemal.** `install_iyi`
  cut `compiler/` from the copy of Crystal's library it ships, and the standard
  library requires it: `crystal/syntax_highlighter` requires
  `compiler/crystal/syntax`, the exception page requires the highlighter, and
  Kemal requires the exception page. README's headline example did not work in
  the thing people download, and 0.2.0 shipped that way. CI now builds a shard
  out of the unpacked tarball.

- **The build daemon died after serving one build from another directory**, and
  could not find `lib` in the client's project. Three bugs, all older than this
  release and all the same fact forgotten — the daemon runs in its own
  directory and the client does not. The third was that `CrystalPath` is a
  struct, so fixing the second through a getter mutated a copy and changed
  nothing. Every existing daemon spec passed through all three, because each
  passes an absolute path and starts the daemon where the runner is.

- **A build that adopted a preanalysed prelude ignored `--use-iyimod`.** That
  path never runs `new_program`, so a build's switches were whoever analysed
  the prelude's — none. The flags, the target and the prelude are in the
  analysis's cache key and so are safe; `--use-iyimod` is not, and was accepted
  and silently ignored while every module was compiled from source.

- **A constant an artifact reads carries a location.** The reads a consumer
  performs on an artifact's behalf were synthesised without one, and LLVM
  refuses a call with no location inside a function that has debug info. It
  never fired under iyi's own library and fired at once under Crystal's, which
  is where it was found — while looking at whether artifacts and `--crystal`
  can be used together. They now can; this was the first of the three things in
  the way.

### Changed

- **A module path is read from the root, not from where it is written.** A
  module called `samples/calc` importing `calc/lexer` resolved `Calc` to
  itself, then said the module was not imported: a true-looking sentence about
  the wrong thing. A module's path is its file's path (R-1), so it cannot mean
  something different depending on where it appears. Found by writing the
  sample above, which is called `calc`.

- **`Array#sort` is `sort_in_place`, and `sorted` is the copy.** A plain `sort`
  meant the opposite thing in the two libraries — it sorted the array under
  iyi's and returned a copy under Crystal's — with no error either way, which
  is the worst shape a difference can take. The plain verb is not in this
  library now, so the same call is an error under one and Crystal's meaning
  under the other.

  Measured before deciding: of everything iyi's library mutates — `<<`, `[]=`,
  `concat`, `shift`, `sort` — only `sort` disagreed, because Crystal writes `!`
  on the mutating member of a *pair* and plainly for the rest. One method
  today, and the shape every future pair would have had. SPEC.md III.1.7a has
  the three options that were on the table.

  The error teaches the rule: a missing name whose participle exists says so,
  which the suggestion machinery could not — `sort` to `sorted` is two edits.

- **iyi answers as iyi.** `iyi tool` printed `Usage: crystal tool`, and it was
  the shape of the bug rather than the string that mattered: the banner was a
  constant interpolating the program name, and a constant is built before the
  entrypoint has said which of the two binaries this is. `clear_cache --help`
  printed the literal text `#{Command.program_name}` at a user, because its
  heredoc was quoted. `repl --help` printed nothing at all. `iyi foo` could
  never find `iyi-foo`: the git-style subcommand lookup was hardcoded to
  `crystal-`, so the extension point existed for one binary of the two.

  Underneath, the compiler carries its own name: `Iyi` is the namespace,
  `src/compiler/iyi` the source, `IYI_*` its nineteen settings, `~/.cache/iyi`
  the cache, `IyiPath` the thing that reads `IYI_PATH`. `bench/identity_floor.py`
  is the gate, and the number it reports went from 12,426 lines across 178
  paths to zero; every remaining mention of Crystal is listed there with the
  reason it genuinely means the other language.

  Nothing about the compatibility binary changed, and that is asserted rather
  than assumed: `crystal` still answers as `crystal`, still reads `CRYSTAL_PATH`
  and its siblings, and `require "compiler/crystal/syntax"` still resolves.
  Crystal's own standard library does that, and anything that used the compiler
  as a library may too. Where both names are set for one setting, iyi's wins.

  Two of the defects were only visible on Linux CI, and both were the same
  mistake: a local run that set `IYI_PATH` by hand, and a gate whose
  `git ls-files` exited 128 inside a container and so checked nothing.

Master is `0.3.0-dev`. Under the artifact rule 0.2.0 introduced, that means
every build of it interoperates with nothing but itself: a version between two
releases names no compiler, so it cannot be handed one released artifact and
told they match.

## 0.2.0 — 2026-08-20

**A program chooses its library.** 0.1.0 had iyi's own 1,184-line prelude, and
that was most of what stood between the language and anybody's real program.
It turned out not to be a library problem: a prelude is a library and the rules
are the language, so a program can keep one and change the other. `--crystal`
does, and there `require` means what it means in Crystal. Nine shards were
swept through it and a Kemal server written in iyi serves HTTP; how many of the
rest work is not something this release measured.

Two more entries take the rules further out — `pub` reaches a macro and a
constant — and closing each found the same hole underneath: a surface nobody
wrote and nobody could refuse.

Artifacts written by this release are read by every other build of it, on the
same target and under the same flags. A `-dev` version between two releases
names no compiler and interoperates with nothing but itself, which is the rule
below doing its job rather than an exception to it.

### Changed

- **The tarball carries Crystal's library, so `--crystal` works in what people
  download.** It shipped iyi's own 56 KB and nothing else, so the release's
  headline feature answered `require "json"` with "can't find file" outside a
  checkout. It ships both now — 13.4 MB to 14.9 MB — and CI runs a `--crystal`
  program out of the unpacked tarball, which is where this was found and where
  it would have been found again.

- **`make cli_spec` says once when the daemon and the compiler are different
  builds.** The daemon refuses a client built from another compiler, correctly
  — it holds an analysed prelude — but the spec saw that as nine failures, each
  printing two version strings, with the reason in none of them. It is easy to
  arrive at, too: the build commit comes from git HEAD while make compares file
  times, so a commit can leave two binaries disagreeing about a commit while
  agreeing about every line of code.

- **`iyi mod diff` says whether a change reaches a module's consumers.** The
  three hashes an artifact carries already answered it and nothing asked them.
  It compares two `.iyimod` files, says which of interface, implementation and
  source moved — with what each of the three means, because the middle one is
  the surprising one — and names the exports that came and went when the
  interface is what moved. `--exit-code` exits 1 in that case, which is
  `git diff`'s spelling and its reason: the answer is not a failure.

- **An iyi program is run on three targets every build, not one.** It compiled
  for nine and was tested on one, which is a weak thing to call portability.
  CI now cross-compiles `hello.iyi` for musl and for aarch64, links each with
  the target's own `cc` and `libgc` (the command `--cross-compile` prints)
  and runs them: in an Alpine container and under emulation. The check is that
  each prints what the same program printed on the machine that compiled it.

- **`bench/runtime.py` measures what the library costs at run time.** The two
  libraries are within noise where they do the same work; `Hash` is 5x ahead
  and does less; `String` is 3.62x behind with the collector off. The first
  reading said string building was twenty times faster, and it was the
  collector, so the bench reports both columns and the honest one is the
  second. A later run no longer shows the twenty; as they run, string
  building is within noise, and the collector is masking a slower builder.

- **iyi describes itself as its own language, compatible with Crystal.** "A
  language built for Developer & Agentic Experience, Portability, Performance,
  and Efficiency", and README says what stands behind each of the four and what
  does not: the edit loop and the artifact are built, portability means nine
  targets that compile and three that are run, the run-time measurement is new
  and says the two libraries are within noise where they do the same work, and
  the agentic claim is a mechanism rather than a result.

  Compatibility is stated as something checkable and in one direction: the same
  compiler builds `.cr` files, an iyi program can `require` a shard with
  `--crystal`, and a Crystal program cannot require an iyi module, because R-2's
  written types and R-3's closed types are what an artifact is made of.

  `iyi version` reads `iyi 0.2.0-dev (built on Crystal 1.22.0-dev …)`: the
  language first and what it is built on after. The licence and NOTICE.md are
  unchanged, because Apache 2.0's attribution is an obligation rather than a
  description.

- **An artifact is read by the release that wrote it, not by the build.** A
  `.iyimod` was locked to the exact compiler build, commit and all, so two
  builds of the same version refused each other's modules and handing one to
  somebody meant handing them your compiler too. The identity is now the
  released version, the target and the flags. Every build of the same released
  version reads every other's artifacts on the same target under the same
  flags. A `-dev` version keeps the commit because it names no release. The
  version comes from `src/IYI_VERSION`, which is also what the binary reports
  and names the tarball.

- **A plain build using iyi's own prelude reaches no third-party library.**
  On macOS and Linux it needs no libgc and links only the platform libc. On
  macOS its undefined symbols are five libc calls (`write`, `exit`, `memset`,
  `malloc`, `realloc`), where 0.1.0's list was seven and four belonged to the
  allocator. On Linux the prelude now issues raw syscalls for `write`, `exit`
  and the allocator (`mmap`), so a Linux program's object asks libc for
  nothing at all. The linked executable still carries the five references its
  link template leaves, named below.

  The price is that the default does not collect. The prelude's allocator
  selection is inverted: a plain build binds `src/gc/none.cr`, which allocates
  over `malloc` and `realloc` and never frees. `-Dgc_boehm` opts back into real
  collection (`libgc.1.dylib` and the four `GC_*` symbols, exactly as before),
  and `-Dgc_none` still works and selects the default allocator. The flag used
  to be accepted and ignored because the prelude declared `@[Link("gc")]`
  directly. That was fixed first, then the default was flipped.

  The compiler lost `libiconv` (the Makefile passes `-Dwithout_iconv`) and
  `libpcre2`, and keeps `libgc`. `-Dgc_none` was tried on the compiler itself
  and is not viable: it emits invalid IR ("Load operand must be a pointer",
  from `LLVM::Module#verify`) on some runs and dies in `main_user_code` on
  others, being a long walk over ASTs with parallel codegen and fibers under
  an allocator that never frees. How pcre2 came off, and what it cost, is in
  the regex entry below.

  `bench/dependency_floor.sh` checks linked libraries beside symbols for a
  default build with iyi's own prelude and for `-Dgc_boehm`, and fails when
  either grows. It checks the compiler binary too, against an allowlist and a
  denylist that now carries `libpcre`. It does not build `--crystal`; that mode
  links Crystal's standard library and may pull every library a required shard
  pulls, so the zero-third-party-library claim and the floor gate do not apply
  to it.

  The gate reads a binary's own direct dependencies on both host platforms:
  `otool -L` load commands on macOS, and `readelf -d` NEEDED entries on Linux.
  `ldd` was on the Linux path and read the transitive closure instead, so
  libLLVM's dependencies counted as iyi's and the Linux compiler appeared to
  link libxml2, libz, libffi, libedit, icu, zstd, lzma, libbsd, libmd and
  libtinfo, while macOS showed none of it. The two platforms were measuring
  different claims, and the wide reading had no teeth: an allowlist holding
  libxml2 because libLLVM brings it can never catch iyi reaching for libxml2
  itself, which is the only case the denylist exists for. Proven both ways:
  rebuilding the compiler with an explicit `-lxml2` fails the gate by name,
  the same library inside libLLVM passes, and `otool -L` on `libLLVM.dylib`
  shows it beside libffi, libedit and libz. `linux-vdso.so.1` left the output
  without being allowed by anything: it was never a `DT_NEEDED` entry, the
  kernel maps it, and `ldd` was merely saying so.

  iyi is no longer Linux x86-64 only. One compiler cross-compiles for seven
  audited triples on four platforms: Linux x86_64 and aarch64, macOS x86_64
  and aarch64, Windows msvc and gnu, and wasm32-wasi. The own-prelude floor
  held on every one, measured with `llvm-nm --undefined-only` against the
  artifact each target actually emits (`.o` for ELF and Mach-O, `.obj` for
  Windows, `.wasm` for wasm32), two programs per triple. This is an emitted
  object audit, not a claim that the test suite runs on every target.

  At the object layer, Linux x86_64 and aarch64 leave no undefined symbols at
  all. macOS x86_64 and aarch64 leave `exit`, `malloc`, `memset`, `realloc` and
  `write`, all from libSystem. Windows msvc leaves `ExitProcess`,
  `GetProcessHeap`, `GetStdHandle`, `HeapAlloc`, `HeapReAlloc` and `WriteFile`,
  all from kernel32, and the gnu triple adds `main`. wasm32-wasi leaves
  `wasi_fd_write` and `wasi_proc_exit`, which are WASI imports. `malloc` and
  `realloc` are gone: the prelude binds `llvm.wasm.memory.grow.i32` as a
  two-argument `fun` and bump-allocates over grown pages. An earlier finding
  that Crystal could not reach `memory.grow` was an arity error, not an
  impossibility. The wasm linker globals (`memory_base`, `stack_pointer`,
  `table_base`, `indirect_function_table`) are linker plumbing, not
  dependencies.

  The linked executable is the other layer and it is not the same number. On
  Linux the program carries the five undefined references its C runtime
  objects leave behind, `__libc_start_main`, `__gmon_start__`,
  `__cxa_finalize` and the two weak `_ITM_` clone-table callbacks. They belong
  to the link template's `crt1.o`, `crti.o` and `crtbegin.o`, not the prelude.
  CI reported them on Linux, which is how this file learned that a claim
  measured on an object is not a claim about an executable. The gate allows
  those five by exact name, so `malloc` or `mmap` still fails: a wildcard would
  have been shorter, and "whatever the crt supplies" is not a measurable set,
  so it would also have hidden a prelude falling back to libc. The five were
  measured against the glibc in the container CI pins, and a different base
  contributes a different fixed set. Musl or an older glibc fails by name
  rather than passing, which is what a fixed-list check is for. On macOS the
  executable leaves the same five libSystem calls the object asked for. On
  both host platforms, an own-prelude program's dependency list is the
  platform libc and nothing else.

  The compiler binary links libLLVM, libc++, libgc and libSystem, and that is
  the whole direct list. `otool -L .build/iyi` prints those four;
  `.build/crystal`, the same compiler under its compatibility name, prints the
  same four. This is the compiler's own link line rather than everything that
  ends up mapped. What libLLVM pulls in beyond itself is LLVM's decision and
  the distribution's build. The floor is a property of what iyi builds rather
  than of what builds it, and the toolchain binary is now LLVM plus a collector
  plus the platform. SPEC.md III.9 records why the compiler keeps that
  collector, and III.10 records how pcre2 left.

- **Macro-level regex now runs on iyi's owned engine, with RE2 semantics.**
  `src/compiler/iyi/rx.cr` is differentially verified against pcre2
  (Appendix B #22). The price for a macro author is no in-pattern
  backreferences and no lookaround. A macro that uses one fails with a named
  error rather than meaning something else, and no pattern in a program or at
  compile time can take exponential time.

  `libpcre2` is off the compiler. `otool -L .build/iyi` lists libLLVM, libc++,
  libgc and libSystem, and `nm -u .build/iyi` leaves none of the thirteen
  `pcre2_*` symbols it used to. An earlier diagnosis blamed the leftover on
  the standard library prelude, assuming `require "regex"` emitted
  `@[Link("pcre2-8")]` even when nothing called it. That was wrong: an unused
  `@[Link]` does not put a library on the link line. The cause was ten reachable
  regex literals. `--emit llvm-ir` on the compiler shows ten expanded regex
  constants, `$Regex:0` through `$Regex:9`, whose patterns identify four
  standard library files the compiler compiles into itself.

  Those four now parse by hand, with no engine, and none calls `Crystal::Rx`,
  because the standard library does not reach into compiler internals:

  - `src/option_parser.cr`, seven literals in `parse_flag_definition`, reached
    from `compiler.cr`, `loader.cr` and most of `command/*`. A 20,633-case
    differential against the original seven regexes found 0 mismatches.
  - `src/process/shell.cr`, one literal in `Process.quote_posix`, reached
    because the compiler shells out to the linker. A 194,690-input
    differential covering every Unicode scalar to U+2FFFF found 0 mismatches,
    and 18 hostile arguments passed a live `/bin/sh` round trip.
  - `src/semantic_version.cr`, `VERSION_PATTERN`, reached from
    `macros/methods.cr` for `compare_versions`. `valid?` and `parse?` now share
    one scanner so they cannot drift. One existing asymmetry remains on
    purpose: `valid?("99999999999999999999999.1.1")` is true while `parse?`
    raises `ArgumentError` from `to_i`.
  - `src/spec/cli.cr`, two uses rather than one, reached because
    `command/spec.cr` requires `spec/cli` so `crystal spec --help` can print
    the runner's options. `--location` is one literal. `-e/--example` was
    `Regex.new(Regex.escape(pattern))`, which is substring matching written
    the long way.

  **`-e/--example` is a breaking change to a standard library public API.**
  `Spec::CLI#pattern` was `Regex?` and is now `String?`.
  `Spec::Item#matches_pattern?` and `filter_by_pattern` now take a `String`,
  with `=~` replaced by `includes?`. The behaviour is identical because
  `Regex.escape` had already reduced every pattern to a literal substring, but
  the type is not. Direct callers get a compile error rather than a
  deprecation.

  Two findings cost more to rediscover than the dependency. PCRE2 in this tree
  is compiled with `UCP`, so its `\s` is Unicode and `Char#whitespace?` is a
  different predicate. They agree on every character except U+0085 NEL, which
  `option_parser.cr` now names explicitly. The differential first reported
  1,114 mismatches, all containing U+0085. The same flag makes `\d` mean
  `\p{Nd}`, so `--location` used to accept a non-ASCII digit as a line number
  and deliberately no longer does. Second, in `/\A(.+?)\:(\d+)\Z/`, the lazy
  `(.+?)` reads as "shortest prefix" and is not one. `(\d+)\Z` has to reach
  the end and `:` is not a digit, so the engine backtracks until the last colon
  is the split. That makes `a:1:2` file `a:1`, line 2. A `split(':')`, or any
  leftmost scan, gets that wrong.

  The gate closed behind it. `libpcre2` came off
  `ALLOWED_LIBS_COMPILER` in `bench/dependency_floor.sh`, and `libpcre` went
  onto `FORBIDDEN`, so the compiler is held to the same denylist as
  own-prelude programs. Injecting a reachable regex literal back into
  `option_parser.cr` makes the gate exit non-zero at both layers, naming the
  gained library and the denylist hit. The first probe was discarded because
  it used an unused constant. Crystal does not instantiate an unreachable
  constant, so no library came back and that probe did not test the gate.

- **Appendix B #20 through #26 record the runtime decisions.** iyi writes its
  own garbage collector (#20), overruling the earlier plan to adopt gcry and
  pay it back in layouts. The owner's goal is control over concurrency,
  parallelism and performance, and owning the collector is the only path to
  it. gcry remains prior art: roughly 87% throughput at roughly 0.80x post-GC
  RSS against Boehm, with precise stack roots correctness-stable and not an RSS
  win. The bill is explicit: heap, stop-the-world, roots, finalizers and
  platforms are rebuilt in this tree. Until that collector serves parallel
  codegen, the compiler keeps bdw-gc (#24, superseded and restated).

  The default own-prelude build still allocates and never collects (#23), so a
  long-running program grows without bound. `-Dgc_boehm` is the opt-in.
  iyi's own prelude has no IO beyond `puts` and no concurrency. A
  `--crystal` program uses Crystal's standard library instead and is outside
  both that limitation and the own-prelude dependency floor.

### Added

- **`iyi build --crystal` compiles a program against Crystal's standard
  library, so `require` reaches the ecosystem.** A `.iyi` file refused
  `require` because there was nothing to require: the prelude is what a program
  gets. That reason stops being true when the prelude is Crystal's. The rules
  do not change with the library — the module header, `pub`, `import`, `using`,
  traits and `impl` are all still there, and a shard is ordinary Crystal
  compiled into the program.

  A Kemal server written this way serves HTTP. What it gives up is R-1 for that
  dependency: the shard is read from source, so the edit loop pays for it the
  way Crystal does. Your own modules are unaffected, and `--emit-iyimod` still
  writes them.

  `crystal tool bind` writes what it generates with `--emit-bind`, its own
  switch, because what it writes is a boundary for a shard rather than this
  build's own modules.

  The two libraries are two modes and do not mix on the artifact side:
  `--use-iyimod` and `--emit-iyimod` need iyi's own prelude. An artifact's
  object code numbers the types its module made, which under Crystal's library
  include the standard library's own, and a consumer compiling its own copy of
  that library has two of everything. That was an LLVM module which would not
  verify; it is a sentence now.

  **Nine shards were swept through it**, each built twice — as an iyi program
  and as a Crystal one, so that a difference is this fork's and a shared
  failure is the ecosystem's. `kemal`, `db`, `ameba`, `habitat`,
  `baked_file_system`, `radix`, `sqlite3`, the standard library's own
  `json`/`yaml`/`uri`/`http`, and a program that round-trips
  `JSON::Serializable` and writes a file. All nine behave the same in both
  languages. One needed a word changed and it was the rule working: `habitat`'s
  macro resolves the type it is handed by name, and a class an iyi module
  leaves unmarked is private, so it needs `pub class`.

  `samples/crystal/stdlib.iyi` is the program CI builds to keep this true: a
  trait with a default, an `impl` on a generic, an error union with `!` and
  `.or`, a `defer`, and JSON, YAML and URI in the same file.

- **`pub` takes a constant.** `pub LIMIT = 42` is reachable through the
  module's name; an unmarked constant is the module's own and is refused by the
  sentence an unmarked `def` gets. Nothing was added to the artifact format,
  because a module's top level already travels as source and the mark travels
  with it.

  The hole under it is the same one `pub macro` found: a constant's visibility
  was never set, so every constant a module declared was reachable. That is
  what a real shard leans on — Kemal hands out every object it has through one.

- **`pub macro`, so a macro can cross a module boundary.** Every macro a module
  writes already travelled in its artifact, because a body that travels may
  call one, but none of them was reachable: `pub` did not take a macro. A
  marked one is now reachable exactly as a `pub def` is, unqualified after
  `using` or through the module's name, and it works against an artifact with
  the module's source deleted. What it exports is a name and an arity, because
  a macro takes syntax and returns syntax.

  Two things worth knowing. Closing this found the hole under it: a macro's
  visibility was never set, so **every** module's macros were already callable
  through its name — that is refused now, with the sentence an unexported `def`
  gets. And macros are not hygienic, so a `pub macro` that writes `tmp = 99`
  assigns to the consumer's `tmp`; SPEC.md IV.4 says so in full.

- **`iyi tool format` formats iyi.** The formatter is Crystal's and knew none
  of iyi's syntax, so a module header, a `pub`, a `trait`, an `impl`, a
  `using`, a bounded `forall`, a `where`, a `defer`, a `!` or an `.or` sent it
  into "there's a bug formatting this file". It knows all of them now, and a
  directory is searched for `.iyi` files as well as `.cr` ones. The prelude and
  the nine samples format to themselves, which is the test that made the last
  three of those show up.

- **`iyi repl` brings the interpreter back on a smaller base** (Appendix B
  #25, reopening #11). It starts, reads a line, evaluates it on the 781-line
  macro interpreter, prints the result, and survives a bad line. Session
  variables persist across lines. Each line is a fresh parse unit, so a bare
  `x` is a Call until the REPL rewrites names it already holds into Vars. This
  is not the 11,377-line revert, which cannot run an iyi program past its
  module header.

  There is no C interop, so no libffi, and the own-prelude floor enforces that:
  libffi is on `bench/dependency_floor.sh`'s denylist. Adding to a sample the
  exact `@[Link("ffi")]` shape a naive revert would produce failed at three
  independent layers, reporting the gained symbol `ffi_prep_cif`, the gained
  library `libffi.8.dylib`, and the denylist hit.

- **wasm32 grows its own heap** (Appendix B #26). The own prelude binds
  `llvm.wasm.memory.grow.i32` as a two-argument `fun` (memory index, then page
  delta) and bump-allocates over the grown pages. `malloc` and `realloc` are
  gone from the emitted `.wasm`; the remaining undefined symbols are the WASI
  imports `wasi_fd_write` and `wasi_proc_exit`, plus linker globals. An earlier
  probe used the one-argument form, failed verification, and was misread as
  "Crystal cannot bind this intrinsic". The two-argument form lowers to
  `memory.grow 0`. Accepting wasi-libc as the platform runtime, or documenting
  wasm32 as a qualified target, were both rejected.

### Fixed

- **A generic imported from an artifact links again when its type argument is
  inferred.** `Box(Int32).new(42)` always worked and `Box.new(42)` did not.
  Inference makes `new` a method on `Box(T)`, which is the artifact's own type,
  and the rule that says "this type's machine code is in the artifact" was
  reading the generic itself. An artifact carries a unit for every non-generic
  type a module declares and none for a generic one, because a generic has
  machine code only once somebody picks its arguments, and the consumer is who
  picks them. So the consumer declared a `new` that nothing defined and the
  program failed to link, saying `undefined reference to Box(T)::new<Int32>`.
  The consumer's rule now matches the producer's. Reported after 0.1.0 went
  out.

- **`Array#sort` sorts the array, and `sorted` hands back a copy.** SPEC.md
  III.1.7(A) settled that pair — the plain verb mutates, the participle copies,
  Swift's convention adopted because `!` had to leave identifiers so postfix
  `!` could propagate an error — and the prelude did not implement it: `sort`
  returned a copy and nothing mutated. It does now, and `sorted` is one line
  over it.

  Worth knowing when moving between the two libraries: Crystal names the same
  pair `sort!` and `sort`, so `a.sort` copies there and sorts here. It is the
  one call in this prelude that means something different under `--crystal`,
  and the note is in `src/iyi/array.iyi` where somebody is standing when it
  matters.

- **A `using` that cannot deliver is refused where it is written.** A module
  header makes a type, and inside it that name means the module — so
  `using app/count::{Tally}` in a module called `tally` asks for a name it
  cannot have. What it said before was that `Tally` was not
  `App::Count::Tally`, at the first line that used one, with nothing pointing
  at the directive. Found by writing a command-line program.

- **`String#size` counts when nobody counted.** Crystal reads `@length == 0` on
  a non-empty string as "not counted yet" and scans; this prelude returned the
  field. A string built by Crystal's own `to_json` therefore printed correctly
  through iyi's `puts` and answered `size` **0** — no error, a wrong number.
  Free for every string this prelude makes, because it fills the field. Found
  while measuring what crosses between the two languages.

- **A macro that cannot see a type says why.** An unresolved path stays a
  `Path`, so every method a macro would call on the type is undefined on that,
  and the message named `Path` rather than the type or the rule:
  `undefined macro method 'Path#constant'`. It now asks whether the path names
  a type that exists and is unexported, and says so when it does. Found by
  `habitat`.

- **The front end reads a `.iyi` file again.** Refusing `require` in a `.iyi`
  file spares the prelude's own, and the flag that says so was set in the
  driver but not in `crystal-front`, so the front-end binary refused the line
  it had just written itself. It is bench-only and ships in nothing.

- **A version bump takes effect.** `src/VERSION` and `src/IYI_VERSION` are
  compiled in with `read_file`, and the build did not depend on them, so
  changing the number changed nothing until something else did.

## 0.1.0 — 2026-08-18

The first release. There is nothing to compare it against, so this says what is
in it rather than what changed, and what a later version will have to keep
faith with.

### The language

Four rules, and everything else follows from them (SPEC.md):

- **R-1** A module is the unit of compilation. `import` forms a DAG, and
  compiling a module reads its imports' declarations, never their bodies.
- **R-2** Everything a module exports (`pub`) writes down full parameter and
  return types.
- **R-2b** `using` brings exported names into unqualified scope, written by the
  consumer.
- **R-3** No open classes. `impl Trait for Type` lives in the module that
  declares the trait or the one that declares the type.

Traits with defaults and associated types, generic impls with `forall`, errors
as ordinary union members with `!` propagation, `defer` scoped to the block,
and Crystal's syntax otherwise: union types, nil-safety, blocks, local
inference, macros.

### The artifact

0.1.0 shipped `.iyimod` **format v19**: declarations, macros, bodies that have
to travel, object code, and a checksum per section. Its artifacts were locked
to the exact compiler build, so another build refused and rebuilt them rather
than migrating them. The 0.2.0 rule above replaces that build identity with
released version, target and flags, while development versions keep the commit.

`iyi build --emit-iyimod DIR` writes them, `--use-iyimod DIR` builds against
them, and `iyi mod dump` prints one as text.

### The tool

`iyi` takes `build`, `run`, `mod`, `env`, `clear_cache`, `tool`, `version` and
`help`. `crystal` is the same compiler under its own name, and it still
compiles `.cr` files. `eval` is deliberately not on iyi's list: it has no
filename, so it gets Crystal's prelude and Crystal's rules, and a command that
answers in another language is worse than one that says where it went.

### Measured

One machine, release compiler, best of seven, seconds. A 30-module,
7,208-line project, rebuilt after changing one line in one module:

| | iyi | Crystal | `go build` |
|---|---|---|---|
| rebuild after one edit | **0.13** | 1.17 | 0.16 |

The same edit with every module read from source instead of from artifacts
costs 0.23 s, which is what R-1 is worth on this project. A full build of a
6,900-line program from scratch is 0.24 s against `go build`'s 0.09 s, which is
where iyi loses. `python3 bench/incremental.py` and `python3
bench/build_speed.py` print both, and refuse to time programs that do not agree
on their output.

### Not in this release

iyi's own 0.1.0 prelude had no IO beyond `puts` and no concurrency; SPEC.md
III.4 specified concurrency and none was built. There was no package manager,
standard library or self-hosting, and the release supported Linux x86-64 only.
`derive` macros did not cross modules. The own prelude was 1,184 lines, its
collections were small, and `a[-1]` raised rather than indexing from the end.
The formatter did not know iyi's syntax: `iyi tool format` said so and left
`.iyi` files alone.

### Provenance

A fork of [Crystal](https://github.com/crystal-lang/crystal) at 1.22.0-dev,
Apache 2.0 with Swift exception, Copyright 2012-2026 Manas Technology
Solutions. The backend, the GC and the type checker are Crystal's work. The
compiler reports itself as `Crystal 1.22.0-dev` because that is what it is, and
it is bootstrapped by released Crystal 1.21.0, which is the version CI pins
and the one to install if you are building this from source.

Two bugs in Crystal's own compiler were found here and fixed in this fork; they
belong upstream and are separate commits for that reason:

- `Crystal.relative_filename` chopped the working directory off any path that
  merely began with its name, so a build in `/x/crystal` with a cache in
  `/x/crystal-cache` wrote its object files to `-cache/…`.
- The cache cleaner deleted the directory of a build that was still running,
  because it keeps the ten most recently modified directories and a build stops
  looking recent while its units sit in an optimization pass.
