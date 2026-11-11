// treemap: ordered map inserts and lookups (SPEC.md)
use std::collections::BTreeMap;

const M: i64 = 1_000_000_007;

fn lcg(x: i64) -> i64 {
    (x * 1103515245 + 12345) % 2147483648
}

fn main() {
    let mut map: BTreeMap<i64, i64> = BTreeMap::new();
    let mut x: i64 = 7;
    for i in 0..500_000i64 {
        x = lcg(x);
        map.insert(x % 1_000_000, i);
    }
    let mut hits: i64 = 0;
    let mut sum: i64 = 0;
    for _ in 0..500_000 {
        x = lcg(x);
        if let Some(v) = map.get(&(x % 1_000_000)) {
            hits += 1;
            sum += *v;
        }
    }
    let mut k: i64 = 0;
    for key in map.keys() {
        k = (k * 31 + key) % M;
    }
    println!("size {} hits {} sum {} keyhash {}", map.len(), hits, sum, k);
}
