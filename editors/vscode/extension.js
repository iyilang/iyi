// The whole client: spawn `iyi lsp`, hand it `.iyi` documents. The
// protocol negotiates everything else — highlighting arrives as
// semantic tokens, quickfixes as code actions, the import pair as
// completion edits — which is why this file has nothing to say.
const { window, workspace } = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");
const { locate, needsShell } = require("./server-path");

let client;

function activate(context) {
  const configured =
    workspace.getConfiguration("iyi").get("serverPath") || "iyi";
  // Not `configured` straight to spawn: an editor started before the
  // installer ran carries the PATH of that moment, so the binary is found
  // where the installers put it as well as on the PATH we were given.
  const command = locate(configured);
  client = new LanguageClient(
    "iyi",
    "iyi language server",
    { command, args: ["lsp"], options: { shell: needsShell(command) } },
    { documentSelector: [{ scheme: "file", language: "iyi" }] }
  );
  context.subscriptions.push(client);
  // A failed spawn is the one failure the protocol cannot report: without
  // this the window simply has no language server and never says so. After
  // the search above, ENOENT means the binary is not installed — or it was
  // installed after this window opened, which is the same to this process.
  client.start().catch((error) => {
    const missing = /ENOENT/.test(String(error && error.message));
    window.showErrorMessage(
      `iyi: could not start \`${command} lsp\`` +
        (missing
          ? ". Install iyi (https://iyi-lang.com), then reopen this window — " +
            "a running editor keeps the PATH it started with. If it lives " +
            "somewhere else, set `iyi.serverPath` to the binary."
          : ` (${error.message}).`)
    );
  });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
