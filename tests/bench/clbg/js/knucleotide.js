'use strict';
// Benchmarks Game k-nucleotide, single-threaded (see ../SPEC.md).

const fs = require('fs');

// Fixed-point decimal formatting rounded like C printf (exact value, ties to even).
function fmt(x, d) {
  let s = x.toFixed(100);
  let neg = false;
  if (s[0] === '-') { neg = true; s = s.slice(1); }
  const dot = s.indexOf('.');
  const ip = s.slice(0, dot), fp = s.slice(dot + 1);
  let digits = ip + fp.slice(0, d);
  const rest = fp.slice(d);
  const last = digits.charCodeAt(digits.length - 1) - 48;
  if (rest[0] > '5' || (rest[0] === '5' && (/[1-9]/.test(rest.slice(1)) || (last & 1) === 1))) {
    digits = (BigInt(digits) + 1n).toString().padStart(digits.length, '0');
  }
  const head = digits.slice(0, digits.length - d) || '0';
  return (neg ? '-' : '') + head + (d > 0 ? '.' + digits.slice(digits.length - d) : '');
}

function readThree(path) {
  const text = fs.readFileSync(path, 'latin1');
  const lines = text.split('\n');
  let i = 0;
  while (i < lines.length && !lines[i].startsWith('>THREE')) i++;
  const parts = [];
  for (i++; i < lines.length && lines[i][0] !== '>'; i++) parts.push(lines[i]);
  return parts.join('').toUpperCase();
}

function count(seq, k) {
  const table = new Map();
  const end = seq.length - k + 1;
  for (let i = 0; i < end; i++) {
    const key = seq.substring(i, i + k);
    table.set(key, (table.get(key) || 0) + 1);
  }
  return table;
}

const path = process.argv.length > 2 ? process.argv[2] : 'data/fasta-1000000.txt';
const seq = readThree(path);
const out = [];
for (const k of [1, 2]) {
  const table = count(seq, k);
  const total = seq.length - k + 1;
  const entries = [...table.entries()];
  entries.sort((a, b) => (b[1] - a[1]) || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  for (const [kmer, c] of entries) out.push(`${kmer} ${fmt(100 * c / total, 3)}`);
  out.push('');
}
for (const kmer of ['GGT', 'GGTA', 'GGTATT', 'GGTATTTTAATT', 'GGTATTTTAATTTATAGT']) {
  const table = count(seq, kmer.length);
  out.push(`${table.get(kmer) || 0}\t${kmer}`);
}
process.stdout.write(out.join('\n') + '\n');
