// Benchmarks Game reverse-complement.
use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Write};

fn complement_table() -> [u8; 256] {
    let mut t = [0u8; 256];
    for (i, x) in t.iter_mut().enumerate() {
        *x = i as u8;
    }
    let from = b"ACGTUMRWSYKVHDBN";
    let to = b"TGCAAKYWSRMBDHVN";
    for (&f, &c) in from.iter().zip(to.iter()) {
        t[f as usize] = c;
        t[f.to_ascii_lowercase() as usize] = c;
    }
    t
}

fn flush<W: Write>(out: &mut W, comp: &[u8; 256], seq: &[u8]) -> io::Result<()> {
    let mut line = Vec::with_capacity(61);
    for chunk in seq.rchunks(60) {
        line.clear();
        line.extend(chunk.iter().rev().map(|&c| comp[c as usize]));
        line.push(b'\n');
        out.write_all(&line)?;
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let path = std::env::args().nth(1).unwrap_or_else(|| "data/fasta-2500000.txt".to_string());
    let reader = BufReader::new(File::open(&path)?);
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let comp = complement_table();
    let mut seq: Vec<u8> = Vec::new();
    for line in reader.split(b'\n') {
        let mut line = line?;
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        if line.first() == Some(&b'>') {
            flush(&mut out, &comp, &seq)?;
            seq.clear();
            out.write_all(&line)?;
            out.write_all(b"\n")?;
        } else {
            seq.extend_from_slice(&line);
        }
    }
    flush(&mut out, &comp, &seq)?;
    out.flush()
}
