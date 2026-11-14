'use strict';
// Benchmarks Game mandelbrot, single-threaded (see ../SPEC.md).

const n = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 4000;
const rowBytes = (n + 7) >> 3;
const header = Buffer.from(`P4\n${n} ${n}\n`, 'latin1');
const pixels = Buffer.alloc(rowBytes * n);
let pos = 0;
for (let y = 0; y < n; y++) {
  const ci = 2.0 * y / n - 1.0;
  let bits = 0;
  for (let x = 0; x < n; x++) {
    const cr = 2.0 * x / n - 1.5;
    let zr = 0.0, zi = 0.0, tr = 0.0, ti = 0.0;
    for (let i = 0; i < 50 && tr + ti <= 4.0; i++) {
      zi = 2.0 * zr * zi + ci;
      zr = tr - ti + cr;
      tr = zr * zr;
      ti = zi * zi;
    }
    bits = (bits << 1) | (tr + ti <= 4.0 ? 1 : 0);
    if ((x & 7) === 7) {
      pixels[pos++] = bits;
      bits = 0;
    }
  }
  if ((n & 7) !== 0) {
    pixels[pos++] = bits << (8 - (n & 7));
  }
}
process.stdout.write(Buffer.concat([header, pixels]));
