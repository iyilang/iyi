all: ##

-include Makefile.local # for optional local options e.g. threads

# Recipes for this Makefile

## Build the compiler and `iyi`, then run a program with ./bin/iyi
##   $ make
## Build the compiler with progress output
##   $ make progress=1
## Clean up built files then build the compiler
##   $ make clean crystal
## Build the compiler in release mode
##   $ make crystal release=1
## Build all assets for a package install (compiler and manpages)
##   $ make build
## Build and install crystal package
##   $ make build && sudo make install
## Run tests
##   $ make test
## Run stdlib tests
##   $ make std_spec
## Run compiler tests
##   $ make compiler_spec
## Run generators (Unicode, SSL config, ...)
##   $ make -B generate_data

CRYSTAL ?= crystal## which previous crystal compiler use

release            ?= ## Compile in release mode
stats              ?= ## Enable statistics output
progress           ?= ## Enable progress output
threads            ?= ## Maximum number of threads to use
debug              ?= ## Add symbolic debug info
verbose            ?= ## Run specs in verbose mode
junit_output       ?= ## Path to output junit results
static             ?= ## Enable static linking
target             ?= ## Cross-compilation target
check              ?= ## Enable only check when running format
order              ?= random## Enable order for spec execution (values: "default" | "random" | seed number)
deref_symlinks     ?= ## Dereference symbolic links for `make install`
sequential_codegen ?= $(if $(filter 0,$(supports_mt)),true,)## Enforce sequential codegen in compiler builds.

