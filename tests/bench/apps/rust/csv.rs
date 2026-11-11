// csv: parse and aggregate (SPEC.md)
use std::collections::HashMap;
use std::env;
use std::fs;

struct Agg {
    count: i64,
    sum_a: i64,
    max_b: i64,
}

fn main() {
    let path = env::args().nth(1).unwrap_or_else(|| "data/sales.csv".to_string());
    let text = fs::read_to_string(&path).expect("read input");
    let mut map: HashMap<&str, Agg> = HashMap::new();
    let mut lines: i64 = 0;
    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        let mut fields = line.split(',');
        let key = fields.next().unwrap();
        let a: i64 = fields.next().unwrap().parse().unwrap();
        let b: i64 = fields.next().unwrap().parse().unwrap();
        let e = map.entry(key).or_insert(Agg { count: 0, sum_a: 0, max_b: 0 });
        e.count += 1;
        e.sum_a += a;
        if b > e.max_b {
            e.max_b = b;
        }
        lines += 1;
    }
    let mut v: Vec<(&str, &Agg)> = map.iter().map(|(k, a)| (*k, a)).collect();
    v.sort_by(|x, y| y.1.sum_a.cmp(&x.1.sum_a).then_with(|| x.0.cmp(y.0)));
    println!("keys {} lines {}", v.len(), lines);
    for (k, a) in v.iter().take(10) {
        println!("{} {} {} {}", k, a.count, a.sum_a, a.max_b);
    }
}
