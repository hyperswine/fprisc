'use strict';
// Benchmarks Game n-body, single-threaded (see ../SPEC.md).

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

const PI = 3.141592653589793;
const SOLAR_MASS = 4 * PI * PI;
const DAYS_PER_YEAR = 365.24;

const bodies = [
  [0, 0, 0, 0, 0, 0, 1],
  [4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
   1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05,
   9.54791938424326609e-04],
  [8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
   -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05,
   2.85885980666130812e-04],
  [1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
   2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05,
   4.36624404335156298e-05],
  [1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
   2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05,
   5.15138902046611451e-05],
];

const NB = bodies.length;
const x = new Float64Array(NB), y = new Float64Array(NB), z = new Float64Array(NB);
const vx = new Float64Array(NB), vy = new Float64Array(NB), vz = new Float64Array(NB);
const m = new Float64Array(NB);
for (let i = 0; i < NB; i++) {
  const b = bodies[i];
  x[i] = b[0]; y[i] = b[1]; z[i] = b[2];
  vx[i] = b[3] * DAYS_PER_YEAR; vy[i] = b[4] * DAYS_PER_YEAR; vz[i] = b[5] * DAYS_PER_YEAR;
  m[i] = b[6] * SOLAR_MASS;
}

function offsetMomentum() {
  let px = 0, py = 0, pz = 0;
  for (let i = 0; i < NB; i++) {
    px += vx[i] * m[i]; py += vy[i] * m[i]; pz += vz[i] * m[i];
  }
  vx[0] = -px / SOLAR_MASS; vy[0] = -py / SOLAR_MASS; vz[0] = -pz / SOLAR_MASS;
}

function energy() {
  let e = 0;
  for (let i = 0; i < NB; i++) {
    e += 0.5 * m[i] * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]);
    for (let j = i + 1; j < NB; j++) {
      const dx = x[i] - x[j], dy = y[i] - y[j], dz = z[i] - z[j];
      e -= m[i] * m[j] / Math.sqrt(dx * dx + dy * dy + dz * dz);
    }
  }
  return e;
}

function advance(dt) {
  for (let i = 0; i < NB; i++) {
    const mi = m[i];
    for (let j = i + 1; j < NB; j++) {
      const dx = x[i] - x[j], dy = y[i] - y[j], dz = z[i] - z[j];
      const d2 = dx * dx + dy * dy + dz * dz;
      const mag = dt / (d2 * Math.sqrt(d2));
      const mj = m[j];
      vx[i] -= dx * mj * mag; vy[i] -= dy * mj * mag; vz[i] -= dz * mj * mag;
      vx[j] += dx * mi * mag; vy[j] += dy * mi * mag; vz[j] += dz * mi * mag;
    }
  }
  for (let i = 0; i < NB; i++) {
    x[i] += dt * vx[i]; y[i] += dt * vy[i]; z[i] += dt * vz[i];
  }
}

const n = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 5000000;
offsetMomentum();
let out = fmt(energy(), 9) + '\n';
for (let i = 0; i < n; i++) advance(0.01);
out += fmt(energy(), 9) + '\n';
process.stdout.write(out);
