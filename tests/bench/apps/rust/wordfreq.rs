// wordfreq: word counts, top 10 (SPEC.md)
use std::collections::HashMap;
use std::env;
use std::fs;

fn main() {
    let path = env::args().nth(1).unwrap_or_else(|| "data/corpus.txt".to_string());
    let text = fs::read_to_string(&path).expect("read input");
    let mut counts: HashMap<&str, i64> = HashMap::new();
    let mut total: i64 = 0;
    for w in text.split_ascii_whitespace() {
        *counts.entry(w).or_insert(0) += 1;
        total += 1;
    }
    let mut v: Vec<(&str, i64)> = counts.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    println!("distinct {} total {}", v.len(), total);
    for (w, c) in v.iter().take(10) {
        println!("{} {}", w, c);
    }
}
