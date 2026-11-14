// Benchmarks Game spectral-norm.

fn a(i: usize, j: usize) -> f64 {
    1.0 / ((i + j) * (i + j + 1) / 2 + i + 1) as f64
}

fn av(v: &[f64], out: &mut [f64]) {
    for (i, o) in out.iter_mut().enumerate() {
        let mut s = 0.0;
        for (j, &x) in v.iter().enumerate() {
            s += a(i, j) * x;
        }
        *o = s;
    }
}

fn atv(v: &[f64], out: &mut [f64]) {
    for (i, o) in out.iter_mut().enumerate() {
        let mut s = 0.0;
        for (j, &x) in v.iter().enumerate() {
            s += a(j, i) * x;
        }
        *o = s;
    }
}

fn atav(v: &[f64], out: &mut [f64], tmp: &mut [f64]) {
    av(v, tmp);
    atv(tmp, out);
}

fn main() {
    let n: usize = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(2000);
    let mut u = vec![1.0; n];
    let mut v = vec![0.0; n];
    let mut tmp = vec![0.0; n];
    for _ in 0..10 {
        atav(&u, &mut v, &mut tmp);
        atav(&v, &mut u, &mut tmp);
    }
    let mut vbv = 0.0;
    let mut vv = 0.0;
    for i in 0..n {
        vbv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    println!("{:.9}", (vbv / vv).sqrt());
}
