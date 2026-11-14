'use strict';
// Benchmarks Game reverse-complement, single-threaded (see ../SPEC.md).

const fs = require('fs');

const LINE = 60;
const comp = new Uint8Array(256);
for (let i = 0; i < 256; i++) comp[i] = i;
const pairs = ['AT', 'CG', 'GC', 'TA', 'UA', 'MK', 'RY', 'WW', 'SS', 'YR', 'KM',
  'VB', 'HD', 'DH', 'BV', 'NN'];
for (const [from, to] of pairs) {
  comp[from.charCodeAt(0)] = to.charCodeAt(0);
  comp[from.toLowerCase().charCodeAt(0)] = to.charCodeAt(0);
}

const path = process.argv.length > 2 ? process.argv[2] : 'data/fasta-2500000.txt';
const input = fs.readFileSync(path);
const len = input.length;

// Output is at most the input plus one newline per 60 characters.
const out = Buffer.allocUnsafe(len + Math.ceil(len / LINE) + 1024);
let op = 0;
let seq = Buffer.allocUnsafe(1 << 20);

let p = 0;
while (p < len) {
  // header line, copied unchanged
  let nl = input.indexOf(10, p);
  if (nl < 0) nl = len;
  op += input.copy(out, op, p, nl);
  out[op++] = 10;
  p = nl + 1;
  // sequence lines up to the next '>' line, newlines removed
  let sl = 0;
  while (p < len && input[p] !== 62) {
    let e = input.indexOf(10, p);
    if (e < 0) e = len;
    const n = e - p;
    if (sl + n > seq.length) {
      const bigger = Buffer.allocUnsafe(Math.max(seq.length * 2, sl + n));
      seq.copy(bigger, 0, 0, sl);
      seq = bigger;
    }
    input.copy(seq, sl, p, e);
    sl += n;
    p = e + 1;
  }
  // reverse complement, 60 a line
  let col = 0;
  for (let i = sl - 1; i >= 0; i--) {
    out[op++] = comp[seq[i]];
    if (++col === LINE) { out[op++] = 10; col = 0; }
  }
  if (col > 0) out[op++] = 10;
}
process.stdout.write(out.subarray(0, op));
