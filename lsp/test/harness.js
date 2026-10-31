'use strict';
// harness.js <file.fpr> -- speak LSP to server.js over stdio and report:
// outline, plus definition checks for words given as line:col pairs.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const file = process.argv[2];
let semLine = 0;
const probes = process.argv.slice(3).filter(p => {
  if (p.startsWith('sem:')) { semLine = +p.slice(4); return false; }
  return true;
});
const text = fs.readFileSync(file, 'utf8');
const uri = 'file://' + path.resolve(file);

const srv = spawn(process.execPath, [path.join(__dirname, '..', 'server', 'server.js')], { stdio: ['pipe', 'pipe', 'inherit'] });

let buf = Buffer.alloc(0);
const pending = new Map();
let nextId = 1;
let diagnostics = null;

srv.stdout.on('data', (c) => {
  buf = Buffer.concat([buf, c]);
  while (true) {
    const he = buf.indexOf('\r\n\r\n');
    if (he === -1) return;
    const m = buf.slice(0, he).toString().match(/Content-Length:\s*(\d+)/i);
    const len = parseInt(m[1], 10);
    if (buf.length < he + 4 + len) return;
    const body = JSON.parse(buf.slice(he + 4, he + 4 + len).toString('utf8'));
    buf = buf.slice(he + 4 + len);
    if (body.id !== undefined && pending.has(body.id)) {
      pending.get(body.id)(body);
      pending.delete(body.id);
    } else if (body.method === 'textDocument/publishDiagnostics') {
      diagnostics = body.params.diagnostics;
    }
  }
});

function send(obj) {
  const b = Buffer.from(JSON.stringify(obj), 'utf8');
  srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`);
  srv.stdin.write(b);
}
function request(method, params) {
  return new Promise((res) => {
    const id = nextId++;
    pending.set(id, res);
    send({ jsonrpc: '2.0', id, method, params });
  });
}
function notify(method, params) { send({ jsonrpc: '2.0', method, params }); }

const KIND = { 2:'mod',3:'ns',5:'class',6:'meth',8:'field',9:'ctor',10:'type',11:'sig',12:'fn',13:'var',14:'const',22:'emem',23:'struct',24:'txn' };

(async () => {
  await request('initialize', { capabilities: {} });
  notify('initialized', {});
  notify('textDocument/didOpen', { textDocument: { uri, languageId: file.endsWith('.sol') ? 'sol' : 'fpr', version: 1, text } });

  const syms = (await request('textDocument/documentSymbol', { textDocument: { uri } })).result;
  console.log(`== outline of ${path.basename(file)} (${syms.length} top-level) ==`);
  for (const s of syms.slice(0, 200)) {
    const kids = s.children.length ? `  [${s.children.map((c) => c.name).join(' ')}]` : '';
    console.log(`  ${String(s.range.start.line + 1).padStart(4)}  ${String(KIND[s.kind] || s.kind).padEnd(6)} ${s.name}${s.detail ? '  :: ' + s.detail : ''}${kids}`);
  }

  const lines = text.split(/\r?\n/);
  for (const p of probes) {
    const hover = p.startsWith('h:');
    const [l, c, label] = (hover ? p.slice(2) : p).split(':');
    const pos = { line: +l - 1, character: +c - 1 };
    const at = lines[pos.line].slice(Math.max(0, pos.character - 10), pos.character + 12);
    if (hover) {
      const r = (await request('textDocument/hover', { textDocument: { uri }, position: pos })).result;
      console.log(`hover ${label || p}: "${at.trim()}" ->`);
      console.log(r ? r.contents.value.split('\n').map(x => '    | ' + x).join('\n') : '    | NOT FOUND');
    } else {
      const r = (await request('textDocument/definition', { textDocument: { uri }, position: pos })).result;
      if (r) {
        const tgt = r.uri === uri ? lines : fs.readFileSync(r.uri.replace('file://',''), 'utf8').split(/\r?\n/);
        const where = r.uri === uri ? '' : ` [${path.basename(r.uri)}]`;
        console.log(`def ${label || p}: "${at.trim()}" -> line ${r.range.start.line + 1}${where}: ${tgt[r.range.start.line].trim().slice(0, 70)}`);
      } else {
        console.log(`def ${label || p}: "${at.trim()}" -> NOT FOUND`);
      }
    }
  }
  // semantic tokens summary
  const st = (await request('textDocument/semanticTokens/full', { textDocument: { uri } })).result;
  if (st && st.data.length) {
    const TYPES=['ns','type','enum','fn','param','var','prop'];
    let l=0,c=0,counts={},sample=[];
    for(let i=0;i<st.data.length;i+=5){
      l+=st.data[i]; c=st.data[i]===0?c+st.data[i+1]:st.data[i+1];
      const t=TYPES[st.data[i+3]]+(st.data[i+4]&1?'*':'')+(st.data[i+4]&2?'!':'');
      counts[t]=(counts[t]||0)+1;
      if(sample.length<14&&l===semLine-1)sample.push(`${lines[l].substr(c,st.data[i+2])}:${t}`);
    }
    console.log('== semantic tokens ==', JSON.stringify(counts));
    if(sample.length)console.log(`  line ${semLine}:`, sample.join('  '));
  }
  await new Promise(r=>setTimeout(r,100));
  if (diagnostics) {
    console.log(`== diagnostics (${diagnostics.length}) ==`);
    for (const d of diagnostics.slice(0,10)) console.log(`  L${d.range.start.line+1}:${d.range.start.character+1} [sev${d.severity}] ${d.message.slice(0,90)}`);
  }
  notify('exit', {});
})();
