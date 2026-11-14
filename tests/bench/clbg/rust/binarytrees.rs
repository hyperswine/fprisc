// Benchmarks Game binarytrees: one Box per node, dropped when unused.

struct Node {
    left: Option<Box<Node>>,
    right: Option<Box<Node>>,
}

fn make(d: u32) -> Box<Node> {
    if d == 0 {
        Box::new(Node { left: None, right: None })
    } else {
        Box::new(Node { left: Some(make(d - 1)), right: Some(make(d - 1)) })
    }
}

fn check(t: &Option<Box<Node>>) -> u64 {
    match t {
        None => 0,
        Some(n) => 1 + check(&n.left) + check(&n.right),
    }
}

fn main() {
    let n: u32 = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(18);
    let min_depth = 4;
    let max_depth = n.max(min_depth + 2);
    let stretch = max_depth + 1;

    let mut out = String::new();
    use std::fmt::Write;
    writeln!(out, "stretch tree of depth {}\t check: {}", stretch, check(&Some(make(stretch)))).unwrap();

    let long_lived = Some(make(max_depth));
    let mut d = min_depth;
    while d <= max_depth {
        let iters: u64 = 1 << (max_depth - d + min_depth);
        let mut sum = 0;
        for _ in 0..iters {
            sum += check(&Some(make(d)));
        }
        writeln!(out, "{}\t trees of depth {}\t check: {}", iters, d, sum).unwrap();
        d += 2;
    }
    writeln!(out, "long lived tree of depth {}\t check: {}", max_depth, check(&long_lived)).unwrap();
    print!("{}", out);
}
