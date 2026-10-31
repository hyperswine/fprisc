'use strict';
const path = require('path');
const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

function activate(context) {
  const serverModule = context.asAbsolutePath(path.join('server', 'server.js'));
  const serverOptions = {
    run: { module: serverModule, transport: TransportKind.stdio },
    debug: { module: serverModule, transport: TransportKind.stdio },
  };
  const settings = vscode.workspace.getConfiguration('fpr');
  const clientOptions = {
    initializationOptions: {
      home: settings.get('home'), modulePaths: settings.get('modulePaths'),
      unresolvedNames: settings.get('unresolvedNames'), unsafeCalls: settings.get('unsafeCalls'),
      check: settings.get('check'), compilerPath: settings.get('compilerPath'), checkArgs: settings.get('checkArgs'),
    },
    synchronize: { configurationSection: 'fpr' },
    documentSelector: [{ scheme: 'file', language: 'fpr' }, { scheme: 'file', language: 'sol' }],
  };
  client = new LanguageClient('fprLs', 'FP-RISC Language Server', serverOptions, clientOptions);
  const ready = client.start();
  const output = vscode.window.createOutputChannel('FP-RISC Optimization Remarks');
  context.subscriptions.push(output);
  const sourceWatcher = vscode.workspace.createFileSystemWatcher('**/*.{fpr,sol,toml}');
  const changed = type => uri => ready.then(() => client.sendNotification('workspace/didChangeWatchedFiles',
    { changes: [{ uri: uri.toString(), type }] })).catch(() => {});
  context.subscriptions.push(sourceWatcher, sourceWatcher.onDidCreate(changed(1)),
    sourceWatcher.onDidChange(changed(2)), sourceWatcher.onDidDelete(changed(3)));
  client.onNotification('fpr/remarksInvalidated', ({ message }) => {
    output.clear(); output.appendLine(`Remarks invalidated: ${message}. Run the command again.`);
  });
  context.subscriptions.push(vscode.commands.registerCommand('fpr.showOptimizationRemarks', async () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'fpr' || editor.document.uri.scheme !== 'file') {
      vscode.window.showInformationMessage('Open a native FP-RISC file to show optimization remarks.'); return;
    }
    const document = editor.document;
    if (document.isDirty) { vscode.window.showInformationMessage('Save the file before requesting optimization remarks.'); return; }
    const version = document.version;
    await ready;
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification,
      title: 'FP-RISC: computing optimization remarks', cancellable: true }, async (_, token) => {
      const cancellation = token.onCancellationRequested(() => client.sendNotification('fpr/cancelOptimizationRemarks', {}).catch(() => {}));
      try {
        const result = await client.sendRequest('fpr/optimizationRemarks', { uri: document.uri.toString() });
        if (token.isCancellationRequested || document.version !== version || result.status === 'cancelled') return;
        if (result.status !== 'ok') { vscode.window.showInformationMessage(result.message || 'Remarks are unavailable.'); return; }
        output.clear();
        const records = result.records.filter(r => r.file === document.uri.fsPath);
        output.appendLine(`Optimization remarks for ${document.uri.fsPath} (definition summaries; pass attempts, not final-code guarantees)`);
        for (const r of records) output.appendLine(`${r.file}:${r.start ? r.start.line + 1 : 1}: ${r.owner}: [${r.kind}/${r.outcome}] ${r.message}`);
        if (!records.length) output.appendLine('No located optimization remarks for this file.');
        output.show(true);
      } catch (e) { vscode.window.showErrorMessage(`FP-RISC remarks: ${e.message}`); }
      finally { cancellation.dispose(); }
    });
  }));
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
