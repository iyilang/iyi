# Tripwire for the native build path (SPEC 3.8, slice C6). Sourced by bench/native_first_light_exercise.sh.
#
#   tripwire_setup DIR LOG
#
# Writes one shim per external tool a native build must never run (ld, cc, clang, gcc, codesign, dsymutil,
# llvm-config, as). Each shim appends its own name and its arguments to LOG and exits 1, so a build that reaches for a
# host tool fails, and LOG is left non-empty for the caller to check. After tripwire_setup, TRIPWIRE_PATH is the PATH
# to prepend for the native build only. Every local name here is prefixed, so the caller's variables are untouched.

TRIPWIRE_TOOLS="ld cc clang gcc codesign dsymutil llvm-config as"

tripwire_setup() {
  _tw_dir=$1
  _tw_log=$2
  mkdir -p "$_tw_dir" || return 1
  : >"$_tw_log" || return 1
  for _tw_name in $TRIPWIRE_TOOLS; do
    cat >"$_tw_dir/$_tw_name" <<SHIM
#!/bin/sh
echo "$_tw_name \$*" >>"$_tw_log"
exit 1
SHIM
    chmod +x "$_tw_dir/$_tw_name" || return 1
  done
  TRIPWIRE_PATH="$_tw_dir"
  export TRIPWIRE_PATH
}

# tripwire_fired LOG: succeeds when a shim ran (LOG is not empty).
tripwire_fired() {
  [ -s "$1" ]
}
