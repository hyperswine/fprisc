// Benchmarks Game k-nucleotide: std HashMap keyed by the k-mer packed
// two bits per base into a u64.
use std::collections::HashMap;
use std::fmt::Write as _;
use std::fs::File;
use std::io::{BufRead, BufReader};

fn code(c: u8) -> u64 {
    match c {
        b'A' => 0,
        b'C' => 1,
        b'G' => 2,
        _ => 3, // b'T'
    }
}

fn pack(s: &[u8]) -> u64 {
    s.iter().fold(0, |k, &c| (k << 2) | code(c))
}

fn unpack(mut key: u64, k: usize) -> String {
    let mut v = vec![0u8; k];
    for i in (0..k).rev() {
        v[i] = b"ACGT"[(key & 3) as usize];
        key >>= 2;
    }
    String::from_utf8(v).unwrap()
}

fn count(seq: &[u8], k: usize) -> HashMap<u64, u32> {
    let mut map = HashMap::new();
    if seq.len() < k {
        return map;
    }
    let mask = if k == 32 { !0 } else { (1u64 << (2 * k)) - 1 };
    let mut key = pack(&seq[..k - 1]);
    for &c in &seq[k - 1..] {
        key = ((key << 2) | code(c)) & mask;
        *map.entry(key).or_insert(0) += 1;
    }
    map
}

fn frequencies(out: &mut String, seq: &[u8], k: usize) {
    let map = count(seq, k);
    let mut list: Vec<(u64, u32)> = map.into_iter().collect();
    // A<C<G<T both packed and in ASCII, so packed order is string order.
    list.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let total = (seq.len() - k + 1) as f64;
    for (key, c) in list {
        writeln!(out, "{} {:.3}", unpack(key, k), 100.0 * c as f64 / total).unwrap();
    }
    out.push('\n');
}

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "data/fasta-1000000.txt".to_string());
    let reader = BufReader::new(File::open(&path).expect("open input"));
    let mut seq = Vec::new();
    let mut in_three = false;
    for line in reader.split(b'\n') {
        let line = line.unwrap();
        if line.first() == Some(&b'>') {
            if in_three {
                break;
            }
            in_three = line.starts_with(b">THREE");
            continue;
        }
        if in_three {
            seq.extend(line.iter().filter(|&&c| c != b'\r').map(|c| c.to_ascii_uppercase()));
        }
    }

    let mut out = String::new();
    frequencies(&mut out, &seq, 1);
    frequencies(&mut out, &seq, 2);
    for q in ["GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"] {
        let map = count(&seq, q.len());
        let c = map.get(&pack(q.as_bytes())).copied().unwrap_or(0);
        writeln!(out, "{}\t{}", c, q).unwrap();
    }
    print!("{}", out);
}
