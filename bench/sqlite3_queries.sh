#!/usr/bin/env bash
# Runs a query through two `.iyimod` boundaries, one of them a driver.
#
# `bench/kemal_serves.sh` and `bench/jwt_signs.sh` prove two kinds of shard
# cross. This proves a third, and the difference is why all three are here:
# `db` and `sqlite3` are a *pair*. `db` declares what a driver must answer and
# never sees one; `sqlite3` answers it and never sees `db`'s source. Every
# `abstract def` in between is a place where the producer compiled a body
# against nothing at all, and the consumer has to compile its own — which is
# the finding this gate holds down. `db`'s
# `Connection#fetch_or_build_prepared_statement` calls an abstract
# `build_prepared_statement`; the copy in `db`'s artifact returns its own
# argument, because in `db`'s build nothing answers it. Linked over the
# consumer's copy it handed back a statement whose `crystal_type_id` was 1.
#
#     bash bench/sqlite3_queries.sh
#
# Needs `make`, `shards`, the network and libsqlite3 - on Windows, sqlite3.lib
# on `LIB` and sqlite3.dll on `PATH` (the Windows job makes both from
# sqlite.org's DLL). Both shards are pinned.
#
# Exits non-zero if any bind or fill fails, if either arm fails to build, or if
# the two answer differently. The rows are the measurement: a boundary that
# lost a bound parameter or read a column at the wrong offset does not crash,
# it answers something else.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# both wrappers in bin/ are posix shell scripts and cannot run a native
# windows build, so a compiler named in the environment wins over the default.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

SQLITE3_VERSION="0.21.0"

for tool in shards; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "needs $tool, which is not on the PATH"
    exit 1
  fi
done

cat > "$WORK/shard.yml" <<YML
name: sqlite3_queries
version: 0.1.0
dependencies:
  sqlite3:
    github: crystal-lang/crystal-sqlite3
    version: $SQLITE3_VERSION
YML

cd "$WORK" || exit 1

if ! shards install > install.log 2>&1; then
  echo "installing the shard failed"
  tail -12 install.log
  echo "workdir $WORK"
  exit 1
fi

export CRYSTAL_PATH="$WORK/lib${PSEP}$REPO/src"
export IYI_PATH="$WORK/lib${PSEP}$REPO/share/iyi/src${PSEP}$REPO/share/iyi/crystal${PSEP}$REPO/src"

mkdir mods

# In dependency order, each boundary bound against the ones before it. See
# `bench/bind_chain.sh` for why both halves of that matter.
bind_one() {
  name="$1"; root="$2"; source="$3"
  if ! "$CRYSTAL" tool bind -e "$root" --emit-bind mods --use-iyimod mods \
        "$source" > "bind-$name.log" 2>&1; then
    echo "binding $name failed"
    tail -10 "bind-$name.log"
    echo "workdir $WORK"
    exit 1
  fi
  keep="$(ls -t mods/*_keep.cr | head -1)"
  if ! (cd mods && "$CRYSTAL" build --iyi-keep "$root" --emit-bind . \
          -o "keep_$name" "$(basename "$keep")" > "fill-$name.log" 2>&1); then
    echo "filling $name failed"
    tail -10 "mods/fill-$name.log"
    echo "workdir $WORK"
    exit 1
  fi
  echo "  bound $name ($root)"
}

echo "bound, in dependency order:"
bind_one db      DB      lib/db/src/db.cr
bind_one sqlite3 SQLite3 lib/sqlite3/src/sqlite3.cr

# `:memory:`, which is the strictest form this can take and the form
# `sqlite3`'s own README uses. Each connection to `:memory:` is its own
# database, so every statement here has to land on the *same* one — the pool
# has to get its connection back. That took `Pool#checkout`'s
# `res.responds_to?(:before_checkout)` finding a hook that is `protected` and
# reached through a type parameter, which the private-callee search could not
# see: without it `auto_release` is never set, nothing returns to the pool, and
# the table is gone by the next statement. A file-backed database does not
# notice any of that, which is exactly why this one is not file-backed.
program='DB.open("sqlite3::memory:") do |db|
  db.exec("create table contacts (name text, age integer)")
  db.exec("insert into contacts values (?, ?)", "John", 30)
  db.exec("insert into contacts values (?, ?)", "Sarah", 33)

  puts db.scalar("select name from contacts order by age").as(String)

  db.query("select name, age from contacts order by age") do |rs|
    rs.each do
      n = rs.read(String)
      a = rs.read(Int32)
      puts "#{n} is #{a}"
    end
  end

  puts db.scalar("select count(*) from contacts").as(Int64)
end'

printf 'module main\n\nrequire "sqlite3"\n\n%s\n' "$program" > app_source.iyi
printf 'module main\n\nimport s_q_lite3\n\n%s\n' "$program" > app_artifact.iyi

status=0

if ! "$IYI" build --crystal -o app_source app_source.iyi > build-source.log 2>&1; then
  echo "the source arm failed to build"
  tail -12 build-source.log
  echo "workdir $WORK"
  exit 1
fi

if ! "$IYI" build --crystal --use-iyimod mods -o app_artifact app_artifact.iyi \
      > build-artifact.log 2>&1; then
  echo "the artifact arm failed to build"
  tail -12 build-artifact.log
  echo "workdir $WORK"
  exit 1
fi

./app_source > answers-source.txt 2>&1 || status=1
./app_artifact > answers-artifact.txt 2>&1 || status=1

if diff -q answers-source.txt answers-artifact.txt > /dev/null; then
  echo "two boundaries, a driver behind an abstract one, and the rows agree"
  sed 's/^/  /' answers-artifact.txt
else
  echo "THE TWO ARMS ANSWER DIFFERENTLY"
  diff answers-source.txt answers-artifact.txt | head -10
  status=1
fi

echo "workdir $WORK"
exit $status
