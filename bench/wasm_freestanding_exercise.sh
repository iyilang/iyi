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

echo '== headless browser ownership and version checks =='
node --input-type=module - "$REPO/bench/wasm_browser.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const { isOwnedHeadless } = await import(pathToFileURL(process.argv[2]).href);
const profile = "/owned/profile";
const owned = { pid: 123, exitCode: null, signalCode: null,
  spawnargs: ["chrome", "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`] };
const shell = {
  product: "HeadlessChrome/156.0.8078.4",
  userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/156.0.8078.4 Safari/537.36",
};
// Browser.getVersion from CI job 134001438359, full Chrome in new-headless mode.
const fullHeadless = {
  product: "Chrome/157.0.8103.50",
  userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/157.0.0.0 Safari/537.36",
};
const headed = { product: fullHeadless.product,
  userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36" };
const headedChild = { ...owned, spawnargs: ["chrome", "--remote-debugging-port=0", `--user-data-dir=${profile}`] };
const deadChild = { ...owned, exitCode: 0 };
const check = (condition, message) => { if (!condition) throw new Error(message); };
check(isOwnedHeadless(shell, owned, profile), "owned headless shell was refused");
check(isOwnedHeadless(fullHeadless, owned, profile), "owned Chrome with headless UA was refused");
check(!isOwnedHeadless(headed, owned, profile), "Chrome without headless UA was accepted");
check(!isOwnedHeadless(fullHeadless, null, profile), "unspawned Chrome was accepted");
check(!isOwnedHeadless(fullHeadless, headedChild, profile), "headed Chrome was accepted");
check(!isOwnedHeadless(shell, headedChild, profile), "headed shell was accepted");
check(!isOwnedHeadless(fullHeadless, deadChild, profile), "exited child was accepted");
check(!isOwnedHeadless(fullHeadless, owned, "/other/profile"), "unowned profile was accepted");
check(!isOwnedHeadless({ ...fullHeadless, userAgent: "NotHeadlessChrome/157.0" }, owned, profile), "partial UA token was accepted");
console.log("headless ownership: shell and Chrome headless UA accepted; headed and unowned cases refused");
JS

echo '== owned browser cleanup =='
node --input-type=module - "$REPO/bench/wasm_browser.mjs" <<'JS'
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const { cleanupOwnedBrowser } = await import(pathToFileURL(process.argv[2]).href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const writer = `
  const fs = require("node:fs"), path = require("node:path");
  const dir = process.argv[1], mode = process.argv[2];
  let count = 0;
  const timer = setInterval(() => fs.writeFileSync(path.join(dir, "active"), String(++count)), 5);
  process.on("SIGTERM", () => {
    if (mode === "graceful") setTimeout(() => { clearInterval(timer); process.exit(0); }, 150);
  });
  console.log("ready");
`;

async function exerciseWriter(mode) {
  const profile = await mkdtemp(join(tmpdir(), "iyi-cleanup-test-"));
  const child = spawn(process.execPath, ["-e", writer, profile, mode], { stdio: ["ignore", "pipe", "pipe"] });
  try {
    await new Promise((resolve, reject) => {
      let ready = false;
      const timeout = setTimeout(() => reject(new Error("writer did not start")), 5000);
      child.stdout.on("data", data => {
        if (!ready && data.toString().includes("ready")) {
          ready = true;
          clearTimeout(timeout);
          resolve();
        }
      });
      child.once("error", reject);
      child.once("exit", () => {
        if (!ready) {
          clearTimeout(timeout);
          reject(new Error("writer exited before ready"));
        }
      });
    });
    let options;
    await cleanupOwnedBrowser(child, profile, async (path, supplied) => {
      check(child.exitCode !== null || child.signalCode !== null, "profile removed while child was writing");
      options = supplied;
      await rm(path, supplied);
    });
    check(!existsSync(profile), "owned profile was not removed");
    check(options?.recursive && options?.force && options?.maxRetries === 10 && options?.retryDelay === 200,
      "profile removal did not use the bounded retry policy");
    if (mode === "graceful") check(child.exitCode === 0, "graceful writer was killed before it exited");
    else check(child.signalCode === "SIGKILL", "unresponsive writer did not receive SIGKILL");
  } finally {
    if (child.pid && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise(resolve => child.once("exit", resolve));
      child.kill("SIGKILL");
      await exited;
    }
    await rm(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  }
}

await exerciseWriter("graceful");
await exerciseWriter("ignore");
const warnings = [];
const originalWarn = console.warn;
console.warn = message => warnings.push(message);
try {
  await cleanupOwnedBrowser(null, "unused", async () => { throw new Error("injected ENOTEMPTY"); });
} finally {
  console.warn = originalWarn;
}
check(warnings.length === 1 && warnings[0].includes("warning: unable to clean up owned browser profile") &&
  warnings[0].includes("injected ENOTEMPTY"), "cleanup failure was not reported as a warning");
console.log("cleanup: waited for writing child; SIGKILL fallback and nonfatal warning held");
JS

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

# A real wasm constructor checks that iyi_start invokes the linker's ctor
# list, rather than only running iyi's own top-level code.
cat > "$WORK/build/ctor.c" <<'C'
static int initialized;
__attribute__((constructor)) static void initialize(void) { initialized++; }
__attribute__((export_name("ctor_value"))) int ctor_value(void) { return initialized; }
C
"${WASI_SDK_PATH:-/opt/wasi-sdk}/bin/clang" --target=wasm32-unknown-unknown -c "$WORK/build/ctor.c" -o "$WORK/build/ctor.o"
wasm-ld "$WORK/build/hello.wasm" "$WORK/build/ctor.o" -o "$WORK/ctor.wasm" --no-entry

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
printf 'print "tail without newline"\n' > "$WORK/partial.iyi"
printf 'File.read("/unavailable")\n' > "$WORK/file_read.iyi"
printf 'File.write("/unavailable", "value")\n' > "$WORK/file_write.iyi"
printf 'File.open("/unavailable")\n' > "$WORK/file_open.iyi"
printf 'File.exists?("/unavailable")\n' > "$WORK/file_exists.iyi"
printf 'File.delete("/unavailable")\n' > "$WORK/file_delete.iyi"
build_wasm contract "$REPO/bench/wasm_freestanding_exercise.iyi"
build_wasm exit "$WORK/exit.iyi"
build_wasm panic "$WORK/panic.iyi"
build_wasm partial "$WORK/partial.iyi"
for name in file_read file_write file_open file_exists file_delete; do
  build_wasm "$name" "$WORK/$name.iyi"
done

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

# Remove only the guest-backed stdin snapshot from the loader used by the
# exercise. The first partial read must then fail after memory grows.
loader="$WORK/src/iyi/wasm/iyi.mjs"
cp "$loader" "$WORK/loader.good"
awk '{ if ($0 ~ /if \(input.length > \(len >>> 0\)\) input = new Uint8Array\(input\);/) { changed++; next } print } END { if (changed != 1) exit 1 }' \
  "$WORK/loader.good" > "$loader"
if cmp -s "$WORK/loader.good" "$loader"; then
  echo 'stdin mutation did not change the loader' >&2; exit 1
fi
if (cd "$WORK" && node "$REPO/bench/wasm_node.mjs" "$WORK/bench/wasm_freestanding_exercise.mjs") >"$WORK/stdin-broken.log" 2>&1; then
  echo 'stdin mutation was not caught' >&2; exit 1
fi
grep -q 'wasm-backed stdin lost unread bytes after memory growth' "$WORK/stdin-broken.log" || { cat "$WORK/stdin-broken.log"; exit 1; }
cp "$WORK/loader.good" "$loader"
cmp -s "$WORK/loader.good" "$loader" || { echo 'stdin mutation was not restored' >&2; exit 1; }
(cd "$WORK" && node "$REPO/bench/wasm_node.mjs" "$WORK/bench/wasm_freestanding_exercise.mjs") >"$WORK/stdin-restored.log" 2>&1 || { cat "$WORK/stdin-restored.log"; exit 1; }
grep -q '"ok":true' "$WORK/stdin-restored.log" || { cat "$WORK/stdin-restored.log"; exit 1; }
echo 'stdin snapshot mutation: memory-growth regression caught as expected'

printf 'export default async function () { throw new Error("page throw proof"); }\n' > "$WORK/throw.mjs"
ln -s "$REPO/bench/wasm_browser.mjs" "$WORK/wasm-browser-symlink.mjs"
if node "$WORK/wasm-browser-symlink.mjs" --chrome "$IYI_CHROME" --root "$WORK" --script throw.mjs >"$WORK/throw.log" 2>&1; then
  echo 'browser runner accepted a thrown exception' >&2; exit 1
fi
grep -q 'page throw proof' "$WORK/throw.log" || { cat "$WORK/throw.log"; exit 1; }
echo 'browser exception: runner exited nonzero through symlink'

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
