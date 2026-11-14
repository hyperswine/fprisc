'use strict';
// Benchmarks Game spectral-norm, single-threaded (see ../SPEC.md).

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

function a(i, j) {
  return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1);
}

function av(n, v, out) {
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let j = 0; j < n; j++) s += a(i, j) * v[j];
    out[i] = s;
  }
}

function atv(n, v, out) {
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let j = 0; j < n; j++) s += a(j, i) * v[j];
    out[i] = s;
  }
}

function atav(n, v, out, tmp) {
  av(n, v, tmp);
  atv(n, tmp, out);
}

const n = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 2000;
const u = new Float64Array(n).fill(1.0);
const v = new Float64Array(n);
const tmp = new Float64Array(n);
for (let i = 0; i < 10; i++) {
  atav(n, u, v, tmp);
  atav(n, v, u, tmp);
}
let vBv = 0, vv = 0;
for (let i = 0; i < n; i++) {
  vBv += u[i] * v[i];
  vv += v[i] * v[i];
}
process.stdout.write(fmt(Math.sqrt(vBv / vv), 9) + '\n');
