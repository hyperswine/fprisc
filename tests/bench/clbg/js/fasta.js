'use strict';
// Benchmarks Game fasta, single-threaded (see ../SPEC.md).

const ALU = 'GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA';

const IUB = [['a', 0.27], ['c', 0.12], ['g', 0.12], ['t', 0.27],
  ['B', 0.02], ['D', 0.02], ['H', 0.02], ['K', 0.02], ['M', 0.02], ['N', 0.02],
  ['R', 0.02], ['S', 0.02], ['V', 0.02], ['W', 0.02], ['Y', 0.02]];
const HOMOSAPIENS = [['a', 0.3029549426680], ['c', 0.1979883004921],
  ['g', 0.1975473066391], ['t', 0.3015094502008]];

const LINE = 60;
const BUF_SIZE = 1 << 16;
let buf = Buffer.allocUnsafe(BUF_SIZE);
let pos = 0;

function flush() {
  if (pos > 0) {
    process.stdout.write(buf.subarray(0, pos));
    buf = Buffer.allocUnsafe(BUF_SIZE);
    pos = 0;
  }
}

function ensure(k) {
  if (pos + k > BUF_SIZE) flush();
}

function writeString(s) {
  ensure(s.length);
  pos += buf.write(s, pos, 'latin1');
}

function repeatFasta(header, src, count) {
  writeString(header + '\n');
  const s = Buffer.from(src, 'latin1');
  const len = s.length;
  let k = 0;
  while (count > 0) {
    const line = Math.min(LINE, count);
    ensure(line + 1);
    for (let i = 0; i < line; i++) {
      buf[pos++] = s[k];
      if (++k === len) k = 0;
    }
    buf[pos++] = 10;
    count -= line;
  }
}

const IM = 139968, IA = 3877, IC = 29573;
let seed = 42;
function random() {
  seed = (seed * IA + IC) % IM;
  return seed / IM;
}

function randomFasta(header, table, count) {
  writeString(header + '\n');
  const nt = table.length;
  const chars = new Uint8Array(nt);
  const cum = new Float64Array(nt);
  let acc = 0;
  for (let i = 0; i < nt; i++) {
    chars[i] = table[i][0].charCodeAt(0);
    acc += table[i][1];
    cum[i] = acc;
  }
  const lastIndex = nt - 1;
  while (count > 0) {
    const line = Math.min(LINE, count);
    ensure(line + 1);
    for (let i = 0; i < line; i++) {
      const r = random();
      let j = 0;
      while (j < lastIndex && cum[j] <= r) j++;
      buf[pos++] = chars[j];
    }
    buf[pos++] = 10;
    count -= line;
  }
}

const n = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 2500000;
repeatFasta('>ONE Homo sapiens alu', ALU, 2 * n);
randomFasta('>TWO IUB ambiguity codes', IUB, 3 * n);
randomFasta('>THREE Homo sapiens frequency', HOMOSAPIENS, 5 * n);
flush();
