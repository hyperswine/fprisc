'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { pathToFileURL } = require('url');
const { spawn } = require('child_process');
const root = path.resolve(__dirname, '..');
const home = path.resolve(process.argv[2] || path.join(root, '..'));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-lsp-'));
const srv = spawn(process.execPath, [path.join(root, 'server/server.js')]);
let buffer = Buffer.alloc(0), id = 0;
const pending = new Map();
const diagnostics = new Map();
const timer = setTimeout(() => { console.error('LSP test timed out'); srv.kill(); process.exitCode = 1; }, 15000);
srv.stdout.on('data', chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const end = buffer.indexOf('\r\n\r\n');
    if (end < 0) return;
    const length = +buffer.subarray(0, end).toString().match(/Content-Length: (\d+)/i)[1];
    if (buffer.length < end + 4 + length) return;
    const message = JSON.parse(buffer.subarray(end + 4, end + 4 + length));
    buffer = buffer.subarray(end + 4 + length);
    if (message.method === 'textDocument/publishDiagnostics') diagnostics.set(message.params.uri, message.params.diagnostics);
    const resolve = pending.get(message.id);
    if (resolve) { pending.delete(message.id); resolve(message); }
  }
});
function send(method, params, requestId) {
  const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: requestId, method, params }));
  srv.stdin.write(`Content-Length: ${body.length}\r\n\r\n`); srv.stdin.write(body);
}
async function request(method, params) {
  const result = await new Promise(resolve => { pending.set(++id, resolve); send(method, params, id); });
  assert(!result.error, JSON.stringify(result.error)); return result.result;
}
const uri = file => pathToFileURL(file).href;
function open(file, text) { send('textDocument/didOpen', { textDocument: { uri: uri(file), languageId: file.endsWith('.sol') ? 'sol' : 'fpr', version: 1, text } }); }
const ask = (method, file, line=0, character=0) => request('textDocument/' + method, { textDocument: { uri: uri(file) }, position: { line, character } });
(async () => {
  const caps = await request('initialize', { rootUri: uri(temp), initializationOptions: { home } });
  assert(caps.capabilities.completionProvider);
  const file = path.join(temp, 'app.fpr');
  open(file, 'profile base.\nTerm = use "std/term".\nmain = Term.run.\nEv msg = Type (Msg msg | Quit).\nBlock = Layout { size : Word, next : Block }.\nModel = { count : Int }.\n# Foreign docs\nOs.poll : List Int -> List Int.\ncodec = @Ev.\nvalue = Os.poll Nil.\nprobe = timeNow 0.');
  const symbols = await ask('documentSymbol', file);
  assert.equal(symbols.find(s => s.name === 'Ev').kind, 10);
  assert.deepEqual(symbols.find(s => s.name === 'Ev').children.map(s => s.name), ['Msg', 'Quit']);
  assert(symbols.find(s => s.name === 'Block').children.some(s => s.name === 'next'));
  assert.equal(symbols.find(s => s.name === 'Model').kind, 23);
  const def = await ask('definition', file, 2, 13);
  assert.equal(def.uri, uri(path.join(home, 'std/term.fpr')));
  const complete = await ask('completion', file, 2, 12);
  assert(complete.some(s => s.label === 'run'));
  assert((await ask('hover', file, 7, 4)).contents.value.includes('Foreign docs'));
  assert.equal((await ask('definition', file, 9, 12)).range.start.line, 7);
  assert((await ask('hover', file, 8, 10)).contents.value.includes('wire codec'));
  assert.equal(await ask('hover', file, 10, 10), null);
  assert(!(await ask('completion', file, 10, 0)).some(s => s.label === 'timeNow'));
  const sem = (await ask('semanticTokens/full', file)).data;
  let line=0, col=0;
  for(let i=0;i<sem.length;i+=5) { line+=sem[i]; col=sem[i] ? sem[i+1] : col+sem[i+1]; assert(!(line===10 && col===8), 'Sol-only builtin must not get an AOT semantic token'); }
  open(path.join(home, 'std/term.fpr'), 'fresh x = x.');
  assert((await ask('completion', file, 2, 12)).some(s => s.label === 'fresh'), 'unsaved imports are used');
  const local = path.join(temp, 'std'); fs.mkdirSync(local); fs.writeFileSync(path.join(local, 'term.fpr'), 'local x = x.');
  assert((await ask('completion', file, 2, 12)).some(s => s.label === 'local'), 'importer-relative modules take priority');
  const extra = path.join(temp, 'extra'); fs.mkdirSync(extra); fs.writeFileSync(path.join(extra, 'other.fpr'), 'found x = x.');
  send('workspace/didChangeConfiguration', { settings: { fpr: { home, modulePaths: [extra] } } });
  open(file, 'X = use "other".\nmain = X.found 1.');
  assert.equal((await ask('definition', file, 1, 11)).uri, uri(path.join(extra, 'other.fpr')));
  const sol = path.join(temp, 'app.sol'); open(sol, 'x = timeNow 0.');
  assert((await ask('hover', sol, 0, 6)).contents.value.includes('timeNow'));
  for (const ext of ['fpr', 'sol']) {
    const colors = path.join(temp, 'colors.' + ext);
    const source = 'x : Int.\nx = 42.\ny = x.\nidentity a = a.\nclosure = fn a -> a.\nitems : List Int.\nitems = Nil.\ncopy = identity x.';
    open(colors, source);
    const outline = await ask('documentSymbol', colors);
    assert.equal(outline.filter(s => s.name === 'x').length, 1, 'a value signature must not duplicate the symbol');
    assert.equal(outline.find(s => s.name === 'x').kind, 13);
    assert.equal(outline.find(s => s.name === 'identity').kind, 12);
    assert.equal(outline.find(s => s.name === 'closure').kind, 12);
    const data = (await ask('semanticTokens/full', colors)).data;
    const tokens = new Map(); let row = 0, column = 0;
    for (let i = 0; i < data.length; i += 5) {
      row += data[i]; column = data[i] ? data[i+1] : column + data[i+1];
      tokens.set(`${row}:${column}`, caps.capabilities.semanticTokensProvider.legend.tokenTypes[data[i+3]]);
    }
    for (const [position, kind] of Object.entries({ '0:4':'type', '1:0':'variable', '2:4':'variable', '3:0':'function', '4:0':'function', '5:8':'type', '5:13':'type', '6:0':'variable', '7:7':'function', '7:16':'variable' }))
      assert.equal(tokens.get(position), kind, `${ext} semantic category at ${position}`);
    const imported = path.join(temp, 'consumer.' + ext);
    open(imported, 'C = use "colors".\nresult = C.x.');
    const memberTokens = (await ask('semanticTokens/full', imported)).data;
    let l=0, c=0, found;
    for (let i=0; i<memberTokens.length; i+=5) { l+=memberTokens[i]; c=memberTokens[i] ? memberTokens[i+1] : c+memberTokens[i+1]; if(l===1 && c===11) found=caps.capabilities.semanticTokensProvider.legend.tokenTypes[memberTokens[i+3]]; }
    assert.equal(found, 'variable', 'imported values keep variable coloring');
    const grammar = JSON.parse(fs.readFileSync(path.join(root, `syntaxes/${ext}.tmLanguage.json`)));
    const valueRule = new RegExp(grammar.repository.valueDef.match);
    assert(valueRule.test('x = 42.'));
    assert(!valueRule.test('f x = x.'));
    assert(!valueRule.test('f = fn x -> x.'));
    assert(grammar.patterns.findIndex(p => p.include === '#valueDef') < grammar.patterns.findIndex(p => p.include === '#topDef'));
  }
  const civil = `civil days =
  z = days + 719468;
  era = (case z >= 0 of True -> z | False -> z - 146096) / 146097;
  doe = z - era * 146097;
  yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  mp = (5 * doy + 2) / 153;
  d = doy - (153 * mp + 2) / 5 + 1;
  m = case mp < 10 of True -> mp + 3 | False -> mp - 9;
  y = yoe + era * 400 + (case m <= 2 of True -> 1 | False -> 0);
  (y, m, d).
other days = z.
shadow days = str = days; str.
record days = rec = { field = days }; rec.
scoped days = (inside = days; inside).
outside days = inside.
inline days = first = days; second = first; second.
`;
  for (const ext of ['fpr', 'sol']) {
    const file = path.join(temp, 'locals.' + ext);
    open(file, civil);
    const data = (await ask('semanticTokens/full', file)).data;
    const tokens = new Map(); let line = 0, col = 0;
    for (let i=0; i<data.length; i+=5) {
      line+=data[i]; col=data[i] ? data[i+1] : col+data[i+1];
      tokens.set(`${line}:${col}`, { type: caps.capabilities.semanticTokensProvider.legend.tokenTypes[data[i+3]], mods: data[i+4] });
    }
    const lines = civil.split('\n');
    for (let line=0; line<=10; line++) {
      for (const m of lines[line].matchAll(/\b(z|era|doe|yoe|doy|mp|d|m|y|days)\b/g)) {
        assert.equal(tokens.get(`${line}:${m.index}`)?.type, m[0] === 'days' ? 'parameter' : 'variable', `${ext}: ${m[0]} on line ${line+1}`);
        if (line>0 && m.index===2 && line<10) assert.equal(tokens.get(`${line}:${m.index}`).mods, 2, 'local declaration modifier');
      }
    }
    assert(!tokens.has('11:13'), 'locals do not leak to another clause');
    for (const m of lines[12].matchAll(/\bstr\b/g)) assert.equal(tokens.get(`12:${m.index}`)?.type, 'variable', 'locals shadow builtin functions');
    assert(!tokens.has(`13:${lines[13].indexOf('field')}`), 'record fields are not local variables');
    assert(!tokens.has(`15:${lines[15].indexOf('inside')}`), 'nested locals do not leak');
    for (const m of lines[16].matchAll(/\b(first|second)\b/g)) assert.equal(tokens.get(`16:${m.index}`)?.type, 'variable', 'inline sequential bindings');
  }
  for (const ext of ['fpr', 'sol']) {
    const file = path.join(temp, 'cases.' + ext);
    const source = `unwrap input = case input of
  Ok (head :: tail) -> (head, tail)
  | Err problem -> problem.
nested input = case input of
  Ok outer -> (case outer of Some inner -> inner | None -> outer)
  | Err failure -> outer.
shadow input = case input of Ok str -> str | Err failure -> str failure.
`;
    open(file, source);
    const data = (await ask('semanticTokens/full', file)).data;
    const actual = new Map(); let line=0, col=0;
    for (let i=0; i<data.length; i+=5) {
      line+=data[i]; col=data[i] ? data[i+1] : col+data[i+1];
      actual.set(`${line}:${col}`, { type: caps.capabilities.semanticTokensProvider.legend.tokenTypes[data[i+3]], mods:data[i+4] });
    }
    const lines=source.split('\n');
    for (const [line,names] of [[1,['head','tail']],[2,['problem']],[4,['outer','inner']],[5,['failure']]]) {
      for (const name of names) for (const m of lines[line].matchAll(new RegExp(`\\b${name}\\b`, 'g')))
        assert.equal(actual.get(`${line}:${m.index}`)?.type, 'variable', `${ext} case binding ${name}`);
    }
    assert.equal(actual.get('1:6').mods, 2, 'case pattern declaration is marked');
    assert(!actual.has(`5:${lines[5].indexOf('outer')}`), 'no binding in sibling arm');
    const strPositions=[...lines[6].matchAll(/\bstr\b/g)].map(m=>m.index);
    assert.deepEqual(strPositions.map(col=>actual.get(`6:${col}`)?.type), ['variable','variable','function'], 'branch shadowing ends at next arm');
  }
  for (const ext of ['fpr', 'sol']) {
    const file = path.join(temp, 'diagnostics.' + ext);
    const source = `good days =
  z = days + 1;
  fn n -> z + n.
match input = case input of Ok item -> item | Err problem -> problem.
record r = { count = r.count, text = "unknownName" }.
number = 0xff + 1.25e3.
hole = ?todo.
missing x = misspelled x + anotherMissing.
`;
    open(file, source);
    await ask('documentSymbol', file);
    const got = diagnostics.get(uri(file));
    assert.deepEqual(got.map(d => source.split('\n')[d.range.start.line].slice(d.range.start.character,d.range.end.character)), ['misspelled','anotherMissing']);
    assert(got.every(d => d.severity === 3 && d.code === 'unresolved-name'));
    open(file, 'fixed x = x.');
    await ask('documentSymbol', file);
    assert.deepEqual(diagnostics.get(uri(file)), [], 'fixing a name clears the squiggle');
    send('workspace/didChangeConfiguration', { settings: { fpr: { home, unresolvedNames:false } } });
    open(file, 'bad x = nonexistent x.');
    await ask('documentSymbol', file);
    assert.deepEqual(diagnostics.get(uri(file)), [], 'diagnostics can be disabled');
    send('workspace/didChangeConfiguration', { settings: { fpr: { home, unresolvedNames:true } } });
    await ask('documentSymbol', file);
    assert.equal(diagnostics.get(uri(file)).length, 1, 'configuration changes refresh diagnostics');
  }
  const consumer = path.join(temp, 'unresolved-import.fpr');
  const library = path.join(temp, 'diag-lib.fpr');
  open(library, 'first x = x.\nsecond x = x.\nthird x = x.');
  open(consumer, 'Lib = use "diag-lib".\nx = Lib.absent 1.\ny = F64.absent 1.');
  await ask('documentSymbol', consumer);
  assert.equal(diagnostics.get(uri(consumer)).length, 2, 'unknown imported and builtin members');
  open(library, 'first x = x.\nsecond x = x.\nthird x = x.\nabsent x = x.');
  await ask('documentSymbol', consumer);
  assert.equal(diagnostics.get(uri(consumer)).length, 1, 'editing an imported module refreshes dependent squiggles');
  for (const ext of ['fpr', 'sol']) {
    const file = path.join(temp, 'unsafe-calls.' + ext);
    const lib = path.join(temp, 'unsafe-lib.' + ext);
    const blanket = path.join(temp, 'blanket.' + ext);
    open(lib, 'danger : unsafe Int -> Int.\ndanger x = x.\nsafe x = x.');
    open(blanket, 'unsafe module.\nrun x = x.');
    const source = `Lib = use "unsafe-lib".
Blanket = use "blanket".
danger : unsafe Int -> Int.
danger x = danger x.
safe x = x.
alias = Lib.danger.
a x = danger x.
b x = Lib.danger x.
c x = alias x.
d x = x |> danger.
e x = (danger) x.
f x = safe x.
g danger = danger 1.
h x = danger = safe; danger x.
i x = case x of Ok danger -> danger 1 | Err problem -> 0.
j = fn danger -> danger 1.
k x = Blanket.run x.
reference = danger.
text = "danger 1". # danger 1
`;
    send('workspace/didChangeConfiguration', { settings: { fpr: { home, unresolvedNames:false } } });
    open(file, source);
    await ask('documentSymbol', file);
    assert.deepEqual(diagnostics.get(uri(file)), [], 'unsafe-call diagnostics are off by default');
    send('workspace/didChangeConfiguration', { settings: { fpr: { home, unresolvedNames:false, unsafeCalls:true } } });
    await ask('documentSymbol', file);
    const got = diagnostics.get(uri(file));
    assert.deepEqual(got.map(d=>d.range.start.line), [3,6,7,8,9,10,16], `${ext}: only unsafe call sites`);
    assert(got.every(d=>d.code==='unsafe-call' && d.severity===3));
    assert.deepEqual(got.map(d=>source.split('\n')[d.range.start.line].slice(d.range.start.character,d.range.end.character)), ['danger','danger','danger','alias','danger','danger','run'], 'underline symbol only');
    open(lib, 'danger : Int -> Int.\ndanger x = x.\nsafe x = x.');
    await ask('documentSymbol', file);
    assert.deepEqual(diagnostics.get(uri(file)).map(d=>d.range.start.line), [3,6,9,10,16], 'import signature changes refresh callers');
    send('workspace/didChangeConfiguration', { settings: { fpr: { home, unresolvedNames:false, unsafeCalls:false } } });
    await ask('documentSymbol', file);
    assert.deepEqual(diagnostics.get(uri(file)), [], 'switching off clears underlines');
  }
  console.log('current-api: all LSP regression checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => { clearTimeout(timer); srv.kill(); fs.rmSync(temp, { recursive: true, force: true }); });
