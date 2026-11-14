// Benchmarks Game mandelbrot: binary PBM, scalar, single-threaded.
use std::io::Write;

fn main() {
    let n: usize = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(4000);
    let row_bytes = (n + 7) / 8;
    let mut out = Vec::with_capacity(row_bytes * n + 32);
    write!(out, "P4\n{} {}\n", n, n).unwrap();
    let nf = n as f64;
    for y in 0..n {
        let ci = 2.0 * y as f64 / nf - 1.0;
        let mut row = vec![0u8; row_bytes];
        for x in 0..n {
            let cr = 2.0 * x as f64 / nf - 1.5;
            let (mut zr, mut zi, mut tr, mut ti) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
            let mut i = 0;
            while i < 50 && tr + ti <= 4.0 {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
                i += 1;
            }
            if tr + ti <= 4.0 {
                row[x >> 3] |= 0x80 >> (x & 7);
            }
        }
        out.extend_from_slice(&row);
    }
    std::io::stdout().lock().write_all(&out).unwrap();
}
