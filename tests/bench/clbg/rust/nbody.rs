// Benchmarks Game n-body.

const PI: f64 = 3.141592653589793;
const SOLAR_MASS: f64 = 4.0 * PI * PI;
const DAYS_PER_YEAR: f64 = 365.24;

#[derive(Clone, Copy)]
struct Body {
    x: f64, y: f64, z: f64,
    vx: f64, vy: f64, vz: f64,
    mass: f64,
}

fn body(p: [f64; 7]) -> Body {
    Body {
        x: p[0], y: p[1], z: p[2],
        vx: p[3] * DAYS_PER_YEAR, vy: p[4] * DAYS_PER_YEAR, vz: p[5] * DAYS_PER_YEAR,
        mass: p[6] * SOLAR_MASS,
    }
}

fn initial() -> [Body; 5] {
    let mut b = [
        body([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]),
        body([4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
              1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05,
              9.54791938424326609e-04]),
        body([8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
              -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05,
              2.85885980666130812e-04]),
        body([1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
              2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05,
              4.36624404335156298e-05]),
        body([1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
              2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05,
              5.15138902046611451e-05]),
    ];
    let (mut px, mut py, mut pz) = (0.0, 0.0, 0.0);
    for x in b.iter() {
        px += x.vx * x.mass;
        py += x.vy * x.mass;
        pz += x.vz * x.mass;
    }
    b[0].vx = -px / SOLAR_MASS;
    b[0].vy = -py / SOLAR_MASS;
    b[0].vz = -pz / SOLAR_MASS;
    b
}

fn energy(b: &[Body; 5]) -> f64 {
    let mut e = 0.0;
    for i in 0..b.len() {
        let bi = &b[i];
        e += 0.5 * bi.mass * (bi.vx * bi.vx + bi.vy * bi.vy + bi.vz * bi.vz);
        for bj in &b[i + 1..] {
            let dx = bi.x - bj.x;
            let dy = bi.y - bj.y;
            let dz = bi.z - bj.z;
            e -= bi.mass * bj.mass / (dx * dx + dy * dy + dz * dz).sqrt();
        }
    }
    e
}

fn advance(b: &mut [Body; 5], dt: f64) {
    for i in 0..b.len() {
        let (head, tail) = b.split_at_mut(i + 1);
        let bi = &mut head[i];
        for bj in tail.iter_mut() {
            let dx = bi.x - bj.x;
            let dy = bi.y - bj.y;
            let dz = bi.z - bj.z;
            let d2 = dx * dx + dy * dy + dz * dz;
            let mag = dt / (d2 * d2.sqrt());
            bi.vx -= dx * bj.mass * mag;
            bi.vy -= dy * bj.mass * mag;
            bi.vz -= dz * bj.mass * mag;
            bj.vx += dx * bi.mass * mag;
            bj.vy += dy * bi.mass * mag;
            bj.vz += dz * bi.mass * mag;
        }
    }
    for x in b.iter_mut() {
        x.x += dt * x.vx;
        x.y += dt * x.vy;
        x.z += dt * x.vz;
    }
}

fn main() {
    let n: u64 = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(5_000_000);
    let mut b = initial();
    println!("{:.9}", energy(&b));
    for _ in 0..n {
        advance(&mut b, 0.01);
    }
    println!("{:.9}", energy(&b));
}
