// Benchmarks Game fasta.
use std::io::{self, BufWriter, Write};

const LINE: usize = 60;
const IM: u32 = 139968;
const IA: u32 = 3877;
const IC: u32 = 29573;

const ALU: &[u8] = b"GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGG\
TCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGG\
GCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAG\
GCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";

const IUB: &[(u8, f64)] = &[
    (b'a', 0.27), (b'c', 0.12), (b'g', 0.12), (b't', 0.27),
    (b'B', 0.02), (b'D', 0.02), (b'H', 0.02), (b'K', 0.02), (b'M', 0.02),
    (b'N', 0.02), (b'R', 0.02), (b'S', 0.02), (b'V', 0.02), (b'W', 0.02), (b'Y', 0.02),
];

const HOMOSAPIENS: &[(u8, f64)] = &[
    (b'a', 0.3029549426680), (b'c', 0.1979883004921),
    (b'g', 0.1975473066391), (b't', 0.3015094502008),
];

struct Rng {
    seed: u32,
}

impl Rng {
    fn next(&mut self) -> f64 {
        self.seed = (self.seed * IA + IC) % IM;
        self.seed as f64 / IM as f64
    }
}

fn repeat<W: Write>(out: &mut W, s: &[u8], mut n: usize) -> io::Result<()> {
    let mut k = 0;
    let mut line = Vec::with_capacity(LINE + 1);
    while n > 0 {
        let m = n.min(LINE);
        line.clear();
        for _ in 0..m {
            line.push(s[k]);
            k += 1;
            if k == s.len() {
                k = 0;
            }
        }
        line.push(b'\n');
        out.write_all(&line)?;
        n -= m;
    }
    Ok(())
}

fn random<W: Write>(out: &mut W, rng: &mut Rng, table: &[(u8, f64)], mut n: usize) -> io::Result<()> {
    let mut acc = 0.0;
    let cum: Vec<(u8, f64)> = table.iter().map(|&(c, p)| { acc += p; (c, acc) }).collect();
    let last = cum.len() - 1;
    let mut line = Vec::with_capacity(LINE + 1);
    while n > 0 {
        let m = n.min(LINE);
        line.clear();
        for _ in 0..m {
            let r = rng.next();
            let j = cum[..last].iter().position(|&(_, p)| p > r).unwrap_or(last);
            line.push(cum[j].0);
        }
        line.push(b'\n');
        out.write_all(&line)?;
        n -= m;
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let n: usize = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(2_500_000);
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let mut rng = Rng { seed: 42 };
    out.write_all(b">ONE Homo sapiens alu\n")?;
    repeat(&mut out, ALU, 2 * n)?;
    out.write_all(b">TWO IUB ambiguity codes\n")?;
    random(&mut out, &mut rng, IUB, 3 * n)?;
    out.write_all(b">THREE Homo sapiens frequency\n")?;
    random(&mut out, &mut rng, HOMOSAPIENS, 5 * n)?;
    out.flush()
}