O            := .build
# iyi: the two version files are compiled in with `read_file`, so a build that
# does not depend on them says the old number after the number changes.
SOURCES      := $(shell find src -name '*.cr') src/VERSION src/IYI_VERSION
SPEC_SOURCES := $(shell find spec -name '*.cr')
MAN1PAGES    := $(patsubst doc/man/%.adoc,man/%.1,$(wildcard doc/man/*.adoc))
override FLAGS += -D strict_multi_assign -D preview_overload_order $(if $(release),--release )$(if $(stats),--stats )$(if $(progress),--progress )$(if $(threads),--threads $(threads) )$(if $(debug),-d )$(if $(static),--static )$(if $(LDFLAGS),--link-flags="$(LDFLAGS)" )$(if $(target),--cross-compile --target $(target) )
# iyi: -Dwithout_iconv because iyi's String has no encoding conversion, so the
# compiler asks libiconv for nothing.
#
# -Dgc_none was tried here too and is not viable, which is worth recording so
# nobody spends the afternoon again. A compiler built without a collector emits
# invalid IR ("Load operand must be a pointer", from `LLVM::Module#verify`) on
# some runs and dies in `main_user_code` on others: the compiler is not a short
# lived process that allocates a little, it is a long walk over ASTs with
# parallel codegen and fibers, and `src/gc/none.cr` never frees. So the compiler
# keeps bdw-gc and the programs it builds do not, which is the split SPEC.md
# III.9 already draws. The owned collector it tracks is what ends this.
override COMPILER_FLAGS += -Dwithout_openssl -Dwithout_zlib -Dwithout_iconv$(if $(sequential_codegen), -Dwithout_mt,)
SPEC_WARNINGS_OFF := --exclude-warnings spec/std --exclude-warnings spec/compiler --exclude-warnings spec/primitives --exclude-warnings src/float/printer --exclude-warnings src/random.cr
override SPEC_FLAGS += $(if $(verbose),-v )$(if $(junit_output),--junit_output $(junit_output) )$(if $(order),--order=$(order) )
IYI_CONFIG_LIBRARY_PATH := '$$ORIGIN/../lib/iyi'
ifndef IYI_CONFIG_BUILD_COMMIT
	IYI_CONFIG_BUILD_COMMIT := $(shell git rev-parse --short HEAD 2> /dev/null)
endif
IYI_CONFIG_PATH := '$$ORIGIN/../share/crystal/src'
ifndef BASE_CRYSTAL_VERSION
	BASE_CRYSTAL_VERSION := $(shell $(CRYSTAL) env CRYSTAL_VERSION)
endif
ifndef CRYSTAL_VERSION
	CRYSTAL_VERSION := $(shell cat src/VERSION)
endif
ifndef SOURCE_DATE_EPOCH
	SOURCE_DATE_EPOCH := $(shell (cat src/SOURCE_DATE_EPOCH || (git show -s --format=%ct HEAD || stat -c "%Y" Makefile ||stat -f "%m" Makefile)) 2> /dev/null)
endif
check_lld := command -v ld.lld >/dev/null && case "$$(uname -s)" in MINGW32*|MINGW64*|Linux) echo 1;; esac
ifeq ($(shell $(check_lld)),1)
  EXPORT_CC ?= CC="$(CC) -fuse-ld=lld"
endif
override EXPORTS += \
  IYI_CONFIG_BUILD_COMMIT="$(IYI_CONFIG_BUILD_COMMIT)" \
  IYI_CONFIG_PATH=$(IYI_CONFIG_PATH) \
  SOURCE_DATE_EPOCH="$(SOURCE_DATE_EPOCH)"
override EXPORTS_BUILD += \
	$(EXPORT_CC) \
	IYI_CONFIG_LIBRARY_PATH=$(IYI_CONFIG_LIBRARY_PATH)
SHELL = sh

manpages_gz := $(patsubst %.1,%.1.gz,$(MAN1PAGES))

ifeq ($(LLVM_VERSION),)
	ifndef LLVM_CONFIG
  	LLVM_CONFIG := $(shell src/llvm/ext/find-llvm-config.sh)
	endif
	LLVM_VERSION := $(if $(LLVM_CONFIG),$(shell "$(LLVM_CONFIG)" --version 2> /dev/null))
endif

# FIXME: Crystal docker images before 1.8 can't build a functional compiler
# with MT because the bundled LLVM version is buggy (roughly LLVM < 15)
# See https://github.com/crystal-lang/crystal/pull/16380
supports_mt := $(if $(filter 1.8.0,$(shell printf "%s\n%s" "1.8.0" "$(BASE_CRYSTAL_VERSION)" | sort -V | tail -n1)),0,1)

LLVM_EXT_DIR = src/llvm/ext
LLVM_EXT_OBJ = $(LLVM_EXT_DIR)/llvm_ext.o
CXXFLAGS     += $(if $(debug),-g -O0)

# MSYS2 support (native Windows should use `Makefile.win` instead)
ifeq ($(OS),Windows_NT)
EXE     := .exe
WINDOWS := 1
else
EXE     :=
WINDOWS :=
endif
CRYSTAL_BIN := crystal$(EXE)
# The build daemon must be single-threaded: it forks a child per build, and only
# the forking thread survives a fork, so a multi-threaded runtime would hand the
# child a broken one. `crystal daemon start` execs this binary.
CRYSTAL_DAEMON_BIN := crystal-daemon$(EXE)
# iyi: its own server, because a daemon is the compiler it was built from. `iyi`
# and `crystal` are one compiler with two preludes and two command surfaces, and
# `iyi daemon start` looks for a sibling named after the binary that was typed.
IYI_DAEMON_BIN := iyi-daemon$(EXE)

# iyi: what a downloadable build of iyi is called.
IYI_VERSION ?= $(shell cat src/IYI_VERSION)
IYI_PACKAGE := iyi-$(IYI_VERSION)-$(shell uname -s | tr A-Z a-z)-$(shell uname -m)

# iyi: "beside this binary", in the loader's own words — the token differs
# per platform and nothing else about the rule does.
#
# The compiler needs one shared library at *runtime* that a fresh machine
# has no reason to own: LLVM's. A tarball that does not carry it is a
# tarball whose `bin/iyi` dies on `libLLVM.so.NN: cannot open shared object
# file` — which every release before this one shipped, invisibly, because
# the gate that unpacks the tarball ran on the machine that built it and
# found the library it had just linked against. So the package carries
# libLLVM in `lib/`, the binaries carry an rpath that finds it there, and
# CI's clean room runs the whole thing in an image with nothing on it.
# `\$$ORIGIN` and not `$$ORIGIN`: the bootstrap compiler runs its link command through a
# shell, so an unescaped token is expanded there and the binary is left
# asking for `/../lib` — which resolves to the *system* library and hides
# the bug it was written to fix. Measured, not guessed: the first cut
# shipped exactly that.
# A comma cannot be written inside a `$(if ...)` without this: make reads
# it as an argument separator.
comma := ,
ORIGIN_TOKEN := $(if $(filter Darwin,$(shell uname -s)),@loader_path,\$$ORIGIN)
# `--disable-new-dtags` earns its keep: the modern `DT_RUNPATH` applies
# only to the object that declares it, so the binary found the bundled
# libLLVM and libLLVM then went looking for *its* libedit in /usr/lib.
# The old `DT_RPATH` is inherited by the whole chain, which is what a
# self-contained package needs.
SELF_RPATH   := --link-flags='-Wl,-rpath,$(ORIGIN_TOKEN)/../lib $(if $(filter Darwin,$(shell uname -s)),,-Wl$(comma)--disable-new-dtags)'

DESTDIR ?=
PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
LIBDIR  ?= $(PREFIX)/lib
DATADIR ?= $(PREFIX)/share
DOCDIR  ?= $(DATADIR)/doc/crystal
MANDIR  ?= $(DATADIR)/man
INSTALL ?= /usr/bin/install

ifeq ($(or $(TERM),$(TERM),dumb),dumb)
  colorize = $(shell printf "%s" "$1" >&2)
else
  colorize = $(shell printf "\033[33m%s\033[0m\n" "$1" >&2)
endif

DEPS = $(LLVM_EXT_OBJ)
ifneq ($(LLVM_VERSION),)
  ifeq ($(shell test $(firstword $(subst ., ,$(LLVM_VERSION))) -ge 18; echo $$?),0)
    DEPS =
  endif
endif

check_llvm_config = $(eval \
	check_llvm_config := $(if $(LLVM_VERSION), \
	$(call colorize,Using $(or $(LLVM_CONFIG),externally configured LLVM) [version=$(LLVM_VERSION)]), \
	$(error "Could not locate compatible llvm-config, make sure it is installed and in your PATH, or set LLVM_VERSION / LLVM_CONFIG. Compatible versions: $(shell cat src/llvm/ext/llvm-versions.txt))) \
	)

.PHONY: all
# iyi: both names, because a plain `make` that leaves you with a binary called
# `crystal` and nothing called `iyi` is a confusing way to build iyi.
all: crystal iyi

.PHONY: test
test: spec ## Run tests

.PHONY: spec
spec: std_spec primitives_spec compiler_spec

.PHONY: std_spec
std_spec: $(O)/std_spec$(EXE) ## Run standard library specs
	$(O)/std_spec$(EXE) $(SPEC_FLAGS)

.PHONY: compiler_spec
compiler_spec: $(O)/compiler_spec$(EXE) ## Run compiler specs
	$(O)/compiler_spec$(EXE) $(SPEC_FLAGS)

.PHONY: primitives_spec
primitives_spec: $(O)/primitives_spec$(EXE) ## Run primitives specs
	$(O)/primitives_spec$(EXE) $(SPEC_FLAGS)

# iyi: the daemon refuses a client built from a different compiler, and it is
# right to — it holds an analysed prelude and would serve builds from the old
# one. What it cannot do is say so once: the spec sees nine failures, each
# printing two version strings, and the reason is in none of them.
#
# The mismatch is easy to arrive at and hard to see, because the build commit
# is baked in from git HEAD while make compares file times: commit, rebuild one
# of the two, and they disagree about a commit while agreeing about every line
# of code. Asked here instead, once, before the specs run.
.PHONY: check_daemon_matches
check_daemon_matches: $(O)/crystal$(EXE) $(O)/$(CRYSTAL_DAEMON_BIN)
	@client="$$($(O)/crystal$(EXE) --version | head -1)"; \
	 daemon="$$($(O)/$(CRYSTAL_DAEMON_BIN) --version | head -1)"; \
	 if [ "$$client" != "$$daemon" ]; then \
	   echo "the daemon and the compiler are different builds, so every daemon spec will fail:"; \
	   echo "  compiler: $$client"; \
	   echo "  daemon:   $$daemon"; \
	   echo "rebuild the one that is behind: make -B crystal-daemon"; \
	   exit 1; \
	 fi

.PHONY: cli_spec
# `$(O)/iyi` too: one spec here runs `iyi daemon start` to read the name it
# looks its server up by. Not `iyi-daemon` — that spec is about the lookup
# failing, so a server would be the wrong thing to have.
cli_spec: $(O)/cli_spec$(EXE) check_daemon_matches $(O)/iyi$(EXE) ## Run compiler CLI specs
	$(O)/cli_spec$(EXE) $(SPEC_FLAGS)

.PHONY: simple_smoke_test
simple_smoke_test: ## Build std specs as a smoke test
simple_smoke_test: $(O)/std_spec$(EXE)

.PHONY: smoke_test
smoke_test: ## Build std specs, compiler specs and compiler as a smoke test
smoke_test: $(O)/std_spec$(EXE) $(O)/compiler_spec$(EXE) $(O)/$(CRYSTAL_BIN)

SHELLCHECK_SOURCES := $(wildcard **/*.sh) $(wildcard **/*.bash) bin/crystal bin/check-compiler-flag scripts/git/pre-commit

.PHONY: lint-shellcheck
lint-shellcheck:
	shellcheck --severity=warning $(SHELLCHECK_SOURCES)

.PHONY: all_spec
all_spec: $(O)/all_spec$(EXE) ## Run all specs (note: this builds a huge program; `test` recipe builds individual binaries and is recommended for reduced resource usage)
	$(O)/all_spec$(EXE) $(SPEC_FLAGS)

.PHONY: crystal
crystal: $(O)/$(CRYSTAL_BIN) ## Build the compiler under Crystal's name (specs and bench use this one)

.PHONY: iyi
iyi: $(O)/iyi$(EXE) ## iyi: build `iyi` itself, runnable as ./bin/iyi [default, with crystal]

.PHONY: crystal-front
crystal-front: $(O)/crystal-front$(EXE) ## iyi: build the front end, which links no LLVM

.PHONY: crystal-daemon
crystal-daemon: $(O)/$(CRYSTAL_DAEMON_BIN) ## Build the single-threaded build daemon

.PHONY: iyi-daemon
iyi-daemon: $(O)/$(IYI_DAEMON_BIN) ## iyi: build iyi's own single-threaded build daemon

.PHONY: build
build: ## Build all files for a package install (currently the compiler and manpages)
# bake-format off: Mbake bug with Duplicate target rule https://github.com/EbodShojaei/bake/issues/106
build: release := 1
build: crystal manpages
# bake-format on

.PHONY: manpages
manpage: ## Build the manpages
manpages: $(manpages_gz)

.PHONY: deps llvm_ext
deps: $(DEPS) ## Build dependencies
llvm_ext: $(LLVM_EXT_OBJ)

.PHONY: format
format: ## Format sources
# The files this repository owns, which is not the same as the files under
# these directories: `shards install` in a sample writes other projects'
# source into a `lib/` beside it, and the formatter's own `-e lib` default
# is anchored at the top level, so a vendored tree one directory down was
# walked into and `check=1` failed on code nobody here wrote. Tracked plus
# new-and-not-ignored is the same rule `bench/identity_floor.py` reads for
# the same reason, `safe.directory` included: inside the build image the
# checkout is owned by another user and git 2.35+ refuses `ls-files`
# without it, which would turn this gate into a crash rather than a check.
	git -c safe.directory='*' ls-files -z --cached --others --exclude-standard '*.cr' '*.iyi' \
	  | xargs -0 ./bin/crystal tool format$(if $(check), --check)

.PHONY: generate_data
generate_data: ## Run generator scripts for Unicode, SSL config, ...
	$(MAKE) -B -f scripts/generate_data.mk

.PHONY: install
install: ## Install the crystal compiler package at DESTDIR
install: install_compiler install_man install_completions

.PHONY: uninstall
uninstall: ## Uninstall the Crystal compiler package from DESTDIR
uninstall: uninstall_compiler uninstall_man uninstall_completions

# iyi: the binary and its prelude, and nothing else — an iyi program requires
# only the prelude and the prelude requires only itself, so what is installed
# beside `bin/iyi` is 549 KB rather than a standard library.
.PHONY: install_iyi
install_iyi: ## iyi: install `iyi` and its prelude at DESTDIR
install_iyi: $(O)/iyi$(EXE) $(O)/$(IYI_DAEMON_BIN)
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(BINDIR)/"
	$(INSTALL) -m 0755 "$(O)/iyi$(EXE)" "$(DESTDIR)$(BINDIR)/iyi$(EXE)"

# Beside `iyi`, because that is where `iyi daemon start` looks. Shipped rather
# than left to be built: the daemon halves a `--crystal` build (SPEC.md IV.1d),
# and a feature that needs `make` first is a feature nobody who downloaded a
# tarball has.
	$(INSTALL) -m 0755 "$(O)/$(IYI_DAEMON_BIN)" "$(DESTDIR)$(BINDIR)/$(IYI_DAEMON_BIN)"

	$(INSTALL) -d -m 0755 "$(DESTDIR)$(DATADIR)/iyi/src"
	cp -R -p $(if $(deref_symlinks),-L,-P) src/iyi "$(DESTDIR)$(DATADIR)/iyi/src/iyi"

# And the standard library beside it, because `import std/text` is a program's
# line and not a checkout's. It rode into the tarball under the other
# language's directory before this - `src/.` below copies everything there -
# so it resolved by accident, out of a library it is not part of. Here it is
# on `IYI_PATH` under its own name.
	cp -R -p $(if $(deref_symlinks),-L,-P) src/std "$(DESTDIR)$(DATADIR)/iyi/src/std"

# iyi: the other library, because `--crystal` is not a developer's switch.
#
# A program built with it gets Crystal's standard library, and an install that
# ships only iyi's own 549 KB answers `require "json"` with "can't find file",
# which is the headline feature failing in the thing people download.
#
# `compiler/` was cut from this, on the grounds that a compiler carrying its own
# source carries it twice. That was wrong, and the way it was wrong is the
# lesson: **the standard library requires it.** `crystal/syntax_highlighter`
# requires `compiler/crystal/syntax`, Crystal's exception page requires the
# highlighter, and Kemal requires the exception page — so `require "kemal"`,
# this README's headline example, could not be built from the tarball anybody
# downloaded. Shipping a library means shipping what it requires, and deciding
# otherwise from the outside is guessing. Crystal's own install copies all of
# `src` for the same reason. `iyi/` stays out because it is already above.
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(DATADIR)/iyi/crystal"
# `src/.` rather than `src/*/`: a glob's trailing slash means two different
# things to the two cps — GNU copies the directory, BSD copies its *contents* —
# so the darwin tarball shipped Crystal's library flattened into one directory
# and `--crystal` could not find `crystal/system/time` out of it. `dir/.` is
# the one spelling POSIX gives both cps the same meaning for; `iyi/` and
# `std/` ride in and are removed below.
	cp -R -p $(if $(deref_symlinks),-L,-P) src/. "$(DESTDIR)$(DATADIR)/iyi/crystal/"
	rm -rf "$(DESTDIR)$(DATADIR)/iyi/crystal/iyi"
# And `std/`, for the reason it is above under its own name: nothing in
# Crystal's library requires `std/...`, the directory's 969 KB is a second
# copy of a library that already shipped, and while it is there it answers
# `import std/text` out of `share/iyi/crystal` — which is how the accident
# looked before `src/std` was installed at all, and which would let that
# line break again without a program noticing. `bench/tarball_std.sh`
# proves the absence by moving the real one aside.
	rm -rf "$(DESTDIR)$(DATADIR)/iyi/crystal/std"

	$(INSTALL) -d -m 0755 "$(DESTDIR)$(DATADIR)/licenses/iyi/"
	$(INSTALL) -m 644 LICENSE "$(DESTDIR)$(DATADIR)/licenses/iyi/LICENSE"
	$(INSTALL) -m 644 NOTICE.md "$(DESTDIR)$(DATADIR)/licenses/iyi/NOTICE.md"

.PHONY: uninstall_iyi
uninstall_iyi: ## iyi: remove what install_iyi installed
	rm -f "$(DESTDIR)$(BINDIR)/iyi$(EXE)"
	rm -f "$(DESTDIR)$(BINDIR)/$(IYI_DAEMON_BIN)"
	rm -rf "$(DESTDIR)$(DATADIR)/iyi"
	rm -rf "$(DESTDIR)$(DATADIR)/licenses/iyi"

# iyi: the binaries about to be packaged are optimised ones.
#
# `release := 1` above asks for that, and asking is not enough: make rebuilds
# on file times, so a `.build/iyi` left over from an ordinary `make iyi` is
# newer than every source and gets packaged as it is. Nothing about the tarball
# would look wrong. The binary would simply be an unoptimised compiler, and
# every build every user ran would go through it — a release nobody could see
# was slow.
#
# So it is asked of the binary rather than of the build: `--version` says which
# it is.
.PHONY: check_iyi_is_release
check_iyi_is_release: $(O)/iyi$(EXE) $(O)/$(IYI_DAEMON_BIN)
	@for bin in iyi$(EXE) $(IYI_DAEMON_BIN); do \
	   if $(O)/$$bin --version | grep -q "not built in release mode"; then \
	     echo "$(O)/$$bin is not an optimised build, and a tarball ships what it packages."; \
	     echo "It is up to date by file times, so make will not rebuild it. Force it:"; \
	     echo "  make -B iyi iyi-daemon release=1"; \
	     exit 1; \
	   fi; \
	 done

# iyi: the same layout in a file somebody can download. Relocatable, because
# the binary finds its prelude relative to itself.
.PHONY: iyi-tarball
iyi-tarball: ## iyi: build a relocatable tarball at $(O)
# bake-format off: Mbake bug with Duplicate target rule https://github.com/EbodShojaei/bake/issues/106
iyi-tarball: release := 1
iyi-tarball: $(O)/iyi$(EXE) $(O)/$(IYI_DAEMON_BIN) check_iyi_is_release
# bake-format on
	rm -rf "$(O)/iyi-package"
# `release=1` again, for the sub-make: `release := 1` above is this goal's
# and does not travel. Under `make -B iyi-tarball` the sub-make inherits
# `-B`, rebuilds `iyi` for `install_iyi` *after* the guard above passed, and
# without the word rebuilt it unoptimised — the exact package the guard
# exists to refuse, found by running the tarball this way once.
	$(MAKE) install_iyi release=1 DESTDIR="$(CURDIR)/$(O)/iyi-package" PREFIX=""
	$(INSTALL) -m 644 README.md "$(O)/iyi-package/share/iyi/README.md"
	$(INSTALL) -m 644 SPEC.md "$(O)/iyi-package/share/iyi/SPEC.md"
	cp -R -p samples/iyi "$(O)/iyi-package/share/iyi/samples"
	cp -R -p samples/crystal "$(O)/iyi-package/share/iyi/samples/crystal"
# A sample that depends on a shard leaves what it builds beside it, and the
# copy above takes whatever is on disk. `samples/crystal/kemal` had 82 MB of
# `mods/`, a fetched `lib/` and a linked binary sitting in it after one run —
# none of it the sample, all of it in the tarball. Pruned by what it is rather
# than by name, so the next sample of that shape is covered too.
	find "$(O)/iyi-package/share/iyi/samples" \
	     \( -name lib -o -name mods \) -type d -prune -exec rm -rf {} +
	find "$(O)/iyi-package/share/iyi/samples" -type f -perm -u+x -delete
	find "$(O)/iyi-package/share/iyi/samples" -type d -empty -delete
# What the binaries need at runtime and a fresh machine has no reason to
# own — libgc, and libstdc++ on Linux; LLVM is inside the binary when it
# was linked against `scripts/build-static-llvm.sh`'s archive, and the
# script refuses a package that carries libLLVM in that case. Not a
# curated list: the script takes what the loader reports, and CI's clean
# room (a bare image with nothing but a C toolchain) is what judges it.
	bash scripts/bundle-runtime-libs.sh "$(O)/iyi-package"
	tar -czf "$(O)/$(IYI_PACKAGE).tar.gz" -C "$(O)/iyi-package" .
	@echo "wrote $(O)/$(IYI_PACKAGE).tar.gz"

.PHONY: install_compiler
install_compiler: $(O)/$(CRYSTAL_BIN)
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(BINDIR)/"
	$(INSTALL) -m 0755 "$(O)/$(CRYSTAL_BIN)" "$(DESTDIR)$(BINDIR)/$(CRYSTAL_BIN)"

	$(INSTALL) -d -m 0755 $(DESTDIR)$(DATADIR)/crystal
	cp -R -p $(if $(deref_symlinks),-L,-P) src "$(DESTDIR)$(DATADIR)/crystal/src"
	rm -rf "$(DESTDIR)$(DATADIR)/crystal/$(LLVM_EXT_OBJ)" # Don't install llvm_ext.o

	$(INSTALL) -d -m 0755 "$(DESTDIR)$(DATADIR)/licenses/crystal/"
	$(INSTALL) -m 644 LICENSE "$(DESTDIR)$(DATADIR)/licenses/crystal/LICENSE"

.PHONY: uninstall_compiler
uninstall_compiler:
	rm -f "$(DESTDIR)$(BINDIR)/$(CRYSTAL_BIN)"

	rm -rf "$(DESTDIR)$(DATADIR)/crystal/src"
	rm -f "$(DESTDIR)$(DATADIR)/licenses/crystal/LICENSE"

.PHONY: install_man
install_man: $(manpages_gz)
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(MANDIR)/man1/"
	$(INSTALL) -m 644 $^ "$(DESTDIR)$(MANDIR)/man1/"

.PHONY: uninstall_man
uninstall_man:
	rm -f $(patsubst man/%,$(DESTDIR)$(MANDIR)/man1/%.gz,$(MAN1PAGES))

.PHONY: install_completions
install_completions:
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(DATADIR)/bash-completion/completions/"
	$(INSTALL) -m 644 etc/completion.bash "$(DESTDIR)$(DATADIR)/bash-completion/completions/crystal"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(DATADIR)/zsh/site-functions/"
	$(INSTALL) -m 644 etc/completion.zsh "$(DESTDIR)$(DATADIR)/zsh/site-functions/_crystal"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d/"
	$(INSTALL) -m 644 etc/completion.fish "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d/crystal.fish"

.PHONY: uninstall_completions
uninstall_completions:
	rm -f "$(DESTDIR)$(DATADIR)/bash-completion/completions/crystal"
	rm -f "$(DESTDIR)$(DATADIR)/zsh/site-functions/_crystal"
	rm -f "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d/crystal.fish"

ifeq ($(WINDOWS),1)
.PHONY: install_dlls
install_dlls: $(O)/$(CRYSTAL_BIN) ## Install the compiler's dependent DLLs at DESTDIR (Windows only)
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(BINDIR)/"
	@ldd $(O)/$(CRYSTAL_BIN) | grep -iv ' => /c/windows/system32' | sed 's/.* => //; s/ (.*//' | xargs -t -i $(INSTALL) -m 0755 '{}' "$(DESTDIR)$(BINDIR)/"
endif

$(O)/all_spec$(EXE): $(DEPS) $(SOURCES) $(SPEC_SOURCES)
	$(call check_llvm_config)
	@mkdir -p $(O)
	$(EXPORT_CC) $(EXPORTS) ./bin/crystal build $(FLAGS) $(SPEC_WARNINGS_OFF) -o $@ spec/all_spec.cr

$(O)/std_spec$(EXE): $(DEPS) $(SOURCES) $(SPEC_SOURCES)
	$(call check_llvm_config)
	@mkdir -p $(O)
	$(EXPORT_CC) ./bin/crystal build $(FLAGS) $(SPEC_WARNINGS_OFF) -o $@ spec/std_spec.cr
$(O)/compiler_spec$(EXE): $(DEPS) $(SOURCES) $(SPEC_SOURCES)
	$(call check_llvm_config)
	@mkdir -p $(O)
	$(EXPORT_CC) ./bin/crystal build $(FLAGS) $(COMPILER_FLAGS) $(SPEC_WARNINGS_OFF) -o $@ spec/compiler_spec.cr --release

$(O)/primitives_spec$(EXE): $(O)/$(CRYSTAL_BIN) $(DEPS) $(SOURCES) $(SPEC_SOURCES)
	@mkdir -p $(O)
	$(EXPORT_CC) ./bin/crystal build $(FLAGS) $(SPEC_WARNINGS_OFF) -o $@ spec/primitives_spec.cr

$(O)/cli_spec$(EXE): $(O)/$(CRYSTAL_BIN) $(O)/$(IYI_DAEMON_BIN) $(DEPS) $(SOURCES) $(SPEC_SOURCES)
	@mkdir -p $(O)
	$(EXPORT_CC) ./bin/crystal build $(FLAGS) $(SPEC_WARNINGS_OFF) -o $@ spec/cli_spec.cr

$(O)/$(CRYSTAL_BIN): $(DEPS) $(SOURCES)
	$(call check_llvm_config)
	@mkdir -p $(O)
	$(EXPORTS) $(EXPORTS_BUILD) ./bin/crystal build $(FLAGS) $(COMPILER_FLAGS) -o $(if $(WINDOWS),$(O)/crystal-next.exe,$@) src/compiler/crystal.cr
	@# NOTE: on MSYS2 it is not possible to overwrite a running program, so the compiler must be first built with
	@# a different filename and then moved to the final destination.
	$(if $(WINDOWS),mv $(O)/crystal-next.exe $@)

# iyi: the same compiler under its own name — the commands iyi has, a usage
# line that names them, and a version that says what it is a fork of. It links
# what `crystal` links, because it *is* `crystal`; what differs is the surface.
# Its prelude is its own, and it is 549 KB: `iyi` installed as `bin/iyi` finds
# `share/iyi/src/iyi/prelude.iyi` beside it and needs nothing else — no
# `IYI_PATH`, no standard library, because an iyi program requires only the
# prelude and the prelude requires only itself.
$(O)/iyi$(EXE): $(DEPS) $(SOURCES)
	$(call check_llvm_config)
	@mkdir -p $(O)
	$(EXPORTS) $(EXPORTS_BUILD) IYI_CONFIG_PATH='$$ORIGIN/../share/iyi/src:$$ORIGIN/../share/iyi/crystal:$$ORIGIN/../src' \
	  ./bin/crystal build $(FLAGS) $(COMPILER_FLAGS) $(SELF_RPATH) -o $@ src/compiler/iyi.cr
	@echo "built $@ — run it as ./bin/iyi"

# iyi: the same compiler, single-threaded, which is what lets it fork.
#
# The daemon forks a child per build and only the forking thread survives a
# fork, so the server half cannot be the multi-threaded binary. Same sources,
# same prelude path, `-Dwithout_mt` — and a name `iyi daemon start` will find
# beside itself, installed or in `.build`.
$(O)/$(IYI_DAEMON_BIN): $(DEPS) $(SOURCES)
	$(call check_llvm_config)
	@mkdir -p $(O)
	$(EXPORTS) $(EXPORTS_BUILD) IYI_CONFIG_PATH='$$ORIGIN/../share/iyi/src:$$ORIGIN/../share/iyi/crystal:$$ORIGIN/../src' \
	  ./bin/crystal build $(FLAGS) $(COMPILER_FLAGS) $(SELF_RPATH) -Dwithout_mt -o $@ src/compiler/iyi.cr
	@echo "built $@ — \`iyi daemon start\` finds it beside iyi"

# iyi: the front end on its own. Linking libLLVM costs 26 ms of load-time
# initialisers whether or not anything generates code, and `--no-codegen` never
# calls it — so this links none and starts in 6 ms rather than 39 (SPEC.md
# 0.1.0, src/compiler/iyi/llvm_shim.cr).
#
# The host triple and the LLVM version are baked in from the compiler that has
# LLVM, because without it there is nothing to ask.
$(O)/crystal-front$(EXE): $(DEPS) $(SOURCES) $(O)/$(CRYSTAL_BIN)
	@mkdir -p $(O)
	$(EXPORTS) $(EXPORTS_BUILD) \
	  IYI_CONFIG_TARGET="$$($(O)/$(CRYSTAL_BIN) --version | sed -n 's/^Default target: //p')" \
	  IYI_CONFIG_LLVM_VERSION="$$($(O)/$(CRYSTAL_BIN) --version | sed -n 's/^LLVM: //p')" \
	  ./bin/crystal build $(FLAGS) $(COMPILER_FLAGS) -Dwithout_llvm -o $@ src/compiler/crystal_front.cr

$(O)/$(CRYSTAL_DAEMON_BIN): $(DEPS) $(SOURCES)
	$(call check_llvm_config)
	@mkdir -p $(O)
	$(EXPORTS) $(EXPORTS_BUILD) ./bin/crystal build $(FLAGS) $(COMPILER_FLAGS) -Dwithout_mt -o $@ src/compiler/crystal.cr

$(LLVM_EXT_OBJ): $(LLVM_EXT_DIR)/llvm_ext.cc
	$(call check_llvm_config)
	$(CXX) -c $(CXXFLAGS) -o $@ $< $(if $(LLVM_CONFIG),$(shell $(LLVM_CONFIG) --cxxflags))

$(O)/crystal-pu$(EXE): spec/support/process-utils.cr $(SOURCES)
	@mkdir -p $(O)
	$(EXPORT_CC) ./bin/crystal build $(FLAGS) -o $@ $<

man/: $(MAN1PAGES)

man/%.gz: man/%
	gzip -c -9 $< > $@

man/%.1: doc/man/%.adoc
	SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) asciidoctor -a crystal_version=$(CRYSTAL_VERSION) $< -b manpage -o $@

.PHONY: clean
clean: clean_crystal clean_man ## Clean up built directories and files
	rm -rf $(LLVM_EXT_OBJ)

.PHONY: clean_crystal
clean_crystal: ## Clean up crystal built files
	rm -rf $(O)

.PHONY: clean_man
clean_man:
	rm -rf ./man

.PHONY: clean_cache
clean_cache: ## Clean up IYI_CACHE_DIR files
	rm -rf $(shell ./bin/crystal env IYI_CACHE_DIR)

.PHONY: help
help: ## Show this help
	@echo
	@printf '\033[34mtargets:\033[0m\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) |\
		sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo
	@printf '\033[34moptional variables:\033[0m\n'
	@grep -hE '^[a-zA-Z_-]+ \?=.*?## .*$$' $(MAKEFILE_LIST) |\
		sort | \
		awk 'BEGIN {FS = " \\?=.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo
	@printf '\033[34mrecipes:\033[0m\n'
	@grep -hE '^##.*$$' $(MAKEFILE_LIST) |\
		awk 'BEGIN {FS = "## "}; /^## [a-zA-Z_-]/ {printf "  \033[36m%s\033[0m\n", $$2}; /^##  / {printf "  %s\n", $$2}'
