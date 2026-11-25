import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";

// Only this runner's live child, started in headless mode with its private
// profile, can be a proof browser. A Chrome/ product also needs the
// HeadlessChrome user-agent token.
// CI job 134001438359: product Chrome/157.0.8103.50, user agent
// Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)
// HeadlessChrome/157.0.0.0 Safari/537.36.
export function isOwnedHeadless(version, child, profile) {
  if (!Number.isInteger(child?.pid) || child.pid <= 0 ||
      child.exitCode !== null || child.signalCode !== null ||
      !profile || !child.spawnargs?.includes(`--user-data-dir=${profile}`) ||
      !child.spawnargs?.includes("--remote-debugging-port=0") ||
      !child.spawnargs?.includes("--headless=new")) return false;
  if (typeof version?.product !== "string") return false;
  if (version.product.startsWith("HeadlessChrome/")) return true;
  return version.product.startsWith("Chrome/") &&
    typeof version.userAgent === "string" &&
    /(?:^|\s)HeadlessChrome\/\d[\d.]*(?:\s|$)/.test(version.userAgent);
}

function hasExited(child) {
  return child.exitCode !== null || child.signalCode !== null;
}

function waitForExit(child, timeout) {
  if (hasExited(child)) return Promise.resolve(true);
  return new Promise(resolve => {
    const finish = exited => {
      clearTimeout(timer);
      child.off("exit", onExit);
      resolve(exited);
    };
    const onExit = () => finish(true);
    const timer = setTimeout(() => finish(hasExited(child)), timeout);
    child.once("exit", onExit);
    if (hasExited(child)) finish(true);
  });
}

