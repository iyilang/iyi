#!/usr/bin/env bash
# Build the same programs natively and for the freestanding wasm host, then
# run their shared contract in Node and an isolated headless browser.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
IYI_CHROME="${IYI_CHROME:?set IYI_CHROME to an isolated headless Chrome executable}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-freestanding.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/build" "$WORK/bench" "$WORK/src/iyi/wasm"
cp "$REPO/bench/wasm_freestanding_exercise.mjs" "$WORK/bench/"
cp "$REPO/src/iyi/wasm/iyi.mjs" "$WORK/src/iyi/wasm/"

build_wasm() {
  local name="$1" source="$2" command
  command="$("$IYI" build --cross-compile --target wasm32-unknown-unknown -o "$WORK/build/$name" "$source")"
  case "$command" in 'wasm-ld '*) ;; *) echo "unexpected link command: $command" >&2; exit 1 ;; esac
  case "$command" in *'--no-entry'*) ;; *) echo "missing --no-entry: $command" >&2; exit 1 ;; esac
  eval "$command"
  mv "$WORK/build/$name" "$WORK/$name.wasm"
}

echo '== native and cross-compiled sample programs =='
for name in hello format io; do
  # wasi-sdk also ships a host linker; keep it off the native compiler's PATH.
  if ! PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$IYI" build -o "$WORK/build/$name.native" "$REPO/samples/iyi/$name.iyi" >"$WORK/build/$name.native.log" 2>&1; then
    cat "$WORK/build/$name.native.log"
    exit 1
  fi
  printf 'first line\nsecond line\nthird line\n' | "$WORK/build/$name.native" > "$WORK/$name.expected"
  build_wasm "$name" "$REPO/samples/iyi/$name.iyi"
done

# Link the printed command with no entry flag removed: the linker must refuse.
link_command="$("$IYI" build --cross-compile --target wasm32-unknown-unknown -o "$WORK/build/no-entry" "$REPO/samples/iyi/hello.iyi")"
case "$link_command" in *' --no-entry'*) ;; *) echo 'negative proof has no --no-entry to remove' >&2; exit 1 ;; esac
if eval "${link_command/ --no-entry/}" >"$WORK/no-entry.log" 2>&1; then
  echo 'linker accepted the command without --no-entry' >&2; exit 1
fi
printf 'linker without --no-entry rejected: '; head -1 "$WORK/no-entry.log"

# Also exercise the compiler's direct linker invocation rather than evaluating
# its printed cross-compile command.
"$IYI" build --target wasm32-unknown-unknown -o "$WORK/build/direct" "$REPO/samples/iyi/hello.iyi"
test -s "$WORK/build/direct"
echo 'direct build: module written by wasm-ld'

printf 'exit(3)\n' > "$WORK/exit.iyi"
printf 'raise "freestanding panic proof"\n' > "$WORK/panic.iyi"
build_wasm contract "$REPO/bench/wasm_freestanding_exercise.iyi"
build_wasm exit "$WORK/exit.iyi"
build_wasm panic "$WORK/panic.iyi"

echo '== shared Node and browser contract =='
(cd "$WORK" && node "$REPO/bench/wasm_node.mjs" "$WORK/bench/wasm_freestanding_exercise.mjs")
node "$REPO/bench/wasm_browser.mjs" --chrome "$IYI_CHROME" --root "$WORK" --script bench/wasm_freestanding_exercise.mjs

echo '== negative proofs =='
mkdir -p "$WORK/broken/iyi"
cp -R "$REPO/src/iyi/." "$WORK/broken/iyi/"
awk '{ if ($0 ~ /LibIyiHost.write\(fd, buffer, count.to_i32\)/) { sub(/LibIyiHost.write\(fd,/, "LibIyiHost.write(2,"); changed++ } print } END { if (changed != 1) exit 1 }' \
  "$REPO/src/iyi/prelude.iyi" > "$WORK/broken/iyi/prelude.iyi"
command="$(IYI_PATH="$WORK/broken:$REPO/src" "$IYI" build --cross-compile --target wasm32-unknown-unknown -o "$WORK/build/broken" "$REPO/samples/iyi/hello.iyi")"
eval "$command"
mv "$WORK/hello.wasm" "$WORK/hello.good"
cp "$WORK/build/broken" "$WORK/hello.wasm"
if (cd "$WORK" && node "$REPO/bench/wasm_node.mjs" "$WORK/bench/wasm_freestanding_exercise.mjs") >"$WORK/broken.log" 2>&1; then
  echo 'stdout redirection defect was not caught' >&2; exit 1
fi
grep -q 'hello differs from native stdout' "$WORK/broken.log" || { cat "$WORK/broken.log"; exit 1; }
mv "$WORK/hello.good" "$WORK/hello.wasm"
echo 'write fd mutation: native output comparison failed as expected'

printf 'export default async function () { throw new Error("page throw proof"); }\n' > "$WORK/throw.mjs"
if node "$REPO/bench/wasm_browser.mjs" --chrome "$IYI_CHROME" --root "$WORK" --script throw.mjs >"$WORK/throw.log" 2>&1; then
  echo 'browser runner accepted a thrown exception' >&2; exit 1
fi
grep -q 'page throw proof' "$WORK/throw.log" || { cat "$WORK/throw.log"; exit 1; }
echo 'browser exception: runner exited nonzero'

printf 'export default async function () { await new Promise(() => {}); }\n' > "$WORK/timeout.mjs"
if node "$REPO/bench/wasm_browser.mjs" --chrome "$IYI_CHROME" --root "$WORK" --script timeout.mjs --timeout 3000 >"$WORK/timeout.log" 2>&1; then
  echo 'browser runner accepted a timeout' >&2; exit 1
fi
grep -q 'browser proof timed out' "$WORK/timeout.log" || { cat "$WORK/timeout.log"; exit 1; }
echo 'browser timeout: runner exited nonzero'

cat > "$WORK/nonheadless.mjs" <<'JS'
#!/usr/bin/env node
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
const profile = process.argv.find(arg => arg.startsWith("--user-data-dir=")).split("=")[1];
const server = createServer();
server.on("upgrade", (request, socket) => {
  const accept = createHash("sha1").update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let buffered = Buffer.alloc(0);
  socket.on("data", chunk => {
    buffered = Buffer.concat([buffered, chunk]);
    if (buffered.length < 6) return;
    const length = buffered[1] & 127;
    if (length >= 126 || buffered.length < 6 + length) return;
    const mask = buffered.subarray(2, 6);
    const payload = Buffer.from(buffered.subarray(6, 6 + length));
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    const message = JSON.parse(payload.toString());
    const response = Buffer.from(JSON.stringify({ id: message.id, result: { product: "Chrome/123" } }));
    socket.write(Buffer.concat([Buffer.from([0x81, response.length]), response]));
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(join(profile, "DevToolsActivePort"), `${server.address().port}\n/devtools/browser/fake\n`));
JS
chmod +x "$WORK/nonheadless.mjs"
if node "$REPO/bench/wasm_browser.mjs" --chrome "$WORK/nonheadless.mjs" --root "$WORK" --script throw.mjs >"$WORK/nonheadless.log" 2>&1; then
  echo 'browser runner accepted a non-headless product' >&2; exit 1
fi
grep -q 'Browser Chrome/123' "$WORK/nonheadless.log"
grep -q 'refusing a non-headless browser' "$WORK/nonheadless.log"
echo 'simulated Browser Chrome/123: rejected as non-headless'
echo 'freestanding wasm: all checks passed'
