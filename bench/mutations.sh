# Whether an exercise builds its broken copies this run. Sourced by the
# exercises whose proofs patch a module and build it again:
#
#     . "$REPO/bench/mutations.sh"
#     if mutations_wanted; then
#       ...the broken copies...
#     fi
#
# IYI_MUTATIONS names the exercises whose proofs run: unset or `all` for
# every one, `none` for none, otherwise the exercises' names without `.sh`
# (`std_zip_exercise std_tls_exercise`), separated by spaces. Unset is a
# person running a gate by hand, and they get every proof. CI sets it from
# scripts/ci_plan.py: a proof answers for the module it breaks and the
# exercise that catches the break, so a push builds the copies of the
# modules it touched, and the nightly run builds every one, on every
# platform.
mutations_wanted() {
  local self
  self="$(basename "$0" .sh)"
  case " ${IYI_MUTATIONS:-all} " in
    " all " | *" $self "*) return 0 ;;
  esac
  echo "  skipped: IYI_MUTATIONS does not name $self, so its broken copies are left to a run that does"
  return 1
}