// child and profile are the process and mkdtemp directory this runner made.
// A cleanup warning must not replace the result of the proof itself.
export async function cleanupOwnedBrowser(child, profile, remove = rm) {
  try {
    if (child?.pid && !hasExited(child)) {
      child.kill("SIGTERM");
      if (!await waitForExit(child, 2000)) {
        child.kill("SIGKILL");
        if (!await waitForExit(child, 2000)) throw new Error("child did not exit after SIGKILL");
      }
    }
    await remove(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch (error) {
    console.warn(`warning: unable to clean up owned browser profile: ${error?.message ?? String(error)}`);
  }
}

function argumentsOf(args) {
  const values = {};
  while (args.length) {
    const key = args.shift();
    if (!["--chrome", "--root", "--script", "--timeout"].includes(key) || !args.length || values[key]) {
      throw new Error("usage: wasm_browser.mjs --chrome PATH --root DIR --script REL.mjs [--timeout MS]");
    }
    values[key] = args.shift();
  }
  if (!values["--chrome"] || !values["--root"] || !values["--script"]) throw new Error("chrome, root and script are required");
  if (isAbsolute(values["--script"]) || values["--script"].split(/[\\/]/).includes("..")) throw new Error("script must be a relative path under root");
  const timeout = Number(values["--timeout"] ?? 30000);
  if (!Number.isSafeInteger(timeout) || timeout <= 0) throw new Error("timeout must be a positive number of milliseconds");
  return { chrome: values["--chrome"], root: resolve(values["--root"]), script: values["--script"], timeout };
}

class CDP {
  constructor(socket) {
    this.socket = socket;
    this.next = 0;
    this.pending = new Map();
    this.listeners = new Map();
    socket.addEventListener("message", event => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pair = this.pending.get(message.id);
        if (!pair) return;
        this.pending.delete(message.id);
        if (message.error) pair.reject(new Error(message.error.message));
        else pair.resolve(message.result);
      } else {
        const key = `${message.sessionId ?? ""}:${message.method}`;
        for (const listener of this.listeners.get(key) ?? []) listener(message.params);
      }
    });
    socket.addEventListener("close", () => {
      for (const pair of this.pending.values()) pair.reject(new Error("browser connection closed"));
      this.pending.clear();
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.next;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  on(method, sessionId, listener) {
    const key = `${sessionId ?? ""}:${method}`;
    const listeners = this.listeners.get(key) ?? [];
    listeners.push(listener);
    this.listeners.set(key, listeners);
  }
}

async function main() {
  const { chrome, root, script, timeout } = argumentsOf(process.argv.slice(2));
  const realRoot = await realpath(root);
  const profile = await mkdtemp(join(tmpdir(), "iyi-chrome-"));
  const server = createServer(async (req, res) => {
    try {
      const pathname = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
      if (pathname === "/__iyi_runner__.html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end("<!doctype html><meta charset=utf-8><title>iyi wasm proof</title>");
        return;
      }
      const file = await realpath(resolve(realRoot, `.${pathname}`));
      const suffix = relative(realRoot, file);
      if (suffix === ".." || suffix.startsWith(`..${sep}`) || isAbsolute(suffix)) throw new Error("outside root");
      const bytes = await readFile(file);
      const type = extname(file) === ".mjs" ? "text/javascript" : "application/octet-stream";
      res.writeHead(200, { "Content-Type": type });
      res.end(bytes);
    } catch {
      res.writeHead(404);
      res.end();
    }
  });
  let child;
  let socket;
  let timer;
  let stderr = "";
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const port = server.address().port;
    child = spawn(chrome, ["--headless=new", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--disable-gpu", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
    child.stderr.on("data", data => { stderr = (stderr + data.toString()).slice(-8192); });
    let spawnError;
    child.once("error", error => { spawnError = error; });
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`browser proof timed out after ${timeout} ms`)), timeout);
    });
    const result = await Promise.race([deadline, (async () => {
      let active;
      while (!active) {
        if (spawnError) throw spawnError;
        if (child.exitCode !== null || child.signalCode !== null) throw new Error(`browser exited before DevTools was ready: ${stderr}`);
        try { active = await readFile(join(profile, "DevToolsActivePort"), "utf8"); }
        catch (error) { if (error.code !== "ENOENT") throw error; await sleep(25); }
      }
      const [debugPort, browserPath] = active.trim().split("\n");
      socket = new WebSocket(`ws://127.0.0.1:${debugPort}${browserPath}`);
      await new Promise((resolve, reject) => {
        socket.addEventListener("open", resolve, { once: true });
        socket.addEventListener("error", reject, { once: true });
      });
      const cdp = new CDP(socket);
      const version = await cdp.send("Browser.getVersion");
      console.log(`Browser ${version.product}`);
      console.log(`Browser.getVersion ${JSON.stringify(version)}`);
      console.log(`Browser argv ${JSON.stringify(child.spawnargs)}`);
      if (!isOwnedHeadless(version, child, profile)) throw new Error("refusing a non-headless browser or an unowned browser");
      const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
      await cdp.send("Runtime.enable", {}, sessionId);
      await cdp.send("Page.enable", {}, sessionId);
      const loaded = new Promise(resolve => cdp.on("Page.loadEventFired", sessionId, resolve));
      cdp.on("Runtime.consoleAPICalled", sessionId, event => {
        console.log(...event.args.map(arg => arg.value ?? arg.description ?? ""));
      });
      await cdp.send("Page.navigate", { url: `http://127.0.0.1:${port}/__iyi_runner__.html` }, sessionId);
      await loaded;
      const scriptUrl = `/${script.split("/").map(encodeURIComponent).join("/")}`;
      const expression = `(async () => {
        const { default: run } = await import(${JSON.stringify(scriptUrl)});
        return await run({
          load: async path => {
            const response = await fetch(path.startsWith('/') ? path : '/' + path);
            if (!response.ok) throw new Error('fetch failed: ' + path + ' (' + response.status + ')');
            return new Uint8Array(await response.arrayBuffer());
          },
          log: (...args) => console.log(...args),
        });
      })()`;
      const evaluation = await cdp.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
      if (evaluation.exceptionDetails) throw new Error(evaluation.exceptionDetails.exception?.description ?? evaluation.exceptionDetails.text);
      return evaluation.result.value;
    })()]);
    console.log(JSON.stringify(result));
    if (result?.ok !== true) throw new Error("browser script did not report ok: true");
  } finally {
    clearTimeout(timer);
    socket?.close();
    await cleanupOwnedBrowser(child, profile);
    await new Promise(resolve => server.close(resolve));
  }
}

const entry = process.argv[1] && await realpath(process.argv[1]).catch(() => null);
if (entry && import.meta.url === pathToFileURL(entry).href) {
  try {
    await main();
  } catch (error) {
    console.error(error?.stack ?? String(error));
    process.exitCode = 1;
  }
}
