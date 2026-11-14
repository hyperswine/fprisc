'use strict';
// Benchmarks Game fannkuch-redux, single-threaded (see ../SPEC.md).

function fannkuch(n) {
  const perm1 = new Int32Array(n);
  const perm = new Int32Array(n);
  const count = new Int32Array(n);
  for (let i = 0; i < n; i++) perm1[i] = i;
  let maxFlips = 0, checksum = 0, permIndex = 0, r = n;
  for (;;) {
    while (r !== 1) { count[r - 1] = r; r--; }
    perm.set(perm1);
    let flips = 0;
    let k = perm[0];
    while (k !== 0) {
      for (let i = 0, j = k; i < j; i++, j--) {
        const t = perm[i]; perm[i] = perm[j]; perm[j] = t;
      }
      flips++;
      k = perm[0];
    }
    if (flips > maxFlips) maxFlips = flips;
    checksum += (permIndex & 1) === 0 ? flips : -flips;
    for (;;) {
      if (r === n) return [checksum, maxFlips];
      const p0 = perm1[0];
      for (let i = 0; i < r; i++) perm1[i] = perm1[i + 1];
      perm1[r] = p0;
      count[r]--;
      if (count[r] > 0) break;
      r++;
    }
    permIndex++;
  }
}

const n = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 10;
const [checksum, maxFlips] = fannkuch(n);
process.stdout.write(`${checksum}\nPfannkuchen(${n}) = ${maxFlips}\n`);
