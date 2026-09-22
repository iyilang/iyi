// The whole client: spawn `iyi lsp`, hand it `.iyi` documents. The
// protocol negotiates everything else — highlighting arrives as
// semantic tokens, quickfixes as code actions, the import pair as
// completion edits — which is why this file has nothing to say.
const { window, workspace } = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

function activate(context) {
  const command =
    workspace.getConfiguration("iyi").get("serverPath") || "iyi";
  client = new LanguageClient(
    "iyi",
    "iyi language server",
    { command, args: ["lsp"] },
    { documentSelector: [{ scheme: "file", language: "iyi" }] }
  );
  context.subscriptions.push(client);
  // A failed spawn is the one failure the protocol cannot report: without
  // this the window simply has no language server and never says so. The
  // cause is nearly always `iyi` missing from the PATH a GUI launch
  // inherits, so the message names the command and the setting that fixes it.
  client.start().catch((error) => {
    window.showErrorMessage(
      `iyi: could not start \`${command} lsp\` (${error.message}). ` +
        "Install iyi or set `iyi.serverPath` to the binary."
    );
  });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
