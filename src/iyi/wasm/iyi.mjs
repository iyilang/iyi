// Host bindings for wasm32-unknown-unknown. No WASI or Node dependency.
export class IyiExit extends Error {
  constructor(code) {
    super(`iyi exited with status ${code}`);
    this.name = "IyiExit";
    this.code = code;
  }
}

function consoleWriter(method) {
  const decoder = new TextDecoder();
  let pending = "";
  const write = bytes => {
    pending += decoder.decode(bytes, { stream: true });
    let end;
    while ((end = pending.indexOf("\n")) !== -1) {
      method(pending.slice(0, end));
      pending = pending.slice(end + 1);
    }
  };
  write.flush = () => {
    pending += decoder.decode();
    if (pending) method(pending);
    pending = "";
  };
  return write;
}

export async function instantiate(source, options = {}) {
  if (options.imports && Object.prototype.hasOwnProperty.call(options.imports, "iyi")) {
    throw new TypeError('the "iyi" import module is reserved');
  }
  const defaultStdout = options.stdout == null ? consoleWriter(console.log.bind(console)) : null;
  const defaultStderr = options.stderr == null ? consoleWriter(console.error.bind(console)) : null;
  const stdout = options.stdout ?? defaultStdout;
  const stderr = options.stderr ?? defaultStderr;
  const stdin = options.stdin ?? (() => null);
  let instance;
  let input = new Uint8Array(0);
  let inputOffset = 0;

  function view(ptr, len) {
    const start = ptr >>> 0;
    const count = len >>> 0;
    const buffer = instance.exports.memory.buffer;
    if (start > buffer.byteLength || count > buffer.byteLength - start) {
      throw new RangeError("iyi memory range is out of bounds");
    }
    return new Uint8Array(buffer, start, count);
  }

  const host = {
    write(fd, ptr, len) {
      if (fd !== 1 && fd !== 2) return -1;
      try {
        (fd === 1 ? stdout : stderr)(view(ptr, len).slice());
        return len;
      } catch {
        return -1;
      }
    },
    read(fd, ptr, len) {
      if (fd !== 0) return -1;
      try {
        if (inputOffset === input.length) {
          input = stdin() ?? new Uint8Array(0);
          if (!(input instanceof Uint8Array)) throw new TypeError("stdin must return Uint8Array or null");
          inputOffset = 0;
        }
        const count = Math.min(len >>> 0, input.length - inputOffset);
        view(ptr, count).set(input.subarray(inputOffset, inputOffset + count));
        inputOffset += count;
        return count;
      } catch {
        return -1;
      }
    },
    exit(code) {
      throw new IyiExit(code);
    },
    clock_ns(clock) {
      if (clock === 0) return BigInt(Date.now()) * 1000000n;
      if (clock === 1) return BigInt(Math.floor(performance.now() * 1000000));
      return 0n;
    },
    random(ptr, len) {
      try {
        const bytes = view(ptr, len);
        for (let offset = 0; offset < bytes.length; offset += 65536) {
          globalThis.crypto.getRandomValues(bytes.subarray(offset, offset + 65536));
        }
        return 0;
      } catch {
        return -1;
      }
    },
  };

  source = await source;
  if (typeof Response !== "undefined" && source instanceof Response) {
    if (!source.ok) throw new Error(`fetching wasm failed: HTTP ${source.status}`);
    source = await source.arrayBuffer();
  }
  const module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
  instance = await WebAssembly.instantiate(module, { ...options.imports, iyi: host });
  const exports = instance.exports;
  if (!(exports.memory instanceof WebAssembly.Memory) ||
      typeof exports.iyi_start !== "function" || typeof exports.iyi_alloc !== "function" ||
      typeof exports.iyi_free !== "function") {
    throw new TypeError("module does not export the iyi freestanding runtime");
  }

  let started = false;
  const iyi = {
    instance,
    module,
    exports,
    memory: exports.memory,
    async start() {
      if (started) return -1;
      started = true;
      try {
        return exports.iyi_start();
      } catch (error) {
        if (error instanceof IyiExit) return error.code;
        throw error;
      } finally {
        defaultStdout?.flush();
        defaultStderr?.flush();
      }
    },
    alloc(size) {
      if (!started) throw new Error("call start() before allocating");
      if (!Number.isInteger(size) || size < 0 || size > 0x7fffffff) throw new RangeError("invalid allocation size");
      const ptr = exports.iyi_alloc(size) >>> 0;
      if (ptr === 0) throw new Error("iyi allocation failed");
      return ptr;
    },
    free(ptr) {
      if (!started) throw new Error("call start() before freeing");
      exports.iyi_free(ptr);
    },
    put(value) {
      let bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
      if (!(bytes instanceof Uint8Array)) throw new TypeError("put expects a string or Uint8Array");
      // Allocation can grow memory and detach an input view into that memory.
      if (bytes.buffer === exports.memory.buffer) bytes = new Uint8Array(bytes);
      const ptr = iyi.alloc(bytes.length);
      view(ptr, bytes.length).set(bytes);
      return { ptr, len: bytes.length };
    },
    bytes(ptr, len) {
      return view(ptr, len).slice();
    },
    string(ptr, len) {
      return new TextDecoder().decode(view(ptr, len));
    },
    async call(name, ...args) {
      if (!started) throw new Error("call start() before calling an export");
      if (typeof exports[name] !== "function") throw new TypeError(`unknown iyi export: ${name}`);
      try {
        return exports[name](...args);
      } finally {
        defaultStdout?.flush();
        defaultStderr?.flush();
      }
    },
  };
  if (options.start !== false) await iyi.start();
  return iyi;
}
