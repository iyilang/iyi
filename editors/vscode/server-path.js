// Finding `iyi`, because "it is on my PATH" and "it is on the PATH this
// editor was started with" are different sentences. A window open while the
// installer ran keeps the environment Explorer handed it — Windows
// broadcasts the change, a running process does not re-read it — and on
// macOS a GUI launch never reads a login shell's profile at all. Both end
// as `spawn iyi ENOENT` with the binary sitting where the installer put it.
//
// So: the PATH we did get, then the two prefixes the installers write.
// Pure, and parameterised by platform and environment, so the Windows
// branch is exercised from anywhere.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

function isExecutable(file, windows) {
  try {
    if (!fs.statSync(file).isFile()) return false;
    // The execute bit is a POSIX question; on Windows the extension is the
    // answer, and PATHEXT already asked it.
    if (!windows) fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// `iyi` names `iyi.exe` on Windows. `.exe` is tried before the rest of
// PATHEXT because node spawns one directly, while a `.bat` or `.cmd` needs a
// shell — and the shell is what the caller must know about.
function namesOf(command, windows, env) {
  if (!windows || path.win32.extname(command)) return [command];
  const exts = (env.PATHEXT || ".COM;.EXE;.BAT;.CMD")
    .split(";")
    .map((ext) => ext.trim().toLowerCase())
    .filter(Boolean);
  const exe = exts.filter((ext) => ext === ".exe");
  return [...exe, ...exts.filter((ext) => ext !== ".exe")].map(
    (ext) => command + ext
  );
}

// Where install.ps1 and install.sh put it, and what IYI_PREFIX overrode.
function prefixesOf(windows, env, home) {
  const prefixes = [];
  if (env.IYI_PREFIX) prefixes.push(env.IYI_PREFIX);
  if (windows) {
    if (env.LOCALAPPDATA)
      prefixes.push(path.win32.join(env.LOCALAPPDATA, "Programs", "iyi"));
  } else {
    prefixes.push(path.posix.join(home, ".local"), "/usr/local", "/usr");
  }
  return prefixes;
}

// The files a spawn of `command` would be satisfied by, in the order they
// are worth trying: everything the PATH we were handed offers first, then
// the prefixes. Separate from the filesystem so the order is a fact one can
// read — and check on a machine of the other kind.
function searchPath(command, options = {}) {
  const platform = options.platform || process.platform;
  const env = options.env || process.env;
  const home = options.home || os.homedir();
  const windows = platform === "win32";
  const p = windows ? path.win32 : path.posix;

  const dirs = (env.PATH || env.Path || "")
    .split(windows ? ";" : ":")
    .filter(Boolean);
  for (const prefix of prefixesOf(windows, env, home)) {
    dirs.push(p.join(prefix, "bin"));
  }

  const files = [];
  for (const dir of dirs) {
    for (const name of namesOf(command, windows, env)) {
      files.push(p.join(dir, name));
    }
  }
  return files;
}

// Returns an absolute path when one of those places has the binary, and the
// command unchanged when none does — the spawn then fails as it did before
// and the message names what was looked for.
function locate(command, options = {}) {
  const windows = (options.platform || process.platform) === "win32";

  // A path the user spelled out is the one to use, wrong or not: silently
  // running a different binary than the setting names is worse than ENOENT.
  if (command.includes("/") || (windows && command.includes("\\"))) {
    return command;
  }

  for (const file of searchPath(command, options)) {
    if (isExecutable(file, windows)) return file;
  }
  return command;
}

// `.bat` and `.cmd` are scripts cmd.exe runs; node refuses to spawn one
// without a shell, and says EINVAL when asked.
function needsShell(command, platform = process.platform) {
  return platform === "win32" && /\.(bat|cmd)$/i.test(command);
}

module.exports = { locate, needsShell, searchPath };
