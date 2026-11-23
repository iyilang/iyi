# Sourced by the gates that ask a server on this machine for a page
# (`bench/shard_serves.sh`, `bench/kemal_serves.sh`).
#
#     loopback_get PORT PATH           the body of GET http://127.0.0.1:PORT/PATH
#     loopback_get PORT PATH status    its status code, and a newline
#
# Exits nonzero when nothing answered. It asks with `curl` where there is one,
# and with bash's own `/dev/tcp` where there is not: the crystal docker image
# ships neither `curl` nor Python, and installing one from Ubuntu's archives
# put a gate's pass on whether `archive.ubuntu.com` answered (two jobs of
# iyilang/iyi run 44514733307 lost 3 and 11 minutes to it and failed). The
# request is HTTP/1.0 so the server answers with a length and closes, and the
# body is what follows the blank line.
loopback_get() {
  local port="$1" path="$2" want="${3:-body}" resp
  if command -v curl > /dev/null 2>&1; then
    if [ "$want" = status ]; then
      curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$port$path"
    else
      curl -s --max-time 5 "http://127.0.0.1:$port$path"
    fi
    return
  fi
  resp="$( (
    exec 3<> "/dev/tcp/127.0.0.1/$port" || exit 1
    printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' "$path" >&3
    timeout 5 cat <&3
  ) 2> /dev/null)" || return 1
  [ -n "$resp" ] || return 1
  if [ "$want" = status ]; then
    resp="${resp%%$'\r'*}"
    resp="${resp#* }"
    printf '%s\n' "${resp%% *}"
  else
    printf '%s' "${resp#*$'\r\n\r\n'}"
  fi
}
