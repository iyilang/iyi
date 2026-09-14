#!/usr/bin/env python3
"""Fails when Crystal's name stands in for iyi's own.

iyi is a permanent fork. Crystal is the language it came from, not its
identity, so the name is allowed only where it genuinely denotes Crystal: the
standard library a `--crystal` program compiles against, the licence and
provenance, the compatibility binary, and upstream's documentation kept beside
ours. Everywhere else it is leakage, and leakage is what this refuses.

    python3 bench/identity_floor.py            # check
    python3 bench/identity_floor.py --list     # every unallowed occurrence

Two layers, because either alone is fooled. PATHS catches a whole tree that
should have been renamed. LINES catches a name inside a file that was otherwise
cut over, which is the shape a skipped hunk leaves behind.

A new match is not automatically wrong. It is a claim that this occurrence
denotes Crystal rather than iyi, and the way to make that claim is to add it
here, in the same commit, with the reason. What this refuses is the version
where the name creeps back and nobody notices.

This is written in Python rather than shell on purpose: the first draft used
`grep -P`, the `grep` on the PATH inside a script has no `-P`, and every
allowlist test errored and failed OPEN. A gate that cannot fail is worse than
no gate, so the matching is done here where the semantics are exact.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Trees and files that are Crystal's, not iyi's. Each carries its reason.
ALLOWED_PATHS: list[tuple[str, str]] = [
    # Crystal's standard library. A `--crystal` program compiles against it,
    # and so does the compiler, which is a Crystal program (SPEC.md B.2).
    (r"^src/(?!compiler/|iyi/)", "Crystal's standard library"),
    (r"^spec/std/", "that library's own specs"),
    (r"^spec/primitives/", "that library's primitives specs"),
    # Crystal's compiler, tested as Crystal: these suites assert Crystal's
    # semantics on `.cr` sources through the compatibility binary, and their
    # fixtures are Crystal programs naming Crystal's runtime symbols.
    (r"^spec/compiler/(codegen|semantic|parser|formatter|lexer|loader)/", "Crystal's own semantics, tested as Crystal"),
    (r"^spec/compiler/data/", "Crystal source fixtures"),
    (r"^spec/(syntax|std|wasm32_std)_spec\.cr$", "that library's spec entrypoints"),
    (r"^spec/support/", "the harness those suites share"),
    (r"^scripts/", "generators that emit Crystal's stdlib tables"),
    # Drives the compatibility binary by the name a user types.
    (r"^spec/compiler-cli/", "compatibility binary's CLI specs"),
    # The self-hosting lexer's oracle. It proves the iyi-written lexer agrees
    # token for token with the frontend iyi is still bootstrapped from, so the
    # other language is the thing being compared against, by name.
    (r"^bench/selfhost_lexer_exercise\.sh$", "the frontend the selfhost lexer is checked against"),
    # The self-hosting parser's oracle, for the same reason as the lexer's: it
    # parses each fixture with the iyi parser and with the frontend iyi is
    # still bootstrapped from, and requires the normalised trees identical.
    # The other language is what is being compared against, so it is named.
    (r"^bench/selfhost_parser_exercise\.sh$", "the frontend the selfhost parser is checked against"),
    # The self-hosting normalizer's oracle, for the same reason as the
    # parser's: it normalises each fixture with the iyi normalizer and with
    # the frontend iyi is still bootstrapped from, and requires the dumped
    # trees identical. The other language is the thing being compared against.
    (r"^bench/selfhost_normalizer_exercise\.sh$", "the frontend the selfhost normalizer is checked against"),
    # The self-hosting bind tool's oracle, for the same reason as the
    # normalizer's: it analyzes each fixture with the iyi bind tool and with
    # the frontend iyi is still bootstrapped from, and requires the bound
    # methods identical. The other language is the thing being compared against.
    (r"^bench/selfhost_bind_exercise\.sh$", "the frontend the selfhost bind tool is checked against"),
    # The self-hosting artifact format's oracle: it compares what the iyi
    # artifact reader and writer produce against what the frontend emits, and
    # requires the artifacts and dumps identical. The other language is the
    # frontend being compared against.
    (r"^bench/selfhost_iyimod_exercise\.sh$", "the frontend the selfhost artifact format is checked against"),
    # The self-hosting command driver's oracle. It verifies dispatch, exit
    # codes, and usage output against the frontend iyi is still bootstrapped
    # from, requiring identical observables for every command vector.
    (r"^bench/selfhost_command_exercise\.sh$", "the frontend the selfhost command driver is checked against"),
    # The self-hosting semantic visitor's oracle. It verifies type and method
    # declaration tables against the frontend iyi is still bootstrapped from,
    # requiring identical declarations for every fixture.
    (r"^bench/selfhost_semantic_exercise\.sh$", "the frontend the selfhost semantic visitor is checked against"),
    # The self-hosting type system's oracle. It verifies type calculation,
    # unification, and rendered names against the frontend iyi is still
    # bootstrapped from, requiring identical types for every fixture.
    (r"^bench/selfhost_types_exercise\.sh$", "the frontend the selfhost type system is checked against"),
    # The self-hosting macro engine's oracle. It verifies macro expansion
    # ASTs against the frontend iyi is still bootstrapped from, requiring
    # identical expanded ASTs for every fixture.
    (r"^bench/selfhost_macros_exercise\.sh$", "the frontend the selfhost macro engine is checked against"),
    # The self-hosting build daemon's oracle. It verifies socket path selection,
    # over-limit refusal, candidate search order, and error text against the
    # frontend iyi is still bootstrapped from.
    (r"^bench/selfhost_daemon_exercise\.sh$", "the frontend the selfhost build daemon is checked against"),
    # The self-hosting platform support oracle. It verifies target triple parsing,
    # flags, naming, and linker command generation against the frontend iyi is
    # still bootstrapped from.
    (r"^bench/selfhost_platform_exercise\.sh$", "the frontend the selfhost platform support is checked against"),
    # The self-hosting code generator's oracle. It verifies emitted LLVM IR
    # and native object execution against the frontend iyi is still bootstrapped
    # from, requiring identical emitted IR and execution for every fixture.
    (r"^bench/selfhost_codegen_exercise\.sh$", "the frontend the selfhost codegen is checked against"),
    # The self-hosting artifact wiring oracle. It verifies that the pure iyi
    # artifact tool wired behind --selfhost produces output identical to the
    # frontend across all corpus modules.
    (r"^bench/selfhost_mod_wiring_exercise\.sh$", "the frontend the selfhost artifact wiring is checked against"),
    # The self-hosting formatter wiring oracle. It verifies that the pure iyi
    # formatter tool wired behind --selfhost produces output identical to the
    # frontend across all corpus files.
    (r"^bench/selfhost_format_wiring_exercise\.sh$", "the frontend the selfhost formatter wiring is checked against"),
    # The self-hosting parser wiring oracle. It verifies that the pure iyi
    # front end wired behind --selfhost produces output identical to the
    # frontend across the parser fixtures and samples tree.
    (r"^bench/selfhost_parser_wiring_exercise\.sh$", "the frontend the selfhost parser wiring is checked against"),
    # The self-hosting end-to-end compiler oracle. It verifies whole-program
    # compilation, execution parity, and dependency floors against the
    # frontend iyi is still bootstrapped from.
    (r"^bench/selfhost_compile_exercise\.sh$", "the frontend the selfhost compiler is checked against"),
    # The UUID exercise records a spelling iyi cannot have: `v1!`..`v8!` are
    # the other language's names, and `!` is an iyi operator. Naming the
    # language there is the whole point of the note.
    (r"^bench/std_utility_types_exercise\.(iyi|sh)$", "a spelling only the other language has"),
    # `tool bind` runs under `crystal`, on Crystal source, against Crystal's
    # library: it is how a shard is bound for an iyi consumer to import. The
    # bench drives that binary and names it throughout.
    (r"^bench/bind_speed\.py$", "a bench that drives the compatibility binary"),
    # Provenance, licence, copyright.
    (r"^README\.crystal\.md$", "upstream's README, kept"),
    (r"^LICENSE", "Crystal's licence"),
    (r"^NOTICE\.md$", "Crystal's copyright"),
    # The compatibility binary, shipped so `.cr` sources still build.
    (r"^bin/crystal", "the compatibility binary"),
    (r"^samples/crystal/", "programs that exist to use Crystal's library"),
    # Upstream's manual pages, artwork, and editor integration keyed on
    # Crystal's own type names.
    (r"^doc/man/crystal", "upstream's manual pages"),
    (r"^doc/assets/", "upstream's artwork"),
    (r"^etc/", "debugger and editor integration"),
    # Bootstrap toolchain lookup.
    (r"^Makefile\.win$", "bootstrap toolchain lookup"),
    (r"^shell\.nix$", "bootstrap toolchain lookup"),
    (r"^\.gitattributes$", "language detection for the .cr tree"),
    (r"^CODE_OF_CONDUCT\.md$", "Crystal's code of conduct, kept"),
    (r"^GC_DESIGN\.md$", "cites gcry, Crystal's collector, as prior art"),
    (r"^src/compiler/crystal\.cr$", "the compatibility binary's entrypoint"),
    # This gate names Crystal in order to say what it forbids, so it cannot be
    # subject to itself. Its own correctness is proved by the pass/fail probe
    # in `main`, not by its prose.
    (r"^bench/identity_floor\.py$", "the gate's own prose"),
    (r"^src/compiler/crystal_front\.cr$", "the front-end bench binary's entrypoint"),
    # Crystal's stdlib highlighter, and Crystal programs that used the compiler
    # as a library, still `require "compiler/crystal/syntax"`. This directory
    # is the shim that makes that path resolve.
    (r"^src/compiler/crystal/", "shims so Crystal's stdlib can still require the compiler"),
    # `init` and `spec` are in CRYSTAL_ONLY: `iyi init` answers "it belongs to
    # Crystal", so this file is only ever reached under the crystal name and its
    # banners are correct as written.
    (r"^src/compiler/iyi/tools/init\.cr$", "a Crystal-only command's implementation"),
    # These measure the compatibility binary against iyi, so naming it is the
    # measurement. `bench/identity_floor.py` is excluded above for its prose.
    (r"^bench/(build_speed|artifact_speed|incremental|macro_cost|runtime)", "benches that measure iyi against Crystal's library"),
    (r"^bench/(incremental|build_speed)/", "the generators those benches drive"),
    (r"^spec/(debug|spec_helper\.cr)", "the spec harness driving both binaries"),
    (r"^bin/check-compiler-flag$", "builds the compatibility binary twice"),
    (r"^bench/(machine_probe|dependency_floor)", "measures the compatibility binary and its libraries"),
    (r"^spec/compiler/util_spec\.cr$", "specs Crystal's own util module"),
    (r"^samples/iyi/", "programs whose comments compare iyi with Crystal"),
]

# Lines that name Crystal legitimately inside a file that is otherwise iyi's.
ALLOWED_LINES: list[tuple[str, str]] = [
    (r"--crystal", "the compatibility mode's own flag"),
    (r"crystal_prelude", "the flag recording a build against Crystal's standard library"),
    # The ported command driver is checked byte for byte against the driver it
    # replaces, and that driver prints this sentence. Changing the wording here
    # would fail `bench/selfhost_command_exercise.sh` rather than rename
    # anything a user sees: nothing dispatches through this port yet. When it
    # takes over, this sentence becomes iyi's to write and this entry goes.
    (r"Cannot initialize Crystal project", "the replaced driver's own wording, held for parity"),
    (r"crystal_front", "the front-end bench binary"),
    (r"CRYSTAL_ONLY", "the list of commands that belong to Crystal"),
    (r"Crystal 1\.", "the upstream version this forked from"),
    (r"fork of Crystal", "provenance"),
    (r"README\.crystal", "provenance"),
    (r"Manas Technology", "copyright holder"),
    (r"crystal-lang\.org", "upstream's site"),
    (r"github\.com/crystal-lang", "upstream's repository"),
    (r"[Cc]opyright.*Crystal", "copyright"),
    # Three arrivals from upstream's tarball work. `crystal/syntax_highlighter`
    # is a real path inside Crystal's standard library, and the reason the
    # tarball has to ship `compiler/`: the highlighter requires
    # `compiler/crystal/syntax`, Crystal's exception page requires the
    # highlighter, and Kemal requires the page. Naming it is the finding.
    (r"crystal/syntax_highlighter", "a path inside Crystal's standard library"),
    (r"Crystal::SyntaxHighlighter", "a class inside Crystal's standard library"),
    # Upstream's packaging, cited because iyi took a rule from it: their
    # build refuses a compiler that names a host library, and iyi's
    # package refuses the same thing. A reader who cannot find the file
    # cannot check the claim, so the filename travels.
    (r"omnibus/config/software", "a path inside upstream's packaging repository"),
    # Provenance of a *rule*, not a naming slip: where the fork keeps an
    # upstream semantic (lazy typing, in `iyi check`'s header) the honest
    # comment says which language the rule came from.
    (r"inherited from Crystal", "provenance of an inherited semantic"),
    # The artifact header records which library a module was built against, and
    # an import across the two is refused by name in both directions. The field
    # is called what it means (SPEC.md IV.5).
    (r"crystal_library", "the header field naming the other library"),
    # Crystal's daemon is its own binary with its own socket: `iyi` and
    # `crystal` are one compiler with two command surfaces, and each looks up a
    # server named after the binary that was typed.
    (r"CRYSTAL_DAEMON_(BIN|SOCKET)", "the other command surface's own daemon"),
    # A message that has to name the language the *file* is written in: this
    # compiler reads both, and reporting a `.iyi` file of unreadable bytes as
    # "not a valid Crystal source file" named the wrong one. The line is the
    # choice between them, so it mentions both by necessity.
    (r'ends_with\?\(".iyi"\) \? "iyi" : "Crystal"', "the line that picks which language a file is"),
    (r"Crystal (caches|runs|takes)", "a sentence about the other language"),
    # `iyi migrate` and `iyi bind` are about the other language by
    # definition: a Crystal project, a Crystal file kept as Crystal, the
    # tree's own output compared against what Crystal answered. Their
    # gates say "Crystal" because that is the input.
    (r"(a|the|as|ordinary|becomes|is|in|not|One|A) Crystal", "a sentence about the other language"),
    (r"which is the lookup Crystal performs", "a sentence about the other language"),
    (r"every Crystal bang|Crystal ignores", "a sentence about the other language's rule"),
    (r"(are|stay|stays|stayed|still) Crystal", "a sentence about files that keep being the other language"),
    (r"crystal_shards", "the module a migrated tree keeps its shard requires in"),
    (r"crystal_shop|crystal\.(out|err)|CRYSTAL=|\$CRYSTAL\b", "the gate's own Crystal arm"),
    (r"struct Int32", "the fixture's reopening of a library type"),
    (r"stays Crystal", "where a reopening belongs (SPEC.md III.6)"),
    (r"Crystal::EventLoop", "a class inside Crystal's standard library"),
    # Crystal's DWARF reader, arriving with the 1.22 merge: the spec exercises
    # `Crystal::DWARF` directly, and that is the namespace the class is
    # actually in, on the `--crystal` side this fork keeps whole.
    (r"Crystal::DWARF", "a namespace inside Crystal's standard library"),
    # A constant `openssl_ext` defines inside its own `lib`, named for the
    # language whose `IO` it bridges. A boundary that reopens a namespace the
    # library already has must not assign it twice, and naming the one that
    # caught it is the finding.
    (r"CRYSTAL_BIO", "a constant a shard defines, named for the other language"),
    # The GitHub organisation two of the shards these gates pin are published
    # under. A dependency's coordinates are not prose and there is no other
    # spelling of them: `crystal-community/jwt` is where `shards install` looks.
    (r"github: crystal-community/", "a shard's own coordinates"),
    # And the driver's, for the same reason: `crystal-lang/crystal-sqlite3` is
    # where `shards install` looks and there is no other spelling of it.
    (r"github: crystal-lang/", "a shard's own coordinates"),
    # `samples/iyi/hello.iyi` line 115 builds `User.new("crystal")`, so the
    # greeting it prints carries that name. The hero quotes the run, and the
    # word is data the program printed rather than a language being renamed.
    (r"Hello, crystal!", "a line a sample prints, quoted from a real run"),
    (
        r"Crystal's (own|library|licence|license|compiler|semantics|stdlib|"
        r"standard|prelude|codegen|cache|interpreter|fibers|ecosystem|list|"
        r"requirements|answer|version|numbers|README)",
        "a sentence about the other language",
    ),
    (
        r"the Crystal (project|language|compiler|standard|library|ecosystem|"
        r"binary|bootstrap|stdlib)",
        "a sentence about the other language",
    ),
    (r"as Crystal\b", "a comparison with the other language"),
    (r"than Crystal\b", "a comparison with the other language"),
    (r"Crystal\b.*(shard|Kemal|ecosystem)", "the ecosystem it borrows"),
    # The compiler is a Crystal program, built by a Crystal bootstrap, and
    # ships a second binary called `crystal`. Naming that toolchain is not
    # leakage: it is the build saying which compiler compiles this one.
    (r"bin/crystal|\.build/crystal|make crystal|crystallang/crystal", "the bootstrap and compatibility binaries"),
    (r"crystal (spec|build|run|tool|env|deps|version)\b", "a command run against those binaries"),
    (r"CRYSTAL_(VERSION|PATH|HAS_WRAPPER|SPEC_|ONLY|BIN|ENV|FORMATTERS|WORKERS|BOOTSTRAP_)", "read by Crystal's runtime, bootstrap or wrapper"),
    (r"__crystal_|crystal_type_id|crystal_instance_type_id|LibCrystalMain", "Crystal's runtime ABI symbols"),
    (r"Crystal::(LLVM_VERSION|VERSION|DESCRIPTION|ABI)", "constants the bootstrap injects"),
    (r"Crystal\.format|module Crystal\b", "Crystal's own API, called or reopened"),
    (
        r"language = source\.filename",
        "labels invalid .cr input as the compatibility language",
    ),
    (r"```crystal", "a fenced code block's language tag"),
    (r"samples/crystal/", "programs that exist to use Crystal's library"),
    (r"src/crystal/", "a path inside Crystal's standard library"),
    (r"name: crystal\b", "the CI artifact holding that binary"),
    (r"sdogruyol/gcry|gcry", "Crystal's collector, cited as prior art"),
    (r"valid Crystal source", "the formatter's message on a `.cr` source"),
    (r"Crystal (could not|does not|reads|ships|has|is the language|cannot|of course)", "a sentence about the other language"),
    (r"(and|as|a|an|ordinary|shared|the) Crystal (one|program|shard|source|binary|proc|truth)", "a sentence about the other language"),
    (r"Crystal's", "a sentence about the other language"),
    # The Makefile's targets and the binaries they build. `make crystal` builds
    # the compatibility binary, `crystal-front` the front-end bench binary, and
    # `crystal-daemon` the build daemon that binary execs. Those are their names.
    (r"crystal-front|crystal-daemon|IYI_DAEMON_BIN", "binaries named for the compatibility binary"),
    (r"^\.PHONY: crystal|^crystal[:-]|^all: crystal|^build: crystal|make clean crystal|install crystal", "Makefile targets building those binaries"),
    (r"share/crystal|doc/crystal|DATADIR\)/doc", "where Crystal's library and docs install"),
    (r"CRYSTAL \?=|previous crystal compiler", "the bootstrap compiler the build reads"),
    # Crystal's own API, called from a compiler that is a Crystal program.
    (r"Crystal::(Digest|System|Macros|Repl)", "Crystal's stdlib API"),
    (r'require "crystal/', "a require of Crystal's stdlib"),
    (r"crystal_(malloc|realloc|raise|type_id|instance_type_id)", "Crystal's runtime ABI symbols"),
    # The `Crystal` module the compiler DEFINES in the program it compiles:
    # a program reads `Crystal::VERSION`, so the constant is the language's.
    (r"define_crystal_|types\[\"Crystal\"\]|@crystal\b|crystal\.types", "the Crystal module a compiled program reads"),
    # Crystal's library, licence, docs and shell completions install under
    # Crystal's name because they are Crystal's files.
    (r"DATADIR\)/(crystal|licenses/crystal|bash-completion|zsh|fish)", "where Crystal's files install"),
    (r"completions/crystal|_crystal|crystal\.fish", "Crystal's shell completions"),
    (r"clean_crystal|crystal-next", "the compatibility binary's build rules"),
    # A backtick-quoted `crystal ...` is the compatibility binary, named as a
    # command. Prose and comments say it constantly, because half the point of
    # the fork is explaining which binary does what.
    (r"`crystal[ `-]|`\.?/?bin/crystal", "the compatibility binary, quoted as a command"),
    (r"/crystal-cache|/x/crystal|/tmp/x/crystal", "a path in the prefix-is-not-a-parent example"),
    (r"Crystal name|a Crystal (program|project|file|one|source|style|proc)", "a sentence about the other language"),
    (r"Crystal (type|types|code|docs|projects|which this compiler)", "a sentence about the other language"),
    (r"in Crystal\b|to Crystal\b|belongs to Crystal|of Crystal\b", "a sentence about the other language"),
    (r"crystal\.\*|Usage: crystal|print Crystal environment|crystal <command>", "the compatibility binary's own banner and log source"),
    (r'program_name : String = "crystal"', "the documented default, set by the entrypoint"),
    (r"with crystal\]|the crystal compiler package|~/\.cache/crystal", "the compatibility binary's build and cache"),
    (r"'crystal deps' has been removed", "a message about a removed Crystal command"),
    (r"Crystal (requires|spells|duck-types|monomorphises|exception|Core Team)", "a sentence about the other language"),
    (r"the way Crystal|way Crystal does|rather than a Crystal|than Crystal", "a comparison with the other language"),
    (r"crystal@manas\.tech", "the copyright holder's address"),
    (r'"Crystal"\.scan|/Crystal/|"Crystal"\.', "the word as test data in a macro spec"),
    (r"Crystal::Rx", "the compiler's own engine, named for its namespace"),
    (r'parsed\["crystal"\]|"crystal" *=>', "shards' own manifest key"),
    (r"crystal-release|src/compiler/crystal\.cr|clean_cache crystal", "the compatibility binary's build"),
    (r"names crystal in the same banner|program_name = \"crystal\"", "the spec that pins the compatibility name"),
    (r"from-crystal|reads CRYSTAL_PATH when IYI_PATH", "the spec that pins the Crystal env-var fallback"),
    # Backticks required. A bare `CRYSTAL_DAEMON` matched the Makefile's
    # `CRYSTAL_DAEMON_BIN`, which the cutover had renamed to `IYI_DAEMON_BIN`,
    # and so hid a real break: upstream's new `check_daemon_matches` expanded
    # an undefined variable, ran `--version` on a directory, and reported the
    # daemon's version as empty. An allowlist entry wide enough to cover a
    # defect is not an allowlist entry.
    (r"CRYSTAL_#\{name\}|`CRYSTAL_DAEMON(_SOCKET)?`|crystal docker image", "the fallback that keeps Crystal's env vars working"),
    (r"Crystal on the machine|a Crystal\b", "a sentence about the other language"),
    # Comments citing Crystal's own source, DWARF producer strings, and the
    # version banner's "a fork of Crystal X" clause. All name the other
    # language or upstream's files, none is a name a person is shown as ours.
    (r"crystal/(tools|dwarf|system)/", "a path inside Crystal's own source"),
    (r'"Crystal" *<<|"Crystal", is_optimised|io << "Crystal "', "the DWARF producer and version banner naming upstream"),
    (r"(compiled|interpreted|valid|future|in) Crystal\b", "a sentence about the other language"),
    (r"Crystal (only ever|refuses|injects|module|needs|repository|path)", "a sentence about the other language"),
    (r"crystal (was compiled|code|repository)|in crystal\b|\.crystal\b", "a sentence about the other language"),
    (r"Crystal source files", "the formatter's description of `.cr` input"),
    (r"\$crystal|\$CRYSTAL\b|\$\{CRYSTAL\}|regex crystal", "a shell variable and a type-name list"),
    (r"Crystal (resolves|infers|compiles|writes|builds|already|narrows|standard library)", "a sentence about the other language"),
    (r"other Crystal|the crystal\b|as crystal\b|CONST \(Crystal\)", "a sentence about the other language"),
    (r"crystal-lang/crystal#", "an upstream issue reference"),
    (r"^\s*#\s+Crystal (and|is|are|does|has|was)\b", "a wrapped sentence about the other language"),
    (r"^\s*#\s*(is|are) Crystal\b", "a wrapped sentence about the other language"),
    # A comment whose sentence about the other language wraps, leaving
    # `Crystal` as the last word on the line with its verb on the next.
    (r"(#|\*) .*\bCrystal$", "a wrapped sentence about the other language"),
    (r'"cr", "crystal"|crystal language tag', "the fenced-block language tag the formatter normalises"),
    (r'File\.join\(iyi_exec_path, "crystal"\)', "the spec runner finding the Crystal-only binary"),
    (r"Crystal (docker|is unable|compiler built with)", "the bootstrap toolchain and its diagnostics"),
    (r"Codegen \(crystal\)", "a progress label for the Crystal codegen stage"),
    (r"predefined types|C functions to Crystal procs", "Crystal's own type setup"),
    # 0.2.0 ships Crystal's standard library inside the tarball so `--crystal`
    # works in what people download. It installs under `share/iyi/crystal`,
    # which names the library it holds.
    (r"share/iyi/crystal|/iyi/crystal|samples/crystal", "where Crystal's library ships inside the tarball"),
    (r"\$\(O\)/crystal", "the compatibility binary the build compares against"),
    (r'compiler/crystal/syntax', "the shim path Crystal's stdlib requires"),
    (r"Compatible with Crystal", "what the shard manifest says iyi is compatible with"),
    (r"where Crystal uses the plain verb", "a sentence about the other language"),
    # `bench/doc_numbers.py` holds the patterns that match the docs' own
    # sentences, so it quotes SPEC's "lines, Crystal, forked" verbatim.
    (r"lines, Crystal, forked", "a pattern matching SPEC's own sentence"),
    # `tool bind` writes an artifact for a `--crystal` consumer, so two of the
    # things it carries are Crystal's and are named for it. `crystal_types` is
    # the set of names that consumer already has from Crystal's library, which
    # is what decides whether a bound shard may name a type. `crystal_requires`
    # is the `require`s a shard's source made that resolved into Crystal's
    # library, replayed in the artifact because the consumer's prelude does not
    # hold every file of it. Renaming either would claim a name iyi does not own.
    # `crystal_private` is the other half of that question: the names Crystal's
    # library declares `private`, which a bound shard may *hold* a value of and
    # may not write down. Same table, same language, one predicate apart.
    (r"crystal_types|crystal_requires|crystal_private", "what a --crystal consumer already has, carried by name"),
    (r"a \*Crystal\* source", "a sentence about the other language"),
]

PATH_RES = [(re.compile(p), why) for p, why in ALLOWED_PATHS]
LINE_RES = [(re.compile(p), why) for p, why in ALLOWED_LINES]
NEEDLE = re.compile("crystal", re.IGNORECASE)


def tracked_files() -> list[str]:
    # `-c safe.directory=*` is required inside the crystal docker image:
    # checkout writes files owned by a different user than the container,
    # git 2.35+ refuses `ls-files` with exit 128, and a gate that crashes
    # is a gate that is not checking.
    #
    # `--others --exclude-standard` adds files that exist but are not staged
    # yet, so a local run sees what CI will see. Without it a new file was
    # invisible until `git add`, every local run passed, and the gate first
    # spoke on the pull request. Twice, the second time on this file's own
    # sibling. Ignored files stay ignored, which is what `--exclude-standard`
    # is for.
    def ls(*args: str) -> list[str]:
        return subprocess.run(
            ["git", "-c", "safe.directory=*", "ls-files", *args],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()

    return sorted(set(ls()) | set(ls("--others", "--exclude-standard")))


def path_allowed(rel: str) -> str | None:
    for rx, why in PATH_RES:
        if rx.search(rel):
            return why
    return None


# In prose, `Crystal` capitalised is the other language's proper name, and the
# fork explaining its relationship to it is the point of these documents. What
# stays checked in them is lowercase `crystal`, because that is what a binary, a
# path, a command, an environment variable and a URL are spelled with - and a
# wrong one of those sends a person somewhere real. The security-advisory link
# in CODE_OF_CONDUCT.md pointed at another owner's repository, and that is the
# shape this keeps looking for while letting the prose alone.
# `.mdx` is a lesson: prose with components in it, and the same reasoning
# applies to it as to `.md`.
PROSE_DOC = re.compile(r"\.mdx?$")
LOWER_NEEDLE = re.compile(r"crystal")


def line_allowed(line: str, rel: str = "") -> str | None:
    for rx, why in LINE_RES:
        if rx.search(line):
            return why
    prose = PROSE_DOC.search(rel)
    if prose and not LOWER_NEEDLE.search(line):
        return "the other language's name, in prose"
    return None


def main() -> int:
    show_all = "--list" in sys.argv
    path_hits: list[str] = []
    line_hits: list[tuple[str, int, str]] = []

    for rel in tracked_files():
        if path_allowed(rel):
            continue

        if NEEDLE.search(rel):
            path_hits.append(rel)

        fp = REPO / rel
        try:
            text = fp.read_text()
        except (UnicodeDecodeError, OSError, IsADirectoryError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if NEEDLE.search(line) and not line_allowed(line, rel):
                line_hits.append((rel, n, line.strip()[:120]))

    if not path_hits and not line_hits:
        print("iyi owns its name")
        return 0

    print("CRYSTAL'S NAME IS STANDING IN FOR IYI'S")
    print()
    limit = None if show_all else 30
    for rel in path_hits[:limit]:
        print(f"PATH  {rel}")
    if limit and len(path_hits) > limit:
        print(f"      ... and {len(path_hits) - limit} more paths")
    print()
    for rel, n, line in line_hits[:limit]:
        print(f"LINE  {rel}:{n}  {line}")
    if limit and len(line_hits) > limit:
        print(f"      ... and {len(line_hits) - limit} more lines")

    by_file: dict[str, int] = {}
    for rel, _, _ in line_hits:
        by_file[rel] = by_file.get(rel, 0) + 1
    print()
    print(f"paths: {len(path_hits)}    lines: {len(line_hits)}    files: {len(by_file)}")
    if by_file and not show_all:
        print()
        print("worst files:")
        for rel, n in sorted(by_file.items(), key=lambda kv: -kv[1])[:10]:
            print(f"  {n:6}  {rel}")
    print()
    print("Each is a place iyi is called Crystal. If an occurrence genuinely")
    print("denotes the other language, add it to ALLOWED_PATHS or ALLOWED_LINES")
    print("in this script, in the same commit, and say why.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
