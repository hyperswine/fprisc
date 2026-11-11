// sim: particle simulation (SPEC.md)
const NP: usize = 20_000;
const STEPS: usize = 2_000;

#[derive(Clone, Copy)]
struct Particle {
    px: i64,
    py: i64,
    vx: i64,
    vy: i64,
}

fn lcg(x: i64) -> i64 {
    (x * 1103515245 + 12345) % 2147483648
}

fn main() {
    let mut ps: Vec<Particle> = Vec::with_capacity(NP);
    let mut x: i64 = 1;
    for _ in 0..NP {
        x = lcg(x);
        let px = x % 1_000_000;
        x = lcg(x);
        let py = x % 1_000_000;
        x = lcg(x);
        let vx = x % 2001 - 1000;
        x = lcg(x);
        let vy = x % 2001 - 1000;
        ps.push(Particle { px, py, vx, vy });
    }
    for _ in 0..STEPS {
        for p in ps.iter_mut() {
            p.vy -= 1;
            p.px += p.vx;
            if p.px < 0 {
                p.px = -p.px;
                p.vx = -p.vx;
            } else if p.px > 1_000_000 {
                p.px = 2_000_000 - p.px;
                p.vx = -p.vx;
            }
            p.py += p.vy;
            if p.py < 0 {
                p.py = -p.py;
                p.vy = -p.vy;
            } else if p.py > 1_000_000 {
                p.py = 2_000_000 - p.py;
                p.vy = -p.vy;
            }
        }
    }
    let (mut sx, mut sy, mut e) = (0i64, 0i64, 0i64);
    for p in &ps {
        sx += p.px;
        sy += p.py;
        e += p.vx * p.vx + p.vy * p.vy;
    }
    println!(
        "particles {} steps {} sx {} sy {} energy {}",
        NP, STEPS, sx, sy, e
    );
}
