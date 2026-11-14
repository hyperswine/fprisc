// Benchmarks Game fannkuch-redux, single-threaded.

fn main() {
    let n: usize = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(10);
    let mut perm1: Vec<usize> = (0..n).collect();
    let mut perm = vec![0usize; n];
    let mut count = vec![0usize; n];
    let mut max_flips = 0;
    let mut checksum: i64 = 0;
    let mut perm_index: u64 = 0;
    let mut r = n;
    loop {
        while r != 1 {
            count[r - 1] = r;
            r -= 1;
        }
        perm.copy_from_slice(&perm1);
        let mut flips = 0;
        let mut k = perm[0];
        while k != 0 {
            perm[..=k].reverse();
            flips += 1;
            k = perm[0];
        }
        max_flips = max_flips.max(flips);
        checksum += if perm_index % 2 == 0 { flips as i64 } else { -(flips as i64) };

        loop {
            if r == n {
                println!("{}\nPfannkuchen({}) = {}", checksum, n, max_flips);
                return;
            }
            let p0 = perm1[0];
            for i in 0..r {
                perm1[i] = perm1[i + 1];
            }
            perm1[r] = p0;
            count[r] -= 1;
            if count[r] > 0 {
                break;
            }
            r += 1;
        }
        perm_index += 1;
    }
}
