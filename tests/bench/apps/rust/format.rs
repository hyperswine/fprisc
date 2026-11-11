// format: string building (SPEC.md)
const N: i64 = 1_000_000;
const M: i64 = 1_000_000_007;

fn main() {
    let mut lines: Vec<String> = Vec::with_capacity(N as usize);
    for i in 0..N {
        let c = (i * 7919) % 10007;
        let q = i % 17 + 1;
        let cents = (i * 104729) % 1_000_000;
        let s = match i % 3 {
            0 => "open",
            1 => "paid",
            _ => "shipped",
        };
        lines.push(format!(
            "order {} cust c{} qty {} total {}.{:02} status {}",
            i, c, q, cents / 100, cents % 100, s
        ));
    }
    let mut bytes: i64 = 0;
    let mut h: i64 = 0;
    for l in &lines {
        let len = l.len() as i64;
        bytes += len;
        h = (h * 31 + len) % M;
    }
    println!("lines {} bytes {} hash {}", N, bytes, h);
    println!("{}", lines[0]);
    println!("{}", lines[499_999]);
    println!("{}", lines[999_999]);
}
